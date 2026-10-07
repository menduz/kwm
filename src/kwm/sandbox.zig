//! The sandbox of a window. The pid of the client comes from the
//! unreliable_pid event of river. kwm finds the sandbox of that process from
//! its cgroup, in /proc/<pid>/cgroup:
//!
//! - The sandbox launcher starts each run in a systemd scope below the slice
//!   "sandbox-<name>.slice". The program cannot change its cgroup, because it
//!   has no access to /sys/fs/cgroup or to systemd. The color and the GTK
//!   theme come from `config_path`. This also works when the pid is not the
//!   pid of the program, for example the Sentry of gVisor.
//! - If `config_path` exists, a process in no sandbox slice is on the host.
//!   Its name is "host", and its color is the color of the "host" block of
//!   `config_path`. Without `config_path`, the process has no sandbox and no
//!   label.
//!
//! kwm does not read the environment of the process. The program can change
//! it. SANDBOX_NAME and SANDBOX_COLOR are only for the programs in the
//! sandbox, for example the shell prompt. Thus a run without a scope
//! (SANDBOX_NO_SCOPE) is on the host for kwm.
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


/// The color of a sandbox without a valid color in `config_path`.
pub const default_color: u32 = 0xc01c28ff;

/// The configuration of the sandboxes, from the NixOS module of the sandbox
/// launcher:
///
///     {"host": {"color": "#rrggbb"},
///      "environments": {"<name>": {"color": "#rrggbb", "gtkTheme": "..."}}}
pub const config_path = "/etc/sandboxes/config.json";

/// The size of the buffer that `read` needs: the cgroup file, the
/// configuration file and the memory to parse the configuration.
pub const buffer_size = 64 * 1024;
const cgroup_max = 4 * 1024;
const config_max = 28 * 1024;


/// The sandbox values of a process. The slices point into the buffer of
/// `read`.
pub const Info = struct {
    name: []const u8,
    /// 0xRRGGBBAA.
    color: u32,
    gtk_theme: ?[]const u8 = null,
    /// The process is in no sandbox slice. A sandbox has a slice, also a
    /// sandbox with the name "host".
    host: bool = false,

    /// The window shows a label with the sandbox name. A window on the host
    /// has no label. The bar shows the name.
    pub fn has_label(self: Info) bool {
        return !self.host;
    }
};


/// Read the sandbox of the process `pid`. The result points into `buffer`,
/// which has `buffer_size` bytes. null: kwm cannot read the cgroup of the
/// process, or the process is in no sandbox and there is no `config_path`.
pub fn read(pid: i32, buffer: *[buffer_size]u8) ?Info {
    if (pid <= 0) return null;

    var path_buffer: [32]u8 = undefined;
    const path = fmt.bufPrintZ(&path_buffer, "/proc/{}/cgroup", .{ pid }) catch return null;
    const cgroup = read_file(path, buffer[0..cgroup_max]) orelse return null;

    var json = read_file(config_path, buffer[cgroup_max..][0..config_max]);
    // A file that fills the buffer is cut. Its JSON text is not valid.
    if (json) |text| {
        if (text.len == config_max) json = "";
    }

    var fba: std.heap.FixedBufferAllocator = .init(buffer[cgroup_max + config_max ..]);
    return resolve(fba.allocator(), cgroup, json);
}


/// The sandbox of a process, from the contents of its /proc/<pid>/cgroup
/// and the JSON text of `config_path` (null: there is no file).
///
/// - A process in "sandbox-<name>.slice" is in the sandbox <name>, with the
///   color and the GTK theme of the sandbox in `json`. A sandbox that is not
///   in `json` has the default color.
/// - Another process is on the host, with the color of the "host" block of
///   `json`. null: there is no `json`.
///
/// The result points into `cgroup` and into the memory of `allocator`.
pub fn resolve(allocator: mem.Allocator, cgroup: []const u8, json: ?[]const u8) ?Info {
    if (parse_cgroup(cgroup)) |name| {
        var info: Info = .{ .name = name, .color = default_color };
        if (parse_config(allocator, json orelse "", name)) |environment| {
            info.color = color_of(environment);
            info.gtk_theme = environment.gtkTheme;
        }
        return info;
    }

    var info: Info = .{ .name = "host", .color = default_color, .host = true };
    if (parse_config(allocator, json orelse return null, "host")) |host| {
        info.color = color_of(host);
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


/// The color of a block of `config_path`. A block without a valid color has
/// the default color.
fn color_of(environment: Environment) u32 {
    const color = environment.color orelse return default_color;
    return parse_color(color) orelse default_color;
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

const test_config =
    \\{"host": {"color": "#808080"}, "environments": {
    \\  "work": {"color": "#3a7d44", "gtkTheme": "win-classic-sandbox-work"},
    \\  "web": {"color": "green"}
    \\}}
;
const test_work_cgroup = "0::/user.slice/user-1000.slice/user@1000.service/sandbox.slice/sandbox-work.slice/sandbox-work-1234-5678.scope\n";
const test_host_cgroup = "0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-foot-1.scope\n";

test "resolve: a sandbox has the values of the configuration and a label" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const info = resolve(arena.allocator(), test_work_cgroup, test_config).?;
    try testing.expectEqualStrings("work", info.name);
    try testing.expectEqual(@as(u32, 0x3a7d44ff), info.color);
    try testing.expectEqualStrings("win-classic-sandbox-work", info.gtk_theme.?);
    try testing.expect(!info.host);
    try testing.expect(info.has_label());
}

test "resolve: a sandbox without valid values has the default color" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // The color is not "#rrggbb".
    const web = resolve(arena.allocator(), "0::/sandbox.slice/sandbox-web.slice/a.scope\n", test_config).?;
    try testing.expectEqual(default_color, web.color);
    // The sandbox is not in the configuration.
    const other = resolve(arena.allocator(), "0::/sandbox.slice/sandbox-other.slice/a.scope\n", test_config).?;
    try testing.expectEqualStrings("other", other.name);
    try testing.expectEqual(default_color, other.color);
    try testing.expectEqual(@as(?[]const u8, null), other.gtk_theme);
    // There is no configuration, or it is not valid.
    const no_config = resolve(arena.allocator(), test_work_cgroup, null).?;
    try testing.expectEqualStrings("work", no_config.name);
    try testing.expectEqual(default_color, no_config.color);
    try testing.expect(no_config.has_label());
    try testing.expectEqual(default_color, resolve(arena.allocator(), test_work_cgroup, "").?.color);
}

test "resolve: a process in no sandbox slice is on the host, without a label" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const info = resolve(arena.allocator(), test_host_cgroup, test_config).?;
    try testing.expectEqualStrings("host", info.name);
    try testing.expectEqual(@as(u32, 0x808080ff), info.color);
    try testing.expect(info.host);
    try testing.expect(!info.has_label());
}

test "resolve: the host without a valid host color has the default color" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // A configuration that is cut, not valid, or without a host block.
    for ([_][]const u8{ "", "not json", "{\"host\": {}}", "{\"environments\": {}}" }) |json| {
        const info = resolve(arena.allocator(), test_host_cgroup, json).?;
        try testing.expect(info.host);
        try testing.expectEqual(default_color, info.color);
    }
}

test "resolve: without a configuration, a process in no sandbox has no sandbox" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectEqual(@as(?Info, null), resolve(arena.allocator(), test_host_cgroup, null));
    try testing.expectEqual(@as(?Info, null), resolve(arena.allocator(), "", null));
}

test "resolve: only the cgroup gives a sandbox" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // A cgroup v1 line does not give a sandbox. The process is on the host.
    const info = resolve(arena.allocator(), "1:name=systemd:/sandbox.slice/sandbox-work.slice/a.scope\n0::/app.slice/a.scope\n", test_config).?;
    try testing.expect(info.host);
}

test "dim and text_color" {
    try testing.expectEqual(@as(u32, 0x1d3e22ff), dim(0x3a7d44ff));
    try testing.expectEqual(@as(u32, 0xffffffff), text_color(0x3a7d44ff));
    try testing.expectEqual(@as(u32, 0x000000ff), text_color(0xf29718ff));
}
