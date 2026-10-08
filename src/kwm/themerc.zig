//! The colors of an xfwm4 theme, in <theme>/xfwm4/themerc, without I/O.
//! theme.zig reads the file. `zig build test` runs the tests below.
//!
//! A line is "key=value". kwm reads a value "#rrggbb" or "#rgb" as a color,
//! and skips the other lines (for example "button_layout=O|C"). The parser
//! accepts spaces and tabs around the key and the value, empty lines, "\r"
//! at the end of a line, and comment lines: the first character after the
//! spaces is "#". A value stops at the first space or tab.
//!
//! win-classic-theme writes these keys (the xfwm4 names, and two keys that
//! xfwm4 does not read):
//!
//!     active_color_1          the caption of the focused window
//!     active_gradient_color   the right end of that caption (not xfwm4)
//!     active_text_color       the title of the focused window
//!     inactive_color_1, inactive_gradient_color, inactive_text_color
//!     active_color_2          the face of the frame and of the buttons
//!     active_hilight_2        the highlight of the 3D edges
//!     active_shadow_2         the shadow of the 3D edges
//!     active_border_color     the frame: the dark outer edge
//!     buttons_color           the glyph of a button (not xfwm4)

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const testing = std.testing;


pub const Entry = struct {
    key: []const u8,
    /// 0xRRGGBBff.
    color: u32,
};


pub const Iterator = struct {
    lines: mem.TokenIterator(u8, .scalar),

    pub fn next(self: *Iterator) ?Entry {
        while (self.lines.next()) |raw| {
            const line = mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;

            const eq = mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = mem.trim(u8, line[0..eq], " \t");
            if (key.len == 0) continue;

            var value = mem.trim(u8, line[eq + 1 ..], " \t");
            if (mem.indexOfAny(u8, value, " \t")) |end| value = value[0..end];
            const color = parse_hex(value) orelse continue;

            return .{ .key = key, .color = color };
        }
        return null;
    }
};


/// The colors of the text of a themerc file, in the order of the file.
pub fn iterate(text: []const u8) Iterator {
    return .{ .lines = mem.tokenizeScalar(u8, text, '\n') };
}


/// "#rrggbb" or "#rgb" to 0xRRGGBBff.
pub fn parse_hex(value: []const u8) ?u32 {
    if (value.len == 0 or value[0] != '#') return null;
    const digits = value[1..];
    const rgb: u32 = switch (digits.len) {
        6 => blk: {
            for (digits) |d| _ = fmt.charToDigit(d, 16) catch return null;
            break :blk fmt.parseInt(u32, digits, 16) catch return null;
        },
        3 => blk: {
            var v: u32 = 0;
            for (digits) |d| {
                const n = fmt.charToDigit(d, 16) catch return null;
                v = (v << 8) | (n * 17);
            }
            break :blk v;
        },
        else => return null,
    };
    return (rgb << 8) | 0xff;
}


fn expect_entries(text: []const u8, expected: []const Entry) !void {
    var it = iterate(text);
    for (expected) |entry| {
        const got = it.next() orelse return error.TestExpectedEntry;
        try testing.expectEqualStrings(entry.key, got.key);
        try testing.expectEqual(entry.color, got.color);
    }
    try testing.expectEqual(@as(?Entry, null), it.next());
}

test "iterate: the colors of a themerc of win-classic-theme" {
    try expect_entries(
        \\active_color_1=#6c2525
        \\inactive_color_1=#434444
        \\active_border_color=#060606
        \\button_layout=O|C
        \\button_offset=1
        \\full_width_title=true
        \\active_text_color=#dddddd
    , &.{
        .{ .key = "active_color_1", .color = 0x6c2525ff },
        .{ .key = "inactive_color_1", .color = 0x434444ff },
        .{ .key = "active_border_color", .color = 0x060606ff },
        .{ .key = "active_text_color", .color = 0xddddddff },
    });
}

test "iterate: spaces, tabs and carriage returns around the key and the value" {
    try expect_entries(
        "  active_color_1 = #6c2525  \r\n" ++
        "\tactive_color_2\t=\t#303131\t\r\n" ++
        "active_text_color=   #dddddd\n" ++
        "buttons_color =#ddd   trailing words\n",
    &.{
        .{ .key = "active_color_1", .color = 0x6c2525ff },
        .{ .key = "active_color_2", .color = 0x303131ff },
        .{ .key = "active_text_color", .color = 0xddddddff },
        .{ .key = "buttons_color", .color = 0xddddddff },
    });
}

test "iterate: comments, empty lines and lines without a color" {
    try expect_entries(
        \\# a comment
        \\   # an indented comment=#ffffff
        \\
        \\no equal sign #ffffff
        \\=#ffffff
        \\empty_value=
        \\not_a_color=6c2525
        \\bad_hex=#6c25zz
        \\too_long=#6c252500
        \\active_color_1=#6C2525
    , &.{
        .{ .key = "active_color_1", .color = 0x6c2525ff },
    });
}

test "iterate: an empty text has no colors" {
    try expect_entries("", &.{});
    try expect_entries("\n\r\n  \n", &.{});
}

test "parse_hex: six and three digits" {
    try testing.expectEqual(@as(?u32, 0x6c2525ff), parse_hex("#6c2525"));
    try testing.expectEqual(@as(?u32, 0xaabbccff), parse_hex("#abc"));
    try testing.expectEqual(@as(?u32, null), parse_hex("#ab"));
    try testing.expectEqual(@as(?u32, null), parse_hex("6c2525"));
    try testing.expectEqual(@as(?u32, null), parse_hex("#+12345"));
}
