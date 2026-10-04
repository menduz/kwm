//! The window border style of Windows: a raised outer edge, a raised inner
//! edge, and `face` between the edges and the window. Refer to the "Window
//! Border Style" of the Windows user interface guidelines:
//!
//! - raised outer edge: `face` at the top and left, `frame` at the bottom and
//!   right.
//! - raised inner edge: `highlight` at the top and left, `shadow` at the
//!   bottom and right.
//!
//! A border of 3 pixels or more also has an outline of 1 pixel in `outline`
//! outside the outer edge. The outline shows the focused window.
//!
//! A decoration below the window holds one solid color strip for each line.
//! The strips of the bottom and right lines are above the others, thus they
//! take the corners, as in the frame of Windows.

const Self = @This();

const std = @import("std");
const log = std.log.scoped(.raised_border);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const wp = wayland.client.wp;
const river = wayland.client.river;

const config = @import("config");

const Context = @import("context.zig");
const Window = @import("window.zig");
const SolidColorComponent = @import("render/solid_color_component.zig");

const ctx = Context.get();

/// The strips, from the bottom of the stack to the top.
const Strip = enum {
    outline_top,
    outline_bottom,
    outline_left,
    outline_right,
    fill_top,
    fill_bottom,
    fill_left,
    fill_right,
    face_top,
    face_left,
    highlight_top,
    highlight_left,
    shadow_bottom,
    shadow_right,
    frame_bottom,
    frame_right,
};

const strip_count = @typeInfo(Strip).@"enum".fields.len;


wl_surface: *wl.Surface,
wp_viewport: *wp.Viewport,
rwm_decoration: *river.DecorationV1,
strips: [strip_count]SolidColorComponent = undefined,

/// The last state that `render` drew. `render` does nothing for the same state.
drawn: ?struct {
    width: i32,
    height: i32,
    border: i32,
    bevel: config.Bevel,
} = null,


pub fn init(self: *Self, window: *Window) !void {
    log.debug("<{*}> init", .{ self });

    const wl_surface = try ctx.wl_compositor.createSurface();
    errdefer wl_surface.destroy();

    const wp_viewport = try ctx.wp_viewporter.getViewport(wl_surface);
    errdefer wp_viewport.destroy();

    const rwm_decoration = try window.rwm_window.getDecorationBelow(wl_surface);
    errdefer rwm_decoration.destroy();

    self.* = .{
        .wl_surface = wl_surface,
        .wp_viewport = wp_viewport,
        .rwm_decoration = rwm_decoration,
    };

    // A new subsurface goes above the subsurfaces that the parent has already.
    var count: usize = 0;
    errdefer for (self.strips[0..count]) |*strip| strip.deinit();
    for (&self.strips) |*strip| {
        try strip.init(wl_surface);
        count += 1;
    }
}


pub fn deinit(self: *Self) void {
    log.debug("<{*}> deinit", .{ self });

    for (&self.strips) |*strip| strip.deinit();
    self.rwm_decoration.destroy();
    self.wp_viewport.destroy();
    self.wl_surface.destroy();
}


/// Draw the border around a window of `width` x `height`. `border` is the
/// width of the border.
pub fn render(self: *Self, width: i32, height: i32, border: i32, bevel: config.Bevel) void {
    if (self.drawn) |d| {
        if (d.width == width and d.height == height and d.border == border
            and std.meta.eql(d.bevel, bevel)) return;
    }
    self.drawn = .{ .width = width, .height = height, .border = border, .bevel = bevel };

    log.debug("<{*}> rendering {}x{}, border {}", .{ self, width, height, border });

    // The size of the decoration, with the border.
    const w = width + 2 * border;
    const h = height + 2 * border;

    self.rwm_decoration.setOffset(-border, -border);
    self.rwm_decoration.syncNextCommit();

    // The decoration itself is transparent. Only the strips have a color, so
    // a transparent window does not show a color below it.
    const buffer = ctx.wp_single_pixel_buffer_manager.createU32RgbaBuffer(0, 0, 0, 0) catch |err| {
        log.err("<{*}> create buffer failed: {}", .{ self, err });
        return;
    };
    defer buffer.destroy();

    self.wl_surface.attach(buffer, 0, 0);
    self.wl_surface.damage(0, 0, w, h);
    self.wp_viewport.setDestination(w, h);

    // The outline uses the outside pixel. The edges are inside the outline,
    // and the face fills the rest to the window.
    const o: i32 = if (border >= 3) 1 else 0;
    const ew = w - 2 * o;
    const eh = h - 2 * o;
    const e = o + 2;
    const fill = border - e;

    for (&self.strips, 0..) |*strip, i| {
        const kind: Strip = @enumFromInt(i);
        const x: i32, const y: i32, const sw: i32, const sh: i32, const color: u32 = switch (kind) {
            .outline_top => .{ 0, 0, w, 1, bevel.outline },
            .outline_bottom => .{ 0, h - 1, w, 1, bevel.outline },
            .outline_left => .{ 0, 1, 1, h - 2, bevel.outline },
            .outline_right => .{ w - 1, 1, 1, h - 2, bevel.outline },
            .fill_top => .{ e, e, w - 2 * e, fill, bevel.face },
            .fill_bottom => .{ e, h - border, w - 2 * e, fill, bevel.face },
            .fill_left => .{ e, border, fill, h - 2 * border, bevel.face },
            .fill_right => .{ w - border, border, fill, h - 2 * border, bevel.face },
            .face_top => .{ o, o, ew, 1, bevel.face },
            .face_left => .{ o, o, 1, eh, bevel.face },
            .highlight_top => .{ o + 1, o + 1, ew - 2, 1, bevel.highlight },
            .highlight_left => .{ o + 1, o + 1, 1, eh - 2, bevel.highlight },
            .shadow_bottom => .{ o + 1, o + eh - 2, ew - 2, 1, bevel.shadow },
            .shadow_right => .{ o + ew - 2, o + 1, 1, eh - 2, bevel.shadow },
            .frame_bottom => .{ o, o + eh - 1, ew, 1, bevel.frame },
            .frame_right => .{ o + ew - 1, o, 1, eh, bevel.frame },
        };

        // A border of 1 pixel has only the outer edge. A border of 2 pixels
        // has the two edges. A border of 3 pixels adds the outline.
        const needed = switch (kind) {
            .outline_top, .outline_bottom, .outline_left, .outline_right => o > 0,
            .fill_top, .fill_bottom, .fill_left, .fill_right => fill > 0,
            .highlight_top, .highlight_left, .shadow_bottom, .shadow_right => border >= 2,
            else => border >= 1,
        };
        if (!needed or sw <= 0 or sh <= 0) {
            // A transparent pixel keeps the strip, without a visible line.
            strip.render(0, 0, 1, 1, 0);
            continue;
        }
        strip.render(x, y, sw, sh, color);
    }

    self.wl_surface.commit();
}
