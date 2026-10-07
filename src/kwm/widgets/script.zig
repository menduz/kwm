//! Script widget: the output of a shell command, as a waybar custom module.
//! Each line that the command writes is the new text, or a JSON object with
//! "text", "tooltip" and "class".
//!
//! "tooltip_on_click" is not in waybar: a list with a shell command for each
//! line of the tooltip. A click on the line runs its command. An empty string
//! or null: the line has no command.

const std = @import("std");
const mem = std.mem;
const linux = std.os.linux;
const log = std.log.scoped(.widgets);

const posix = @import("posix");

const common = @import("common.zig");
const ctx = common.ctx;

pub const Process = struct {
    pid: posix.pid_t,
    fd: posix.fd_t,
    /// Output that has no '\n' yet.
    line: std.ArrayList(u8) = .empty,
};

/// The running command, or null.
pub const Data = ?Process;


/// Start `exec` with `sh -c`. Its standard output goes to a pipe that the
/// main loop polls.
pub fn start(exec: []const u8) ?Process {
    var arena_allocator: std.heap.ArenaAllocator = .init(ctx.gpa);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    const cmd = arena.dupeZ(u8, exec) catch return null;
    const argv = [_:null]?[*:0]const u8 { "sh", "-c", cmd.ptr, null };
    const env_block = ctx.env.createPosixBlock(arena, .{}) catch |err| {
        log.err("createPosixBlock failed: {}", .{ err });
        return null;
    };

    var fds: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) {
        log.err("pipe2 failed", .{});
        return null;
    }

    const pid = posix.fork() catch |err| {
        log.err("fork failed: {}", .{ err });
        posix.close(fds[0]);
        posix.close(fds[1]);
        return null;
    };

    if (pid == 0) {
        _ = posix.setsid() catch {};
        _ = posix.system.sigprocmask(posix.SIG.SETMASK, &posix.sigemptyset(), null);
        // dup2 clears close-on-exec on the new descriptor.
        if (linux.errno(linux.dup2(fds[1], 1)) != .SUCCESS) posix.exit(127);
        if (ctx.env.get("HOME")) |home| posix.chdir(home) catch {};
        const err = posix.execve("sh", &argv, env_block.slice.ptr);
        log.err("execve failed: {}", .{ err });
        posix.exit(127);
    }

    posix.close(fds[1]);

    const flags = posix.fcntl(fds[0], posix.F.GETFL, 0) catch 0;
    _ = posix.fcntl(fds[0], posix.F.SETFL, flags | (1 << @bitOffsetOf(posix.O, "NONBLOCK"))) catch {};

    return .{ .pid = pid, .fd = fds[0] };
}


/// Stop the command and all of its processes. The command is the leader of
/// its own process group (setsid in `start`), so kwm sends SIGTERM to the
/// group. A shell gets SIGTERM, but runs its trap only after the command that
/// it waits for. A script that waits for a pipeline (for example
/// `pw-dump --monitor | jq`) would then never stop, and the pipeline would
/// stay after kwm.
pub fn stop(data: *Data) void {
    var process = data.* orelse return;
    if (std.c.kill(-process.pid, .TERM) != 0) _ = std.c.kill(process.pid, .TERM);
    posix.close(process.fd);
    process.line.deinit(ctx.gpa);
    data.* = null;
}


/// Read the output of the command. Parse the newest complete line into
/// `out`, and return true when there was one. When the command stops,
/// `data` becomes null.
pub fn read(cfg: anytype, data: *Data, out: *common.Output) !bool {
    // A pointer into `data`, so the partial line stays there.
    const process = if (data.*) |*p| p else return false;

    var newest: std.ArrayList(u8) = .empty;
    defer newest.deinit(ctx.gpa);
    var found = false;

    var buffer: [4096]u8 = undefined;
    while (true) {
        const n = posix.read(process.fd, &buffer) catch |err| switch (err) {
            error.WouldBlock => break,
            else => 0,
        };
        if (n == 0) {
            // The command stopped. Use a last line without '\n'.
            if (process.line.items.len > 0) {
                newest.clearRetainingCapacity();
                try newest.appendSlice(ctx.gpa, process.line.items);
                found = true;
            }
            posix.close(process.fd);
            process.line.deinit(ctx.gpa);
            data.* = null;
            break;
        }

        try process.line.appendSlice(ctx.gpa, buffer[0..n]);
        while (mem.indexOfScalar(u8, process.line.items, '\n')) |end| {
            newest.clearRetainingCapacity();
            try newest.appendSlice(ctx.gpa, process.line.items[0..end]);
            found = true;
            process.line.replaceRangeAssumeCapacity(0, end + 1, &.{});
        }
    }

    if (!found) return false;
    try parse(cfg, newest.items, out);
    return true;
}


/// The classes "warning" and "critical" give a color. The class "blink"
/// makes the widget flash.
fn apply_class(name: []const u8, color: *?u32, out: *common.Output) void {
    if (mem.eql(u8, name, "critical")) color.* = ctx.cfg.bar.widget_colors.critical;
    if (mem.eql(u8, name, "warning") and color.* == null) color.* = ctx.cfg.bar.widget_colors.warning;
    if (mem.eql(u8, name, "blink")) out.blink = true;
}


fn parse(cfg: anytype, line: []const u8, out: *common.Output) !void {
    switch (cfg.return_type) {
        .text => try out.text.appendSlice(ctx.gpa, line),
        .json => {
            const parsed = std.json.parseFromSlice(std.json.Value, ctx.gpa, line, .{}) catch |err| {
                log.warn("script output is not JSON: {}", .{ err });
                return error.BadJson;
            };
            defer parsed.deinit();
            if (parsed.value != .object) return error.BadJson;
            const object = parsed.value.object;

            // "class" is a name or a list of names, as in waybar.
            var color: ?u32 = null;
            if (object.get("class")) |class| switch (class) {
                .string => |name| apply_class(name, &color, out),
                .array => |names| for (names.items) |name| {
                    if (name == .string) apply_class(name.string, &color, out);
                },
                else => {},
            };
            // A flashing widget is red when no class gives a color.
            if (out.blink and color == null) color = ctx.cfg.bar.widget_colors.critical;
            if (object.get("text")) |value| if (value == .string) {
                try common.append_colored(&out.text, color, value.string);
            };
            if (object.get("tooltip")) |value| if (value == .string) {
                try out.tooltip.appendSlice(ctx.gpa, value.string);
            };
            if (object.get("tooltip_on_click")) |value| if (value == .array) {
                for (value.array.items, 0..) |cmd, i| {
                    if (i > 0) try out.tooltip_on_click.append(ctx.gpa, 0);
                    // A NUL in a command would separate two items.
                    if (cmd == .string and mem.indexOfScalar(u8, cmd.string, 0) == null) {
                        try out.tooltip_on_click.appendSlice(ctx.gpa, cmd.string);
                    }
                }
            };
        },
    }
    out.hidden = out.text.items.len == 0;
}
