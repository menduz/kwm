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


/// The place of a window in its workspace: the windows on the visible tags
/// of its output.
pub const Place = struct {
    /// The layout tiles the window: it is not floating, and the output does
    /// not use the float layout.
    tiled: bool,
    /// The output uses a layout that tiles windows, not the float layout.
    tiling_layout: bool,
    /// The layout gives the window all of the output.
    fills_output: bool,
    /// Another window that the layout tiles shows in the workspace.
    other_tiled: bool,
    /// Another window, tiled or floating, shows in the workspace.
    other_window: bool,
};


/// True when the window can maximize itself. kwm gives the window the
/// maximize capability of xdg-shell only then, thus the client can hide its
/// maximize button.
///
/// - A tiled window, when no other tiled window shares its workspace. The
///   floating windows stay above it.
/// - A floating window, when it is the only window of its workspace.
///
/// The user can maximize each window (toggle_maximize).
pub fn can_maximize(place: Place) bool {
    if (place.tiled) return !place.other_tiled;
    return !place.other_window;
}


/// What kwm does for a request of the client.
pub const Action = enum {
    none,
    /// kwm maximizes the window: it ignores the layout until it loses the
    /// focus.
    maximize,
    unmaximize,
    /// The window stops floating. In a tiling layout a maximized window is
    /// not floating: it is the only tiled window, thus it fills the output.
    tile,
};


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
    ///
    /// - Before the init event, a request is only the initial state of the
    ///   client.
    /// - A window that fills the output is maximized for the client already.
    ///   Some clients ask again for that state, for example when their window
    ///   shows again after a change of tag. kwm then does not maximize the
    ///   window itself: a window that kwm maximizes has the border around it,
    ///   and ignores the layout and the floating state until it loses the
    ///   focus.
    /// - A window that cannot maximize itself (can_maximize) stays as it is.
    pub fn request(self: *State, maximize: bool, place: Place) Action {
        if (!self.initialized) {
            self.at_start = maximize;
            return .none;
        }
        if (!maximize) return .unmaximize;
        return maximize_action(place);
    }

    /// The init event, after the window rules. Returns what kwm does with a
    /// maximize request of the start of the window.
    pub fn init(self: *State, place: Place) Action {
        self.initialized = true;
        if (!self.at_start or place.tiled) return .none;
        return maximize_action(place);
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


fn maximize_action(place: Place) Action {
    if (!can_maximize(place)) return .none;
    if (place.tiled) return if (place.fills_output) .none else .maximize;
    return if (place.tiling_layout) .tile else .maximize;
}


test "fills_area: only the full exclusive area" {
    try testing.expect(fills_area(0, 0, 1280, 696, 1280, 696));
    // The tile layout with an outer gap.
    try testing.expect(!fills_area(6, 6, 1268, 684, 1280, 696));
    // The master of two windows.
    try testing.expect(!fills_area(0, 0, 640, 696, 1280, 696));
    try testing.expect(!fills_area(0, 1, 1280, 695, 1280, 696));
}

/// A place for the tests: a window alone in a tiling layout.
fn test_place(fields: struct {
    tiled: bool = true,
    tiling_layout: bool = true,
    fills_output: bool = false,
    other_tiled: bool = false,
    other_window: bool = false,
}) Place {
    return .{
        .tiled = fields.tiled,
        .tiling_layout = fields.tiling_layout,
        .fills_output = fields.fills_output,
        .other_tiled = fields.other_tiled,
        .other_window = fields.other_window or fields.other_tiled,
    };
}

test "can_maximize: a tiled window without other tiled windows" {
    try testing.expect(can_maximize(test_place(.{})));
    try testing.expect(!can_maximize(test_place(.{ .other_tiled = true })));
    // A floating window above it does not matter.
    try testing.expect(can_maximize(test_place(.{ .other_window = true })));
}

test "can_maximize: a floating window only alone in its workspace" {
    try testing.expect(can_maximize(test_place(.{ .tiled = false })));
    try testing.expect(!can_maximize(test_place(.{ .tiled = false, .other_window = true })));
    try testing.expect(!can_maximize(test_place(.{ .tiled = false, .other_tiled = true })));
}

test "request: an unmaximize request goes through" {
    var state: State = .{ .initialized = true };
    try testing.expectEqual(Action.unmaximize, state.request(false, test_place(.{})));
    try testing.expectEqual(Action.unmaximize, state.request(false, test_place(.{ .other_tiled = true })));
    try testing.expect(!state.at_start);
}

test "request: a window that fills the output is not maximized again" {
    var state: State = .{ .initialized = true };
    try testing.expectEqual(@as(?bool, true), state.sync(false, true));
    // The client asks for the state that it has already.
    try testing.expectEqual(Action.none, state.request(true, test_place(.{ .fills_output = true })));
}

test "request: a tiled window that does not fill the output is maximized" {
    // For example without smart_gaps.
    var state: State = .{ .initialized = true };
    try testing.expectEqual(Action.maximize, state.request(true, test_place(.{})));
}

test "request: a tiled window does not maximize itself next to another tiled window" {
    var state: State = .{ .initialized = true };
    try testing.expectEqual(Action.none, state.request(true, test_place(.{ .other_tiled = true })));
}

test "request: a floating window alone stops floating in a tiling layout" {
    var state: State = .{ .initialized = true };
    try testing.expectEqual(Action.tile, state.request(true, test_place(.{ .tiled = false })));
}

test "request: a floating window alone in the float layout is maximized" {
    var state: State = .{ .initialized = true };
    const place = test_place(.{ .tiled = false, .tiling_layout = false });
    try testing.expectEqual(Action.maximize, state.request(true, place));
}

test "request: a floating window with other windows does not maximize itself" {
    var state: State = .{ .initialized = true };
    try testing.expectEqual(Action.none, state.request(true, test_place(.{ .tiled = false, .other_window = true })));
    try testing.expectEqual(Action.none, state.request(true, test_place(.{ .tiled = false, .other_tiled = true })));
}

test "init: a tiled window does not keep a maximize request of its start" {
    var state: State = .{};
    try testing.expectEqual(Action.none, state.request(true, test_place(.{})));
    try testing.expectEqual(Action.none, state.init(test_place(.{})));
    try testing.expect(state.initialized);
}

test "init: a floating window alone keeps a maximize request of its start" {
    var state: State = .{};
    _ = state.request(true, test_place(.{ .tiled = false }));
    try testing.expectEqual(Action.tile, state.init(test_place(.{ .tiled = false })));
}

test "init: a floating window with other windows is not maximized at start" {
    var state: State = .{};
    _ = state.request(true, test_place(.{ .tiled = false }));
    try testing.expectEqual(Action.none, state.init(test_place(.{ .tiled = false, .other_window = true })));
}

test "init: an unmaximize request before init cancels the maximize request" {
    var state: State = .{};
    _ = state.request(true, test_place(.{ .tiled = false }));
    _ = state.request(false, test_place(.{ .tiled = false }));
    try testing.expectEqual(Action.none, state.init(test_place(.{ .tiled = false })));
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
    _ = a.init(test_place(.{ .fills_output = true }));
    try testing.expectEqual(@as(?bool, true), a.sync(false, true));

    // The client opens window b in the state of a: maximized.
    var b: State = .{};
    try testing.expectEqual(Action.none, b.request(true, test_place(.{ .other_tiled = true })));
    try testing.expectEqual(Action.none, b.init(test_place(.{ .other_tiled = true })));

    // The layout gives each window half of the output.
    try testing.expectEqual(@as(?bool, false), a.sync(false, false));
    try testing.expectEqual(@as(?bool, null), b.sync(false, false));
    try testing.expect(!a.informed);
    try testing.expect(!b.informed);
}
