const Self = @This();

const build_options = @import("build_options");
const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const unicode = std.unicode;
const log = std.log.scoped(.bar);

const wayland = @import("wayland");
const wp = wayland.client.wp;
const wl = wayland.client.wl;
const river = wayland.client.river;
const pixman = @import("pixman");
const fcft = @import("fcft");
const mvzr = @import("mvzr");

const utils = @import("utils.zig");
const types = @import("types.zig");
const render_ = @import("render.zig");
const binding = @import("binding.zig");
const Context = @import("context.zig");
const Seat = @import("seat.zig");
const Output = @import("output.zig");
const ShellSurface = @import("shell_surface.zig");
const widgets = @import("widgets.zig");
const tooltip = @import("tooltip.zig");

const ctx = Context.get();
const color_pattern = mvzr.compile("\\^#([0-9a-zA-Z]{8}|!)").?;
pub var status_buffer = [1]u8 { 0 } ** 256;

font: render_.Font = undefined,

wl_surface: *wl.Surface = undefined,
shell_surface: ShellSurface = undefined,
wp_viewport: *wp.Viewport = undefined,
wp_fractional_scale: *wp.FractionalScaleV1 = undefined,
static_component: render_.Component = undefined,
dynamic_component: render_.Component = undefined,

output: *Output,

scale: u32,
static_component_damaged: bool = true,
dynamic_component_damaged: bool = true,
background_damaged: bool = true,
hidden: bool,

dynamic_splits_buffer: [@typeInfo(types.BarArea).@"enum".fields.len-2]i32 = undefined,
static_splits: std.ArrayList(i32) = .empty,
dynamic_splits: std.ArrayList(i32) = undefined,

/// The places of the widgets in the dynamic component, in physical pixels.
widget_rects_buffer: [2 * widgets.max_widgets]WidgetRect = undefined,
widget_rects: std.ArrayList(WidgetRect) = undefined,

const WidgetRect = struct {
    side: widgets.Side,
    index: usize,
    x0: i32,
    x1: i32,
};


pub fn init(self: *Self, output: *Output) !void {
    log.debug("<{*}> init", .{ self });

    const scale = 120;

    self.* = .{
        .output = output,
        .scale = scale,
        .hidden = !ctx.cfg.bar.show_default,
    };

    try self.font.init(ctx.cfg.bar.font, scale);
    errdefer self.font.deinit();

    self.dynamic_splits = .initBuffer(&self.dynamic_splits_buffer);
    self.widget_rects = .initBuffer(&self.widget_rects_buffer);

    if (!self.hidden) {
        try self.show();
    }
}


pub fn deinit(self: *Self) void {
    log.debug("<{*}> deinit", .{ self });

    if (!self.hidden) {
        self.hidden = true;
        self.hide();
    }
    self.font.deinit();

    self.static_splits.deinit(ctx.gpa);
}


pub inline fn reload_font(self: *Self) void {
    log.debug("<{*}> reload font", .{ self });

    self.font.reload(ctx.cfg.bar.font, self.scale);
}


pub inline fn height(self: *const Self, logical: bool) i32 {
    return if (logical) utils.physics2logical(
        i32,
        self.font.height(),
        self.scale,
    ) else self.font.height();
}


pub fn handle_click(self: *Self, seat: *Seat) void {
    log.debug("<{*}> handle click by {*}", .{ self, seat });

    const pointer_x = seat.pointer_position.x;
    const pointer_y = seat.pointer_position.y;

    // ensure in range
    if (pointer_x < self.output.x or pointer_x > self.output.x + self.output.width) {
        return;
    }
    switch (ctx.cfg.bar.position) {
        .top => {
            if (pointer_y < self.output.y or pointer_y > self.output.y + self.height(true)) {
                return;
            }
        },
        .bottom => {
            if (pointer_y < self.output.y + self.output.height - self.height(true)
                or pointer_y > self.output.y + self.output.height) {
                return;
            }
        }
    }

    var action: ?binding.Action = null;
    defer if (action) |a| {
        seat.append_action(a);
    };

    var x = utils.logical2physics(i32, pointer_x - self.output.x, self.scale);
    if (ctx.cfg.bar.tags) |area| {
        if (x <= self.static_component_width()) {
            for (0.., self.static_splits.items) |i, split| {
                if (x <= split) {
                    const tag = @as(u32, @intCast(1)) << @as(u5, @intCast(i));
                    const callback_action = area.click.getter.get(seat.button) orelse return;
                    action = switch (callback_action) {
                        .set_window_tag => .{ .set_window_tag = .{ .tag = .{ .tag = tag } } },
                        .toggle_window_tag => .{ .toggle_window_tag = .{ .mask = tag } },
                        .set_output_tag => .{ .set_output_tag = .{ .tag = .{ .tag = tag } } },
                        .toggle_output_tag => .{ .toggle_output_tag = .{ .mask = tag } },
                        else => callback_action,
                    };
                    break;
                }
            }
            return;
        }
    }

    x -= self.static_component_width();
    if (self.widget_index_at(x)) |rect| {
        widgets.click(rect.side, rect.index, seat.button);
        return;
    }
    inline for (0.., &[_]types.BarArea { .mode, .layout, .title }) |i, area_type| {
        if (ctx.cfg.bar.get(area_type)) |area| {
            if (x <= self.dynamic_splits.items[i]) {
                action = area.click.getter.get(seat.button) orelse return;
                return;
            }
        }
    }

    if (ctx.cfg.bar.status) |area| {
        if (x > self.dynamic_splits.getLast()) {
            action = area.click.getter.get(seat.button) orelse return;
        }
    }
}


fn widget_index_at(self: *const Self, x: i32) ?WidgetRect {
    for (self.widget_rects.items) |rect| {
        if (x >= rect.x0 and x < rect.x1) return rect;
    }
    return null;
}


/// The widget under a pointer at `surface_x` on `surface`, for the tooltip
/// and for scroll events.
pub fn widget_at(self: *Self, surface: *wl.Surface, surface_x: i32) ?tooltip.Target {
    if (self.hidden or surface != self.dynamic_component.wl_surface) return null;

    const x = utils.logical2physics(i32, surface_x, self.scale);
    const rect = self.widget_index_at(x) orelse return null;
    return .{
        .bar = self,
        .side = rect.side,
        .index = rect.index,
        .x = self.output.x + utils.physics2logical(i32, self.static_component_width() + rect.x0, self.scale),
    };
}


pub fn toggle(self: *Self) void {
    log.debug("<{*}> toggle: {}", .{ self, !self.hidden });

    self.hidden = !self.hidden;
    if (self.hidden) {
        self.hide();
    } else {
        self.show() catch |err| {
            self.hidden = true;
            log.err("<{*}> failed to show: {}", .{ self, err });
            return;
        };
    }
}


pub fn damage(self: *Self, @"type": enum { all, tags, dynamic, layout, mode, title, status }) void {
    log.debug("<{*}> damage {s}", .{ self, @tagName(@"type") });

    switch (@"type") {
        .all => {
            self.background_damaged = true;
        },
        .tags => {
            self.static_component_damaged = true;
            self.dynamic_component_damaged = true;
        },
        else => self.dynamic_component_damaged = true,
    }
}


pub fn render(self: *Self) void {
    if (self.hidden) return;

    log.debug("<{*}> rendering", .{ self });

    if (self.static_component_damaged or self.background_damaged) {
        defer self.static_component_damaged = false;

        self.render_static_component();
    }

    if (self.dynamic_component_damaged or self.background_damaged) {
        defer self.dynamic_component_damaged = false;

        self.render_dynamic_component();
    }

    if (self.background_damaged) {
        defer self.background_damaged = false;

        self.render_background();
    }
}


inline fn static_component_width(self: *Self) i32 {
    return self.static_splits.getLastOrNull() orelse 0;
}


inline fn get_pad(self: *const Self) u16 {
    return @intCast(self.font.height());
}


fn render_background(self: *Self) void {
    log.debug("<{*}> rendering background", .{ self });

    const h = self.height(false);
    const logical_h = self.height(true);

    self.shell_surface.sync_next_commit();
    if (comptime build_options.background_enabled) {
        self.shell_surface.place(.{ .above = self.output.background.shell_surface.rwm_shell_surface_node });
    } else {
        self.shell_surface.place(.bottom);
    }
    self.shell_surface.set_position(self.output.x, self.output.y + switch (ctx.cfg.bar.position) {
        .top => 0,
        .bottom => self.output.height - logical_h,
    });

    const buffer = (
        if (ctx.cfg.bar.empty()) blk: {
            const rgba = utils.rgba(ctx.cfg.bar.scheme.normal.bg);
            break :blk ctx.wp_single_pixel_buffer_manager.createU32RgbaBuffer(
                rgba.r,
                rgba.g,
                rgba.b,
                rgba.a
            );
        }
        else ctx.wp_single_pixel_buffer_manager.createU32RgbaBuffer(0, 0, 0, 0)
    ) catch |err| {
        log.err("<{*}> create buffer failed: {}", .{ self, err });
        return;
    };
    defer buffer.destroy();

    self.static_component.manage(0, 0);
    self.dynamic_component.manage(
        utils.physics2logical(i32, self.static_component_width(), self.scale),
        0,
    );

    self.wl_surface.attach(buffer, 0, 0);
    self.wl_surface.damageBuffer(
        0, 0,
        utils.logical2physics(i32, self.output.width, self.scale), h,
    );
    self.wp_viewport.setDestination(self.output.width, logical_h);
    self.wl_surface.commit();
}


fn draw_box(
    self: *const Self,
    buffer: *render_.Buffer,
    inner: bool,
    pos: enum { top, bottom },
    c: *const pixman.Color,
    x: i16,
    y: i16,
) void {
    const h: u16 = @intCast(self.height(false));
    const box_size: u16 = @intCast(@divFloor(h, 6) + 2);
    const box_offset: i16 = @intCast(@divFloor(h, 9));
    var box = [_]pixman.Rectangle16 {
        .{
            .x = x + box_offset,
            .y = switch (pos) {
                .top => y + 1,
                .bottom => @intCast(h - box_size - 1),
            },
            .width = box_size,
            .height = box_size,
        }
    };
    if (inner) {
        box[0].x += 1;
        box[0].y += 1;
        box[0].width -= 2;
        box[0].height -= 2;
    }
    _ = pixman.Image.fillRectangles(
        .src,
        buffer.image,
        c,
        1,
        &box,
    );
}


fn render_static_component(self: *Self) void {
    log.debug("<{*}> rendering static component", .{ self });

    self.static_splits.clearRetainingCapacity();

    const area = ctx.cfg.bar.tags orelse {
        self.static_splits.append(ctx.gpa, 0) catch |err| {
            log.err("<{*}> append failed: {}", .{ self, err });
        };
        return;
    };

    self.static_splits.ensureTotalCapacity(ctx.gpa, area.tags.len) catch |err| {
        log.err("<{*}> ensure static_splits total capacity to {} failed: {}", .{ self, area.tags.len, err });
        return;
    };

    var texts: std.ArrayList(*const fcft.TextRun) = .empty;
    texts.ensureTotalCapacity(ctx.gpa, area.tags.len) catch |err| {
        log.err("<{*}> initCapacity for texts while render_static_component failed: {}", .{ self, err });
        return;
    };
    defer texts.deinit(ctx.gpa);

    for (area.tags) |label| {
        const utf8 = render_.utils.to_utf8(ctx.gpa, label) catch |err| {
            log.warn("<{*}> to_utf8 failed: {}", .{ self, err });
            return;
        };
        defer ctx.gpa.free(utf8);

        texts.appendBounded(
            self.font.rasterize_text_run(utf8) orelse return
        ) catch unreachable;
    }

    defer {
        for (texts.items) |text| {
            text.destroy();
        }
    }

    const pad = self.get_pad();
    const w: u16 = blk: {
        var width: u16 = 0;
        for (texts.items) |text| {
            width += @intCast(render_.utils.text_width(text)+pad);
            self.static_splits.appendBounded(@intCast(width)) catch unreachable;
        }
        break :blk width;
    };
    const h: u16 = @intCast(self.height(false));

    const buffer = self.next_buffer(.static, w, h) orelse return;

    const windows_tag: u32 = self.output.occupied_tags();
    const focused_window = ctx.focused_window();

    const scheme = ctx.cfg.bar.get_scheme(.tags);
    const select_fg = render_.utils.color(scheme.select.fg);
    const select_bg = render_.utils.color(scheme.select.bg);
    const normal_fg = render_.utils.color(scheme.normal.fg);
    const normal_bg = render_.utils.color(scheme.normal.bg);

    const bg_rect = [_]pixman.Rectangle16 {
        .{
            .x = 0,
            .y = 0,
            .width = w,
            .height = h,
        },
    };
    _ = pixman.Image.fillRectangles(.src, buffer.image, &normal_bg, 1, &bg_rect);

    var x: i16 = 0;
    const y: i16 = 0;
    for (0.., texts.items) |i, text| {
        const tag: u32 = @as(u32, @intCast(1)) << @as(u5, @intCast(i));

        const is_focused = self.output.tag & tag != 0;

        const tag_width: u16 = @intCast(render_.utils.text_width(text)+pad); 
        defer x += @intCast(tag_width);

        if (is_focused) {
            const tag_rect = [_]pixman.Rectangle16 {
                .{
                    .x = x,
                    .y = y,
                    .width = tag_width,
                    .height = h,
                }
            };
            _ = pixman.Image.fillRectangles(
                .src,
                buffer.image,
                &select_bg,
                1,
                &tag_rect,
            );
        }

        if (windows_tag & tag != 0) {
            self.draw_box(
                buffer,
                false,
                .top,
                if (is_focused) &select_fg else &normal_fg,
                x,
                y,
            );

            if (focused_window == null or focused_window.?.tag & tag == 0) {
                self.draw_box(
                    buffer,
                    true,
                    .top,
                    if (is_focused) &select_bg else &normal_bg,
                    x,
                    y,
                );
            }
        }

        _ = self.font.render_text(
            buffer,
            text,
            if (is_focused) &select_fg else &normal_fg,
            x+@as(i16, @intCast(@divFloor(pad, 2))),
            y,
        );
    }

    self.static_component.render(buffer, self.scale);
}


fn render_dynamic_component(self: *Self) void {
    log.debug("<{*}> rendering dynamic component", .{ self });

    self.dynamic_splits.clearRetainingCapacity();

    const pad = self.get_pad();
    const w: u16 = @intCast(
        utils.logical2physics(i32, self.output.width, self.scale)-self.static_component_width()
    );
    const h: u16 = @intCast(self.height(false));

    const buffer = self.next_buffer(.dynamic, w, h) orelse return;

    var bg_rect = [_]pixman.Rectangle16 {
        .{
            .x = 0,
            .y = 0,
            .width = w,
            .height = h,
        },
    };

    var x: i16 = 0;
    const y: i16 = 0;

    if (ctx.cfg.bar.mode) |area| draw_mode: {
        const tag = area.tag(ctx.mode) orelse ctx.mode;
        if (tag.len == 0) break :draw_mode;

        const color = ctx.cfg.bar.get_scheme(.{ .mode = ctx.mode }).normal;
        const fg = render_.utils.color(color.fg);
        const bg = render_.utils.color(color.bg);

        _ = pixman.Image.fillRectangles(.src, buffer.image, &bg, 1, &bg_rect);

        x += self.font.render_str(
            buffer,
            tag,
            &fg,
            x+@as(i16, @intCast(@divFloor(pad, 2))),
            y,
        ) + @as(i16, @intCast(pad));
    }
    self.dynamic_splits.appendBounded(x) catch unreachable;

    bg_rect[0].x = x;
    bg_rect[0].width = w - @as(u16, @intCast(x));

    if (ctx.cfg.bar.layout) |area| draw_layout: {
        var layout_tag_buffer: [32]u8 = undefined;
        const layout_tag = blk: {
            const tag = switch (self.output.current_layout()) {
                .tile => |tile| area.tags.tile.getter.get(tile.master_location),
                .grid => |grid| area.tags.grid.getter.get(grid.direction),
                .monocle => area.tags.monocle,
                .deck => |deck| area.tags.deck.getter.get(deck.master_location),
                .scroller => area.tags.scroller,
                .centered_master => |centered_master| area.tags.centered_master.getter.get(centered_master.direction),
                .float => area.tags.float,
            };
            const left = mem.indexOf(u8, tag, "{{") orelse break :blk tag;
            const right = mem.lastIndexOf(u8, tag, "}}") orelse break :blk tag;

            if (left < right) {
                var num: usize = 0;
                var it = ctx.windows.safeIterator(.forward);
                while (it.next()) |window| {
                    if (window.is_visible_in(self.output) and !window.floating) {
                        num += 1;
                    }
                }

                var buf: [8]u8 = undefined;
                const str =
                    if (right-left == 2 or num > 0) fmt.bufPrint(&buf, "{}", .{ num }) catch break :blk tag
                    else tag[left+2..right];

                const n = mem.replace(
                    u8,
                    tag,
                    tag[left..right+2],
                    str,
                    &layout_tag_buffer,
                );
                break :blk layout_tag_buffer[0..tag.len + str.len*n - (right-left+2)*n];
            } else break :blk tag;
        };
        if (layout_tag.len == 0) break :draw_layout;

        const color = ctx.cfg.bar.get_scheme(.{ .layout = self.output.current_layout() }).normal;
        const fg = render_.utils.color(color.fg);
        const bg = render_.utils.color(color.bg);

        _ = pixman.Image.fillRectangles(.src, buffer.image, &bg, 1, &bg_rect);

        x += self.font.render_str(
            buffer,
            layout_tag,
            &fg,
            x+@as(i16, @intCast(@divFloor(pad, 2))),
            y,
        ) + @as(i16, @intCast(pad));
    }
    self.dynamic_splits.appendBounded(x) catch unreachable;

    bg_rect[0].x = x;
    bg_rect[0].width = w - @as(u16, @intCast(x));

    const title_start = x;
    if (ctx.cfg.bar.title) |_| draw_title: {
        const scheme = ctx.cfg.bar.get_scheme(.title);
        const normal_fg = render_.utils.color(scheme.normal.fg);
        const normal_bg = render_.utils.color(scheme.normal.bg);
        const select_fg = render_.utils.color(scheme.select.fg);
        const select_bg = render_.utils.color(scheme.select.bg);

        const top = ctx.focus_top_in(self.output, false);
        if (top == null) {
            _ = pixman.Image.fillRectangles(
                .src,
                buffer.image,
                &normal_bg,
                1,
                &bg_rect
            );
            break :draw_title;
        }

        const window = top.?;
        var fg: *const pixman.Color = undefined;
        var bg: *const pixman.Color = undefined;
        if (self.output == ctx.current_output) {
            fg = &select_fg;
            bg = &select_bg;
        } else {
            fg = &normal_fg;
            bg = &normal_bg;
        }
        _ = pixman.Image.fillRectangles(.src, buffer.image, bg, 1, &bg_rect);

        if (window.sticky) {
            self.draw_box(buffer, false, .top, fg, x, y);
        }

        if (window.floating) {
            self.draw_box(
                buffer,
                false,
                if (window.sticky) .bottom else .top,
                fg,
                x,
                y,
            );

            self.draw_box(
                buffer,
                true,
                if (window.sticky) .bottom else .top,
                bg,
                x,
                y,
            );
        }

        x += self.font.render_str(
            buffer,
            window.title orelse "???",
            fg,
            x+@as(i16, @intCast(@divFloor(pad, 2))),
            y,
        ) + @as(i16, @intCast(pad));
    } else {
        const bg = render_.utils.color(ctx.cfg.bar.scheme.normal.bg);
        _ = pixman.Image.fillRectangles(
            .src,
            buffer.image,
            &bg,
            1,
            &bg_rect
        );
    }
    self.dynamic_splits.appendBounded(@intCast(w)) catch unreachable;

    self.widget_rects.clearRetainingCapacity();
    const status_scheme = ctx.cfg.bar.get_scheme(.status).normal;
    const status_fg = render_.utils.color(status_scheme.fg);
    const status_bg = render_.utils.color(status_scheme.bg);

    // The widgets at the right end. `right_x` is where they start.
    var right_x: i16 = @intCast(w);
    draw_right: {
        var right = self.rasterize_widgets(.right, status_fg) catch |err| {
            log.warn("<{*}> rasterize right widgets failed: {}", .{ self, err });
            break :draw_right;
        };
        defer right.deinit();
        if (right.width == 0) break :draw_right;

        right_x = @max(title_start, @as(i16, @intCast(w -| @as(u16, @intCast(right.width)) -| pad)));
        self.draw_widgets(buffer, &right, right_x, w, &status_bg, pad, y);
    }

    // The status text, at the left of the right widgets.
    var status_x = right_x;
    if (ctx.cfg.bar.status) |area| draw_status: {
        const status_text: []const u8 = mem.trimEnd(
            u8,
            switch (area.data) {
                .text => |text| text,
                else => mem.span(@as([*:0]const u8, @ptrCast(&status_buffer))),
            },
            "\n ",
        );
        if (status_text.len == 0) break :draw_status;

        var status = self.rasterize_status(status_text, status_fg) catch |err| {
            log.warn("<{*}> rasterize status failed: {}", .{ self, err });
            break :draw_status;
        };
        defer status.deinit();

        status_x = @max(title_start, right_x -| @as(i16, @intCast(status.width)) -| @as(i16, @intCast(pad)));
        bg_rect[0].x = status_x;
        bg_rect[0].width = @as(u16, @intCast(right_x)) - @as(u16, @intCast(status_x));
        _ = pixman.Image.fillRectangles(.src, buffer.image, &status_bg, 1, &bg_rect);

        x = status_x + @as(i16, @intCast(@divFloor(pad, 2)));
        for (status.runs.items) |item| {
            const cc, const text = item;
            x += self.font.render_text(buffer, text, &cc, x, y);
        }
    }

    // The widgets in the center of the output. They hide the end of a long
    // title, and they move left when the right side needs the space.
    var center_x = status_x;
    draw_center: {
        var center = self.rasterize_widgets(.center, status_fg) catch |err| {
            log.warn("<{*}> rasterize center widgets failed: {}", .{ self, err });
            break :draw_center;
        };
        defer center.deinit();
        if (center.width == 0) break :draw_center;

        const center_w: i32 = @as(i32, @intCast(center.width)) + pad;
        const output_center = @divFloor(utils.logical2physics(i32, self.output.width, self.scale), 2)
            - self.static_component_width();
        var start: i32 = @min(output_center - @divFloor(center_w, 2), @as(i32, status_x) - center_w);
        start = @max(start, title_start);
        center_x = @intCast(start);
        self.draw_widgets(buffer, &center, center_x, @intCast(status_x), &status_bg, pad, y);
    }

    self.dynamic_splits.items[self.dynamic_splits.items.len-1] = @min(center_x, status_x);

    self.dynamic_component.render(buffer, self.scale);
}


const StatusText = struct {
    runs: std.ArrayList(struct { pixman.Color, *const fcft.TextRun }) = .empty,
    width: u32 = 0,

    fn deinit(self: *StatusText) void {
        for (self.runs.items) |item| {
            item[1].destroy();
        }
        self.runs.deinit(ctx.gpa);
    }
};


/// Rasterize a status text. `^#RRGGBBAA` changes the color of the text that
/// follows, and `^#!` sets the default color again.
fn rasterize_status(self: *Self, status_text: []const u8, fg: pixman.Color) !StatusText {
    var result: StatusText = .{};
    errdefer result.deinit();

    var i: usize = 0;
    var c = fg;
    var it = color_pattern.iterator(status_text);
    var match = it.next();
    while (i < status_text.len) {
        if (match == null or i < match.?.start) {
            const end = if (match) |m| m.start else status_text.len;
            defer i = end;

            const utf8 = try render_.utils.to_utf8(ctx.gpa, status_text[i..end]);
            defer ctx.gpa.free(utf8);

            const text = self.font.rasterize_text_run(utf8) orelse return error.RasterizeFailed;
            result.runs.append(ctx.gpa, .{ c, text }) catch |err| {
                text.destroy();
                return err;
            };
        } else if (i == match.?.start) blk: {
            defer {
                i += match.?.slice.len;
                match = it.next();
            }

            if (match.?.slice.len == 3) {
                c = fg;
            } else {
                const hex = match.?.slice[2..];
                c = render_.utils.color(fmt.parseInt(u32, hex, 16) catch |err| {
                    log.err("parseInt failed: {}", .{ err });
                    break :blk;
                });
            }
        } else unreachable;
    }

    for (result.runs.items) |item| {
        _, const text = item;
        result.width += render_.utils.text_width(text);
    }
    return result;
}


/// The rasterized widgets of one side, with the space between them.
const WidgetRow = struct {
    side: widgets.Side,
    texts: std.ArrayList(struct { index: usize, text: StatusText }) = .empty,
    gap: u32 = 0,
    width: u32 = 0,

    fn deinit(self: *WidgetRow) void {
        for (self.texts.items) |*item| item.text.deinit();
        self.texts.deinit(ctx.gpa);
    }
};


fn rasterize_widgets(self: *Self, side: widgets.Side, fg: pixman.Color) !WidgetRow {
    var row: WidgetRow = .{ .side = side, .gap = @intCast(self.get_pad()) };
    errdefer row.deinit();

    for (0.., widgets.states(side)) |index, state| {
        if (state.hidden or state.text.items.len == 0) continue;

        var text = try self.rasterize_status(state.text.items, fg);
        errdefer text.deinit();
        if (row.texts.items.len > 0) row.width += row.gap;
        row.width += text.width;
        try row.texts.append(ctx.gpa, .{ .index = index, .text = text });
    }
    return row;
}


/// Fill the background from `x0` to `x1`, and draw the widgets from `x0`.
fn draw_widgets(
    self: *Self,
    buffer: *render_.Buffer,
    row: *const WidgetRow,
    x0: i16,
    x1: u16,
    bg: *const pixman.Color,
    pad: u16,
    y: i16,
) void {
    var rect = [_]pixman.Rectangle16 {
        .{
            .x = x0,
            .y = 0,
            .width = x1 -| @as(u16, @intCast(x0)),
            .height = @intCast(self.height(false)),
        },
    };
    _ = pixman.Image.fillRectangles(.src, buffer.image, bg, 1, &rect);

    const half_gap: i32 = @intCast(row.gap / 2);
    var x: i32 = x0 + @as(i32, @intCast(@divFloor(pad, 2)));
    for (row.texts.items) |item| {
        const start = x;
        for (item.text.runs.items) |run| {
            const cc, const text = run;
            x += self.font.render_text(buffer, text, &cc, x, y);
        }
        self.widget_rects.appendBounded(.{
            .side = row.side,
            .index = item.index,
            .x0 = start - half_gap,
            .x1 = x + half_gap,
        }) catch {};
        x += @intCast(row.gap);
    }
}

fn show(self: *Self) !void {
    std.debug.assert(!self.hidden);

    log.debug("<{*}> show", .{ self });

    const wl_surface = try ctx.wl_compositor.createSurface();
    errdefer wl_surface.destroy();

    try self.shell_surface.init(wl_surface, .{ .bar = self });
    errdefer self.shell_surface.deinit();

    const wp_viewport = try ctx.wp_viewporter.getViewport(wl_surface);
    errdefer wp_viewport.destroy();

    const wp_fractional_scale = try ctx.wp_fractional_scale_manager.getFractionalScale(wl_surface);
    errdefer wp_fractional_scale.destroy();

    try self.static_component.init(wl_surface);
    errdefer self.static_component.deinit();

    try self.dynamic_component.init(wl_surface);
    errdefer self.dynamic_component.deinit();

    self.wl_surface = wl_surface;
    self.wp_viewport = wp_viewport;
    self.wp_fractional_scale = wp_fractional_scale;
    wp_fractional_scale.setListener(*Self, wp_fractional_scale_listener, self);
    self.damage(.all);

    if (ctx.cfg.bar.status) |area| {
        if (area.data != .text and !ctx.is_listening_status()) {
            ctx.start_listening_status();
        }
    }
}


fn hide(self: *Self) void {
    std.debug.assert(self.hidden);

    log.debug("<{*}> hide", .{ self });

    tooltip.forget(self);
    self.widget_rects.clearRetainingCapacity();

    self.static_component.deinit();
    self.static_component = undefined;

    self.dynamic_component.deinit();
    self.dynamic_component = undefined;

    self.wp_viewport.destroy();
    self.wp_viewport = undefined;

    self.wp_fractional_scale.destroy();
    self.wp_fractional_scale = undefined;

    self.shell_surface.deinit();
    self.shell_surface = undefined;

    self.wl_surface.destroy();
    self.wl_surface = undefined;
}


fn wp_fractional_scale_listener(wp_fractional_scale: *wp.FractionalScaleV1, event: wp.FractionalScaleV1.Event, bar: *Self) void {
    std.debug.assert(wp_fractional_scale == bar.wp_fractional_scale);

    switch (event) {
        .preferred_scale => |data| {
            log.debug("<{*}> preferred_scale: {}", .{ bar, data.scale });

            if (data.scale != bar.scale) {
                bar.scale = data.scale;
                bar.reload_font();
                bar.damage(.all);
            }
        }
    }
}


fn next_buffer(self: *Self, @"type": enum { static, dynamic }, width: i32, height_: i32) ?*render_.Buffer {
    log.debug("<{*}> get buffer for {s}", .{ self, @tagName(@"type") });

    const component =  &switch (@"type") {
        .static => self.static_component,
        .dynamic => self.dynamic_component,
    };
    const buffer = component.next_buffer() orelse {
        log.warn("<{*}> next_buffer return null", .{ self });
        return null;
    };
    buffer.init(width, height_) catch |err| {
        log.err("<{*}> init buffer for {s} rendering failed: {}", .{ self, @tagName(@"type"), err });
        return null;
    };
    return buffer;
}
