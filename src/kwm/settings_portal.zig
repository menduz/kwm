//! The GTK theme of the desktop, from the settings portal
//! (org.freedesktop.portal.Settings) on the session bus. toggle-theme of
//! nix-config sets the GSettings key org.gnome.desktop.interface gtk-theme;
//! the portal then sends SettingChanged, and kwm reads the colors of the new
//! theme (theme.set_gtk_theme). At the start, without GTK_THEME, kwm reads
//! the key with ReadOne. portal_setting.zig chooses the setting.
//!
//! kwm uses the connection of the tray: tray.zig calls `attach` after it
//! connects and `detach` before it disconnects. Thus kwm follows the theme
//! only with the tray.

const std = @import("std");
const mem = std.mem;
const log = std.log.scoped(.settings_portal);

const sd = @import("sd_bus.zig");
const theme = @import("theme.zig");
const portal_setting = @import("portal_setting.zig");
const Context = @import("context.zig");

const ctx = Context.get();

const portal_name = "org.freedesktop.portal.Desktop";
const portal_path = "/org/freedesktop/portal/desktop";
const settings_interface = "org.freedesktop.portal.Settings";

var signal_slot: ?*sd.Slot = null;
var read_slot: ?*sd.Slot = null;


/// Follow the GTK theme on the bus `bus`.
pub fn attach(bus: *sd.Bus) void {
    _ = sd.check(
        sd.sd_bus_match_signal_async(
            bus, &signal_slot, portal_name, portal_path, settings_interface,
            "SettingChanged", on_setting_changed, null, null,
        ),
        "match SettingChanged",
    ) catch return;

    // GTK_THEME comes first, as for GTK.
    if (ctx.env.get("GTK_THEME") != null) return;
    _ = sd.check(
        sd.sd_bus_call_method_async(
            bus, &read_slot, portal_name, portal_path, settings_interface,
            "ReadOne", on_read_one, null, "ss",
            portal_setting.namespace.ptr, portal_setting.key.ptr,
        ),
        "call ReadOne",
    ) catch return;
}


pub fn detach() void {
    signal_slot = sd.sd_bus_slot_unref(signal_slot);
    read_slot = sd.sd_bus_slot_unref(read_slot);
}


/// Read a string in a variant.
fn read_variant_string(m: *sd.Message) ?[]const u8 {
    if (sd.sd_bus_message_enter_container(m, 'v', "s") <= 0) return null;
    var s: ?[*:0]const u8 = null;
    if (sd.sd_bus_message_read_basic(m, 's', @ptrCast(&s)) <= 0) return null;
    return mem.span(s orelse return null);
}


fn apply(namespace: []const u8, key: []const u8, value: []const u8) void {
    const name = portal_setting.gtk_theme(namespace, key, value) orelse return;
    log.info("GTK theme from the settings portal: {s}", .{ name });
    theme.set_gtk_theme(name);
}


/// SettingChanged (namespace, key, value).
fn on_setting_changed(m: *sd.Message, _: ?*anyopaque, _: *sd.Error) callconv(.c) c_int {
    var namespace: ?[*:0]const u8 = null;
    var key: ?[*:0]const u8 = null;
    if (sd.sd_bus_message_read(m, "ss", &namespace, &key) <= 0) return 0;
    const value = read_variant_string(m) orelse return 0;
    apply(mem.span(namespace orelse return 0), mem.span(key orelse return 0), value);
    return 0;
}


/// The reply of ReadOne: the value in a variant.
fn on_read_one(m: *sd.Message, _: ?*anyopaque, _: *sd.Error) callconv(.c) c_int {
    read_slot = sd.sd_bus_slot_unref(read_slot);
    if (sd.sd_bus_message_get_error(m)) |err| {
        // Without a portal, kwm keeps the colors of the configuration.
        log.warn("read the GTK theme from the settings portal failed: {s}", .{ err.message orelse err.name orelse "unknown error" });
        return 0;
    }
    const value = read_variant_string(m) orelse return 0;
    apply(portal_setting.namespace, portal_setting.key, value);
    return 0;
}
