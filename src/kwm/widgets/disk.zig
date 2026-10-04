//! Disk widget: the free space of a file system, from statvfs(3). It shows
//! only when the disk is full enough or the free space is low.
//!
//! The approach follows w_dysk.zig of ziew (https://github.com/gryzus24/ziew,
//! MIT license).

const std = @import("std");
const fmt = std.fmt;

const common = @import("common.zig");
const ctx = common.ctx;

// glibc on 64-bit Linux.
const Statvfs = extern struct {
    bsize: c_ulong,
    frsize: c_ulong,
    blocks: u64,
    bfree: u64,
    bavail: u64,
    files: u64,
    ffree: u64,
    favail: u64,
    fsid: c_ulong,
    flag: c_ulong,
    namemax: c_ulong,
    spare: [6]c_int,
};
extern "c" fn statvfs(path: [*:0]const u8, buf: *Statvfs) c_int;


pub fn update(cfg: anytype, out: *common.Output) !void {
    var st: Statvfs = undefined;
    if (statvfs(cfg.path.ptr, &st) != 0) return error.Statvfs;

    const total = st.blocks * st.frsize;
    const free = st.bavail * st.frsize;
    const used = (st.blocks -| st.bfree) * st.frsize;
    // As df(1): the space for root is not available to the user.
    const usable = used + free;
    const percent = if (usable == 0) 0 else used * 100 / usable;

    const alert = free < cfg.alert;
    out.hidden = !alert and percent < cfg.show;

    const gb: u64 = 1_000_000_000;
    var buffer: [32]u8 = undefined;
    try common.append_colored(
        &out.text,
        if (alert) ctx.cfg.bar.widget_colors.critical else null,
        try fmt.bufPrint(&buffer, "{}G", .{ free / gb }),
    );

    // As the waybar tooltip, in GB with two decimals.
    try out.tooltip.print(ctx.gpa, "Storage: {}.{:0>2} GB out of {}.{:0>2} GB available ({}% used)", .{
        free / gb, free % gb / (gb / 100),
        total / gb, total % gb / (gb / 100),
        percent,
    });
}
