//! The maximized state of a window, without Wayland objects. window.zig gives
//! the values of a window to these functions and sends the result to river.
//! `zig build test` runs the tests below.

const std = @import("std");
const testing = std.testing;


/// True when a tiled window covers all of the exclusive area of its output,
/// for example the one window with smart_gaps, or the monocle layout with
/// smart_gaps. The coordinates are relative to the exclusive area.
pub fn fills_area(x: i32, y: i32, width: i32, height: i32, area_width: i32, area_height: i32) bool {
    return x == 0 and y == 0 and width == area_width and height == area_height;
}


/// The maximized state of a window that the client asks for and that the
/// client knows.
pub const State = struct {
    /// The init event is handled. Before it, a request is only the initial
    /// state of the client.
    initialized: bool = false,
    /// The client asked to be maximized before the init event. A client often
    /// keeps its last state (Chromium gives a new window the state of the last
    /// active window). kwm tells a tiled window that fills the output that it
    /// is maximized, and the client then asks for the same state for its next
    /// window. Thus only a floating window gets this initial state.
    at_start: bool = false,
    /// The maximized state that the client knows.
    informed: bool = false,

    /// The client asks to be maximized (true) or unmaximized (false).
    /// `fills_output` is true when the layout gives the window all of the
    /// output. Returns the new maximize value of kwm, or null when kwm keeps
    /// its value.
    ///
    /// - Before the init event, a request is only the initial state of the
    ///   client.
    /// - A window that fills the output is maximized for the client already.
    ///   Some clients ask again for that state, for example when their window
    ///   shows again after a change of tag. kwm then does not maximize the
    ///   window itself: a window that kwm maximizes has the border around it,
    ///   and ignores the layout and the floating state until it loses the
    ///   focus.
    pub fn request(self: *State, maximize: bool, fills_output: bool) ?bool {
        if (!self.initialized) {
            self.at_start = maximize;
            return null;
        }
        if (maximize and fills_output) return null;
        return maximize;
    }

    /// The init event, after the window rules. Returns true when kwm maximizes
    /// the window at start.
    pub fn init(self: *State, tiled: bool) bool {
        self.initialized = true;
        return self.at_start and !tiled;
    }

    /// Returns the maximized state to send to the client, or null when the
    /// client knows it. The client is maximized when kwm maximizes it, and
    /// also when it fills the output.
    pub fn sync(self: *State, maximize: bool, fills_output: bool) ?bool {
        const maximized = maximize or fills_output;
        if (maximized == self.informed) return null;
        self.informed = maximized;
        return maximized;
    }
};


test "fills_area: only the full exclusive area" {
    try testing.expect(fills_area(0, 0, 1280, 696, 1280, 696));
    // The tile layout with an outer gap.
    try testing.expect(!fills_area(6, 6, 1268, 684, 1280, 696));
    // The master of two windows.
    try testing.expect(!fills_area(0, 0, 640, 696, 1280, 696));
    try testing.expect(!fills_area(0, 1, 1280, 695, 1280, 696));
}

test "request: a mapped window gets the request at once" {
    var state: State = .{ .initialized = true };
    try testing.expectEqual(@as(?bool, true), state.request(true, false));
    try testing.expectEqual(@as(?bool, false), state.request(false, false));
    try testing.expect(!state.at_start);
}

test "request: a window that fills the output is not maximized again" {
    var state: State = .{ .initialized = true };
    try testing.expectEqual(@as(?bool, true), state.sync(false, true));
    // The client asks for the state that it has already.
    try testing.expectEqual(@as(?bool, null), state.request(true, true));
    // An unmaximize request still goes through.
    try testing.expectEqual(@as(?bool, false), state.request(false, true));
}

test "init: a tiled window does not keep a maximize request of its start" {
    var state: State = .{};
    try testing.expectEqual(@as(?bool, null), state.request(true, false));
    try testing.expect(!state.init(true));
    try testing.expect(state.initialized);
}

test "init: a floating window keeps a maximize request of its start" {
    var state: State = .{};
    try testing.expectEqual(@as(?bool, null), state.request(true, false));
    try testing.expect(state.init(false));
}

test "init: an unmaximize request before init cancels the maximize request" {
    var state: State = .{};
    _ = state.request(true, false);
    _ = state.request(false, false);
    try testing.expect(!state.init(false));
}

test "sync: the client gets each change once" {
    var state: State = .{};
    try testing.expectEqual(@as(?bool, null), state.sync(false, false));
    try testing.expectEqual(@as(?bool, true), state.sync(false, true));
    try testing.expectEqual(@as(?bool, null), state.sync(false, true));
    try testing.expectEqual(@as(?bool, false), state.sync(false, false));
}

test "sync: a window that kwm maximizes stays maximized without the full output" {
    var state: State = .{};
    try testing.expectEqual(@as(?bool, true), state.sync(true, false));
    try testing.expectEqual(@as(?bool, null), state.sync(true, true));
    try testing.expectEqual(@as(?bool, null), state.sync(true, false));
    try testing.expectEqual(@as(?bool, false), state.sync(false, false));
}

test "a second window of the same client does not stay maximized" {
    // Window a is alone and fills the output, thus the client knows that a
    // is maximized.
    var a: State = .{};
    _ = a.init(true);
    try testing.expectEqual(@as(?bool, true), a.sync(false, true));

    // The client opens window b in the state of a: maximized.
    var b: State = .{};
    try testing.expectEqual(@as(?bool, null), b.request(true, false));
    const b_maximize = b.init(true);
    try testing.expect(!b_maximize);

    // The layout gives each window half of the output.
    try testing.expectEqual(@as(?bool, false), a.sync(false, false));
    try testing.expectEqual(@as(?bool, null), b.sync(b_maximize, false));
    try testing.expect(!a.informed);
    try testing.expect(!b.informed);
}
