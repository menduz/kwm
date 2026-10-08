//! The decorations of a window, without Wayland objects: the negotiation of
//! server side decorations, and the title bar of win-classic-theme (the
//! win98/ submodule of nix-config). window.zig and title_bar.zig give the
//! values of a window to these functions. `zig build test` runs the tests
//! below.

const std = @import("std");
const testing = std.testing;


pub const Mode = enum { csd, ssd };


/// The decorations that kwm asks the client to use. kwm always tries server
/// side decorations: only a client without xdg-decoration (for example GTK3)
/// draws its own. A window rule comes first.
pub fn mode(rule: ?Mode, only_supports_csd: bool, default: Mode) Mode {
    if (rule) |m| return m;
    if (only_supports_csd) return .csd;
    return default;
}


/// The height of the title bar, in logical pixels: the caption of Windows
/// (18 pixels), and a line of the face color between it and the window.
pub const caption_height = 18;
pub const height = caption_height + 1;

/// The close button of Windows, in logical pixels, at the right end of the
/// caption.
pub const button_width = 16;
pub const button_height = 14;
/// The space between the button and the right end and the top of the
/// caption.
pub const button_margin = 2;

/// The space at the left of the title.
pub const text_margin = 3;


pub const Window = struct {
    ssd: bool,
    /// kwm maximizes the window.
    maximized: bool,
    /// The layout gives the window all of the output. The client knows the
    /// window as maximized.
    fills_output: bool,
    fullscreen: bool,
};


/// A window with server side decorations has a title bar, except when it is
/// maximized or fullscreen.
pub fn has_title_bar(window: Window) bool {
    return window.ssd and !window.maximized and !window.fills_output and !window.fullscreen;
}


pub const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,

    pub fn contains(rect: Rect, x: i32, y: i32) bool {
        return x >= rect.x and x < rect.x + rect.width and y >= rect.y and y < rect.y + rect.height;
    }
};


/// The close button in a title bar of `width` logical pixels. The
/// coordinates are relative to the title bar.
pub fn close_button(width: i32) Rect {
    return .{
        .x = width - button_margin - button_width,
        .y = button_margin,
        .width = button_width,
        .height = button_height,
    };
}


/// The color at `x` of a gradient from `start` (at 0) to `end` (at
/// `width - 1`), as Windows paints the caption of the active window. The
/// colors are 0xRRGGBBAA.
pub fn gradient(start: u32, end: u32, x: i32, width: i32) u32 {
    if (width <= 1) return start;
    const pos: i64 = std.math.clamp(x, 0, width - 1);
    const span: i64 = width - 1;
    var result: u32 = 0;
    inline for (.{ 24, 16, 8, 0 }) |shift| {
        const a: i64 = (start >> shift) & 0xff;
        const b: i64 = (end >> shift) & 0xff;
        const c: i64 = a + @divFloor((b - a) * pos + @divFloor(span, 2), span);
        result |= @as(u32, @intCast(c)) << shift;
    }
    return result;
}


/// A pixel of the close button.
pub const Pixel = enum { frame, shadow, face, highlight, glyph };

/// The close button of win-classic-theme: xfwm4/close-active.xpm, without
/// the transparent rows and columns.
///
///     .  frame       +  highlight       @  face
///     #  shadow      o  glyph (the text color of a button)
///
/// The pressed button is the sunken edge of Windows (DrawFrameControl with
/// DFCS_PUSHED): the frame and then the shadow at the top and the left, the
/// highlight at the bottom and the right, and the glyph one pixel down and
/// right. xfwm4/close-pressed.xpm has a different top edge (the shadow, then
/// the face), thus its left edge looks darker than its top edge.
const button_rows = [button_height]*const [button_width]u8{
    "+++++++++++++++.",
    "+@@@@@@@@@@@@@#.",
    "+@@@@@@@@@@@@@#.",
    "+@@@oo@@@@oo@@#.",
    "+@@@@oo@@oo@@@#.",
    "+@@@@@oooo@@@@#.",
    "+@@@@@@oo@@@@@#.",
    "+@@@@@oooo@@@@#.",
    "+@@@@oo@@oo@@@#.",
    "+@@@oo@@@@oo@@#.",
    "+@@@@@@@@@@@@@#.",
    "+@@@@@@@@@@@@@#.",
    "+##############.",
    "................",
};
const pressed_rows = [button_height]*const [button_width]u8{
    "...............+",
    ".#############@+",
    ".#@@@@@@@@@@@@@+",
    ".#@@@@@@@@@@@@@+",
    ".#@@@oo@@@@oo@@+",
    ".#@@@@oo@@oo@@@+",
    ".#@@@@@oooo@@@@+",
    ".#@@@@@@oo@@@@@+",
    ".#@@@@@oooo@@@@+",
    ".#@@@@oo@@oo@@@+",
    ".#@@@oo@@@@oo@@+",
    ".#@@@@@@@@@@@@@+",
    ".#@@@@@@@@@@@@@+",
    "++++++++++++++++",
};


/// The pixel at `x`, `y` of the close button, in logical pixels.
pub fn button_pixel(pressed: bool, x: usize, y: usize) Pixel {
    const rows = if (pressed) &pressed_rows else &button_rows;
    return switch (rows[y][x]) {
        '.' => .frame,
        '#' => .shadow,
        '+' => .highlight,
        'o' => .glyph,
        else => .face,
    };
}


test "mode: kwm always tries server side decorations" {
    // A client with xdg-decoration gets server side decorations, also when it
    // prefers client side decorations.
    try testing.expectEqual(Mode.ssd, mode(null, false, .ssd));
    // The configuration can choose client side decorations.
    try testing.expectEqual(Mode.csd, mode(null, false, .csd));
    // A client without xdg-decoration draws its own.
    try testing.expectEqual(Mode.csd, mode(null, true, .ssd));
    // A window rule comes first.
    try testing.expectEqual(Mode.csd, mode(.csd, false, .ssd));
    try testing.expectEqual(Mode.ssd, mode(.ssd, true, .ssd));
}

test "has_title_bar: a window with server side decorations that is not maximized" {
    const window: Window = .{ .ssd = true, .maximized = false, .fills_output = false, .fullscreen = false };
    try testing.expect(has_title_bar(window));
    var w = window;
    w.ssd = false;
    try testing.expect(!has_title_bar(w));
    w = window;
    w.maximized = true;
    try testing.expect(!has_title_bar(w));
    w = window;
    w.fills_output = true;
    try testing.expect(!has_title_bar(w));
    w = window;
    w.fullscreen = true;
    try testing.expect(!has_title_bar(w));
}

test "close_button: at the right end of the caption" {
    const b = close_button(400);
    try testing.expectEqual(Rect{ .x = 382, .y = 2, .width = 16, .height = 14 }, b);
    try testing.expect(b.contains(382, 2));
    try testing.expect(b.contains(397, 15));
    try testing.expect(!b.contains(398, 8));
    try testing.expect(!b.contains(381, 8));
    try testing.expect(!b.contains(390, 16));
    // The button fits in the caption.
    try testing.expect(b.y + b.height <= caption_height);
}

test "gradient: from the start color to the end color" {
    const start: u32 = 0x000080ff;
    const end: u32 = 0x1084d0ff;
    try testing.expectEqual(start, gradient(start, end, 0, 100));
    try testing.expectEqual(end, gradient(start, end, 99, 100));
    try testing.expectEqual(@as(u32, 0x0842a8ff), gradient(start, end, 50, 101));
    // Out of range and a narrow bar.
    try testing.expectEqual(end, gradient(start, end, 500, 100));
    try testing.expectEqual(start, gradient(start, end, 0, 1));
}

test "button_pixel: each row has the width of the button" {
    for (button_rows, pressed_rows) |row, pressed_row| {
        try testing.expectEqual(@as(usize, button_width), row.len);
        try testing.expectEqual(@as(usize, button_width), pressed_row.len);
    }
}

test "button_pixel: the close button of win-classic-theme" {
    try testing.expectEqual(Pixel.highlight, button_pixel(false, 0, 0));
    try testing.expectEqual(Pixel.frame, button_pixel(false, 15, 0));
    try testing.expectEqual(Pixel.frame, button_pixel(false, 0, 13));
    try testing.expectEqual(Pixel.shadow, button_pixel(false, 14, 5));
    try testing.expectEqual(Pixel.face, button_pixel(false, 1, 1));
    try testing.expectEqual(Pixel.glyph, button_pixel(false, 4, 3));
    // Pressed: the bevel is inverted and the glyph moves one pixel.
    try testing.expectEqual(Pixel.frame, button_pixel(true, 0, 0));
    try testing.expectEqual(Pixel.frame, button_pixel(true, 1, 0));
    try testing.expectEqual(Pixel.shadow, button_pixel(true, 1, 1));
    try testing.expectEqual(Pixel.highlight, button_pixel(true, 15, 0));
    try testing.expectEqual(Pixel.highlight, button_pixel(true, 15, 13));
    try testing.expectEqual(Pixel.highlight, button_pixel(true, 0, 13));
    try testing.expectEqual(Pixel.face, button_pixel(true, 4, 3));
    try testing.expectEqual(Pixel.glyph, button_pixel(true, 5, 4));
}

test "button_pixel: the glyph is the same in both buttons, one pixel apart" {
    for (0..button_height - 1) |y| {
        for (0..button_width - 1) |x| {
            const normal = button_pixel(false, x, y) == .glyph;
            const pressed = button_pixel(true, x + 1, y + 1) == .glyph;
            try testing.expectEqual(normal, pressed);
        }
    }
}

test "button_pixel: the edges of the pressed button are the same at the top and at the left" {
    // The outer line: the frame. The inner line: the shadow.
    for (0..button_height - 1) |i| {
        try testing.expectEqual(button_pixel(true, i, 0), button_pixel(true, 0, i));
        if (i >= 1) try testing.expectEqual(button_pixel(true, i, 1), button_pixel(true, 1, i));
    }
    // The bottom and the right edges are the highlight.
    for (0..button_width) |x| try testing.expectEqual(Pixel.highlight, button_pixel(true, x, button_height - 1));
    for (0..button_height) |y| try testing.expectEqual(Pixel.highlight, button_pixel(true, button_width - 1, y));
}
