//! CPU widget: the CPU use since the last update as a meter, from /proc/stat.
//!
//! The approach follows w_cpu.zig of ziew (https://github.com/gryzus24/ziew,
//! MIT license).

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;

const common = @import("common.zig");
const ctx = common.ctx;

/// The counters of the last update.
pub const Data = struct {
    total: u64 = 0,
    idle: u64 = 0,
};


pub fn update(cfg: anytype, data: *Data, out: *common.Output) !void {
    var buffer: [512]u8 = undefined;
    const stat = try common.read_file("/proc/stat", &buffer);

    // The first line: "cpu  user nice system idle iowait irq softirq steal ..."
    const line = stat[0 .. mem.indexOfScalar(u8, stat, '\n') orelse stat.len];
    var fields = mem.tokenizeScalar(u8, line, ' ');
    if (!mem.eql(u8, fields.next() orelse "", "cpu")) return error.BadProcStat;

    var values: [8]u64 = .{ 0 } ** 8;
    for (&values) |*v| {
        v.* = fmt.parseInt(u64, fields.next() orelse break, 10) catch 0;
    }
    var total: u64 = 0;
    for (values) |v| total += v;
    const idle = values[3] + values[4];

    const delta_total = total -| data.total;
    const delta_idle = idle -| data.idle;
    data.* = .{ .total = total, .idle = idle };

    const percent = if (delta_total == 0) 0 else (delta_total -| delta_idle) * 100 / delta_total;
    try common.append_meter(&out.text, cfg, percent);
    try out.tooltip.print(ctx.gpa, "CPU {}%", .{ percent });
}
