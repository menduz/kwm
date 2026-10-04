//! Helpers that all widgets use.

const std = @import("std");
const fmt = std.fmt;

const posix = @import("posix");

const Context = @import("../context.zig");

pub const ctx = Context.get();

/// The result of one update of a widget.
pub const Output = struct {
    /// The text on the bar. It can have `^#RRGGBBAA` and `^#!` color codes.
    text: std.ArrayList(u8) = .empty,
    /// The text of the tooltip. Lines are separated by '\n'.
    tooltip: std.ArrayList(u8) = .empty,
    hidden: bool = false,
    /// The widget flashes: its text changes between its colors and the
    /// color of the bar text.
    blink: bool = false,

    pub fn deinit(self: *Output) void {
        self.text.deinit(ctx.gpa);
        self.tooltip.deinit(ctx.gpa);
    }
};


pub fn append_colored(text: *std.ArrayList(u8), color: ?u32, str: []const u8) !void {
    if (color) |c| {
        try text.print(ctx.gpa, "^#{x:0>8}{s}^#!", .{ c, str });
    } else {
        try text.appendSlice(ctx.gpa, str);
    }
}


pub fn level_color(percent: u64, warning: u8, critical: u8) ?u32 {
    if (percent >= critical) return ctx.cfg.bar.widget_colors.critical;
    if (percent >= warning) return ctx.cfg.bar.widget_colors.warning;
    return null;
}


// The meters of waybar.nix: 17 levels in two braille cells. U+2800 is the
// blank braille cell, so the width stays the same.
const braille_levels = [_][]const u8 {
    "⠀⠀", "⡀⠀", "⡄⠀", "⡆⠀", "⡇⠀", "⣇⠀", "⣧⠀", "⣷⠀", "⣿⠀",
    "⣿⡀", "⣿⡄", "⣿⡆", "⣿⡇", "⣿⣇", "⣿⣧", "⣿⣷", "⣿⣿",
};


/// A meter widget configuration has `format`, `warning` and `critical`.
pub fn append_meter(text: *std.ArrayList(u8), meter: anytype, percent: u64) !void {
    const color = level_color(percent, meter.warning, meter.critical);
    switch (meter.format) {
        .braille => {
            const index = @min(percent * braille_levels.len / 100, braille_levels.len - 1);
            try append_colored(text, color, braille_levels[index]);
        },
        .percent => {
            var buffer: [8]u8 = undefined;
            try append_colored(text, color, try fmt.bufPrint(&buffer, "{}%", .{ percent }));
        },
    }
}


/// Read a file of /proc or /sys into `buffer`.
pub fn read_file(path: [*:0]const u8, buffer: []u8) ![]const u8 {
    const fd = try posix.openZ(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    defer posix.close(fd);

    var len: usize = 0;
    while (len < buffer.len) {
        const n = try posix.read(fd, buffer[len..]);
        if (n == 0) break;
        len += n;
    }
    return buffer[0..len];
}


/// Write `bytes` with a unit: "512B", "1.2K", "34M", "1.5G".
pub fn print_bytes(list: *std.ArrayList(u8), bytes: u64) !void {
    const units = "BKMGT";
    var value = bytes * 10;
    var unit: usize = 0;
    while (value >= 1024 * 10 and unit < units.len - 1) : (unit += 1) {
        value /= 1024;
    }
    if (unit == 0 or value >= 100) {
        try list.print(ctx.gpa, "{}{c}", .{ value / 10, units[unit] });
    } else {
        try list.print(ctx.gpa, "{}.{}{c}", .{ value / 10, value % 10, units[unit] });
    }
}
