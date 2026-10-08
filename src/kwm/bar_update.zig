//! When the bar draws a change, without Wayland objects. bar.zig gives the
//! damage of a bar. `zig build test` runs the tests below.
//!
//! kwm draws in the render sequence of river, and a manage sequence comes
//! before each render sequence. A manage sequence arranges all windows. Thus
//! a change of the status (for example the clock or the CPU meter each
//! second) must not need one: the dynamic component of the bar is a
//! desynchronized subsurface, and its commit shows at once. Only a change
//! that river must place (the static component, the background) waits for a
//! render sequence.

const std = @import("std");
const testing = std.testing;


pub const Damage = struct {
    hidden: bool,
    static: bool,
    dynamic: bool,
    background: bool,
};

pub const When = enum {
    /// Nothing to draw.
    nothing,
    /// Draw the dynamic component now, outside of a render sequence.
    now,
    /// Ask river for a manage and a render sequence (manage_dirty).
    render_sequence,
};

pub fn when(damage: Damage) When {
    if (damage.hidden) return .nothing;
    if (damage.static or damage.background) return .render_sequence;
    if (damage.dynamic) return .now;
    return .nothing;
}


test "a change of the status draws now" {
    try testing.expectEqual(When.now, when(.{ .hidden = false, .static = false, .dynamic = true, .background = false }));
}

test "a change that river must place waits for a render sequence" {
    try testing.expectEqual(When.render_sequence, when(.{ .hidden = false, .static = true, .dynamic = true, .background = false }));
    try testing.expectEqual(When.render_sequence, when(.{ .hidden = false, .static = false, .dynamic = true, .background = true }));
}

test "a hidden bar draws nothing" {
    try testing.expectEqual(When.nothing, when(.{ .hidden = true, .static = true, .dynamic = true, .background = true }));
}

test "a bar without damage draws nothing" {
    try testing.expectEqual(When.nothing, when(.{ .hidden = false, .static = false, .dynamic = false, .background = false }));
}
