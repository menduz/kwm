//! The menu of a tray item (com.canonical.dbusmenu), in an external program
//! such as rofi. There is one menu at a time.
//!
//! kwm gets the layout of the menu, and writes one row for each menu item
//! to the standard input of `bar.tray.menu_command`. A submenu gives rows
//! such as "Parent › Child". The rows have the row options of rofi: icon,
//! nonselectable and active. The program writes the index of the chosen row
//! to its standard output, and kwm sends the event "clicked" for that item.

const std = @import("std");
const mem = std.mem;
const linux = std.os.linux;
const log = std.log.scoped(.tray_menu);

const posix = @import("posix");

const sd = @import("sd_bus.zig");
const Context = @import("context.zig");

const ctx = Context.get();

const menu_interface = "com.canonical.dbusmenu";

/// Where the menu shows: the position of the icon in logical pixels of its
/// output. `x` is the left edge of the icon, `y` is the edge of the bar
/// below a top bar or above a bottom bar, and `right` is the distance from
/// the right edge of the icon to the right edge of the output.
pub const Place = struct {
    x: i32,
    y: i32,
    right: i32,
};

const ToggleType = enum { none, checkmark, radio };

const Node = struct {
    id: i32,
    label: []const u8 = "",
    icon_name: []const u8 = "",
    enabled: bool = true,
    visible: bool = true,
    separator: bool = false,
    submenu: bool = false,
    toggle_type: ToggleType = .none,
    toggle_state: i32 = -1,
    children: []Node = &.{},
};

const Process = struct {
    pid: posix.pid_t,
    fd: posix.fd_t,
    output: std.ArrayList(u8) = .empty,
};

const Menu = struct {
    arena: std.heap.ArenaAllocator,
    bus: *sd.Bus,
    service: [:0]const u8,
    path: [:0]const u8,
    title: []const u8,
    place: Place,
    slot: ?*sd.Slot = null,
    /// The slots of AboutToShow of the empty submenus.
    submenu_slots: std.ArrayList(*sd.Slot) = .empty,
    /// AboutToShow calls of empty submenus that did not reply yet.
    pending: usize = 0,
    /// The layout was read again after AboutToShow of the empty submenus.
    refreshed: bool = false,
    root: Node = .{ .id = 0 },
    /// The id of the menu item of each row.
    row_ids: std.ArrayList(i32) = .empty,
    process: ?Process = null,
};

var menu: ?*Menu = null;


/// Show the menu at `path` of the item at `service`.
pub fn open(bus: *sd.Bus, service: []const u8, path: []const u8, title: []const u8, place: Place) void {
    close();
    start(bus, service, path, title, place) catch |err| {
        log.err("open the menu of {s} failed: {}", .{ service, err });
        close();
    };
}


/// Stop the menu program and forget the menu.
pub fn close() void {
    const m = menu orelse return;
    menu = null;
    _ = sd.sd_bus_slot_unref(m.slot);
    for (m.submenu_slots.items) |slot| _ = sd.sd_bus_slot_unref(slot);
    m.submenu_slots.deinit(ctx.gpa);
    if (m.process) |*process| {
        _ = std.c.kill(process.pid, .TERM);
        posix.close(process.fd);
        process.output.deinit(ctx.gpa);
    }
    m.row_ids.deinit(ctx.gpa);
    m.arena.deinit();
    ctx.gpa.destroy(m);
}


/// The standard output of the menu program, for poll.
pub fn poll_fd() ?posix.pollfd {
    const m = menu orelse return null;
    const process = m.process orelse return null;
    return .{ .fd = process.fd, .events = posix.POLL.IN, .revents = 0 };
}


/// Read the standard output of the menu program. When the program stops,
/// send "clicked" for the chosen row.
pub fn handle_fd() void {
    const m = menu orelse return;
    const process = &(m.process orelse return);
    var buffer: [256]u8 = undefined;
    while (true) {
        const n = posix.read(process.fd, &buffer) catch |err| switch (err) {
            error.WouldBlock => return,
            else => {
                log.warn("read the menu program failed: {}", .{ err });
                close();
                return;
            },
        };
        if (n == 0) break;
        process.output.appendSlice(ctx.gpa, buffer[0..n]) catch {
            close();
            return;
        };
    }

    // The program stopped.
    const text = mem.trim(u8, process.output.items, " \t\r\n");
    if (std.fmt.parseInt(usize, text, 10)) |row| {
        if (row < m.row_ids.items.len) {
            const id = m.row_ids.items[row];
            log.debug("{s}: clicked {}", .{ m.service, id });
            send_event(m, id, "clicked");
        }
    } else |_| {}
    send_event(m, 0, "closed");
    close();
}


fn send_event(m: *Menu, id: i32, event: [:0]const u8) void {
    _ = sd.sd_bus_call_method_async(
        m.bus, null, m.service, m.path, menu_interface, "Event",
        null, null, "isvu", @as(c_int, id), event.ptr, "i", @as(c_int, 0), @as(u32, 0),
    );
}


fn start(bus: *sd.Bus, service: []const u8, path: []const u8, title: []const u8, place: Place) !void {
    const m = try ctx.gpa.create(Menu);
    m.* = .{
        .arena = .init(ctx.gpa),
        .bus = bus,
        .service = "",
        .path = "",
        .title = "",
        .place = place,
    };
    menu = m;
    const a = m.arena.allocator();
    m.service = try a.dupeZ(u8, service);
    m.path = try a.dupeZ(u8, path);
    m.title = try a.dupe(u8, title);

    // The item can fill the menu now. Errors do not matter.
    _ = try sd.check(sd.sd_bus_call_method_async(
        bus, &m.slot, m.service, m.path, menu_interface, "AboutToShow",
        on_about_to_show_root, m, "i", @as(c_int, 0),
    ), "AboutToShow");
}


/// The menu of a callback, when it is still the current menu.
fn current(userdata: ?*anyopaque) ?*Menu {
    const m: *Menu = @ptrCast(@alignCast(userdata orelse return null));
    return if (menu == m) m else null;
}


fn on_about_to_show_root(_: *sd.Message, userdata: ?*anyopaque, _: *sd.Error) callconv(.c) c_int {
    const m = current(userdata) orelse return 0;
    m.slot = sd.sd_bus_slot_unref(m.slot);
    get_layout(m);
    return 0;
}


fn get_layout(m: *Menu) void {
    _ = sd.check(sd.sd_bus_call_method_async(
        m.bus, &m.slot, m.service, m.path, menu_interface, "GetLayout",
        on_layout, m, "iias", @as(c_int, 0), @as(c_int, -1), @as(c_int, 0),
    ), "GetLayout") catch close();
}


fn on_layout(msg: *sd.Message, userdata: ?*anyopaque, _: *sd.Error) callconv(.c) c_int {
    const m = current(userdata) orelse return 0;
    m.slot = sd.sd_bus_slot_unref(m.slot);
    if (sd.sd_bus_message_get_error(msg)) |err| {
        log.warn("{s}: GetLayout failed: {s}", .{ m.service, err.message orelse err.name orelse "" });
        close();
        return 0;
    }
    read_layout(msg, m) catch |err| {
        log.warn("{s}: read the menu failed: {}", .{ m.service, err });
        close();
        return 0;
    };

    // Some items fill a submenu only after AboutToShow of that submenu.
    if (!m.refreshed) {
        m.refreshed = true;
        about_to_show_empty(m, &m.root);
        if (m.pending > 0) return 0;
    }
    show(m) catch |err| {
        log.err("{s}: start the menu program failed: {}", .{ m.service, err });
        close();
    };
    return 0;
}


fn about_to_show_empty(m: *Menu, node: *const Node) void {
    for (node.children) |*child| {
        if (child.submenu and child.children.len == 0 and child.visible) {
            var slot: ?*sd.Slot = null;
            const rc = sd.sd_bus_call_method_async(
                m.bus, &slot, m.service, m.path, menu_interface, "AboutToShow",
                on_about_to_show_submenu, m, "i", @as(c_int, child.id),
            );
            if (rc >= 0) {
                m.submenu_slots.append(ctx.gpa, slot.?) catch {
                    _ = sd.sd_bus_slot_unref(slot);
                    continue;
                };
                m.pending += 1;
            }
        }
        about_to_show_empty(m, child);
    }
}


fn on_about_to_show_submenu(_: *sd.Message, userdata: ?*anyopaque, _: *sd.Error) callconv(.c) c_int {
    const m = current(userdata) orelse return 0;
    m.pending -= 1;
    if (m.pending == 0) {
        for (m.submenu_slots.items) |slot| _ = sd.sd_bus_slot_unref(slot);
        m.submenu_slots.clearRetainingCapacity();
        get_layout(m);
    }
    return 0;
}


// The layout: u(ia{sv}av).

fn read_layout(msg: *sd.Message, m: *Menu) !void {
    var revision: u32 = 0;
    _ = try sd.check(sd.sd_bus_message_read_basic(msg, 'u', @ptrCast(&revision)), "read u");
    _ = try sd.check(sd.sd_bus_message_enter_container(msg, 'r', "ia{sv}av"), "enter (ia{sv}av)");
    m.root = try read_node(msg, m.arena.allocator());
    _ = try sd.check(sd.sd_bus_message_exit_container(msg), "exit (ia{sv}av)");
}


fn read_node(msg: *sd.Message, a: mem.Allocator) !Node {
    var node: Node = .{ .id = 0 };
    _ = try sd.check(sd.sd_bus_message_read_basic(msg, 'i', @ptrCast(&node.id)), "read i");

    _ = try sd.check(sd.sd_bus_message_enter_container(msg, 'a', "{sv}"), "enter a{sv}");
    while (try sd.check(sd.sd_bus_message_enter_container(msg, 'e', "sv"), "enter {sv}") > 0) {
        var key_z: ?[*:0]const u8 = null;
        _ = try sd.check(sd.sd_bus_message_read_basic(msg, 's', @ptrCast(&key_z)), "read key");
        const key = mem.span(key_z orelse "");
        var contents: ?[*:0]const u8 = null;
        _ = try sd.check(sd.sd_bus_message_peek_type(msg, null, &contents), "peek");
        const signature = mem.span(contents orelse "");

        if (mem.eql(u8, signature, "s")) {
            var value_z: ?[*:0]const u8 = null;
            _ = try sd.check(sd.sd_bus_message_read(msg, "v", "s", &value_z), "read s");
            const value = mem.span(value_z orelse "");
            if (mem.eql(u8, key, "label")) {
                node.label = try a.dupe(u8, value);
            } else if (mem.eql(u8, key, "icon-name")) {
                node.icon_name = try a.dupe(u8, value);
            } else if (mem.eql(u8, key, "type")) {
                node.separator = mem.eql(u8, value, "separator");
            } else if (mem.eql(u8, key, "children-display")) {
                node.submenu = mem.eql(u8, value, "submenu");
            } else if (mem.eql(u8, key, "toggle-type")) {
                node.toggle_type =
                    if (mem.eql(u8, value, "checkmark")) .checkmark
                    else if (mem.eql(u8, value, "radio")) .radio
                    else .none;
            }
        } else if (mem.eql(u8, signature, "b")) {
            var value: c_int = 0;
            _ = try sd.check(sd.sd_bus_message_read(msg, "v", "b", &value), "read b");
            if (mem.eql(u8, key, "enabled")) node.enabled = value != 0;
            if (mem.eql(u8, key, "visible")) node.visible = value != 0;
        } else if (mem.eql(u8, signature, "i") and mem.eql(u8, key, "toggle-state")) {
            _ = try sd.check(sd.sd_bus_message_read(msg, "v", "i", &node.toggle_state), "read i");
        } else {
            _ = try sd.check(sd.sd_bus_message_skip(msg, "v"), "skip v");
        }
        _ = try sd.check(sd.sd_bus_message_exit_container(msg), "exit {sv}");
    }
    _ = try sd.check(sd.sd_bus_message_exit_container(msg), "exit a{sv}");

    var children: std.ArrayList(Node) = .empty;
    _ = try sd.check(sd.sd_bus_message_enter_container(msg, 'a', "v"), "enter av");
    while (try sd.check(sd.sd_bus_message_enter_container(msg, 'v', "(ia{sv}av)"), "enter v") > 0) {
        _ = try sd.check(sd.sd_bus_message_enter_container(msg, 'r', "ia{sv}av"), "enter (ia{sv}av)");
        try children.append(a, try read_node(msg, a));
        _ = try sd.check(sd.sd_bus_message_exit_container(msg), "exit (ia{sv}av)");
        _ = try sd.check(sd.sd_bus_message_exit_container(msg), "exit v");
    }
    _ = try sd.check(sd.sd_bus_message_exit_container(msg), "exit av");
    node.children = children.items;
    if (node.children.len > 0) node.submenu = true;
    return node;
}


// The rows.

/// Write the rows of the children of `node`, with `prefix` before the
/// labels.
fn write_rows(m: *Menu, w: *std.Io.Writer, node: *const Node, prefix: []const u8) !void {
    const a = m.arena.allocator();
    for (node.children) |*child| {
        if (!child.visible or child.separator) continue;
        const label = try strip_mnemonics(a, child.label);
        if (child.submenu) {
            if (child.children.len == 0) continue;
            const sub_prefix = try std.fmt.allocPrint(a, "{s}{s} › ", .{ prefix, label });
            try write_rows(m, w, child, sub_prefix);
            continue;
        }

        const on = child.toggle_state == 1;
        const mark = switch (child.toggle_type) {
            .none => "",
            .checkmark => if (on) "✓ " else "☐ ",
            .radio => if (on) "● " else "○ ",
        };
        try w.print("{s}{s}{s}", .{ mark, prefix, label });
        // The row options of rofi: "\x00" before the first, "\x1f" between.
        var separator: []const u8 = "\x00";
        if (child.icon_name.len > 0) {
            try w.print("{s}icon\x1f{s}", .{ separator, child.icon_name });
            separator = "\x1f";
        }
        if (!child.enabled) {
            try w.print("{s}nonselectable\x1ftrue", .{ separator });
            separator = "\x1f";
        }
        if (on) try w.print("{s}active\x1ftrue", .{ separator });
        try w.writeByte('\n');
        try m.row_ids.append(ctx.gpa, child.id);
    }
}


/// Remove the "_" before a mnemonic letter. "__" is one "_". A new line is
/// a space, because each row is one line.
fn strip_mnemonics(a: mem.Allocator, label: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < label.len) : (i += 1) {
        switch (label[i]) {
            '_' => if (i + 1 < label.len and label[i + 1] == '_') {
                try out.append(a, '_');
                i += 1;
            },
            '\n', '\r', 0 => try out.append(a, ' '),
            else => |c| try out.append(a, c),
        }
    }
    return out.items;
}


// The menu program.

fn show(m: *Menu) !void {
    const cfg = ctx.cfg.bar.tray orelse return error.NoTray;
    const a = m.arena.allocator();

    var rows: std.Io.Writer.Allocating = .init(a);
    try write_rows(m, &rows.writer, &m.root, "");
    if (m.row_ids.items.len == 0) {
        log.info("{s}: the menu is empty", .{ m.service });
        close();
        return;
    }

    // The arguments, with the places of the menu.
    const argv = try a.allocSentinel(?[*:0]const u8, cfg.menu_command.len, null);
    for (cfg.menu_command, 0..) |arg, i| {
        var out: std.Io.Writer.Allocating = .init(a);
        var rest = arg;
        while (mem.indexOfScalar(u8, rest, '{')) |open_i| {
            try out.writer.writeAll(rest[0..open_i]);
            rest = rest[open_i..];
            // A "{" that does not start a placeholder stays, for example in
            // the theme strings of rofi.
            if (mem.indexOfScalar(u8, rest, '}')) |end| {
                if (try write_placeholder(&out.writer, m, rest[1..end])) {
                    rest = rest[end + 1 ..];
                    continue;
                }
            }
            try out.writer.writeByte('{');
            rest = rest[1..];
        }
        try out.writer.writeAll(rest);
        argv[i] = (try a.dupeZ(u8, out.written())).ptr;
    }
    if (argv.len == 0) return error.NoMenuCommand;

    m.process = try spawn(a, argv, rows.written());
}


/// Write the value of the placeholder `name`. Return false for an unknown
/// name.
fn write_placeholder(w: *std.Io.Writer, m: *const Menu, name: []const u8) !bool {
    if (mem.eql(u8, name, "title")) try w.writeAll(m.title)
    else if (mem.eql(u8, name, "x")) try w.print("{}", .{ m.place.x })
    else if (mem.eql(u8, name, "y")) try w.print("{}", .{ m.place.y })
    else if (mem.eql(u8, name, "right")) try w.print("{}", .{ m.place.right })
    else return false;
    return true;
}


/// Start the program with `input` on its standard input. Its standard output
/// goes to a pipe that the main loop polls.
fn spawn(a: mem.Allocator, argv: [:null]?[*:0]const u8, input: []const u8) !Process {
    const env_block = try ctx.env.createPosixBlock(a, .{});

    var stdin: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&stdin, .{ .CLOEXEC = true })) != .SUCCESS) return error.Pipe;
    defer posix.close(stdin[1]);
    var stdout: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&stdout, .{ .CLOEXEC = true })) != .SUCCESS) {
        posix.close(stdin[0]);
        return error.Pipe;
    }

    const pid = posix.fork() catch |err| {
        posix.close(stdin[0]);
        posix.close(stdout[0]);
        posix.close(stdout[1]);
        return err;
    };
    if (pid == 0) {
        _ = posix.setsid() catch {};
        _ = posix.system.sigprocmask(posix.SIG.SETMASK, &posix.sigemptyset(), null);
        // dup2 clears close-on-exec on the new descriptors.
        if (linux.errno(linux.dup2(stdin[0], 0)) != .SUCCESS) posix.exit(127);
        if (linux.errno(linux.dup2(stdout[1], 1)) != .SUCCESS) posix.exit(127);
        if (ctx.env.get("HOME")) |home| posix.chdir(home) catch {};
        const err = posix.execve(argv[0].?, argv.ptr, env_block.slice.ptr);
        log.err("execve {s} failed: {}", .{ argv[0].?, err });
        posix.exit(127);
    }
    posix.close(stdin[0]);
    posix.close(stdout[1]);

    // The rows are small, and the program reads them when it starts.
    var written: usize = 0;
    while (written < input.len) {
        const n = linux.write(stdin[1], input[written..].ptr, input.len - written);
        if (linux.errno(n) != .SUCCESS) break;
        written += n;
    }

    const flags = posix.fcntl(stdout[0], posix.F.GETFL, 0) catch 0;
    _ = posix.fcntl(stdout[0], posix.F.SETFL, flags | (1 << @bitOffsetOf(posix.O, "NONBLOCK"))) catch {};
    return .{ .pid = pid, .fd = stdout[0] };
}
