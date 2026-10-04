//! The current GTK theme, for the colors of the raised border. Refer to
//! `border.raised.gtk_colors` in the configuration.
//!
//! At the start, the name comes from GTK_THEME. `set_gtk_theme` gives a new
//! name at run time. kwm reads the `@define-color` lines of
//! gtk-3.0/gtk.css of that theme. GTK looks for a theme in the same folders.

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const log = std.log.scoped(.theme);

const posix = @import("posix");
const config = @import("config");

const Context = @import("context.zig");

const ctx = Context.get();

var gtk_theme: ?[]u8 = null;
/// The colors of gtk.css, by name, as 0xRRGGBBAA.
var colors: std.StringHashMapUnmanaged(u32) = .empty;


pub fn init() void {
    // GTK_THEME can give a variant after the name: "Name:dark".
    const env = ctx.env.get("GTK_THEME") orelse return;
    const name = env[0 .. mem.indexOfScalar(u8, env, ':') orelse env.len];
    if (name.len == 0) return;

    gtk_theme = ctx.gpa.dupe(u8, name) catch return;
    load(name);
}


pub fn deinit() void {
    clear_colors();
    if (gtk_theme) |name| ctx.gpa.free(name);
    gtk_theme = null;
}


/// The GTK theme changed. Read its colors, and draw the borders again.
pub fn set_gtk_theme(name: []const u8) void {
    if (gtk_theme) |current| {
        if (mem.eql(u8, current, name)) return;
    }

    const copy = ctx.gpa.dupe(u8, name) catch |err| {
        log.err("dupe theme name failed: {}", .{ err });
        return;
    };
    if (gtk_theme) |old| ctx.gpa.free(old);
    gtk_theme = copy;

    load(name);
    ctx.rwm.manageDirty();
}


/// The colors of a raised border for the current GTK theme.
pub fn bevel(focused: bool) config.Bevel {
    const raised = &ctx.cfg.border.raised;
    var result = if (focused) raised.focus else raised.unfocus;

    const names = raised.gtk_colors orelse return result;
    result.face = colors.get(names.face) orelse result.face;
    result.highlight = colors.get(names.highlight) orelse result.highlight;
    result.shadow = colors.get(names.shadow) orelse result.shadow;
    result.frame = colors.get(names.frame) orelse result.frame;
    result.band = colors.get(if (focused) names.focus_band else names.unfocus_band) orelse result.band;
    return result;
}


fn clear_colors() void {
    var it = colors.keyIterator();
    while (it.next()) |key| ctx.gpa.free(key.*);
    colors.clearAndFree(ctx.gpa);
}


/// Read the colors of the theme `name`. Without a theme file, the borders
/// use `focus` and `unfocus` of the configuration.
fn load(name: []const u8) void {
    clear_colors();

    var buffer: [256 * 1024]u8 = undefined;
    const css = read_theme_css(name, &buffer) orelse {
        log.warn("GTK theme {s}: no gtk-3.0/gtk.css found", .{ name });
        return;
    };

    var lines = mem.tokenizeScalar(u8, css, '\n');
    while (lines.next()) |raw| {
        // "@define-color name #rrggbb;" Other values, for example mix(),
        // are not colors that kwm can read.
        const line = mem.trim(u8, raw, " \t\r");
        if (!mem.startsWith(u8, line, "@define-color")) continue;
        var fields = mem.tokenizeAny(u8, line["@define-color".len..], " \t;");
        const key = fields.next() orelse continue;
        const value = fields.next() orelse continue;
        const color = parse_hex(value) orelse continue;

        const owned = ctx.gpa.dupe(u8, key) catch continue;
        const entry = colors.getOrPut(ctx.gpa, owned) catch {
            ctx.gpa.free(owned);
            continue;
        };
        if (entry.found_existing) ctx.gpa.free(owned);
        entry.value_ptr.* = color;
    }
    log.info("GTK theme {s}: {} colors", .{ name, colors.count() });
}


/// "#rrggbb" or "#rgb" to 0xRRGGBBff.
fn parse_hex(value: []const u8) ?u32 {
    if (value.len == 0 or value[0] != '#') return null;
    const digits = value[1..];
    const rgb: u32 = switch (digits.len) {
        6 => fmt.parseInt(u32, digits, 16) catch return null,
        3 => blk: {
            var v: u32 = 0;
            for (digits) |d| {
                const n = fmt.charToDigit(d, 16) catch return null;
                v = (v << 8) | (n * 17);
            }
            break :blk v;
        },
        else => return null,
    };
    return (rgb << 8) | 0xff;
}


/// Find gtk-3.0/gtk.css of the theme in the folders that GTK searches.
fn read_theme_css(name: []const u8, buffer: []u8) ?[]const u8 {
    const home = ctx.env.get("HOME") orelse "";
    var path_buffer: [4096]u8 = undefined;

    // $XDG_DATA_HOME/themes, ~/.themes, then $XDG_DATA_DIRS/themes.
    const data_home = ctx.env.get("XDG_DATA_HOME");
    if (data_home) |dir| {
        if (read_css(&path_buffer, buffer, dir, "/themes", name)) |css| return css;
    } else {
        if (read_css(&path_buffer, buffer, home, "/.local/share/themes", name)) |css| return css;
    }
    if (read_css(&path_buffer, buffer, home, "/.themes", name)) |css| return css;

    const data_dirs = ctx.env.get("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share";
    var dirs = mem.tokenizeScalar(u8, data_dirs, ':');
    while (dirs.next()) |dir| {
        if (read_css(&path_buffer, buffer, dir, "/themes", name)) |css| return css;
    }
    return null;
}


fn read_css(path_buffer: []u8, buffer: []u8, dir: []const u8, sub: []const u8, name: []const u8) ?[]const u8 {
    if (dir.len == 0) return null;
    const path = fmt.bufPrintZ(path_buffer, "{s}{s}/{s}/gtk-3.0/gtk.css", .{ dir, sub, name }) catch return null;

    const fd = posix.openZ(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch return null;
    defer posix.close(fd);

    var len: usize = 0;
    while (len < buffer.len) {
        const n = posix.read(fd, buffer[len..]) catch return null;
        if (n == 0) break;
        len += n;
    }
    log.debug("read {s}", .{ path });
    return buffer[0..len];
}
