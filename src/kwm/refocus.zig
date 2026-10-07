//! The keyboard focus after a drag and drop, without Wayland objects.
//! seat.zig gives the events to these functions and sends the result to
//! river. `zig build test` runs the tests below.
//!
//! river keeps the focus of a seat in two places: the focus that river knows
//! (Seat.focused) and the keyboard focus of wlroots. During a drag, wlroots
//! drops each keyboard enter, and river (0.5) does not send the focus again
//! after the drag. Thus with sloppy_focus, a drag from window A over window B
//! gives:
//!
//! - river knows B as focused, and B shows as activated,
//! - the keyboard stays on A, the source of the drag,
//! - river ignores a focus request for B, because it knows B as focused.
//!
//! Brave closes the source window when a tab goes into another window. Then
//! the keyboard has no focus, and B never gets it.
//!
//! kwm cannot see a drag. When a window closes that does not have the last
//! focus request of kwm, the keyboard can be on that window. Then kwm clears
//! the focus in this manage sequence, and requests the focus in the next one.
//! river then sends a keyboard enter. A close of the focused window does not
//! need this: river clears its focus when the window closes.

const std = @import("std");
const testing = std.testing;


/// The last focus request of kwm for a seat, relative to a window that
/// closes.
pub const LastRequest = enum {
    /// No focus request for a window.
    none,
    /// The focus request was for the window that closes.
    this_window,
    /// The focus request was for another window.
    other_window,
};

/// The request to send to river for a seat that has a window to focus.
pub const Request = enum {
    /// Request the focus for the window.
    focus,
    /// Clear the focus, and request a manage sequence (manage_dirty). The
    /// next manage sequence requests the focus.
    clear,
};

pub const State = struct {
    pending: bool = false,

    /// A window closes.
    pub fn window_closed(self: *State, last_request: LastRequest) void {
        if (last_request == .other_window) self.pending = true;
    }

    /// The request in this manage sequence, for a seat that has a window to
    /// focus.
    pub fn request(self: *State) Request {
        if (!self.pending) return .focus;
        self.pending = false;
        return .clear;
    }

    /// The seat has no window to focus, and kwm clears the focus. This also
    /// sends a keyboard leave, thus the focus needs no other change.
    pub fn cleared(self: *State) void {
        self.pending = false;
    }
};


test "a close of the window of the last focus request needs no change" {
    var state: State = .{};
    state.window_closed(.this_window);
    try testing.expectEqual(Request.focus, state.request());
}

test "a close of another window clears the focus once" {
    var state: State = .{};
    state.window_closed(.other_window);
    try testing.expectEqual(Request.clear, state.request());
    // The next manage sequence requests the focus.
    try testing.expectEqual(Request.focus, state.request());
    try testing.expectEqual(Request.focus, state.request());
}

test "a close without a focus request needs no change" {
    var state: State = .{};
    state.window_closed(.none);
    try testing.expectEqual(Request.focus, state.request());
}

test "two closes in one manage sequence clear the focus once" {
    var state: State = .{};
    state.window_closed(.other_window);
    state.window_closed(.this_window);
    try testing.expectEqual(Request.clear, state.request());
    try testing.expectEqual(Request.focus, state.request());
}

test "a clear without a window to focus ends the change" {
    var state: State = .{};
    state.window_closed(.other_window);
    state.cleared();
    try testing.expectEqual(Request.focus, state.request());
}
