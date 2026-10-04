const Self = @This();

const std = @import("std");
const mem = std.mem;

const kwm = @import("kwm");

const meta = @import("meta.zig");
pub const widget = @import("widget.zig");

const Color = struct {
    fg: u32,
    bg: u32,
};
const Scheme = struct {
    normal: Color,
    select: Color,
};
const BarArea = union(kwm.BarArea) {
    tags,
    mode: ?[]const u8,
    layout: ?kwm.Layout.Type,
    title,
    status,
};


show_default: bool,

position: enum {
    top,
    bottom,
},

font: []const u8,

/// The minimum height of the bar, in logical pixels. When the bar is higher
/// than the font, the text is in the vertical center.
min_height: u32 = 0,

scheme: Scheme,

tags: ?struct {
    tags: []const []const u8,
    /// Text color of the tags without windows. null uses the color of the scheme.
    empty_fg: ?u32 = null,
    click: meta.enum_struct(
        kwm.Button,
        ?kwm.BindingAction
    ),
},

mode: ?struct {
    tags: []const struct { []const u8, []const u8 },
    click: meta.enum_struct(
        kwm.Button,
        ?kwm.BindingAction
    ),

    pub fn tag(self: *const @This(), mode: []const u8) ?[]const u8 {
        for (self.tags) |pair| {
            const m, const t = pair;
            if (mem.eql(u8, m, mode)) return t;
        }
        return null;
    }
},

layout: ?struct {
    tags: struct {
        tile: meta.enum_struct(kwm.Layout.Tile.MasterLocation, []const u8),
        grid: meta.enum_struct(kwm.Layout.Grid.Direction, []const u8),
        monocle: []const u8,
        deck: meta.enum_struct(kwm.Layout.Deck.MasterLocation, []const u8),
        scroller: []const u8,
        centered_master: meta.enum_struct(kwm.Layout.CenteredMaster.Direction, []const u8),
        float: []const u8,
    },
    click: meta.enum_struct(
        kwm.Button,
        ?kwm.BindingAction
    ),
},

title: ?struct {
    click: meta.enum_struct(
        kwm.Button,
        ?kwm.BindingAction
    ),
},

status: ?struct {
    data: union(enum) {
        text: []const u8,
        stdin,
        fifo: []const u8,
    },
    click: meta.enum_struct(
        kwm.Button,
        ?kwm.BindingAction
    ),
},

/// Widgets in the center of the bar, and at the right end of the bar.
/// Refer to widget.zig.
center: []const widget.Widget = &.{},
right: []const widget.Widget = &.{},

widget_colors: struct {
    warning: u32 = 0xffa500ff,
    critical: u32 = 0xff5555ff,
} = .{},

/// Milliseconds that the pointer stays on a widget before its tooltip shows.
tooltip_delay: u32 = 500,

/// The system tray (StatusNotifierItem), at the right end of the bar. null:
/// no tray. kwm must be built with -Dtray=true.
tray: ?struct {
    /// The icon size in logical pixels. 0: the height of the bar.
    icon_size: u32 = 0,
    /// Logical pixels between two icons.
    spacing: u32 = 4,
    /// The icon theme for the icon names of the items.
    icon_theme: []const u8 = "hicolor",
    /// Show the items with the status "Passive".
    show_passive: bool = false,
} = null,

override_colors: []const struct {
    area: BarArea,
    scheme: meta.make_fields_optional(Scheme),

    fn is_match(self: *const @This(), area: BarArea) bool {
        if (std.meta.activeTag(self.area) != std.meta.activeTag(area)) return false;

        return switch (area) {
            .mode => |mode|
                if (self.area.mode) |m| mem.eql(u8, mode.?, m)
                else true,
            .layout => |layout|
                if (self.area.layout) |l| layout.? == l
                else true,
            else => true,
        };
    }
},


pub fn get(self: *const Self, comptime area: kwm.BarArea) @FieldType(Self, @tagName(area)) {
    return @field(self, @tagName(area));
}


pub fn get_scheme(
    self: *const Self,
    area: BarArea,
) Scheme {
    for (self.override_colors) |item| {
        if (!item.is_match(area)) continue;

        return meta.override(self.scheme, item.scheme);
    }

    return self.scheme;
}


pub fn empty(self: *const Self) bool {
    inline for (@typeInfo(kwm.BarArea).@"enum".fields) |field| {
        if (@field(self, field.name) != null) return false;
    }
    return true;
}
