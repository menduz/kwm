//! The sandbox of a window. The pid of the client comes from the
//! unreliable_pid event of river. kwm finds the sandbox of that process in
//! this order:
//!
//! 1. The cgroup. The sandbox launcher starts each run in a systemd scope
//!    below the slice "sandbox-<name>.slice". The program cannot change its
//!    cgroup, because it has no access to /sys/fs/cgroup or to systemd. The
//!    color and the GTK theme come from `config_path`. This also works when
//!    the pid is not the pid of the program, for example the Sentry of
//!    gVisor.
//! 2. The environment, /proc/<pid>/environ, for a run without a scope:
//!    - SANDBOX_NAME: the name of the sandbox, for example "work".
//!    - SANDBOX_COLOR: the color of the sandbox, as "#rrggbb".
//!    - GTK_THEME: the GTK theme of the sandbox (optional).
//!    The program can change its own environ memory. Thus this name is a hint
//!    for the user, not a security boundary.
//! 3. The host. If `config_path` exists, a process in no sandbox is on the
//!    host. Its name is "host", and its color is the color of the "host"
//!    block of `config_path`. Without `config_path`, the process has no
//!    sandbox and no label.
//!
//! The bar, the border and the label of the window then show the sandbox.
//! A window on the host has no label: only the bar shows "host". Refer to
//! sandbox_label.zig.
//!
//! `zig build test` runs the tests below.

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const testing = std.testing;

const posix = @import("posix");


/// The color of a sandbox without a valid SANDBOX_COLOR.
pub const default_color: u32 = 0xc01c28ff;

/// The maximum size of /proc/<pid>/environ that kwm reads.
const environ_max = 64 * 1024;

/// The configuration of the sandboxes, from the NixOS module of the sandbox
/// launcher:
///
///     {"host": {"color": "#rrggbb"},
///      "environments": {"<name>": {"color": "#rrggbb", "gtkTheme": "..."}}}
pub const config_path = "/etc/sandboxes/config.json";

/// The size of the buffer that `read` needs.
pub const buffer_size = 64 * 1024;
const cgroup_max = 4 * 1024;
const config_max = 28 * 1024;


/// The sandbox values of a process. The slices point into the buffer of
/// `parse`.
pub const Info = struct {
    name: []const u8,
    /// 0xRRGGBBAA.
    color: u32,
    gtk_theme: ?[]const u8 = null,
    /// The process is on the host, in no sandbox. Only `parse_host` sets
    /// it. A SANDBOX_NAME "host" in the environment does not set it.
    host: bool = false,

    /// The window shows a label with the sandbox name. A window on the host
    /// has no label. The bar shows the name.
    pub fn has_label(self: Info) bool {
        return !self.host;
    }
};


/// Read the sandbox of the process `pid`. The result points into `buffer`,
/// which has `buffer_size` bytes. null: there is no `config_path` and the
/// process is in no sandbox, or kwm cannot read the process.
pub fn read(pid: i32, buffer: *[buffer_size]u8) ?Info {
    if (pid <= 0) return null;

    var path_buffer: [32]u8 = undefined;

    // 1. The cgroup.
    cgroup: {
        const path = fmt.bufPrintZ(&path_buffer, "/proc/{}/cgroup", .{ pid }) catch break :cgroup;
        const cgroup = read_file(path, buffer[0..cgroup_max]) orelse break :cgroup;
        const name = parse_cgroup(cgroup) orelse break :cgroup;
        return lookup_config(name, buffer[cgroup_max..]);
    }

    // 2. The environment.
    const path = fmt.bufPrintZ(&path_buffer, "/proc/{}/environ", .{ pid }) catch return null;
    const environ = read_file(path, buffer[0..environ_max]) orelse return null;
    if (parse(environ)) |info| return info;

    // 3. The host.
    return lookup_host(buffer[cgroup_max..]);
}


/// The host, with the color of the "host" block of `config_path`. null: there
/// is no `config_path`.
fn lookup_host(buffer: []u8) ?Info {
    if (buffer.len <= config_max) return null;
    var json = read_file(config_path, buffer[0..config_max]) orelse return null;
    // A file that fills the buffer is cut. Its JSON text is not valid.
    if (json.len == config_max) json = "";

    var fba: std.heap.FixedBufferAllocator = .init(buffer[config_max..]);
    return parse_host(fba.allocator(), json);
}


/// The host, with the color of the "host" block in the JSON text of
/// `config_path`. A text that is not valid, or that has no host color, gives
/// the default color.
pub fn parse_host(allocator: mem.Allocator, json: []const u8) Info {
    var info: Info = .{ .name = "host", .color = default_color, .host = true };
    if (json.len == 0) return info;
    if (parse_config(allocator, json, "host")) |host| {
        if (host.color) |color| info.color = parse_color(color) orelse default_color;
    }
    return info;
}


/// Read the file `path` into `buffer`. A longer file is cut at the size of
/// `buffer`.
fn read_file(path: [*:0]const u8, buffer: []u8) ?[]const u8 {
    const fd = posix.openZ(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch return null;
    defer posix.close(fd);

    var len: usize = 0;
    while (len < buffer.len) {
        const n = posix.read(fd, buffer[len..]) catch return null;
        if (n == 0) break;
        len += n;
    }
    return buffer[0..len];
}


/// Find the sandbox name in the contents of /proc/<pid>/cgroup. kwm reads
/// only the line of cgroup v2, "0::<path>". The name comes from the first
/// path component "sandbox-<name>.slice". A name has only the characters
/// a-z, 0-9 and "_".
pub fn parse_cgroup(contents: []const u8) ?[]const u8 {
    var lines = mem.tokenizeScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (!mem.startsWith(u8, line, "0::")) continue;

        var components = mem.tokenizeScalar(u8, line[3..], '/');
        while (components.next()) |component| {
            const prefix = "sandbox-";
            const suffix = ".slice";
            if (!mem.startsWith(u8, component, prefix)) continue;
            if (!mem.endsWith(u8, component, suffix)) continue;
            if (component.len <= prefix.len + suffix.len) continue;

            const name = component[prefix.len .. component.len - suffix.len];
            if (valid_name(name)) return name;
        }
    }
    return null;
}


fn valid_name(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        switch (c) {
            'a'...'z', '0'...'9', '_' => {},
            else => return false,
        }
    }
    return true;
}


/// The sandbox `name` with the color and the GTK theme of `config_path`.
/// Without the file or without the sandbox in it, the sandbox has the
/// default color. The result points into `buffer`.
fn lookup_config(name: []const u8, buffer: []u8) Info {
    var info: Info = .{ .name = name, .color = default_color };
    if (buffer.len <= config_max) return info;

    const json = read_file(config_path, buffer[0..config_max]) orelse return info;
    if (json.len == config_max) return info;

    var fba: std.heap.FixedBufferAllocator = .init(buffer[config_max..]);
    if (parse_config(fba.allocator(), json, name)) |environment| {
        if (environment.color) |color| info.color = parse_color(color) orelse default_color;
        info.gtk_theme = environment.gtkTheme;
    }
    return info;
}


const Environment = struct {
    color: ?[]const u8 = null,
    gtkTheme: ?[]const u8 = null,
};


/// The values of the sandbox `name` in the JSON text of `config_path`. The
/// name "host" gives the "host" block. No sandbox can have that name.
/// null: the text is not valid, or it does not have the sandbox.
pub fn parse_config(allocator: mem.Allocator, json: []const u8, name: []const u8) ?Environment {
    const Config = struct {
        environments: std.json.ArrayHashMap(Environment) = .{},
        host: ?Environment = null,
    };
    const config = std.json.parseFromSliceLeaky(Config, allocator, json, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    if (mem.eql(u8, name, "host")) return config.host;
    return config.environments.map.get(name);
}


/// Find the sandbox values in an environment block: "KEY=value" entries,
/// each one terminated by a NUL byte.
pub fn parse(environ: []const u8) ?Info {
    var name: ?[]const u8 = null;
    var color: ?u32 = null;
    var gtk_theme: ?[]const u8 = null;

    var it = mem.splitScalar(u8, environ, 0);
    while (it.next()) |entry| {
        if (value_of(entry, "SANDBOX_NAME")) |v| {
            if (v.len > 0) name = v;
        } else if (value_of(entry, "SANDBOX_COLOR")) |v| {
            color = parse_color(v);
        } else if (value_of(entry, "GTK_THEME")) |v| {
            // GTK_THEME can give a variant after the name: "Name:dark".
            const theme = v[0 .. mem.indexOfScalar(u8, v, ':') orelse v.len];
            if (theme.len > 0) gtk_theme = theme;
        }
    }

    return .{
        .name = name orelse return null,
        .color = color orelse default_color,
        .gtk_theme = gtk_theme,
    };
}


fn value_of(entry: []const u8, comptime key: []const u8) ?[]const u8 {
    if (!mem.startsWith(u8, entry, key ++ "=")) return null;
    return entry[key.len + 1 ..];
}


/// "#rrggbb" to 0xRRGGBBff.
pub fn parse_color(value: []const u8) ?u32 {
    if (value.len != 7 or value[0] != '#') return null;
    const rgb = fmt.parseInt(u32, value[1..], 16) catch return null;
    return (rgb << 8) | 0xff;
}


/// The color of a sandbox for a window without the focus: the same hue, with
/// half of the brightness.
pub fn dim(color: u32) u32 {
    const r = (color >> 24) & 0xff;
    const g = (color >> 16) & 0xff;
    const b = (color >> 8) & 0xff;
    return ((r / 2) << 24) | ((g / 2) << 16) | ((b / 2) << 8) | (color & 0xff);
}


/// Black or white, the text color with the most contrast on `color`.
pub fn text_color(color: u32) u32 {
    const r = (color >> 24) & 0xff;
    const g = (color >> 16) & 0xff;
    const b = (color >> 8) & 0xff;
    // The luma of ITU-R BT.601, times 1000.
    const luma = 299 * r + 587 * g + 114 * b;
    return if (luma > 140 * 1000) 0x000000ff else 0xffffffff;
}


test "parse: the name, the color and the GTK theme" {
    const env = "PATH=/bin\x00SANDBOX_NAME=work\x00SANDBOX_COLOR=#3a7d44\x00GTK_THEME=win-classic-teal:dark\x00";
    const info = parse(env).?;
    try testing.expectEqualStrings("work", info.name);
    try testing.expectEqual(@as(u32, 0x3a7d44ff), info.color);
    try testing.expectEqualStrings("win-classic-teal", info.gtk_theme.?);
}

test "parse: no SANDBOX_NAME is no sandbox" {
    try testing.expectEqual(@as(?Info, null), parse("SANDBOX_COLOR=#3a7d44\x00HOME=/home/a\x00"));
    try testing.expectEqual(@as(?Info, null), parse("SANDBOX_NAME=\x00"));
    try testing.expectEqual(@as(?Info, null), parse(""));
}

test "parse: a bad color gives the default color" {
    const info = parse("SANDBOX_NAME=x\x00SANDBOX_COLOR=green\x00").?;
    try testing.expectEqual(default_color, info.color);
}

test "parse: the key must match the full name" {
    try testing.expectEqual(@as(?Info, null), parse("XSANDBOX_NAME=work\x00SANDBOX_NAMES=a\x00"));
}

test "parse: an environment without the last NUL byte" {
    try testing.expectEqualStrings("work", parse("A=b\x00SANDBOX_NAME=work").?.name);
}

test "parse_cgroup: the slice of a sandbox scope" {
    const cgroup = "0::/user.slice/user-1000.slice/user@1000.service/sandbox.slice/sandbox-work.slice/sandbox-work-1234-5678.scope\n";
    try testing.expectEqualStrings("work", parse_cgroup(cgroup).?);
}

test "parse_cgroup: no sandbox slice" {
    try testing.expectEqual(@as(?[]const u8, null), parse_cgroup("0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-foot-1.scope\n"));
    try testing.expectEqual(@as(?[]const u8, null), parse_cgroup("0::/user.slice/user@1000.service/sandbox.slice/x.scope\n"));
    try testing.expectEqual(@as(?[]const u8, null), parse_cgroup(""));
}

test "parse_cgroup: only the cgroup v2 line" {
    try testing.expectEqual(@as(?[]const u8, null), parse_cgroup("1:name=systemd:/sandbox.slice/sandbox-work.slice/a.scope\n"));
    const mixed = "1:name=systemd:/sandbox-old.slice\n0::/sandbox.slice/sandbox-new.slice/a.scope\n";
    try testing.expectEqualStrings("new", parse_cgroup(mixed).?);
}

test "parse_cgroup: a bad name does not match" {
    try testing.expectEqual(@as(?[]const u8, null), parse_cgroup("0::/sandbox.slice/sandbox-.slice/a.scope\n"));
    try testing.expectEqual(@as(?[]const u8, null), parse_cgroup("0::/sandbox.slice/sandbox-Work.slice/a.scope\n"));
    try testing.expectEqual(@as(?[]const u8, null), parse_cgroup("0::/sandbox-work.scope\n"));
    // A dash in the slice name means a slice below a slice. The next
    // component gives the name.
    try testing.expectEqualStrings("my_box2", parse_cgroup("0::/sandbox-a-b.slice/sandbox-my_box2.slice/a.scope").?);
}

test "parse_config: the color and the GTK theme of a sandbox" {
    const json =
        \\{"version": 1, "environments": {
        \\  "work": {"color": "#3a7d44", "gtkTheme": "win-classic-sandbox-work", "network": "full"},
        \\  "tmp": {"color": "#c01c28", "gtkTheme": null}
        \\}}
    ;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const work = parse_config(arena.allocator(), json, "work").?;
    try testing.expectEqualStrings("#3a7d44", work.color.?);
    try testing.expectEqualStrings("win-classic-sandbox-work", work.gtkTheme.?);

    const tmp = parse_config(arena.allocator(), json, "tmp").?;
    try testing.expectEqual(@as(?[]const u8, null), tmp.gtkTheme);

    try testing.expectEqual(@as(?Environment, null), parse_config(arena.allocator(), json, "other"));
    try testing.expectEqual(@as(?Environment, null), parse_config(arena.allocator(), "not json", "work"));
    // This text has no host block.
    try testing.expectEqual(@as(?Environment, null), parse_config(arena.allocator(), json, "host"));
}

test "parse_config: the host block" {
    const json =
        \\{"host": {"color": "#f29718"}, "environments": {
        \\  "work": {"color": "#000000"}
        \\}}
    ;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const host = parse_config(arena.allocator(), json, "host").?;
    try testing.expectEqualStrings("#f29718", host.color.?);
    try testing.expectEqual(@as(?[]const u8, null), host.gtkTheme);
}

test "parse_host: the host has the host color and no label" {
    const json =
        \\{"host": {"color": "#808080"}, "environments": {
        \\  "work": {"color": "#000000"}
        \\}}
    ;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const info = parse_host(arena.allocator(), json);
    try testing.expectEqualStrings("host", info.name);
    try testing.expectEqual(@as(u32, 0x808080ff), info.color);
    try testing.expect(info.host);
    try testing.expect(!info.has_label());
}

test "parse_host: no host color gives the default color" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const empty = parse_host(arena.allocator(), "");
    try testing.expectEqual(default_color, empty.color);
    try testing.expect(empty.host);

    const not_json = parse_host(arena.allocator(), "not json");
    try testing.expectEqual(default_color, not_json.color);
    try testing.expect(!not_json.has_label());

    const no_color = parse_host(arena.allocator(), "{\"host\": {}}");
    try testing.expectEqual(default_color, no_color.color);
}

test "has_label: a sandbox has a label" {
    try testing.expect(parse("SANDBOX_NAME=work\x00").?.has_label());
    // The environment cannot make a window a host window.
    const fake = parse("SANDBOX_NAME=host\x00").?;
    try testing.expect(!fake.host);
    try testing.expect(fake.has_label());
}

test "dim and text_color" {
    try testing.expectEqual(@as(u32, 0x1d3e22ff), dim(0x3a7d44ff));
    try testing.expectEqual(@as(u32, 0xffffffff), text_color(0x3a7d44ff));
    try testing.expectEqual(@as(u32, 0x000000ff), text_color(0xf29718ff));
}
