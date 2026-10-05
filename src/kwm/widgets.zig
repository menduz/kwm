//! Runtime of the bar widgets. Refer to src/config/widget.zig.
//!
//! Each widget type has a file in widgets/. This file keeps the state of the
//! widgets, updates them with a timer, and runs their click commands.

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const log = std.log.scoped(.widgets);

const build_options = @import("build_options");
const posix = @import("posix");
const config = @import("config");

const types = @import("types.zig");
const Context = @import("context.zig");
const common = @import("widgets/common.zig");
const clock = @import("widgets/clock.zig");
const cpu = @import("widgets/cpu.zig");
const disk = @import("widgets/disk.zig");
const battery = @import("widgets/battery.zig");
const mem_widget = @import("widgets/mem.zig");
const net = @import("widgets/net.zig");
const script = @import("widgets/script.zig");

const Widget = config.widget.Widget;

const ctx = Context.get();

/// `end` is at the right of the tray, at the right end of the bar.
pub const Side = enum { center, right, end };
const sides = std.enums.values(Side);

/// The maximum number of widgets on one side.
pub const max_widgets = 16;

/// Milliseconds before a script with interval 0 starts again, after it
/// stopped or after it did not start.
const restart_delay = 30_000;

pub const State = struct {
    /// The text on the bar. It can have `^#RRGGBBAA` and `^#!` color codes.
    text: std.ArrayList(u8) = .empty,
    /// The text of the tooltip. Lines are separated by '\n'.
    tooltip: std.ArrayList(u8) = .empty,
    /// The click commands of the tooltip lines. Refer to `common.Output`.
    tooltip_on_click: std.ArrayList(u8) = .empty,
    hidden: bool = false,
    /// The widget flashes. Refer to `text`.
    blink: bool = false,
    /// `text` without the color codes, for the flashing.
    plain: std.ArrayList(u8) = .empty,
    /// Awake-clock milliseconds of the next update.
    next_update: i64 = 0,
    scroll: f64 = 0,

    cpu: cpu.Data = .{},
    net: net.Data = .{},
    script: script.Data = null,

    fn deinit(self: *State) void {
        script.stop(&self.script);
        self.text.deinit(ctx.gpa);
        self.plain.deinit(ctx.gpa);
        self.tooltip.deinit(ctx.gpa);
        self.tooltip_on_click.deinit(ctx.gpa);
    }
};

var side_states: [sides.len]std.ArrayList(State) = .{ std.ArrayList(State).empty } ** sides.len;
var ticking = false;


pub fn items(side: Side) []const Widget {
    const list = switch (side) {
        .center => ctx.cfg.bar.center,
        .right => ctx.cfg.bar.right,
        .end => ctx.cfg.bar.end,
    };
    return list[0..@min(list.len, max_widgets)];
}


pub fn states(side: Side) []State {
    return side_states[@intFromEnum(side)].items;
}


/// Make the state of the widgets in the configuration, and start the timer.
pub fn init() void {
    clock.init();

    for (sides) |side| {
        side_states[@intFromEnum(side)].appendNTimes(ctx.gpa, .{}, items(side).len) catch |err| {
            log.err("allocate widget states failed: {}", .{ err });
        };
    }

    if (!ticking and any_widgets()) {
        ticking = true;
        ctx.run_later(.fromMilliseconds(0), tick);
    }
}


pub fn deinit() void {
    for (&side_states) |*list| {
        for (list.items) |*state| state.deinit();
        list.clearAndFree(ctx.gpa);
    }
    net.deinit();
}


/// Call after a reload of the configuration. The widgets keep pointers into
/// the old configuration, so make all of them again.
pub fn reload() void {
    deinit();
    init();
}


fn any_widgets() bool {
    for (side_states) |list| {
        if (list.items.len > 0) return true;
    }
    return false;
}


fn tick(_: *Context) void {
    if (!any_widgets()) {
        ticking = false;
        return;
    }

    const now = Io.Timestamp.now(ctx.io, .awake).toMilliseconds();
    var changed = false;
    inline for (sides) |side| {
        for (items(side), states(side)) |*item, *state| {
            if (now >= state.next_update) {
                if (update(item, state, now)) changed = true;
            }
        }
    }
    if (changed) damage_bars();

    ctx.run_later(.fromMilliseconds(1000), tick);
}


/// Update one widget. Return true when it changed.
fn update(item: *const Widget, state: *State, now: i64) bool {
    var out: common.Output = .{};
    defer out.deinit();

    const interval: i64 = switch (item.*) {
        .script => |cfg| {
            if (state.script == null) state.script = script.start(cfg.exec);
            // With interval 0, the command runs all the time. When it stops,
            // handle_script_fd gives the time of the next start.
            state.next_update = if (cfg.interval > 0)
                now + cfg.interval
            else if (state.script == null)
                now + restart_delay
            else
                std.math.maxInt(i64);
            return false;
        },
        inline else => |cfg| cfg.interval,
    };
    state.next_update = now + interval;

    (switch (item.*) {
        .memory => |*cfg| mem_widget.update(cfg, &out),
        .cpu => |*cfg| cpu.update(cfg, &state.cpu, &out),
        .clock => |*cfg| clock.update(cfg, &out),
        .disk => |*cfg| disk.update(cfg, &out),
        .battery => |*cfg| battery.update(cfg, &out),
        .network => |*cfg| net.update(cfg, &state.net, &out),
        .script => unreachable,
    }) catch |err| {
        log.warn("update widget {s} failed: {}", .{ @tagName(item.*), err });
        return false;
    };

    return set(state, &out);
}


fn set(state: *State, out: *const common.Output) bool {
    if (state.hidden == out.hidden
        and state.blink == out.blink
        and mem.eql(u8, state.text.items, out.text.items)
        and mem.eql(u8, state.tooltip.items, out.tooltip.items)
        and mem.eql(u8, state.tooltip_on_click.items, out.tooltip_on_click.items)) return false;

    state.hidden = out.hidden;
    state.blink = out.blink;
    state.text.clearRetainingCapacity();
    state.text.appendSlice(ctx.gpa, out.text.items) catch return false;
    state.plain.clearRetainingCapacity();
    strip_colors(&state.plain, out.text.items) catch return false;
    state.tooltip.clearRetainingCapacity();
    state.tooltip.appendSlice(ctx.gpa, out.tooltip.items) catch return false;
    state.tooltip_on_click.clearRetainingCapacity();
    state.tooltip_on_click.appendSlice(ctx.gpa, out.tooltip_on_click.items) catch return false;
    if (state.blink and !state.hidden) start_blinking();
    return true;
}


/// The text of a widget on the bar now. A flashing widget changes between
/// its text with colors and its text without colors.
pub fn text(state: *const State) []const u8 {
    return if (state.blink and !blink_on) state.plain.items else state.text.items;
}


/// Add `bytes` without the color codes `^#RRGGBBAA` and `^#!` to `list`.
fn strip_colors(list: *std.ArrayList(u8), bytes: []const u8) !void {
    var i: usize = 0;
    while (i < bytes.len) {
        if (mem.startsWith(u8, bytes[i..], "^#!")) {
            i += 3;
        } else if (mem.startsWith(u8, bytes[i..], "^#") and i + 10 <= bytes.len and
            for (bytes[i + 2 .. i + 10]) |c| {
                if (!std.ascii.isAlphanumeric(c)) break false;
            } else true)
        {
            i += 10;
        } else {
            try list.append(ctx.gpa, bytes[i]);
            i += 1;
        }
    }
}


// Flashing -------------------------------------------------------------------

/// Milliseconds between two changes of a flashing widget.
const blink_interval = 150;
/// The phase of the flashing widgets: true shows their colors.
var blink_on = true;
var blinking = false;


fn start_blinking() void {
    if (blinking) return;
    blinking = true;
    blink_on = true;
    ctx.run_later(.fromMilliseconds(blink_interval), blink_tick);
}


fn any_blinking() bool {
    for (std.enums.values(Side)) |side| {
        for (states(side)) |*state| {
            if (state.blink and !state.hidden) return true;
        }
    }
    return false;
}


fn blink_tick(_: *Context) void {
    if (!any_blinking()) {
        blinking = false;
        blink_on = true;
        return;
    }
    blink_on = !blink_on;
    damage_bars();
    ctx.run_later(.fromMilliseconds(blink_interval), blink_tick);
}


fn damage_bars() void {
    if (comptime build_options.bar_enabled) {
        var shown: usize = 0;
        var it = ctx.outputs.safeIterator(.forward);
        while (it.next()) |output| {
            output.bar.damage(.status);
            if (!output.bar.hidden) shown += 1;
        }
        if (shown > 0) ctx.rwm.manageDirty();

        @import("tooltip.zig").damage();
    }
}


// Scripts --------------------------------------------------------------------

/// The file descriptors of the running scripts, for poll.
pub fn script_fds(buffer: []posix.fd_t) []posix.fd_t {
    var len: usize = 0;
    for (side_states) |list| {
        for (list.items) |state| {
            const process = state.script orelse continue;
            if (len == buffer.len) break;
            buffer[len] = process.fd;
            len += 1;
        }
    }
    return buffer[0..len];
}


/// Read the output of the script with this file descriptor.
pub fn handle_script_fd(fd: posix.fd_t) void {
    inline for (sides) |side| {
        for (items(side), states(side)) |*item, *state| {
            const process = state.script orelse continue;
            if (process.fd != fd) continue;

            var out: common.Output = .{};
            defer out.deinit();
            const new_line = script.read(&item.script, &state.script, &out) catch |err| blk: {
                log.warn("read script failed: {}", .{ err });
                break :blk false;
            };
            if (state.script == null and item.script.interval == 0) {
                // The command stopped. Its last text can be old, thus hide
                // the widget until the command starts again.
                log.warn("script `{s}` stopped, start it again in {} s", .{ item.script.exec, restart_delay / 1000 });
                state.next_update = Io.Timestamp.now(ctx.io, .awake).toMilliseconds() + restart_delay;
                out.deinit();
                out = .{ .hidden = true };
                if (set(state, &out)) damage_bars();
                return;
            }
            if (new_line and set(state, &out)) damage_bars();
            return;
        }
    }
}


// Clicks ---------------------------------------------------------------------

fn command(item: *const Widget, comptime field: []const u8) ?[]const u8 {
    return switch (item.*) {
        inline else => |widget| @field(widget, field),
    };
}


/// Run the click command of a widget for a button.
pub fn click(side: Side, index: usize, button: types.Button) void {
    const item = &items(side)[index];
    const cmd = switch (button) {
        .left => command(item, "on_click"),
        .right => command(item, "on_click_right"),
        .middle => command(item, "on_click_middle"),
        else => null,
    } orelse return;
    ctx.spawn_shell(cmd);
}


/// The click command of line `line` of the tooltip of a widget, or null.
pub fn tooltip_command(side: Side, index: usize, line: usize) ?[]const u8 {
    const list = states(side);
    if (index >= list.len or list[index].hidden) return null;
    var it = mem.splitScalar(u8, list[index].tooltip_on_click.items, 0);
    var i: usize = 0;
    while (it.next()) |cmd| : (i += 1) {
        if (i == line) return if (cmd.len == 0) null else cmd;
    }
    return null;
}


/// Run the scroll commands of a widget. `value` is the axis value of
/// wl_pointer: positive is down. One wheel step is 15.
pub fn scroll(side: Side, index: usize, value: f64) void {
    const item = &items(side)[index];
    const state = &states(side)[index];

    state.scroll += value;
    while (@abs(state.scroll) >= 15) {
        const down = state.scroll > 0;
        state.scroll -= if (down) 15 else -15;
        const cmd = (if (down) command(item, "on_scroll_down") else command(item, "on_scroll_up")) orelse continue;
        ctx.spawn_shell(cmd);
    }
}
