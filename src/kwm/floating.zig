//! The position of a floating window, without Wayland objects. window.zig and
//! seat.zig give the values of a window to these functions.
//! `zig build test` runs the tests below.

const std = @import("std");
const testing = std.testing;


pub const Position = struct {
    x: i32,
    y: i32,
};


/// The position of a window at the center of an area. The coordinates are
/// relative to the area.
pub fn center(width: i32, height: i32, area_width: i32, area_height: i32) Position {
    return .{
        .x = @divFloor(area_width - width, 2),
        .y = @divFloor(area_height - height, 2),
    };
}


/// True when kwm moves a window to the center after the toggle_floating
/// action. Only a window that becomes floating moves. A floating geometry that
/// kwm remembers (remember_floating_geometry) stays as it is.
pub fn centers_on_toggle(floating: bool, remembered_geometry: bool) bool {
    return floating and !remembered_geometry;
}


test "center: the window is at the center of the area" {
    try testing.expectEqual(Position{ .x = 320, .y = 148 }, center(640, 400, 1280, 696));
    // The area has the size of the window.
    try testing.expectEqual(Position{ .x = 0, .y = 0 }, center(1280, 696, 1280, 696));
}

test "center: an odd difference rounds down" {
    try testing.expectEqual(Position{ .x = 0, .y = 0 }, center(1279, 695, 1280, 696));
    try testing.expectEqual(Position{ .x = 1, .y = 1 }, center(1277, 693, 1280, 696));
}

test "center: a window larger than the area has a negative position" {
    try testing.expectEqual(Position{ .x = -10, .y = -5 }, center(1300, 706, 1280, 696));
}

test "centers_on_toggle: only a window that becomes floating" {
    try testing.expect(centers_on_toggle(true, false));
    // The window becomes tiled. The layout gives its position.
    try testing.expect(!centers_on_toggle(false, false));
    try testing.expect(!centers_on_toggle(false, true));
}

test "centers_on_toggle: a remembered floating geometry stays" {
    try testing.expect(!centers_on_toggle(true, true));
}
