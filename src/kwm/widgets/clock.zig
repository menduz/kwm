//! Clock widget: the local time with strftime(3) formats.
//!
//! The approach follows w_time.zig of ziew (https://github.com/gryzus24/ziew,
//! MIT license).

const std = @import("std");

const common = @import("common.zig");
const ctx = common.ctx;

// glibc on 64-bit Linux.
const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};
extern "c" fn tzset() void;
extern "c" fn time(t: ?*c_long) c_long;
extern "c" fn localtime_r(t: *const c_long, tm: *Tm) ?*Tm;
extern "c" fn strftime(s: [*]u8, max: usize, format: [*:0]const u8, tm: *const Tm) usize;


/// Read the time zone again, for example after a change of TZ.
pub fn init() void {
    tzset();
}


fn append(list: *std.ArrayList(u8), format: [:0]const u8, tm: *const Tm) !void {
    var buffer: [256]u8 = undefined;
    const len = strftime(&buffer, buffer.len, format.ptr, tm);
    try list.appendSlice(ctx.gpa, buffer[0..len]);
}


pub fn update(cfg: anytype, out: *common.Output) !void {
    const now = time(null);
    var tm: Tm = undefined;
    _ = localtime_r(&now, &tm) orelse return error.LocalTime;

    try append(&out.text, cfg.format, &tm);
    try append(&out.tooltip, cfg.tooltip, &tm);
}
