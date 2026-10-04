//! The system tray: StatusNotifierItem (SNI) on the session bus.
//!
//! kwm is the StatusNotifierWatcher when it gets the name
//! org.kde.StatusNotifierWatcher. When an other program has the name, kwm
//! waits in the queue for the name, and until then it is a
//! StatusNotifierHost of the other watcher. In the two cases, kwm keeps the
//! list of the items and their properties.
//!
//! sd-bus calls the callbacks of this file from `dispatch`, in the event loop.

const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const log = std.log.scoped(.tray);

const posix = @import("posix");
const pixman = @import("pixman");

const sd = @import("sd_bus.zig");
const icons = @import("icons.zig");
const tray_menu = @import("tray_menu.zig");
pub const MenuPlace = tray_menu.Place;
const types = @import("types.zig");
const Context = @import("context.zig");

const ctx = Context.get();

const watcher_name = "org.kde.StatusNotifierWatcher";
const watcher_path = "/StatusNotifierWatcher";
const watcher_interface = "org.kde.StatusNotifierWatcher";
const item_interface = "org.kde.StatusNotifierItem";
const default_item_path = "/StatusNotifierItem";
const dbus_name = "org.freedesktop.DBus";
const dbus_path = "/org/freedesktop/DBus";
const properties_interface = "org.freedesktop.DBus.Properties";

/// Maximum time for a reply. A tray item that does not answer must not stop
/// the tray for long.
const call_timeout_usec = 5 * std.time.us_per_s;

pub const Status = enum { passive, active, needs_attention };

pub const Pixmap = struct {
    width: i32,
    height: i32,
    /// ARGB32 in network byte order, as the SNI specification gives it.
    data: []const u8,
};

pub const Properties = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    status: Status = .active,
    icon_name: []const u8 = "",
    icon_theme_path: []const u8 = "",
    icon_pixmap: []const Pixmap = &.{},
    attention_icon_name: []const u8 = "",
    attention_icon_pixmap: []const Pixmap = &.{},
    tooltip_title: []const u8 = "",
    tooltip_text: []const u8 = "",
    item_is_menu: bool = false,
    /// The object path of the com.canonical.dbusmenu menu.
    menu: []const u8 = "",
};

pub const Item = struct {
    /// The bus name of the item: a well-known name or a unique name.
    service: [:0]const u8,
    path: [:0]const u8,
    /// `service` and `path` together. The watcher uses this name.
    key: [:0]const u8,
    signal_slot: ?*sd.Slot = null,
    call_slot: ?*sd.Slot = null,
    /// The call of a click, and its method.
    action_slot: ?*sd.Slot = null,
    action: [:0]const u8 = "",
    /// The position of the last click, and the place of the icon, for the
    /// menu after Activate fails.
    click_x: i32 = 0,
    click_y: i32 = 0,
    click_place: MenuPlace = .{ .x = 0, .y = 0, .right = 0 },
    /// The scroll that is not sent yet. Refer to `scroll`.
    scroll_value: f64 = 0,
    /// The image of the last pixmap that the bar drew, and that pixmap.
    image: ?*pixman.Image = null,
    image_source: ?*const Pixmap = null,
    /// A signal came while a call was pending. Get the properties again.
    stale: bool = false,
    /// The item gave its properties one time or more.
    ready: bool = false,
    /// The memory of `props`.
    arena: std.heap.ArenaAllocator,
    props: Properties = .{},

    fn create(service: []const u8, path: []const u8) !*Item {
        const self = try ctx.gpa.create(Item);
        errdefer ctx.gpa.destroy(self);
        const service_z = try ctx.gpa.dupeZ(u8, service);
        errdefer ctx.gpa.free(service_z);
        const path_z = try ctx.gpa.dupeZ(u8, path);
        errdefer ctx.gpa.free(path_z);
        const key = try mem.concatWithSentinel(ctx.gpa, u8, &.{ service, path }, 0);
        self.* = .{
            .service = service_z,
            .path = path_z,
            .key = key,
            .arena = .init(ctx.gpa),
        };
        return self;
    }

    fn destroy(self: *Item) void {
        _ = sd.sd_bus_slot_unref(self.signal_slot);
        _ = sd.sd_bus_slot_unref(self.call_slot);
        _ = sd.sd_bus_slot_unref(self.action_slot);
        self.drop_image();
        self.arena.deinit();
        ctx.gpa.free(self.key);
        ctx.gpa.free(self.path);
        ctx.gpa.free(self.service);
        ctx.gpa.destroy(self);
    }

    fn drop_image(self: *Item) void {
        if (self.image) |image| _ = image.unref();
        self.image = null;
        self.image_source = null;
    }

    /// The icon of the item for a square of `size` physical pixels: the
    /// icon name in the icon theme, else the pixmap. With the status
    /// NeedsAttention, the attention icon comes first.
    pub fn icon(self: *Item, size: i32) ?*pixman.Image {
        const props = &self.props;
        const attention = props.status == .needs_attention;
        if (attention and props.attention_icon_name.len > 0) {
            if (icons.get(props.attention_icon_name, props.icon_theme_path, size)) |image| return image;
        }
        if (!attention or props.attention_icon_pixmap.len == 0) {
            if (icons.get(props.icon_name, props.icon_theme_path, size)) |image| return image;
        }
        return self.pixmap_image(size);
    }

    /// The icon from the pixmaps of the item, for a square of `size`
    /// physical pixels: the smallest pixmap that is not smaller, else the
    /// largest pixmap. With the status NeedsAttention, the attention pixmaps
    /// come first. null: no pixmaps.
    pub fn pixmap_image(self: *Item, size: i32) ?*pixman.Image {
        const pixmaps =
            if (self.props.status == .needs_attention and self.props.attention_icon_pixmap.len > 0)
                self.props.attention_icon_pixmap
            else self.props.icon_pixmap;
        if (pixmaps.len == 0) return null;

        var best = &pixmaps[0];
        for (pixmaps[1..]) |*pixmap| {
            const best_fits = @max(best.width, best.height) >= size;
            const fits = @max(pixmap.width, pixmap.height) >= size;
            if (fits and (!best_fits or pixmap.width < best.width)) best = pixmap;
            if (!fits and !best_fits and pixmap.width > best.width) best = pixmap;
        }
        if (self.image_source != best) {
            self.drop_image();
            self.image = to_image(best);
            self.image_source = best;
        }
        return self.image;
    }

    /// The first letter of the id or the title, as upper case. The bar shows
    /// it when the item has no icon.
    pub fn letter(self: *const Item) []const u8 {
        const name = if (self.props.id.len > 0) self.props.id else self.props.title;
        if (name.len == 0) return "?";
        const n = std.unicode.utf8ByteSequenceLength(name[0]) catch return "?";
        if (n > name.len) return "?";
        if (n == 1) return upper[std.ascii.toUpper(name[0])..][0..1];
        return name[0..n];
    }

    /// The tooltip text: the title, and on the next lines the text without
    /// markup. Without a tooltip, the title or the id.
    pub fn tooltip(self: *const Item, buffer: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(buffer);
        const props = &self.props;
        const title =
            if (props.tooltip_title.len > 0) props.tooltip_title
            else if (props.title.len > 0) props.title
            else props.id;
        w.writeAll(mem.trim(u8, title, " \n")) catch return w.buffered();
        if (props.tooltip_text.len > 0) {
            w.writeByte('\n') catch return w.buffered();
            write_without_markup(&w, props.tooltip_text) catch {};
        }
        return mem.trimEnd(u8, w.buffered(), " \n");
    }
};

/// All bytes, so that `upper[c..][0..1]` is the byte c.
const upper = blk: {
    var bytes: [256]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = i;
    break :blk bytes;
};


/// Convert a pixmap (ARGB32 in network byte order) to a pixman image with
/// premultiplied alpha.
fn to_image(pixmap: *const Pixmap) ?*pixman.Image {
    const image = pixman.Image.createBits(.a8r8g8b8, pixmap.width, pixmap.height, null, 0) orelse return null;
    const data = image.getData() orelse {
        _ = image.unref();
        return null;
    };
    const width: usize = @intCast(pixmap.width);
    const height: usize = @intCast(pixmap.height);
    const stride: usize = @intCast(@divExact(image.getStride(), 4));
    for (0..height) |row| {
        for (0..width) |col| {
            const p = pixmap.data[(row * width + col) * 4 ..][0..4];
            const a: u32 = p[0];
            const r: u32 = @as(u32, p[1]) * a / 255;
            const g: u32 = @as(u32, p[2]) * a / 255;
            const b: u32 = @as(u32, p[3]) * a / 255;
            data[row * stride + col] = a << 24 | r << 16 | g << 8 | b;
        }
    }
    icons.desaturate(image);
    return image;
}


/// Write `text` without the HTML tags. <br> starts a new line. Decode the
/// usual entities.
fn write_without_markup(w: *std.Io.Writer, text: []const u8) !void {
    const entities = [_]struct { []const u8, u8 } {
        .{ "&amp;", '&' }, .{ "&lt;", '<' }, .{ "&gt;", '>' },
        .{ "&quot;", '"' }, .{ "&apos;", '\'' }, .{ "&#39;", '\'' }, .{ "&nbsp;", ' ' },
    };
    var i: usize = 0;
    outer: while (i < text.len) {
        switch (text[i]) {
            '<' => {
                const end = mem.indexOfScalarPos(u8, text, i, '>') orelse text.len - 1;
                const tag = text[i + 1 .. end];
                if (std.ascii.startsWithIgnoreCase(tag, "br")) try w.writeByte('\n');
                i = end + 1;
            },
            '&' => {
                for (entities) |entity| {
                    if (mem.startsWith(u8, text[i..], entity[0])) {
                        try w.writeByte(entity[1]);
                        i += entity[0].len;
                        continue :outer;
                    }
                }
                try w.writeByte('&');
                i += 1;
            },
            else => |c| {
                try w.writeByte(c);
                i += 1;
            },
        }
    }
}

var bus: ?*sd.Bus = null;
var unique_name: []const u8 = "";
/// The slots of the watcher object and of the signal matches.
var slots: std.ArrayList(*sd.Slot) = .empty;
/// kwm has the name org.kde.StatusNotifierWatcher.
var watcher = false;
var host_name_buffer: [64]u8 = undefined;
var items: std.ArrayList(*Item) = .empty;


/// Connect to the session bus and start the watcher or the host.
pub fn init() void {
    if (bus != null) return;
    open() catch |err| {
        log.err("start the tray failed: {}", .{ err });
        deinit();
    };
}


pub fn deinit() void {
    for (items.items) |item| item.destroy();
    items.clearAndFree(ctx.gpa);
    for (slots.items) |slot| _ = sd.sd_bus_slot_unref(slot);
    slots.clearAndFree(ctx.gpa);
    tray_menu.close();
    watcher = false;
    unique_name = "";
    bus = sd.sd_bus_flush_close_unref(bus);
    icons.reset();
}


/// Start or stop the tray after a change of the configuration.
pub fn reload() void {
    // The icon theme and the saturation can change.
    icons.reset();
    for (items.items) |item| item.drop_image();
    if (ctx.cfg.bar.tray == null) deinit() else init();
    changed();
}


/// The items that the bar shows, in the order of registration: the items
/// that gave their properties, without the passive items.
pub fn visible_items(buffer: []*Item) []*Item {
    const cfg = ctx.cfg.bar.tray orelse return buffer[0..0];
    var n: usize = 0;
    for (items.items) |item| {
        if (!item.ready or n == buffer.len) continue;
        if (item.props.status == .passive and !cfg.show_passive) continue;
        buffer[n] = item;
        n += 1;
    }
    return buffer[0..n];
}


/// The item at this address, when it still exists.
pub fn find(ptr: *const anyopaque) ?*Item {
    for (items.items) |item| {
        if (@as(*const anyopaque, item) == ptr) return item;
    }
    return null;
}


/// A click on an item. `x` and `y` are the global position of the pointer,
/// and `place` is the place of the icon for the menu. The left button
/// activates the item, or shows its menu when the item is only a menu. The
/// right button shows the menu.
pub fn click(item: *Item, button: types.Button, x: i32, y: i32, place: MenuPlace) void {
    item.click_x = x;
    item.click_y = y;
    item.click_place = place;
    switch (button) {
        .left => if (item.props.item_is_menu) show_menu(item) else call_action(item, "Activate"),
        .middle => call_action(item, "SecondaryActivate"),
        .right => show_menu(item),
        else => {},
    }
}


/// Show the dbusmenu of the item in the menu program. An item without a
/// dbusmenu gets ContextMenu, and shows its menu itself.
fn show_menu(item: *Item) void {
    const b = bus orelse return;
    if (item.props.menu.len == 0 or mem.eql(u8, item.props.menu, "/")) {
        call_action(item, "ContextMenu");
        return;
    }
    const props = &item.props;
    const title =
        if (props.title.len > 0) props.title
        else if (props.tooltip_title.len > 0) props.tooltip_title
        else props.id;
    log.debug("{s}: menu {s}", .{ item.key, props.menu });
    tray_menu.open(b, item.service, props.menu, title, item.click_place);
}


fn call_action(item: *Item, method: [:0]const u8) void {
    log.debug("{s}: {s}({}, {})", .{ item.key, method, item.click_x, item.click_y });
    item.action_slot = sd.sd_bus_slot_unref(item.action_slot);
    item.action = method;
    _ = sd.check(sd.sd_bus_call_method_async(
        bus orelse return, &item.action_slot, item.service, item.path, item_interface, method.ptr,
        on_action, item, "ii", @as(c_int, item.click_x), @as(c_int, item.click_y),
    ), "call an item") catch {};
}


fn on_action(m: *sd.Message, userdata: ?*anyopaque, _: *sd.Error) callconv(.c) c_int {
    const item: *Item = @ptrCast(@alignCast(userdata.?));
    item.action_slot = sd.sd_bus_slot_unref(item.action_slot);
    const err = sd.sd_bus_message_get_error(m) orelse return 0;
    const name = mem.span(err.name orelse "");
    // Items that cannot activate show their menu.
    if (mem.eql(u8, name, "org.freedesktop.DBus.Error.UnknownMethod") and mem.eql(u8, item.action, "Activate")) {
        show_menu(item);
        return 0;
    }
    log.warn("{s}: the call failed: {s}", .{ item.key, reply_error(m).? });
    return 0;
}


/// Scroll on an item. `value` is the axis value of wl_pointer: positive is
/// down. One wheel step is 15, and gives Scroll(1, "vertical") down or
/// Scroll(-1, "vertical") up.
pub fn scroll(item: *Item, value: f64) void {
    const b = bus orelse return;
    item.scroll_value += value;
    while (@abs(item.scroll_value) >= 15) {
        const down = item.scroll_value > 0;
        item.scroll_value -= if (down) 15 else -15;
        _ = sd.sd_bus_call_method_async(
            b, null, item.service, item.path, item_interface, "Scroll",
            null, null, "is", @as(c_int, if (down) 1 else -1), "vertical",
        );
    }
}


/// The file descriptor of the bus, for poll.
pub fn poll_fd() ?posix.pollfd {
    const b = bus orelse return null;
    const events = sd.sd_bus_get_events(b);
    if (events < 0) return null;
    return .{ .fd = sd.sd_bus_get_fd(b), .events = @intCast(events), .revents = 0 };
}


/// Milliseconds until sd-bus must run, for example for the timeout of a
/// call. null: sd-bus waits only for the file descriptor.
pub fn timeout() ?i64 {
    const b = bus orelse return null;
    var usec: u64 = undefined;
    if (sd.sd_bus_get_timeout(b, &usec) < 0 or usec == std.math.maxInt(u64)) return null;
    const now: i64 = Io.Timestamp.now(ctx.io, .awake).toMicroseconds();
    const left: i64 = @as(i64, @intCast(@min(usec, std.math.maxInt(i64)))) - now;
    return @max(0, std.math.divCeil(i64, left, std.time.us_per_ms) catch 0);
}


/// Read and write the bus, and run the callbacks.
pub fn dispatch() void {
    while (bus) |b| {
        const rc = sd.sd_bus_process(b, null);
        if (rc == 0) break;
        if (rc < 0) {
            log.err("the session bus failed: errno {}. Stop the tray.", .{ -rc });
            deinit();
            changed();
            break;
        }
    }
}


fn open() !void {
    var b: ?*sd.Bus = null;
    _ = try sd.check(sd.sd_bus_open_user(&b), "sd_bus_open_user");
    bus = b;
    _ = try sd.check(sd.sd_bus_set_method_call_timeout(b.?, call_timeout_usec), "sd_bus_set_method_call_timeout");

    var unique: ?[*:0]const u8 = null;
    _ = try sd.check(sd.sd_bus_get_unique_name(b.?, &unique), "sd_bus_get_unique_name");
    unique_name = mem.span(unique.?);

    var slot: ?*sd.Slot = null;
    _ = try sd.check(sd.sd_bus_add_object(b.?, &slot, watcher_path, on_watcher_call, null), "sd_bus_add_object");
    try keep(slot);

    try match(dbus_name, dbus_path, dbus_name, "NameOwnerChanged", on_name_owner_changed);
    try match(dbus_name, null, dbus_name, "NameAcquired", on_name_acquired);
    try match(dbus_name, null, dbus_name, "NameLost", on_name_lost);
    try match(watcher_name, watcher_path, watcher_interface, "StatusNotifierItemRegistered", on_watcher_signal);
    try match(watcher_name, watcher_path, watcher_interface, "StatusNotifierItemUnregistered", on_watcher_signal);

    // Without DO_NOT_QUEUE: when an other watcher has the name, kwm gets the
    // name when the other watcher stops.
    _ = try sd.check(
        sd.sd_bus_request_name_async(b.?, &slot, watcher_name, sd.NAME_QUEUE, on_request_watcher, null),
        "request " ++ watcher_name,
    );
    try keep(slot);

    log.info("connected to the session bus as {s}", .{ unique_name });
}


fn keep(slot: ?*sd.Slot) !void {
    const s = slot orelse return;
    slots.append(ctx.gpa, s) catch |err| {
        _ = sd.sd_bus_slot_unref(s);
        return err;
    };
}


fn match(sender: [*:0]const u8, path: ?[*:0]const u8, interface: [*:0]const u8, member: [*:0]const u8, callback: sd.MessageHandler) !void {
    var slot: ?*sd.Slot = null;
    _ = try sd.check(
        sd.sd_bus_match_signal_async(bus.?, &slot, sender, path, interface, member, callback, null, null),
        "sd_bus_match_signal_async",
    );
    try keep(slot);
}


fn reply_error(m: *sd.Message) ?[*:0]const u8 {
    const err = sd.sd_bus_message_get_error(m) orelse return null;
    return err.message orelse err.name orelse "unknown error";
}


fn read_string(m: *sd.Message) ?[]const u8 {
    var s: ?[*:0]const u8 = null;
    if (sd.sd_bus_message_read_basic(m, 's', @ptrCast(&s)) <= 0) return null;
    return mem.span(s orelse return null);
}


// The watcher and the host.

fn on_request_watcher(m: *sd.Message, _: ?*anyopaque, _: *sd.Error) callconv(.c) c_int {
    if (reply_error(m)) |err| {
        log.err("request {s} failed: {s}", .{ watcher_name, err });
        become_host();
        return 0;
    }
    var result: u32 = 0;
    _ = sd.sd_bus_message_read_basic(m, 'u', @ptrCast(&result));
    switch (result) {
        // Primary owner, or already owner. NameAcquired can come first.
        1, 4 => if (!watcher) become_watcher(),
        else => {
            log.info("an other program is the watcher. kwm is a host until it gets {s}", .{ watcher_name });
            become_host();
        },
    }
    return 0;
}


fn on_name_acquired(m: *sd.Message, _: ?*anyopaque, _: *sd.Error) callconv(.c) c_int {
    const name = read_string(m) orelse return 0;
    if (mem.eql(u8, name, watcher_name) and !watcher) become_watcher();
    return 0;
}


fn on_name_lost(m: *sd.Message, _: ?*anyopaque, _: *sd.Error) callconv(.c) c_int {
    const name = read_string(m) orelse return 0;
    if (mem.eql(u8, name, watcher_name) and watcher) {
        log.warn("lost {s}", .{ watcher_name });
        watcher = false;
        become_host();
    }
    return 0;
}


fn become_watcher() void {
    log.info("kwm is the watcher", .{});
    watcher = true;
    // The items look for a host before they show. The items that are
    // registered with the old watcher register again with kwm.
    _ = sd.sd_bus_emit_signal(bus.?, watcher_path, watcher_interface, "StatusNotifierHostRegistered", null);
}


/// Register as a host with the other watcher, and get its items.
fn become_host() void {
    const b = bus orelse return;
    const host_name = std.fmt.bufPrintZ(
        &host_name_buffer,
        "org.kde.StatusNotifierHost-{}",
        .{ std.c.getpid() },
    ) catch unreachable;
    _ = sd.sd_bus_request_name_async(b, null, host_name, 0, null, null);
    _ = sd.sd_bus_call_method_async(
        b, null, watcher_name, watcher_path, watcher_interface, "RegisterStatusNotifierHost",
        null, null, "s", host_name.ptr,
    );
    _ = sd.sd_bus_call_method_async(
        b, null, watcher_name, watcher_path, properties_interface, "Get",
        on_registered_items, null, "ss", watcher_interface, "RegisteredStatusNotifierItems",
    );
}


fn on_registered_items(m: *sd.Message, _: ?*anyopaque, _: *sd.Error) callconv(.c) c_int {
    if (reply_error(m)) |err| {
        log.warn("get the items of the watcher failed: {s}", .{ err });
        return 0;
    }
    if (sd.sd_bus_message_enter_container(m, 'v', "as") <= 0) return 0;
    if (sd.sd_bus_message_enter_container(m, 'a', "s") <= 0) return 0;
    while (read_string(m)) |registration| add_item(registration, null);
    return 0;
}


/// StatusNotifierItemRegistered and StatusNotifierItemUnregistered of the
/// other watcher.
fn on_watcher_signal(m: *sd.Message, _: ?*anyopaque, _: *sd.Error) callconv(.c) c_int {
    // kwm also gets its own signals.
    if (watcher) return 0;
    const member = mem.span(sd.sd_bus_message_get_member(m) orelse return 0);
    const registration = read_string(m) orelse return 0;
    if (mem.eql(u8, member, "StatusNotifierItemRegistered")) {
        add_item(registration, null);
    } else for (items.items, 0..) |item, i| {
        if (mem.eql(u8, item.key, registration)) {
            remove_item(i);
            break;
        }
    }
    return 0;
}


fn on_name_owner_changed(m: *sd.Message, _: ?*anyopaque, _: *sd.Error) callconv(.c) c_int {
    var name_z: ?[*:0]const u8 = null;
    var old_z: ?[*:0]const u8 = null;
    var new_z: ?[*:0]const u8 = null;
    if (sd.sd_bus_message_read(m, "sss", &name_z, &old_z, &new_z) <= 0) return 0;
    const name = mem.span(name_z orelse return 0);
    const new_owner = mem.span(new_z orelse return 0);

    if (new_owner.len == 0) {
        // The program of the item stopped.
        var i = items.items.len;
        while (i > 0) {
            i -= 1;
            if (mem.eql(u8, items.items[i].service, name)) remove_item(i);
        }
    } else if (mem.eql(u8, name, watcher_name) and !mem.eql(u8, new_owner, unique_name)) {
        // An other program is the watcher now.
        become_host();
    }
    return 0;
}


/// The object /StatusNotifierWatcher.
fn on_watcher_call(m: *sd.Message, _: ?*anyopaque, _: *sd.Error) callconv(.c) c_int {
    return watcher_call(m) catch |err| {
        log.warn("watcher call {?s} failed: {}", .{ sd.sd_bus_message_get_member(m), err });
        return -1;
    };
}


fn watcher_call(m: *sd.Message) !c_int {
    if (sd.sd_bus_message_is_method_call(m, watcher_interface, "RegisterStatusNotifierItem") > 0) {
        const registration = read_string(m) orelse return error.InvalidArgs;
        add_item(registration, sd.sd_bus_message_get_sender(m));
        _ = try sd.check(sd.sd_bus_reply_method_return(m, null), "reply");
        return 1;
    }
    if (sd.sd_bus_message_is_method_call(m, watcher_interface, "RegisterStatusNotifierHost") > 0) {
        _ = try sd.check(sd.sd_bus_reply_method_return(m, null), "reply");
        _ = sd.sd_bus_emit_signal(bus.?, watcher_path, watcher_interface, "StatusNotifierHostRegistered", null);
        return 1;
    }
    if (sd.sd_bus_message_is_method_call(m, properties_interface, "Get") > 0) {
        var interface: ?[*:0]const u8 = null;
        var property: ?[*:0]const u8 = null;
        _ = try sd.check(sd.sd_bus_message_read(m, "ss", &interface, &property), "read");

        var reply: ?*sd.Message = null;
        _ = try sd.check(sd.sd_bus_message_new_method_return(m, &reply), "new reply");
        defer _ = sd.sd_bus_message_unref(reply);
        if (!try append_property(reply.?, mem.span(property.?))) {
            _ = try sd.check(sd.sd_bus_reply_method_errorf(
                m, "org.freedesktop.DBus.Error.UnknownProperty", "Unknown property %s", property.?,
            ), "reply");
            return 1;
        }
        _ = try sd.check(sd.sd_bus_send(null, reply.?, null), "send");
        return 1;
    }
    if (sd.sd_bus_message_is_method_call(m, properties_interface, "GetAll") > 0) {
        var reply: ?*sd.Message = null;
        _ = try sd.check(sd.sd_bus_message_new_method_return(m, &reply), "new reply");
        defer _ = sd.sd_bus_message_unref(reply);
        _ = try sd.check(sd.sd_bus_message_open_container(reply.?, 'a', "{sv}"), "open");
        for ([_][:0]const u8 { "RegisteredStatusNotifierItems", "IsStatusNotifierHostRegistered", "ProtocolVersion" }) |property| {
            _ = try sd.check(sd.sd_bus_message_open_container(reply.?, 'e', "sv"), "open");
            _ = try sd.check(sd.sd_bus_message_append(reply.?, "s", property.ptr), "append");
            _ = try append_property(reply.?, property);
            _ = try sd.check(sd.sd_bus_message_close_container(reply.?), "close");
        }
        _ = try sd.check(sd.sd_bus_message_close_container(reply.?), "close");
        _ = try sd.check(sd.sd_bus_send(null, reply.?, null), "send");
        return 1;
    }
    if (sd.sd_bus_message_is_method_call(m, "org.freedesktop.DBus.Introspectable", "Introspect") > 0) {
        _ = try sd.check(sd.sd_bus_reply_method_return(m, "s", introspection.ptr), "reply");
        return 1;
    }
    return 0;
}


/// Append the value of a watcher property as a variant. Return false for an
/// unknown property.
fn append_property(m: *sd.Message, property: []const u8) !bool {
    if (mem.eql(u8, property, "RegisteredStatusNotifierItems")) {
        _ = try sd.check(sd.sd_bus_message_open_container(m, 'v', "as"), "open");
        _ = try sd.check(sd.sd_bus_message_open_container(m, 'a', "s"), "open");
        for (items.items) |item| {
            _ = try sd.check(sd.sd_bus_message_append(m, "s", item.key.ptr), "append");
        }
        _ = try sd.check(sd.sd_bus_message_close_container(m), "close");
        _ = try sd.check(sd.sd_bus_message_close_container(m), "close");
    } else if (mem.eql(u8, property, "IsStatusNotifierHostRegistered")) {
        _ = try sd.check(sd.sd_bus_message_append(m, "v", "b", @as(c_int, 1)), "append");
    } else if (mem.eql(u8, property, "ProtocolVersion")) {
        _ = try sd.check(sd.sd_bus_message_append(m, "v", "i", @as(c_int, 0)), "append");
    } else return false;
    return true;
}


const introspection =
    \\<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
    \\ "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
    \\<node>
    \\ <interface name="org.kde.StatusNotifierWatcher">
    \\  <method name="RegisterStatusNotifierItem"><arg name="service" type="s" direction="in"/></method>
    \\  <method name="RegisterStatusNotifierHost"><arg name="service" type="s" direction="in"/></method>
    \\  <property name="RegisteredStatusNotifierItems" type="as" access="read"/>
    \\  <property name="IsStatusNotifierHostRegistered" type="b" access="read"/>
    \\  <property name="ProtocolVersion" type="i" access="read"/>
    \\  <signal name="StatusNotifierItemRegistered"><arg type="s"/></signal>
    \\  <signal name="StatusNotifierItemUnregistered"><arg type="s"/></signal>
    \\  <signal name="StatusNotifierHostRegistered"/>
    \\  <signal name="StatusNotifierHostUnregistered"/>
    \\ </interface>
    \\ <interface name="org.freedesktop.DBus.Properties">
    \\  <method name="Get"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method>
    \\  <method name="GetAll"><arg type="s" direction="in"/><arg type="a{sv}" direction="out"/></method>
    \\ </interface>
    \\ <interface name="org.freedesktop.DBus.Introspectable">
    \\  <method name="Introspect"><arg type="s" direction="out"/></method>
    \\ </interface>
    \\</node>
    \\
;


// The items.

/// Add an item. `registration` is a bus name, a bus name and an object path,
/// or only an object path. With only an object path, the bus name is
/// `sender`.
fn add_item(registration: []const u8, sender: ?[*:0]const u8) void {
    const service: []const u8, const path: []const u8 =
        if (mem.startsWith(u8, registration, "/"))
            .{ mem.span(sender orelse return), registration }
        else if (mem.indexOfScalar(u8, registration, '/')) |i|
            .{ registration[0..i], registration[i..] }
        else
            .{ registration, default_item_path };

    for (items.items) |item| {
        if (mem.eql(u8, item.service, service) and mem.eql(u8, item.path, path)) return;
    }

    const item = Item.create(service, path) catch |err| {
        log.err("add item {s}{s} failed: {}", .{ service, path, err });
        return;
    };
    items.append(ctx.gpa, item) catch |err| {
        log.err("add item {s} failed: {}", .{ item.key, err });
        item.destroy();
        return;
    };
    log.info("item registered: {s}", .{ item.key });

    _ = sd.check(sd.sd_bus_match_signal_async(
        bus.?, &item.signal_slot, item.service, item.path, item_interface, null,
        on_item_signal, null, item,
    ), "match the signals of an item") catch {};
    get_properties(item);

    if (watcher) {
        _ = sd.sd_bus_emit_signal(bus.?, watcher_path, watcher_interface, "StatusNotifierItemRegistered", "s", item.key.ptr);
    }
}


fn remove_item(i: usize) void {
    const item = items.orderedRemove(i);
    defer item.destroy();
    log.info("item unregistered: {s}", .{ item.key });
    if (watcher) {
        _ = sd.sd_bus_emit_signal(bus.?, watcher_path, watcher_interface, "StatusNotifierItemUnregistered", "s", item.key.ptr);
    }
    changed();
}


fn get_properties(item: *Item) void {
    if (item.call_slot != null) {
        item.stale = true;
        return;
    }
    _ = sd.check(sd.sd_bus_call_method_async(
        bus.?, &item.call_slot, item.service, item.path, properties_interface, "GetAll",
        on_properties, item, "s", item_interface,
    ), "get the properties of an item") catch {};
}


fn on_item_signal(m: *sd.Message, userdata: ?*anyopaque, _: *sd.Error) callconv(.c) c_int {
    const item: *Item = @ptrCast(@alignCast(userdata.?));
    log.debug("{s}: {?s}", .{ item.key, sd.sd_bus_message_get_member(m) });
    get_properties(item);
    return 0;
}


fn on_properties(m: *sd.Message, userdata: ?*anyopaque, _: *sd.Error) callconv(.c) c_int {
    const item: *Item = @ptrCast(@alignCast(userdata.?));
    item.call_slot = sd.sd_bus_slot_unref(item.call_slot);

    if (reply_error(m)) |err| {
        log.warn("get the properties of {s} failed: {s}", .{ item.key, err });
        // An item that never answers is not a tray item.
        if (!item.ready) {
            const i = mem.indexOfScalar(*Item, items.items, item).?;
            remove_item(i);
        }
        return 0;
    }

    var arena: std.heap.ArenaAllocator = .init(ctx.gpa);
    const props = read_properties(m, arena.allocator()) catch |err| {
        log.warn("read the properties of {s} failed: {}", .{ item.key, err });
        arena.deinit();
        return 0;
    };
    item.drop_image();
    item.arena.deinit();
    item.arena = arena;
    item.props = props;
    item.ready = true;
    log.debug(
        "{s}: id \"{s}\", status {s}, icon \"{s}\", {} pixmaps, menu \"{s}\", item is menu: {}, tooltip \"{s}\"",
        .{
            item.key, props.id, @tagName(props.status), props.icon_name, props.icon_pixmap.len,
            props.menu, props.item_is_menu, props.tooltip_title,
        },
    );

    if (item.stale) {
        item.stale = false;
        get_properties(item);
    }
    changed();
    return 0;
}


/// Read the reply of GetAll: a{sv}.
fn read_properties(m: *sd.Message, a: mem.Allocator) !Properties {
    var props: Properties = .{};
    _ = try sd.check(sd.sd_bus_message_enter_container(m, 'a', "{sv}"), "enter a{sv}");
    while (try sd.check(sd.sd_bus_message_enter_container(m, 'e', "sv"), "enter {sv}") > 0) {
        const name = read_string(m) orelse return error.InvalidReply;
        var contents: ?[*:0]const u8 = null;
        _ = try sd.check(sd.sd_bus_message_peek_type(m, null, &contents), "peek");
        const signature = mem.span(contents orelse "");

        if (string_property(&props, name)) |field| {
            field.* = try read_variant_string(m, signature, a);
        } else if (mem.eql(u8, name, "Status")) {
            const status = try read_variant_string(m, signature, a);
            props.status =
                if (mem.eql(u8, status, "Passive")) .passive
                else if (mem.eql(u8, status, "NeedsAttention")) .needs_attention
                else .active;
        } else if (mem.eql(u8, name, "ItemIsMenu") and mem.eql(u8, signature, "b")) {
            var value: c_int = 0;
            _ = try sd.check(sd.sd_bus_message_read(m, "v", "b", &value), "read b");
            props.item_is_menu = value != 0;
        } else if (mem.eql(u8, name, "IconPixmap") and mem.eql(u8, signature, "a(iiay)")) {
            props.icon_pixmap = try read_pixmaps(m, a);
        } else if (mem.eql(u8, name, "AttentionIconPixmap") and mem.eql(u8, signature, "a(iiay)")) {
            props.attention_icon_pixmap = try read_pixmaps(m, a);
        } else if (mem.eql(u8, name, "ToolTip") and mem.eql(u8, signature, "(sa(iiay)ss)")) {
            try read_tooltip(m, &props, a);
        } else {
            _ = try sd.check(sd.sd_bus_message_skip(m, "v"), "skip");
        }
        _ = try sd.check(sd.sd_bus_message_exit_container(m), "exit {sv}");
    }
    _ = try sd.check(sd.sd_bus_message_exit_container(m), "exit a{sv}");
    return props;
}


fn string_property(props: *Properties, name: []const u8) ?*[]const u8 {
    const fields = .{
        .{ "Id", "id" },
        .{ "Title", "title" },
        .{ "IconName", "icon_name" },
        .{ "IconThemePath", "icon_theme_path" },
        .{ "AttentionIconName", "attention_icon_name" },
        .{ "Menu", "menu" },
    };
    inline for (fields) |field| {
        if (mem.eql(u8, name, field[0])) return &@field(props, field[1]);
    }
    return null;
}


/// Read a variant with a string or an object path. Skip other variants.
fn read_variant_string(m: *sd.Message, signature: [:0]const u8, a: mem.Allocator) ![]const u8 {
    if (!mem.eql(u8, signature, "s") and !mem.eql(u8, signature, "o")) {
        _ = try sd.check(sd.sd_bus_message_skip(m, "v"), "skip");
        return "";
    }
    var value: ?[*:0]const u8 = null;
    _ = try sd.check(sd.sd_bus_message_enter_container(m, 'v', signature.ptr), "enter v");
    _ = try sd.check(sd.sd_bus_message_read_basic(m, signature[0], @ptrCast(&value)), "read s");
    _ = try sd.check(sd.sd_bus_message_exit_container(m), "exit v");
    return a.dupe(u8, mem.span(value orelse return ""));
}


/// Read the variant a(iiay): images in sizes.
fn read_pixmaps(m: *sd.Message, a: mem.Allocator) ![]const Pixmap {
    var pixmaps: std.ArrayList(Pixmap) = .empty;
    _ = try sd.check(sd.sd_bus_message_enter_container(m, 'v', "a(iiay)"), "enter v");
    _ = try sd.check(sd.sd_bus_message_enter_container(m, 'a', "(iiay)"), "enter a");
    while (try sd.check(sd.sd_bus_message_enter_container(m, 'r', "iiay"), "enter (iiay)") > 0) {
        var width: c_int = 0;
        var height: c_int = 0;
        _ = try sd.check(sd.sd_bus_message_read(m, "ii", &width, &height), "read ii");
        var ptr: ?*const anyopaque = null;
        var size: usize = 0;
        _ = try sd.check(sd.sd_bus_message_read_array(m, 'y', &ptr, &size), "read ay");
        _ = try sd.check(sd.sd_bus_message_exit_container(m), "exit (iiay)");

        if (width <= 0 or height <= 0 or ptr == null) continue;
        if (size != @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4) continue;
        const bytes: [*]const u8 = @ptrCast(ptr.?);
        try pixmaps.append(a, .{
            .width = width,
            .height = height,
            .data = try a.dupe(u8, bytes[0..size]),
        });
    }
    _ = try sd.check(sd.sd_bus_message_exit_container(m), "exit a");
    _ = try sd.check(sd.sd_bus_message_exit_container(m), "exit v");
    return pixmaps.toOwnedSlice(a);
}


/// Read the variant (sa(iiay)ss): icon name, icon, title and text.
fn read_tooltip(m: *sd.Message, props: *Properties, a: mem.Allocator) !void {
    _ = try sd.check(sd.sd_bus_message_enter_container(m, 'v', "(sa(iiay)ss)"), "enter v");
    _ = try sd.check(sd.sd_bus_message_enter_container(m, 'r', "sa(iiay)ss"), "enter r");
    _ = try sd.check(sd.sd_bus_message_skip(m, "sa(iiay)"), "skip");
    var title: ?[*:0]const u8 = null;
    var text: ?[*:0]const u8 = null;
    _ = try sd.check(sd.sd_bus_message_read(m, "ss", &title, &text), "read ss");
    _ = try sd.check(sd.sd_bus_message_exit_container(m), "exit r");
    _ = try sd.check(sd.sd_bus_message_exit_container(m), "exit v");
    props.tooltip_title = try a.dupe(u8, mem.span(title orelse ""));
    props.tooltip_text = try a.dupe(u8, mem.span(text orelse ""));
}


/// The items or their properties changed. Draw the bars again.
fn changed() void {
    var shown = false;
    var it = ctx.outputs.safeIterator(.forward);
    while (it.next()) |output| {
        output.bar.damage(.dynamic);
        if (!output.bar.hidden) shown = true;
    }
    if (shown) ctx.rwm.manageDirty();
    @import("tooltip.zig").damage();
}
