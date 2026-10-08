//! The title bar of a window with server side decorations, as the caption of
//! win-classic-theme: the title on the title color (a gradient for the
//! focused window), and the close button at the right end. A window of a
//! sandbox shows the name of the sandbox before the title, in the color of
//! the sandbox. A decoration above the window holds the title bar.
//! decoration.zig gives the sizes and the pixels of the close button, and
//! theme.zig the colors.
//!
//! kwm gets the pointer events of its own surfaces, as for the bar: a press
//! on the close button shows the pressed button, and a release on it closes
//! the window.
//!
//! The title bar uses the font and the scale of the bar of the output.

const Self = @This();

const std = @import("std");
const log = std.log.scoped(.title_bar);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const wp = wayland.client.wp;
const river = wayland.client.river;
const pixman = @import("pixman");

const config = @import("config");

const utils = @import("utils.zig");
const render_ = @import("render.zig");
const sandbox = @import("sandbox.zig");
const decoration = @import("decoration.zig");
const theme = @import("theme.zig");
const Context = @import("context.zig");
const Window = @import("window.zig");
const Bar = @import("bar.zig");

const ctx = Context.get();


/// The sandbox of the window, for the name before the title.
pub const Sandbox = struct {
    name: []const u8,
    color: u32,
};

/// The values of a title bar. `render` draws again only for other values.
pub const State = struct {
    /// The width of the window, in logical pixels.
    width: i32,
    focused: bool,
    title: []const u8,
    sandbox: ?Sandbox,
    colors: theme.TitleColors,
    bevel: config.Bevel,
};


wl_surface: *wl.Surface,
wp_viewport: *wp.Viewport,
rwm_decoration: *river.DecorationV1,
buffers: [2]render_.Buffer = .{ .{}, .{} },

/// The pointer button is down on the close button.
pressed: bool = false,
/// A release on the close button asks to close the window. The next manage
/// sequence closes it.
close_requested: bool = false,

/// What the last `draw` drew.
drawn: ?struct {
    bar: *Bar,
    scale: u32,
    width: i32,
    focused: bool,
    pressed: bool,
    /// A hash of the title and the name of the sandbox.
    text: u64,
    sandbox_color: ?u32,
    colors: theme.TitleColors,
    bevel: config.Bevel,
} = null,
offset_set: bool = false,


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


/// Draw the title bar above the window, if a value changed. Call it in a
/// render sequence.
pub fn render(self: *Self, bar: *Bar, state: State) void {
    if (!self.offset_set) {
        // The title bar is above the window, in the space that the window
        // keeps for it.
        self.rwm_decoration.setOffset(0, -decoration.height);
        self.offset_set = true;
    }

    const text = text_hash(state);
    const sandbox_color: ?u32 = if (state.sandbox) |s| s.color else null;
    if (self.drawn) |d| {
        if (d.bar == bar and d.scale == bar.scale and d.width == state.width
            and d.focused == state.focused and d.pressed == self.pressed and d.text == text
            and std.meta.eql(d.sandbox_color, sandbox_color)
            and std.meta.eql(d.colors, state.colors) and std.meta.eql(d.bevel, state.bevel)) return;
    }

    self.draw(bar, state) catch |err| {
        log.err("<{*}> draw failed: {}", .{ self, err });
        return;
    };
    self.drawn = .{
        .bar = bar,
        .scale = bar.scale,
        .width = state.width,
        .focused = state.focused,
        .pressed = self.pressed,
        .text = text,
        .sandbox_color = sandbox_color,
        .colors = state.colors,
        .bevel = state.bevel,
    };
}


fn text_hash(state: State) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(state.title);
    if (state.sandbox) |s| {
        hasher.update(&.{ 0 });
        hasher.update(s.name);
    }
    return hasher.final();
}


/// 0xRRGGBBAA to a pixel of a8r8g8b8 (an opaque color).
fn pixel(rgba: u32) u32 {
    return (rgba >> 8) | (rgba << 24);
}


fn fill(pixels: []u32, stride: i32, x: i32, y: i32, w: i32, h: i32, rgba: u32) void {
    const p = pixel(rgba);
    var row = y;
    while (row < y + h) : (row += 1) {
        const start: usize = @intCast(row * stride + x);
        @memset(pixels[start .. start + @as(usize, @intCast(w))], p);
    }
}


/// The caption from column `from` to the right end: the title color.
fn fill_caption(pixels: []u32, stride: i32, from: i32, w: i32, caption: i32, colors: theme.TitleColors) void {
    var x = from;
    while (x < w) : (x += 1) {
        fill(pixels, stride, x, 0, 1, caption, decoration.gradient(colors.start, colors.end, x, w));
    }
}


fn draw(self: *Self, bar: *Bar, state: State) !void {
    const font = &bar.font;
    const scale = bar.scale;

    const w = utils.logical2physics(i32, state.width, scale);
    const h = utils.logical2physics(i32, decoration.height, scale);
    const caption = utils.logical2physics(i32, decoration.caption_height, scale);
    if (w <= 0 or h <= 0) return;

    const buffer = self.next_buffer() orelse return error.NoBuffer;
    buffer.init(w, h) catch |err| {
        buffer.busy = false;
        return err;
    };
    const pixels: []u32 = @as([*]u32, @ptrCast(@alignCast(buffer.data.ptr)))[0..@intCast(w * h)];

    // The caption, and the line of the face color below it.
    fill_caption(pixels, w, 0, w, caption, state.colors);
    fill(pixels, w, 0, caption, w, h - caption, state.bevel.face);

    // The close button: the pixels of win-classic-theme, each one a square
    // of whole pixels.
    const p: i32 = @intCast(@max(1, scale / 120));
    const button_w = decoration.button_width * p;
    const button_h = decoration.button_height * p;
    const button_x = w - utils.logical2physics(i32, decoration.button_margin, scale) - button_w;
    const button_y = @divFloor(caption - button_h, 2);

    // The name of the sandbox and the title, at the left. The text stops
    // before the close button.
    const text_y = @divFloor(caption - font.height(), 2);
    var x = utils.logical2physics(i32, decoration.text_margin, scale);
    if (state.sandbox) |s| {
        const bg = if (state.focused) s.color else sandbox.dim(s.color);
        const utf8 = try render_.utils.to_utf8(ctx.gpa, s.name);
        defer ctx.gpa.free(utf8);
        if (font.rasterize_text_run(utf8)) |run| {
            defer run.destroy();
            const pad = @divFloor(font.height(), 3);
            const badge_w = @as(i32, @intCast(render_.utils.text_width(run))) + 2 * pad;
            if (x + badge_w < button_x) {
                fill(pixels, w, x, @max(0, text_y), badge_w, @min(caption, font.height()), bg);
                const fg = render_.utils.color(sandbox.text_color(bg));
                _ = font.render_text(buffer, run, &fg, x + pad, text_y);
                x += badge_w + pad;
            }
        }
    }
    if (state.title.len > 0) {
        const utf8 = try render_.utils.to_utf8(ctx.gpa, state.title);
        defer ctx.gpa.free(utf8);
        if (font.rasterize_text_run(utf8)) |run| {
            defer run.destroy();
            const fg = render_.utils.color(state.colors.text);
            _ = font.render_text(buffer, run, &fg, x, text_y);
        }
    }
    // The title color again from the space before the button: it covers a
    // long title.
    const text_end = @max(0, button_x - 2 * p);
    fill_caption(pixels, w, text_end, w, caption, state.colors);

    if (button_x >= 0) {
        for (0..decoration.button_height) |by| {
            for (0..decoration.button_width) |bx| {
                const color = switch (decoration.button_pixel(self.pressed, bx, by)) {
                    .frame => state.bevel.frame,
                    .shadow => state.bevel.shadow,
                    .face => state.bevel.face,
                    .highlight => state.bevel.highlight,
                    .glyph => state.colors.button_text,
                };
                fill(
                    pixels, w,
                    button_x + @as(i32, @intCast(bx)) * p, button_y + @as(i32, @intCast(by)) * p,
                    p, p, color,
                );
            }
        }
    }

    self.rwm_decoration.syncNextCommit();
    self.wl_surface.attach(buffer.wl_buffer, 0, 0);
    self.wl_surface.damageBuffer(0, 0, w, h);
    self.wp_viewport.setDestination(state.width, decoration.height);
    self.wl_surface.commit();
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


fn find(surface: *wl.Surface) ?struct { window: *Window, title_bar: *Self } {
    var it = ctx.windows.safeIterator(.forward);
    while (it.next()) |window| {
        const title_bar = &(window.title_bar orelse continue);
        if (title_bar.wl_surface == surface) return .{ .window = window, .title_bar = title_bar };
    }
    return null;
}


/// A pointer button changed on the surface `surface` of kwm, at `x`, `y` in
/// logical pixels. Returns true for the surface of a title bar.
pub fn pointer_button(surface: *wl.Surface, x: i32, y: i32, pressed: bool) bool {
    const found = find(surface) orelse return false;
    const self = found.title_bar;
    const d = self.drawn orelse return true;
    const on_button = decoration.close_button(d.width).contains(x, y);

    if (pressed) {
        if (on_button and !self.pressed) {
            self.pressed = true;
            ctx.manage_dirty(@src());
        }
    } else if (self.pressed) {
        self.pressed = false;
        if (on_button) {
            log.debug("<{*}> close {*}", .{ self, found.window });
            self.close_requested = true;
        }
        ctx.manage_dirty(@src());
    }
    return true;
}


/// The pointer left the surface `surface` of kwm. A pressed close button
/// comes up, without a close.
pub fn pointer_leave(surface: *wl.Surface) void {
    const found = find(surface) orelse return;
    if (found.title_bar.pressed) {
        found.title_bar.pressed = false;
        ctx.manage_dirty(@src());
    }
}
