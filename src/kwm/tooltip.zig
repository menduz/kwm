//! The tooltip of the bar widgets. There is one tooltip for all outputs.
//!
//! The pointer events of the bar select the target widget. After
//! `bar.tooltip_delay` milliseconds, the next render sequence makes a shell
//! surface below the widget. Shell surfaces change only in a manage or render
//! sequence, so `render` makes all changes.

const std = @import("std");
const mem = std.mem;
const log = std.log.scoped(.tooltip);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const wp = wayland.client.wp;
const pixman = @import("pixman");
const fcft = @import("fcft");

const utils = @import("utils.zig");
const render_ = @import("render.zig");
const widgets = @import("widgets.zig");
const Context = @import("context.zig");
const ShellSurface = @import("shell_surface.zig");
const Bar = @import("bar.zig");

const ctx = Context.get();

pub const Target = struct {
    bar: *Bar,
    side: widgets.Side,
    index: usize,
    /// The left edge of the widget, in logical coordinates of the output.
    x: i32,
};

const Surface = struct {
    wl_surface: *wl.Surface,
    shell_surface: ShellSurface,
    wp_viewport: *wp.Viewport,
    buffers: [2]render_.Buffer = .{ .{}, .{} },

    fn create() !*Surface {
        const self = try ctx.gpa.create(Surface);
        errdefer ctx.gpa.destroy(self);

        const wl_surface = try ctx.wl_compositor.createSurface();
        errdefer wl_surface.destroy();

        const wp_viewport = try ctx.wp_viewporter.getViewport(wl_surface);
        errdefer wp_viewport.destroy();

        self.* = .{
            .wl_surface = wl_surface,
            .shell_surface = undefined,
            .wp_viewport = wp_viewport,
        };
        try self.shell_surface.init(wl_surface, .tooltip);
        return self;
    }

    fn destroy(self: *Surface) void {
        self.shell_surface.deinit();
        self.wp_viewport.destroy();
        self.wl_surface.destroy();
        self.buffers[0].deinit();
        self.buffers[1].deinit();
        ctx.gpa.destroy(self);
    }

    fn next_buffer(self: *Surface) ?*render_.Buffer {
        for (&self.buffers) |*buffer| {
            if (!buffer.busy) {
                buffer.occupy();
                return buffer;
            }
        }
        return null;
    }
};

var target: ?Target = null;
var visible = false;
var dirty = false;
var surface: ?*Surface = null;
/// Each new target increases the generation, so an old delay does nothing.
var generation: u64 = 0;
var shown_generation: u64 = 0;


fn same(a: ?Target, b: ?Target) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.bar == b.?.bar and a.?.side == b.?.side and a.?.index == b.?.index;
}


/// The pointer is on this widget now, or on no widget.
pub fn hover(new: ?Target) void {
    if (same(target, new)) return;
    log.debug("hover {?}", .{ if (new) |t| t.index else null });

    target = new;
    generation += 1;
    if (visible) {
        visible = false;
        request_render();
    }
    if (new != null) {
        ctx.run_later(.fromMilliseconds(ctx.cfg.bar.tooltip_delay), show_later);
    }
}


fn show_later(_: *Context) void {
    // Show only the target of the newest hover.
    if (target == null or shown_generation == generation) return;
    shown_generation = generation;
    visible = true;
    request_render();
}


/// The text of a widget changed.
pub fn damage() void {
    if (visible) dirty = true;
}


/// The bar goes away. Forget it.
pub fn forget(bar: *Bar) void {
    if (target) |t| if (t.bar == bar) hover(null);
}


fn request_render() void {
    dirty = true;
    ctx.rwm.manageDirty();
}


/// Call in each render sequence.
pub fn render() void {
    if (!dirty) return;
    dirty = false;
    log.debug("render, target: {}, visible: {}", .{ target != null, visible });

    const t = target orelse return hide();
    if (!visible) return hide();

    const states = widgets.states(t.side);
    if (t.index >= states.len) return hide();
    const text = states[t.index].tooltip.items;
    if (text.len == 0 or states[t.index].hidden) return hide();

    if (surface == null) {
        surface = Surface.create() catch |err| {
            log.err("create tooltip surface failed: {}", .{ err });
            return;
        };
    }
    draw(surface.?, &t, text) catch |err| {
        log.err("draw tooltip failed: {}", .{ err });
        hide();
    };
}


pub fn deinit() void {
    target = null;
    visible = false;
    hide();
}


fn hide() void {
    if (surface) |s| {
        s.destroy();
        surface = null;
    }
}


fn draw(s: *Surface, t: *const Target, text: []const u8) !void {
    const bar = t.bar;
    const font = &bar.font;
    const scheme = ctx.cfg.bar.scheme.normal;
    const pad: i32 = @divFloor(font.height(), 2);
    const line_height: i32 = font.height();

    // Rasterize each line.
    var runs: std.ArrayList(*const fcft.TextRun) = .empty;
    defer {
        for (runs.items) |run| run.destroy();
        runs.deinit(ctx.gpa);
    }
    var width: i32 = 0;
    var lines = mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const utf8 = try render_.utils.to_utf8(ctx.gpa, line);
        defer ctx.gpa.free(utf8);
        const run = font.rasterize_text_run(utf8) orelse return error.RasterizeFailed;
        runs.append(ctx.gpa, run) catch |err| {
            run.destroy();
            return err;
        };
        width = @max(width, @as(i32, @intCast(render_.utils.text_width(run))));
    }

    const w: i32 = width + 2 * pad;
    const h: i32 = line_height * @as(i32, @intCast(runs.items.len)) + pad;

    const buffer = s.next_buffer() orelse return error.NoBuffer;
    try buffer.init(w, h);

    // A border in the text color around the background.
    const fg = render_.utils.color(scheme.fg);
    const bg = render_.utils.color(scheme.bg);
    var rect = [_]pixman.Rectangle16 {
        .{ .x = 0, .y = 0, .width = @intCast(w), .height = @intCast(h) },
    };
    _ = pixman.Image.fillRectangles(.src, buffer.image, &fg, 1, &rect);
    rect[0] = .{ .x = 1, .y = 1, .width = @intCast(w - 2), .height = @intCast(h - 2) };
    _ = pixman.Image.fillRectangles(.src, buffer.image, &bg, 1, &rect);

    var y: i32 = @divFloor(pad, 2);
    for (runs.items) |run| {
        _ = font.render_text(buffer, run, &fg, pad, y);
        y += line_height;
    }

    // Below a bar at the top, and above a bar at the bottom.
    const output = bar.output;
    const logical_w = utils.physics2logical(i32, w, bar.scale);
    const logical_h = utils.physics2logical(i32, h, bar.scale);
    const x = @min(t.x, output.x + output.width - logical_w);
    const pos_y = switch (ctx.cfg.bar.position) {
        .top => output.y + bar.height(true),
        .bottom => output.y + output.height - bar.height(true) - logical_h,
    };

    s.shell_surface.sync_next_commit();
    s.shell_surface.place(.top);
    s.shell_surface.set_position(@max(x, output.x), pos_y);

    s.wl_surface.attach(buffer.wl_buffer, 0, 0);
    s.wl_surface.damageBuffer(0, 0, w, h);
    s.wp_viewport.setDestination(logical_w, logical_h);
    s.wl_surface.commit();
}
