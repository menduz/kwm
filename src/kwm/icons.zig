//! Icons by name, as the XDG icon theme specification says, in two steps:
//!
//! 1. The symbolic icon ("name-symbolic") in the icon theme of the tray
//!    (for example Adwaita), the themes that it inherits, and hicolor.
//! 2. The icon of the application: in its IconThemePath, hicolor, and the
//!    pixmaps directories. The icon theme of the tray is not used.
//!
//! In each step, when a name is not found, the search continues with the
//! name without its last "-part", as GTK does.
//!
//! A symbolic icon is drawn in the color of the text, as GTK does: its shape
//! and its alpha stay, and its colors change. Some themes give symbolic
//! names to links to their regular icons. Only a file that is symbolic after
//! the links gets the color.
//!
//! libspng reads the PNG files, and resvg draws the SVG files at the
//! requested size. The images and the themes stay in a cache until `reset`.

const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const log = std.log.scoped(.icons);

const pixman = @import("pixman");

const Context = @import("context.zig");

const ctx = Context.get();

const extensions = [_][]const u8 { ".png", ".svg" };

const max_path = 4096;

const DirType = enum { fixed, scalable, threshold };

const Dir = struct {
    path: []const u8,
    size: i32 = 0,
    scale: i32 = 1,
    min_size: i32 = 0,
    max_size: i32 = 0,
    threshold: i32 = 2,
    type: DirType = .threshold,

    /// DirectoryMatchesSize of the specification, for scale 1.
    fn matches(self: *const Dir, size: i32) bool {
        if (self.scale != 1) return false;
        return switch (self.type) {
            .fixed => self.size == size,
            .scalable => self.min_size <= size and size <= self.max_size,
            .threshold => self.size - self.threshold <= size and size <= self.size + self.threshold,
        };
    }

    /// DirectorySizeDistance of the specification, for scale 1.
    fn distance(self: *const Dir, size: i32) i32 {
        const min, const max = switch (self.type) {
            .fixed => .{ self.size, self.size },
            .scalable => .{ self.min_size, self.max_size },
            .threshold => .{ self.size - self.threshold, self.size + self.threshold },
        };
        if (size < min * self.scale) return min * self.scale - size;
        if (size > max * self.scale) return size - max * self.scale;
        return 0;
    }
};

const Theme = struct {
    inherits: []const []const u8,
    dirs: []const Dir,
    /// The base directories that have a directory for this theme.
    bases: []const []const u8,
};

/// The memory of the themes and of the base directories.
var arena: ?std.heap.ArenaAllocator = null;
var base_dirs: ?[]const []const u8 = null;
var themes: std.StringHashMapUnmanaged(?*const Theme) = .empty;
/// The images by "size/theme_path/name". null: no icon with this name.
var images: std.StringHashMapUnmanaged(?*pixman.Image) = .empty;

const max_images = 256;


/// The icon with this name for a square of `size` physical pixels. The
/// image can be larger or smaller than `size`. `theme_path` is the
/// IconThemePath of the item, or "". A symbolic icon has the color `color`
/// (0xRRGGBBAA). The cache keeps the image.
pub fn get(name: []const u8, theme_path: []const u8, size: i32, color: u32) ?*pixman.Image {
    if (name.len == 0 or size <= 0) return null;

    var key_buffer: [1024]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buffer, "{}/{x:0>8}/{s}/{s}", .{ size, color, theme_path, name }) catch return null;
    if (images.get(key)) |image| return image;

    const image = find(name, theme_path, size, color);
    if (images.count() >= max_images) clear_images();
    const owned_key = ctx.gpa.dupe(u8, key) catch return image;
    images.put(ctx.gpa, owned_key, image) catch {
        ctx.gpa.free(owned_key);
        if (image) |i| _ = i.unref();
        return null;
    };
    return image;
}


/// Forget the images and the themes, for example after a change of the
/// icon theme.
pub fn reset() void {
    clear_images();
    images.deinit(ctx.gpa);
    images = .empty;
    themes.deinit(ctx.gpa);
    themes = .empty;
    base_dirs = null;
    if (arena) |*a| a.deinit();
    arena = null;
}


fn clear_images() void {
    var it = images.iterator();
    while (it.next()) |entry| {
        ctx.gpa.free(entry.key_ptr.*);
        if (entry.value_ptr.*) |image| _ = image.unref();
    }
    images.clearRetainingCapacity();
}


fn allocator() mem.Allocator {
    if (arena == null) arena = .init(ctx.gpa);
    return arena.?.allocator();
}


/// Find the file of the icon, and read it.
fn find(name: []const u8, theme_path: []const u8, size: i32, color: u32) ?*pixman.Image {
    const theme_name = if (ctx.cfg.bar.tray) |cfg| cfg.icon_theme else "hicolor";
    var path_buffer: [max_path]u8 = undefined;
    var symbolic_buffer: [256]u8 = undefined;

    // An absolute path is a file.
    if (mem.startsWith(u8, name, "/")) return load(name, name, size, color);

    const base = if (mem.endsWith(u8, name, symbolic_suffix)) name[0 .. name.len - symbolic_suffix.len] else name;

    // 1. The symbolic icon, from the icon theme.
    var variant = base;
    while (true) {
        if (std.fmt.bufPrint(&symbolic_buffer, "{s}" ++ symbolic_suffix, .{ variant })) |symbolic| {
            if (find_file(&path_buffer, symbolic, theme_path, theme_name, size)) |path| {
                return load(name, path, size, color);
            }
        } else |_| {}
        variant = shorter(variant) orelse break;
    }

    // 2. The icon of the application, without the icon theme.
    variant = base;
    while (true) {
        if (find_file(&path_buffer, variant, theme_path, "hicolor", size)) |path| {
            return load(name, path, size, color);
        }
        variant = shorter(variant) orelse break;
    }
    log.debug("{s} ({}): not found", .{ name, size });
    return null;
}


/// The name without its last "-part", or null.
fn shorter(name: []const u8) ?[]const u8 {
    const dash = mem.lastIndexOfScalar(u8, name, '-') orelse return null;
    return name[0..dash];
}


const symbolic_suffix = "-symbolic";


/// Read the file of the icon `name`. A symbolic file gets the color `color`.
fn load(name: []const u8, path: []const u8, size: i32, color: u32) ?*pixman.Image {
    var real_buffer: [max_path]u8 = undefined;
    const real = real_path(path, &real_buffer) orelse path;
    log.debug("{s} ({}): {s}", .{ name, size, real });
    const image = read(path, size) orelse return null;
    const file_name = real[if (mem.lastIndexOfScalar(u8, real, '/')) |i| i + 1 else 0 ..];
    if (mem.indexOf(u8, file_name, symbolic_suffix) != null) recolor(image, color);
    return image;
}


/// The path without links, or null.
fn real_path(path: []const u8, buffer: *[max_path]u8) ?[]const u8 {
    var path_buffer: [max_path]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buffer, "{s}", .{ path }) catch return null;
    const real = std.c.realpath(path_z.ptr, buffer) orelse return null;
    return mem.span(real);
}


/// Draw the image in `color` (0xRRGGBBAA). The alpha of each pixel stays.
fn recolor(image: *pixman.Image, color: u32) void {
    const data = image.getData() orelse return;
    const w: usize = @intCast(image.getWidth());
    const h: usize = @intCast(image.getHeight());
    const stride: usize = @intCast(@divExact(image.getStride(), 4));
    const r = color >> 24 & 0xff;
    const g = color >> 16 & 0xff;
    const b = color >> 8 & 0xff;
    const color_a = color & 0xff;
    for (0..h) |row| {
        for (0..w) |col| {
            const p = &data[row * stride + col];
            const a = (p.* >> 24) * color_a / 255;
            p.* = a << 24 | (r * a / 255) << 16 | (g * a / 255) << 8 | b * a / 255;
        }
    }
}


fn find_file(buffer: []u8, name: []const u8, theme_path: []const u8, theme_name: []const u8, size: i32) ?[]const u8 {
    // The directory of the item: files in it, or themes in it.
    if (theme_path.len > 0) {
        for (extensions) |ext| {
            if (exists(buffer, &.{ theme_path, "/", name, ext })) |path| return path;
        }
    }

    var visited: [16][]const u8 = undefined;
    var n_visited: usize = 0;
    if (find_in_theme(buffer, name, theme_path, theme_name, size, &visited, &n_visited)) |path| return path;
    if (find_in_theme(buffer, name, theme_path, "hicolor", size, &visited, &n_visited)) |path| return path;

    for (get_base_dirs()) |base| {
        if (!mem.endsWith(u8, base, "/icons")) continue;
        const data_dir = base[0 .. base.len - "/icons".len];
        for (extensions) |ext| {
            if (exists(buffer, &.{ data_dir, "/pixmaps/", name, ext })) |path| return path;
        }
    }
    return null;
}


/// FindIconHelper of the specification: the theme, then the themes that it
/// inherits. `visited` stops loops.
fn find_in_theme(
    buffer: []u8,
    name: []const u8,
    theme_path: []const u8,
    theme_name: []const u8,
    size: i32,
    visited: [][]const u8,
    n_visited: *usize,
) ?[]const u8 {
    for (visited[0..n_visited.*]) |v| {
        if (mem.eql(u8, v, theme_name)) return null;
    }
    if (n_visited.* == visited.len) return null;
    visited[n_visited.*] = theme_name;
    n_visited.* += 1;

    const theme = get_theme(theme_name) orelse return null;
    if (lookup(buffer, name, theme_path, theme_name, theme, size)) |path| return path;
    for (theme.inherits) |parent| {
        if (find_in_theme(buffer, name, theme_path, parent, size, visited, n_visited)) |path| return path;
    }
    return null;
}


/// LookupIcon of the specification: a directory of the size, else the
/// directory with the nearest size.
fn lookup(buffer: []u8, name: []const u8, theme_path: []const u8, theme_name: []const u8, theme: *const Theme, size: i32) ?[]const u8 {
    var bases_buffer: [64][]const u8 = undefined;
    var n_bases: usize = 0;
    if (theme_path.len > 0) {
        bases_buffer[0] = theme_path;
        n_bases = 1;
    }
    for (theme.bases) |base| {
        if (n_bases == bases_buffer.len) break;
        bases_buffer[n_bases] = base;
        n_bases += 1;
    }
    const bases = bases_buffer[0..n_bases];

    for (theme.dirs) |*dir| {
        if (!dir.matches(size)) continue;
        for (bases) |base| for (extensions) |ext| {
            if (exists(buffer, &.{ base, "/", theme_name, "/", dir.path, "/", name, ext })) |path| return path;
        };
    }

    var best_distance: i32 = std.math.maxInt(i32);
    var best: ?struct { base: []const u8, dir: []const u8, ext: []const u8 } = null;
    for (theme.dirs) |*dir| {
        const distance = dir.distance(size);
        if (distance >= best_distance) continue;
        search: for (bases) |base| for (extensions) |ext| {
            if (exists(buffer, &.{ base, "/", theme_name, "/", dir.path, "/", name, ext }) != null) {
                best_distance = distance;
                best = .{ .base = base, .dir = dir.path, .ext = ext };
                break :search;
            }
        };
    }
    const b = best orelse return null;
    return exists(buffer, &.{ b.base, "/", theme_name, "/", b.dir, "/", name, b.ext });
}


/// Join `parts` in `buffer`. Return the path when the file exists.
fn exists(buffer: []u8, parts: []const []const u8) ?[]const u8 {
    var len: usize = 0;
    for (parts) |part| {
        if (len + part.len > buffer.len) return null;
        @memcpy(buffer[len..][0..part.len], part);
        len += part.len;
    }
    const path = buffer[0..len];
    Io.Dir.cwd().access(ctx.io, path, .{}) catch return null;
    return path;
}


/// $XDG_DATA_HOME/icons, ~/.icons, and the icons directory of each
/// directory of $XDG_DATA_DIRS.
fn get_base_dirs() []const []const u8 {
    if (base_dirs) |dirs| return dirs;
    const a = allocator();
    var dirs: std.ArrayList([]const u8) = .empty;
    const home = ctx.env.get("HOME") orelse "";
    blk: {
        if (ctx.env.get("XDG_DATA_HOME")) |data_home| {
            if (data_home.len > 0) {
                dirs.append(a, std.fmt.allocPrint(a, "{s}/icons", .{ data_home }) catch break :blk) catch {};
                break :blk;
            }
        }
        if (home.len > 0) dirs.append(a, std.fmt.allocPrint(a, "{s}/.local/share/icons", .{ home }) catch break :blk) catch {};
    }
    if (home.len > 0) {
        if (std.fmt.allocPrint(a, "{s}/.icons", .{ home })) |dir| dirs.append(a, dir) catch {} else |_| {}
    }
    const data_dirs = ctx.env.get("XDG_DATA_DIRS") orelse "";
    var it = mem.tokenizeScalar(u8, if (data_dirs.len > 0) data_dirs else "/usr/local/share:/usr/share", ':');
    while (it.next()) |dir| {
        const icons = std.fmt.allocPrint(a, "{s}/icons", .{ mem.trimEnd(u8, dir, "/") }) catch continue;
        for (dirs.items) |d| {
            if (mem.eql(u8, d, icons)) break;
        } else dirs.append(a, icons) catch {};
    }
    base_dirs = dirs.items;
    return dirs.items;
}


/// The theme from the index.theme of the first base directory that has it.
fn get_theme(name: []const u8) ?*const Theme {
    if (themes.get(name)) |theme| return theme;
    const theme = load_theme(name) catch |err| blk: {
        log.warn("read the icon theme {s} failed: {}", .{ name, err });
        break :blk null;
    };
    const key = allocator().dupe(u8, name) catch return theme;
    themes.put(ctx.gpa, key, theme) catch {};
    return theme;
}


fn load_theme(name: []const u8) !?*const Theme {
    const a = allocator();
    var bases: std.ArrayList([]const u8) = .empty;
    var index: ?[]const u8 = null;
    var buffer: [max_path]u8 = undefined;
    for (get_base_dirs()) |base| {
        if (exists(&buffer, &.{ base, "/", name }) == null) continue;
        try bases.append(a, base);
        if (index == null) {
            const path = exists(&buffer, &.{ base, "/", name, "/index.theme" }) orelse continue;
            index = Io.Dir.cwd().readFileAlloc(ctx.io, path, a, .limited(1 << 20)) catch continue;
        }
    }
    const text = index orelse return null;
    const theme = try a.create(Theme);
    theme.* = try parse_index(a, text);
    theme.bases = bases.items;
    return theme;
}


/// Read index.theme: Inherits and Directories of [Icon Theme], and the
/// section of each directory.
fn parse_index(a: mem.Allocator, text: []const u8) !Theme {
    var inherits: std.ArrayList([]const u8) = .empty;
    var dirs: std.ArrayList(Dir) = .empty;

    // First the list of the directories.
    var section: []const u8 = "";
    var lines = mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |raw| {
        const line = mem.trim(u8, raw, " \t");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            section = mem.trim(u8, line, "[]");
            continue;
        }
        if (!mem.eql(u8, section, "Icon Theme")) continue;
        const eq = mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = mem.trim(u8, line[0..eq], " \t");
        const value = mem.trim(u8, line[eq + 1 ..], " \t");
        var items = mem.tokenizeScalar(u8, value, ',');
        if (mem.eql(u8, key, "Inherits")) {
            while (items.next()) |item| try inherits.append(a, mem.trim(u8, item, " "));
        } else if (mem.eql(u8, key, "Directories") or mem.eql(u8, key, "ScaledDirectories")) {
            while (items.next()) |item| try dirs.append(a, .{ .path = mem.trim(u8, item, " ") });
        }
    }

    // Then the keys of each directory.
    lines = mem.tokenizeAny(u8, text, "\r\n");
    var dir: ?*Dir = null;
    while (lines.next()) |raw| {
        const line = mem.trim(u8, raw, " \t");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            const name = mem.trim(u8, line, "[]");
            dir = for (dirs.items) |*d| {
                if (mem.eql(u8, d.path, name)) break d;
            } else null;
            continue;
        }
        const d = dir orelse continue;
        const eq = mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = mem.trim(u8, line[0..eq], " \t");
        const value = mem.trim(u8, line[eq + 1 ..], " \t");
        if (mem.eql(u8, key, "Type")) {
            d.type =
                if (mem.eql(u8, value, "Fixed")) .fixed
                else if (mem.eql(u8, value, "Scalable")) .scalable
                else .threshold;
            continue;
        }
        const number = std.fmt.parseInt(i32, value, 10) catch continue;
        if (mem.eql(u8, key, "Size")) d.size = number
        else if (mem.eql(u8, key, "Scale")) d.scale = number
        else if (mem.eql(u8, key, "MinSize")) d.min_size = number
        else if (mem.eql(u8, key, "MaxSize")) d.max_size = number
        else if (mem.eql(u8, key, "Threshold")) d.threshold = number;
    }
    // MinSize and MaxSize are Size when they are not given.
    for (dirs.items) |*d| {
        if (d.min_size == 0) d.min_size = d.size;
        if (d.max_size == 0) d.max_size = d.size;
    }
    return .{ .inherits = inherits.items, .dirs = dirs.items, .bases = &.{} };
}


// Image files.

fn read(path: []const u8, size: i32) ?*pixman.Image {
    const image =
        if (mem.endsWith(u8, path, ".svg")) read_svg(path, size)
        else read_png(path);
    return image catch |err| {
        log.warn("read the icon {s} failed: {}", .{ path, err });
        return null;
    };
}


const spng = struct {
    const Ctx = opaque {};
    const Ihdr = extern struct {
        width: u32,
        height: u32,
        bit_depth: u8,
        color_type: u8,
        compression_method: u8,
        filter_method: u8,
        interlace_method: u8,
    };
    const FMT_RGBA8: c_int = 1;
    const DECODE_TRNS: c_int = 1;

    extern "c" fn spng_ctx_new(flags: c_int) ?*Ctx;
    extern "c" fn spng_ctx_free(ctx: *Ctx) void;
    extern "c" fn spng_set_png_buffer(ctx: *Ctx, buf: [*]const u8, size: usize) c_int;
    extern "c" fn spng_set_image_limits(ctx: *Ctx, width: u32, height: u32) c_int;
    extern "c" fn spng_get_ihdr(ctx: *Ctx, ihdr: *Ihdr) c_int;
    extern "c" fn spng_decoded_image_size(ctx: *Ctx, fmt: c_int, len: *usize) c_int;
    extern "c" fn spng_decode_image(ctx: *Ctx, out: [*]u8, len: usize, fmt: c_int, flags: c_int) c_int;
};


fn read_png(path: []const u8) !?*pixman.Image {
    const data = try Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.gpa, .limited(8 << 20));
    defer ctx.gpa.free(data);

    const png = spng.spng_ctx_new(0) orelse return error.OutOfMemory;
    defer spng.spng_ctx_free(png);
    if (spng.spng_set_png_buffer(png, data.ptr, data.len) != 0) return error.InvalidPng;
    _ = spng.spng_set_image_limits(png, 1024, 1024);
    var ihdr: spng.Ihdr = undefined;
    if (spng.spng_get_ihdr(png, &ihdr) != 0) return error.InvalidPng;
    var len: usize = 0;
    if (spng.spng_decoded_image_size(png, spng.FMT_RGBA8, &len) != 0) return error.InvalidPng;
    const pixels = try ctx.gpa.alloc(u8, len);
    defer ctx.gpa.free(pixels);
    if (spng.spng_decode_image(png, pixels.ptr, len, spng.FMT_RGBA8, spng.DECODE_TRNS) != 0) return error.InvalidPng;

    return to_image(pixels, @intCast(ihdr.width), @intCast(ihdr.height), false);
}


const resvg = struct {
    const Options = opaque {};
    const Tree = opaque {};
    const Transform = extern struct { a: f32, b: f32, c: f32, d: f32, e: f32, f: f32 };
    const Size = extern struct { width: f32, height: f32 };

    extern "c" fn resvg_options_create() ?*Options;
    extern "c" fn resvg_options_destroy(opt: *Options) void;
    extern "c" fn resvg_parse_tree_from_file(path: [*:0]const u8, opt: *const Options, tree: *?*Tree) i32;
    extern "c" fn resvg_get_image_size(tree: *const Tree) Size;
    extern "c" fn resvg_render(tree: *const Tree, transform: Transform, width: u32, height: u32, pixmap: [*]u8) void;
    extern "c" fn resvg_tree_destroy(tree: *Tree) void;
};


fn read_svg(path: []const u8, size: i32) !?*pixman.Image {
    const path_z = try ctx.gpa.dupeZ(u8, path);
    defer ctx.gpa.free(path_z);

    const options = resvg.resvg_options_create() orelse return error.OutOfMemory;
    defer resvg.resvg_options_destroy(options);
    var tree: ?*resvg.Tree = null;
    const rc = resvg.resvg_parse_tree_from_file(path_z, options, &tree);
    if (rc != 0 or tree == null) return error.InvalidSvg;
    defer resvg.resvg_tree_destroy(tree.?);

    // Fit the image in the square, in the center.
    const image_size = resvg.resvg_get_image_size(tree.?);
    const side = @max(image_size.width, image_size.height);
    if (side <= 0) return error.InvalidSvg;
    const s: f32 = @as(f32, @floatFromInt(size)) / side;
    const transform: resvg.Transform = .{
        .a = s, .b = 0, .c = 0, .d = s,
        .e = (@as(f32, @floatFromInt(size)) - image_size.width * s) / 2,
        .f = (@as(f32, @floatFromInt(size)) - image_size.height * s) / 2,
    };
    const n: usize = @intCast(size);
    const pixels = try ctx.gpa.alloc(u8, n * n * 4);
    defer ctx.gpa.free(pixels);
    @memset(pixels, 0);
    resvg.resvg_render(tree.?, transform, @intCast(size), @intCast(size), pixels.ptr);

    return to_image(pixels, size, size, true);
}


/// Convert RGBA8 pixels to a pixman image with premultiplied alpha.
fn to_image(pixels: []const u8, width: i32, height: i32, premultiplied: bool) ?*pixman.Image {
    const image = pixman.Image.createBits(.a8r8g8b8, width, height, null, 0) orelse return null;
    const data = image.getData() orelse {
        _ = image.unref();
        return null;
    };
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const stride: usize = @intCast(@divExact(image.getStride(), 4));
    for (0..h) |row| {
        for (0..w) |col| {
            const p = pixels[(row * w + col) * 4 ..][0..4];
            const a: u32 = p[3];
            var r: u32 = p[0];
            var g: u32 = p[1];
            var b: u32 = p[2];
            if (!premultiplied) {
                r = r * a / 255;
                g = g * a / 255;
                b = b * a / 255;
            }
            data[row * stride + col] = a << 24 | r << 16 | g << 8 | b;
        }
    }
    desaturate(image);
    return image;
}


/// Apply `bar.tray.saturation` to an a8r8g8b8 image with premultiplied
/// alpha: mix each pixel with its gray value. The gray value is the luma of
/// ITU-R BT.601. A mix of two premultiplied colors stays premultiplied.
pub fn desaturate(image: *pixman.Image) void {
    const tray = ctx.cfg.bar.tray orelse return;
    const saturation = std.math.clamp(tray.saturation, 0.0, 1.0);
    if (saturation >= 1.0) return;

    const data = image.getData() orelse return;
    const width: usize = @intCast(image.getWidth());
    const height: usize = @intCast(image.getHeight());
    const stride: usize = @intCast(@divExact(image.getStride(), 4));
    for (0..height) |row| {
        for (data[row * stride ..][0..width]) |*pixel| {
            const a = pixel.* >> 24;
            const r: f32 = @floatFromInt(pixel.* >> 16 & 0xff);
            const g: f32 = @floatFromInt(pixel.* >> 8 & 0xff);
            const b: f32 = @floatFromInt(pixel.* & 0xff);
            const gray = 0.299 * r + 0.587 * g + 0.114 * b;
            const mix = struct {
                fn f(c: f32, y: f32, s: f32) u32 {
                    return @intFromFloat(@round(y + s * (c - y)));
                }
            }.f;
            pixel.* = a << 24 | mix(r, gray, saturation) << 16 | mix(g, gray, saturation) << 8 | mix(b, gray, saturation);
        }
    }
}
