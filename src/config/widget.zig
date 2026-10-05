//! Widgets of the bar. `bar.center` and `bar.right` are lists of widgets.
//!
//! Each widget has the click options of waybar modules: `on_click`,
//! `on_click_right`, `on_click_middle`, `on_scroll_up` and `on_scroll_down`.
//! Each one is a shell command.

const std = @import("std");
const Type = std.builtin.Type;

pub const Meter = clickable(struct {
    /// .braille: two braille cells with 17 levels, as the waybar meters.
    /// .percent: the number, for example "46%".
    format: enum { braille, percent } = .braille,
    /// Milliseconds between two updates.
    interval: u32 = 1000,
    /// Percentages for the warning and critical colors.
    warning: u8 = 70,
    critical: u8 = 90,
});

pub const Clock = clickable(struct {
    /// strftime(3) formats of the text and of the tooltip.
    format: [:0]const u8 = "%a %d %H:%M",
    tooltip: [:0]const u8 = "%Y-%m-%dT%H:%M:%S%z",
    interval: u32 = 1000,
});

pub const Disk = clickable(struct {
    path: [:0]const u8 = "/",
    /// Show the widget when this percentage of the disk is used, or more.
    show: u8 = 0,
    /// Show the widget in the critical color when fewer bytes are free.
    alert: u64 = 0,
    interval: u32 = 30_000,
});

pub const Battery = clickable(struct {
    /// The name in /sys/class/power_supply. null: the first of BAT0 to BAT9.
    name: ?[]const u8 = null,
    /// Percentages for the warning and critical colors on battery.
    warning: u8 = 30,
    critical: u8 = 15,
    interval: u32 = 5000,
});

pub const Network = clickable(struct {
    /// The interface. null: the interface of the default route.
    interface: ?[]const u8 = null,
    /// Text formats. {ifname}, {ipaddr}, {down} and {up} are replaced.
    /// {down} and {up} are bytes per second, for example "1.2M".
    format: []const u8 = "⇣{down} ⇡{up}",
    format_disconnected: []const u8 = "disconnected",
    tooltip: []const u8 = "{ifname} {ipaddr}\n⇣{down} ⇡{up}",
    interval: u32 = 1000,
});

pub const Script = clickable(struct {
    /// A shell command. Each line that it writes updates the widget.
    exec: []const u8,
    /// Milliseconds between two runs of `exec`. With 0, `exec` runs one time
    /// and continues to write lines. When it stops, the widget hides, and
    /// kwm starts it again 30 seconds later.
    interval: u32 = 0,
    /// .text: the line is the text.
    /// .json: the line is an object with "text", "tooltip" and "class", as
    /// waybar reads it. The classes "warning" and "critical" select colors.
    return_type: enum { text, json } = .text,
});

pub const Widget = union(enum) {
    memory: Meter,
    cpu: Meter,
    clock: Clock,
    disk: Disk,
    battery: Battery,
    network: Network,
    script: Script,
};

pub const click_fields = [_][]const u8 {
    "on_click",
    "on_click_right",
    "on_click_middle",
    "on_scroll_up",
    "on_scroll_down",
};


/// Add the optional click options to the fields of `T`.
fn clickable(comptime T: type) type {
    const fields = @typeInfo(T).@"struct".fields;
    const len = fields.len + click_fields.len;

    var names: [len][]const u8 = undefined;
    var types: [len]type = undefined;
    var attrs: [len]Type.StructField.Attributes = undefined;

    for (0.., fields) |i, field| {
        names[i] = field.name;
        types[i] = field.type;
        attrs[i] = Type.StructField.Attributes {
            .@"comptime" = field.is_comptime,
            .@"align" = field.alignment,
            .default_value_ptr = field.default_value_ptr,
        };
    }

    const none: ?[]const u8 = null;
    for (fields.len.., click_fields) |i, name| {
        names[i] = name;
        types[i] = ?[]const u8;
        attrs[i] = Type.StructField.Attributes {
            .@"comptime" = false,
            .@"align" = @alignOf(?[]const u8),
            .default_value_ptr = &none,
        };
    }

    return @Struct(.auto, null, &names, &types, &attrs);
}
