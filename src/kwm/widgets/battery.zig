//! Battery widget: the charge of a battery, from /sys/class/power_supply.
//! It shows only on battery and while the battery charges. With the power
//! connected and a battery that does not charge (full, or held at a charge
//! limit), it hides.

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;

const common = @import("common.zig");
const ctx = common.ctx;

// The battery icons of Material Design in Nerd Fonts, as in waybar.nix:
// 10%, 20%, ... 100%.
const level_icons = [_][]const u8 {
    "\u{f007a}", "\u{f007b}", "\u{f007c}", "\u{f007d}", "\u{f007e}",
    "\u{f007f}", "\u{f0080}", "\u{f0081}", "\u{f0082}", "\u{f0079}",
};
const charging_icons = [_][]const u8 {
    "\u{f089c}", "\u{f0086}", "\u{f0087}", "\u{f0088}", "\u{f089d}",
    "\u{f0089}", "\u{f089e}", "\u{f008a}", "\u{f008b}", "\u{f0085}",
};


pub fn update(cfg: anytype, out: *common.Output) !void {
    var name_buffer: [16]u8 = undefined;
    const name = cfg.name orelse find_battery(&name_buffer) orelse {
        out.hidden = true;
        return;
    };

    var status_buffer: [32]u8 = undefined;
    const status = read(name, "status", &status_buffer) orelse "Unknown";
    const charging = mem.eql(u8, status, "Charging");
    const discharging = mem.eql(u8, status, "Discharging");
    out.hidden = !charging and !discharging;

    const capacity: u64 = read_int(name, "capacity") orelse ratio: {
        const now = read_int(name, "energy_now") orelse read_int(name, "charge_now") orelse break :ratio 0;
        const full = read_int(name, "energy_full") orelse read_int(name, "charge_full") orelse break :ratio 0;
        break :ratio if (full == 0) 0 else now * 100 / full;
    };

    const icons = if (charging) &charging_icons else &level_icons;
    const icon = icons[@min(capacity / 10, icons.len - 1)];
    const color: ?u32 =
        if (!discharging) null
        else if (capacity <= cfg.critical) ctx.cfg.bar.widget_colors.critical
        else if (capacity <= cfg.warning) ctx.cfg.bar.widget_colors.warning
        else null;
    var text_buffer: [32]u8 = undefined;
    const text =
        if (capacity < 100) try fmt.bufPrint(&text_buffer, "{s} {}%", .{ icon, capacity })
        else icon;
    try common.append_colored(&out.text, color, text);

    // The power in microwatts, or the current in microamperes times the
    // voltage in microvolts.
    const power: ?u64 = read_int(name, "power_now") orelse power: {
        const current = read_int(name, "current_now") orelse break :power null;
        const voltage = read_int(name, "voltage_now") orelse break :power null;
        break :power current * voltage / 1_000_000;
    };

    try out.tooltip.print(ctx.gpa, "Capacity: {}%\n", .{ capacity });
    if (power) |uw| {
        try out.tooltip.print(ctx.gpa, "Power draw: {}.{:0>2} W\n", .{ uw / 1_000_000, uw % 1_000_000 / 10_000 });
    } else {
        try out.tooltip.appendSlice(ctx.gpa, "Power draw: unknown\n");
    }
    try out.tooltip.print(ctx.gpa, "Status: {s}\n", .{ status });
    if (read_int(name, "cycle_count")) |cycles| {
        try out.tooltip.print(ctx.gpa, "Cycles: {}", .{ cycles });
    } else {
        try out.tooltip.appendSlice(ctx.gpa, "Cycles: unknown");
    }
}


/// The first of BAT0 to BAT9 that is a battery.
fn find_battery(buffer: []u8) ?[]const u8 {
    for (0..10) |i| {
        const name = fmt.bufPrint(buffer, "BAT{}", .{ i }) catch return null;
        var type_buffer: [16]u8 = undefined;
        const kind = read(name, "type", &type_buffer) orelse continue;
        if (mem.eql(u8, kind, "Battery")) return name;
    }
    return null;
}


/// The value in the file `file` of the power supply `name`, without the new
/// line. null: no file.
fn read(name: []const u8, file: []const u8, buffer: []u8) ?[]const u8 {
    var path_buffer: [128]u8 = undefined;
    const path = fmt.bufPrintZ(&path_buffer, "/sys/class/power_supply/{s}/{s}", .{ name, file }) catch return null;
    const text = common.read_file(path.ptr, buffer) catch return null;
    return mem.trim(u8, text, " \n");
}


fn read_int(name: []const u8, file: []const u8) ?u64 {
    var buffer: [32]u8 = undefined;
    const text = read(name, file, &buffer) orelse return null;
    return fmt.parseInt(u64, text, 10) catch null;
}
