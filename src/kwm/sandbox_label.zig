//! The label of a sandbox window: the name of the sandbox, in the color of
//! the sandbox, at the top right corner of the window. A decoration above the
//! window holds the label. Refer to sandbox.zig and `sandbox.label` in the
//! configuration.
//!
//! The label uses the font and the scale of the bar of the output.

const Self = @This();

const std = @import("std");
const log = std.log.scoped(.sandbox_label);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const wp = wayland.client.wp;
const river = wayland.client.river;
const pixman = @import("pixman");

const utils = @import("utils.zig");
const render_ = @import("render.zig");
const sandbox = @import("sandbox.zig");
const Context = @import("context.zig");
const Window = @import("window.zig");
const Bar = @import("bar.zig");

const ctx = Context.get();


wl_surface: *wl.Surface,
wp_viewport: *wp.Viewport,
rwm_decoration: *river.DecorationV1,
buffers: [2]render_.Buffer = .{ .{}, .{} },

/// The last state that `render` drew. `render` draws the buffer again only
/// for a different state.
drawn: ?struct {
    bar: *Bar,
    scale: u32,
    color: u32,
    focused: bool,
    /// The size of the label, in logical pixels.
    width: i32,
    height: i32,
} = null,
/// The last offset from the top left corner of the window.
offset_x: ?i32 = null,


pub fn init(self: *Self, window: *Window) !void {
    log.debug("<{*}> init", .{ self });

    const wl_surface = try ctx.wl_compositor.createSurface();
    errdefer wl_surface.destroy();

    const wp_viewport = try ctx.wp_viewporter.getViewport(wl_surface);
    errdefer wp_viewport.destroy();

    const rwm_decoration = try window.rwm_window.getDecorationAbove(wl_surface);
    errdefer rwm_decoration.destroy();

    self.* = .{
        .wl_surface = wl_surface,
        .wp_viewport = wp_viewport,
        .rwm_decoration = rwm_decoration,
    };
}


pub fn deinit(self: *Self) void {
    log.debug("<{*}> deinit", .{ self });

    self.rwm_decoration.destroy();
    self.wp_viewport.destroy();
    self.wl_surface.destroy();
    self.buffers[0].deinit();
    self.buffers[1].deinit();
}


/// Draw the label `name` on a window that is `window_width` logical pixels
/// wide. Call it in a render sequence.
pub fn render(self: *Self, bar: *Bar, name: []const u8, color: u32, focused: bool, window_width: i32) void {
    const same =
        if (self.drawn) |d|
            d.bar == bar and d.scale == bar.scale and d.color == color and d.focused == focused
        else false;

    if (!same) {
        self.draw(bar, name, color, focused) catch |err| {
            log.err("<{*}> draw failed: {}", .{ self, err });
            return;
        };
    }

    const d = self.drawn orelse return;
    // A small space between the label and the right edge of the window.
    const inset = @divFloor(d.height, 2);
    const x = @max(0, window_width - d.width - inset);
    if (!same or self.offset_x != x) {
        self.offset_x = x;
        self.rwm_decoration.setOffset(x, 0);
    }
}


fn draw(self: *Self, bar: *Bar, name: []const u8, color: u32, focused: bool) !void {
    const font = &bar.font;

    const utf8 = try render_.utils.to_utf8(ctx.gpa, name);
    defer ctx.gpa.free(utf8);
    const run = font.rasterize_text_run(utf8) orelse return error.RasterizeFailed;
    defer run.destroy();

    // The label has a space of half the font height at the left and at the
    // right, and a space of one eighth of the font height at the top and at
    // the bottom.
    const pad_x: i32 = @divFloor(font.height(), 2);
    const pad_y: i32 = @max(1, @divFloor(font.height(), 8));
    const w: i32 = @as(i32, @intCast(render_.utils.text_width(run))) + 2 * pad_x;
    const h: i32 = font.height() + 2 * pad_y;

    const buffer = self.next_buffer() orelse return error.NoBuffer;
    buffer.init(w, h) catch |err| {
        buffer.busy = false;
        return err;
    };

    // A window without the focus has the dim color of the sandbox.
    const bg_rgba = if (focused) color else sandbox.dim(color);
    const bg = render_.utils.color(bg_rgba);
    const fg = render_.utils.color(sandbox.text_color(bg_rgba));
    var rect = [_]pixman.Rectangle16 {
        .{ .x = 0, .y = 0, .width = @intCast(w), .height = @intCast(h) },
    };
    _ = pixman.Image.fillRectangles(.src, buffer.image, &bg, 1, &rect);
    _ = font.render_text(buffer, run, &fg, pad_x, pad_y);

    const logical_w = utils.physics2logical(i32, w, bar.scale);
    const logical_h = utils.physics2logical(i32, h, bar.scale);

    self.rwm_decoration.syncNextCommit();
    self.wl_surface.attach(buffer.wl_buffer, 0, 0);
    self.wl_surface.damageBuffer(0, 0, w, h);
    self.wp_viewport.setDestination(logical_w, logical_h);
    self.wl_surface.commit();

    self.drawn = .{
        .bar = bar,
        .scale = bar.scale,
        .color = color,
        .focused = focused,
        .width = logical_w,
        .height = logical_h,
    };
}


fn next_buffer(self: *Self) ?*render_.Buffer {
    for (&self.buffers) |*buffer| {
        if (!buffer.busy) {
            buffer.occupy();
            return buffer;
        }
    }
    return null;
}
