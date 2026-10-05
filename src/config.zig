const Self = @This();

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const zon = std.zon;
const process = std.process;
const log = std.log.scoped(.config);

const wayland = @import("wayland");
const river = wayland.client.river;

const kwm = @import("kwm");

const rule = @import("config/rule.zig");
const constants = @import("config/constants.zig");
const preprocess = @import("config/preprocess.zig");
pub const meta = @import("config/meta.zig");
pub const widget = @import("config/widget.zig");

// work around for zig issue: https://codeberg.org/ziglang/zig/issues/31570
pub const Modifiers = meta.unpacked(river.SeatV1.Modifiers);

pub const Config = struct {
    env: []const struct { []const u8, []const u8 },

    working_directory: union(enum) {
        none,
        home,
        custom: []const u8,
    },

    startup_cmds: []const []const []const u8,

    xcursor_theme: ?struct {
        name: [:0]const u8,
        size: u32,
    },

    background: ?u32,

    bar: @import("config/bar.zig"),

    single_tagset: bool,

    sloppy_focus: bool,

    /// No gap at the edges of the output when one tiled window fills it, and
    /// no gap in the monocle layout.
    smart_gaps: bool,

    cursor_warp: enum {
        none,
        on_output_changed,
        on_focus_changed,
    },

    disable_wrap_around_for_scroller: bool,

    remember_floating_geometry: bool,

    auto_swallow: bool,

    default_attach_mode: meta.enum_struct(kwm.Layout.Type, kwm.WindowAttachMode),

    default_window_decoration: kwm.WindowDecoration,

    border: struct {
        width: i32,
        color: struct {
            focus: u32,
            unfocus: u32,
            swallowing: u32,
        },
        /// The space on each side between a tiled window with client side
        /// decorations and its place in the layout. The client draws its
        /// frame outside its geometry, in this space and in the border. With
        /// the raised style and a value more than 0, kwm draws the outline
        /// of the border around such a window, and no edges. Example: a GTK
        /// frame of 4 pixels has its two edges in a border of 3 pixels with
        /// a margin of 2.
        csd_margin: i32 = 0,
        /// .flat: the compositor draws the border in `color.focus` or
        /// `color.unfocus`.
        /// .raised: kwm draws the window border style of Windows: a raised
        /// outer edge and a raised inner edge, with an outline of 1 pixel
        /// outside them when the border is 3 pixels or more. Refer to `raised`.
        /// A window with client side decorations draws its own frame, thus
        /// kwm draws only the outline around it. Refer to `csd_margin`.
        style: enum { flat, raised } = .flat,
        raised: struct {
            focus: Bevel = .{ .outline = 0x000080ff },
            unfocus: Bevel = .{},
            /// Read the colors from the `@define-color` lines of gtk-3.0/gtk.css
            /// of the current GTK theme. Each field names a color of that
            /// file. A color that the file does not give comes from `focus`
            /// and `unfocus` above. null: use only `focus` and `unfocus`.
            /// Refer to theme.zig.
            gtk_colors: ?struct {
                face: []const u8 = "bg_color",
                highlight: []const u8 = "light_shadow",
                shadow: []const u8 = "dark_shadow",
                frame: []const u8 = "borders",
                /// null: the outline comes from `focus` and `unfocus`.
                focus_outline: ?[]const u8 = "wm_active_title",
                unfocus_outline: ?[]const u8 = null,
            } = .{},
        } = .{},
    },

    /// The windows of a sandbox. A sandbox launcher sets SANDBOX_NAME and
    /// SANDBOX_COLOR in the environment of a program. kwm then shows the
    /// name in the bar, and draws the border in the color of the sandbox.
    /// Refer to sandbox.zig.
    sandbox: struct {
        /// Show a label with the name of the sandbox at the top right corner
        /// of each window of a sandbox.
        label: bool = true,
    } = .{},

    default_layout: kwm.Layout.Type,
    layout: kwm.Layout,

    bindings: struct {
        repeat_info: struct {
            rate: i32,
            delay: i32,
        },
        key: []const struct {
            mode: ?[]const u8 = null,
            layout: ?u32 = null,
            keysym: []const u8,
            modifiers: Modifiers,
            event: kwm.XkbBindingEvent,
        },
        pointer: []const struct {
            mode: ?[]const u8 = null,
            button: kwm.Button,
            modifiers: Modifiers,
            event: kwm.PointerBindingEvent,
        }
    },

    window_rules: []const rule.Window,
    output_rules: []const rule.Output,
};

/// The colors of a raised border. The defaults are those of the classic
/// scheme of Windows 98.
pub const Bevel = struct {
    /// The top and left line of the outer edge.
    face: u32 = 0xc0c0c0ff,
    /// The top and left line of the inner edge.
    highlight: u32 = 0xffffffff,
    /// The bottom and right line of the inner edge.
    shadow: u32 = 0x808080ff,
    /// The bottom and right line of the outer edge.
    frame: u32 = 0x000000ff,
    /// The line of 1 pixel outside the outer edge. Transparent: no outline.
    outline: u32 = 0x00000000,
};

pub const default: Config = @import("default_config");
pub const lock_mode = constants.lock_mode;
pub const default_mode = constants.default_mode;
pub const WindowRule = rule.Window;
pub const OutputRule = rule.Output;


pub fn load(
    ctx: struct {
        gpa: mem.Allocator,
        io: Io,
        env: *const process.Environ.Map,
    },
    path: []const u8,
) !Config {
    log.info("loading configuration from `{s}`", .{ path });

    var buffer = try preprocess.preprocess(.{ .gpa = ctx.gpa, .io = ctx.io, .env = ctx.env }, path);
    defer buffer.deinit(ctx.gpa);

    @setEvalBranchQuota(20000);
    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(ctx.gpa);
    const config = zon.parse.fromSliceAlloc(
        meta.add_default(Config, default),
        ctx.gpa,
        buffer.items[0..buffer.items.len-1:0],
        &diag,
        // After an error, zon frees the fields that it parsed. These fields
        // can hold slices of `default`, which are not in the heap. Do not
        // free them: kwm uses `default` after an error.
        .{ .ignore_unknown_fields = true, .free_on_error = false },
    ) catch |err| {
        if (err == error.ParseZon) {
            log.err("parse configuration failed: {f}", .{ diag });
        }
        return err;
    };
    return @as(*const Config, @ptrCast(&config)).*;
}


pub fn reload(
    ctx: struct {
        gpa: mem.Allocator,
        io: Io,
        env: *const process.Environ.Map,
    },
    old: *Config,
    path: []const u8
) !meta.field_mask(Config) {
    log.debug("reload configuration from `{s}`", .{ path });

    var new = try load(.{ .gpa = ctx.gpa, .io = ctx.io, .env = ctx.env }, path);
    defer free(ctx.gpa, new);

    var mask: meta.field_mask(Config) = .{};

    const struct_info = @typeInfo(Config).@"struct";
    inline for (struct_info.fields) |field| {
        if (
            !meta.deep_equal(
                @FieldType(Config, field.name),
                &@field(old, field.name),
                &@field(new, field.name),
            )
        ) {
            mem.swap(
                @FieldType(Config, field.name),
                &@field(old, field.name),
                &@field(new, field.name),
            );
            @field(mask, field.name) = true;
        }
    }

    return mask;
}


pub fn free(gpa: mem.Allocator, config: Config) void {
    log.debug("free configuration", .{});

    meta.zon_free(
        gpa,
        @as(*const meta.add_default(Config, default), @ptrCast(&config)).*,
        null
    );
}
