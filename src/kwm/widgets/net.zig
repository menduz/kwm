//! Network widget: the download and upload rates of an interface, from
//! /proc/net/dev, and its IPv4 address and state, from ioctl(2).
//!
//! The approach follows w_net.zig of ziew (https://github.com/gryzus24/ziew,
//! MIT license).

const std = @import("std");
const Io = std.Io;
const fmt = std.fmt;
const mem = std.mem;
const linux = std.os.linux;

const posix = @import("posix");

const common = @import("common.zig");
const ctx = common.ctx;

/// The counters of the last update.
pub const Data = struct {
    ifname: [linux.IFNAMESIZE]u8 = .{ 0 } ** linux.IFNAMESIZE,
    rx: u64 = 0,
    tx: u64 = 0,
    /// Awake-clock milliseconds. 0 before the first update.
    time: i64 = 0,
};

/// A socket for ioctl(2). One socket serves all network widgets.
var socket: ?linux.fd_t = null;


fn get_socket() !linux.fd_t {
    if (socket) |fd| return fd;

    const rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return error.Socket;
    socket = @intCast(rc);
    return socket.?;
}


pub fn deinit() void {
    if (socket) |fd| posix.close(fd);
    socket = null;
}


/// The interface of the default route, from /proc/net/route.
fn default_interface(buffer: []u8) ?[]const u8 {
    const data = common.read_file("/proc/net/route", buffer) catch return null;

    // "Iface Destination Gateway Flags ...". The first line is the header.
    var lines = mem.tokenizeScalar(u8, data, '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        var fields = mem.tokenizeAny(u8, line, " \t");
        const iface = fields.next() orelse continue;
        const destination = fields.next() orelse continue;
        _ = fields.next(); // gateway
        const flags = fmt.parseInt(u32, fields.next() orelse continue, 16) catch continue;
        // RTF_UP
        if (mem.eql(u8, destination, "00000000") and flags & 0x1 != 0) return iface;
    }
    return null;
}


/// The received and transmitted bytes of an interface, from /proc/net/dev.
fn counters(ifname: []const u8) ?struct { rx: u64, tx: u64 } {
    var buffer: [8192]u8 = undefined;
    const data = common.read_file("/proc/net/dev", &buffer) catch return null;

    // "  eth0: rx_bytes rx_packets ... (8 fields) tx_bytes ..."
    var lines = mem.tokenizeScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const colon = mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!mem.eql(u8, mem.trim(u8, line[0..colon], " "), ifname)) continue;

        var fields = mem.tokenizeScalar(u8, line[colon + 1 ..], ' ');
        var values: [9]u64 = undefined;
        for (&values) |*v| {
            v.* = fmt.parseInt(u64, fields.next() orelse return null, 10) catch return null;
        }
        return .{ .rx = values[0], .tx = values[8] };
    }
    return null;
}


fn ifreq_for(ifname: []const u8) linux.ifreq {
    var ifr = mem.zeroes(linux.ifreq);
    const len = @min(ifname.len, linux.IFNAMESIZE - 1);
    @memcpy(ifr.ifrn.name[0..len], ifname[0..len]);
    return ifr;
}


/// True when the interface is up and running.
fn is_running(sock: linux.fd_t, ifname: []const u8) bool {
    var ifr = ifreq_for(ifname);
    if (linux.errno(linux.ioctl(sock, linux.SIOCGIFFLAGS, @intFromPtr(&ifr))) != .SUCCESS) return false;
    return ifr.ifru.flags.UP and ifr.ifru.flags.RUNNING;
}


/// The IPv4 address of the interface, or "no address".
fn print_address(list: *std.ArrayList(u8), sock: linux.fd_t, ifname: []const u8) !void {
    var ifr = ifreq_for(ifname);
    if (linux.errno(linux.ioctl(sock, linux.SIOCGIFADDR, @intFromPtr(&ifr))) != .SUCCESS) {
        try list.appendSlice(ctx.gpa, "no address");
        return;
    }
    const addr: *const linux.sockaddr.in = @ptrCast(&ifr.ifru.addr);
    // The address is in network byte order.
    const b: [4]u8 = @bitCast(addr.addr);
    try list.print(ctx.gpa, "{}.{}.{}.{}", .{ b[0], b[1], b[2], b[3] });
}


/// Replace {ifname}, {ipaddr}, {down} and {up} in `format`.
fn expand(
    list: *std.ArrayList(u8),
    format: []const u8,
    sock: linux.fd_t,
    ifname: []const u8,
    down: u64,
    up: u64,
) !void {
    var rest = format;
    while (mem.indexOfScalar(u8, rest, '{')) |open| {
        try list.appendSlice(ctx.gpa, rest[0..open]);
        const close = mem.indexOfScalarPos(u8, rest, open, '}') orelse {
            rest = rest[open..];
            break;
        };
        const key = rest[open + 1 .. close];
        if (mem.eql(u8, key, "ifname")) {
            try list.appendSlice(ctx.gpa, ifname);
        } else if (mem.eql(u8, key, "ipaddr")) {
            try print_address(list, sock, ifname);
        } else if (mem.eql(u8, key, "down")) {
            try common.print_bytes(list, down);
        } else if (mem.eql(u8, key, "up")) {
            try common.print_bytes(list, up);
        } else {
            try list.appendSlice(ctx.gpa, rest[open .. close + 1]);
        }
        rest = rest[close + 1 ..];
    }
    try list.appendSlice(ctx.gpa, rest);
}


pub fn update(cfg: anytype, data: *Data, out: *common.Output) !void {
    const sock = try get_socket();

    var route_buffer: [4096]u8 = undefined;
    const ifname = cfg.interface orelse default_interface(&route_buffer) orelse "";

    const now = Io.Timestamp.now(ctx.io, .awake).toMilliseconds();
    const current = if (ifname.len > 0 and is_running(sock, ifname)) counters(ifname) else null;
    const c = current orelse {
        data.* = .{};
        try out.text.appendSlice(ctx.gpa, cfg.format_disconnected);
        try out.tooltip.appendSlice(ctx.gpa, if (ifname.len > 0) ifname else "no default route");
        return;
    };

    // Bytes per second since the last update of the same interface.
    var down: u64 = 0;
    var up: u64 = 0;
    const same = data.time != 0 and mem.eql(u8, mem.sliceTo(&data.ifname, 0), ifname);
    if (same and now > data.time) {
        const ms: u64 = @intCast(now - data.time);
        down = (c.rx -| data.rx) * 1000 / ms;
        up = (c.tx -| data.tx) * 1000 / ms;
    }

    data.* = .{ .rx = c.rx, .tx = c.tx, .time = now };
    const len = @min(ifname.len, linux.IFNAMESIZE - 1);
    @memcpy(data.ifname[0..len], ifname[0..len]);

    try expand(&out.text, cfg.format, sock, ifname, down, up);
    try expand(&out.tooltip, cfg.tooltip, sock, ifname, down, up);
}
