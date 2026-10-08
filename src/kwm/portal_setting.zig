//! The settings of the desktop that kwm follows, without D-Bus objects.
//! settings_portal.zig gives the values of the settings portal to these
//! functions. `zig build test` runs the tests below.

const std = @import("std");
const mem = std.mem;
const testing = std.testing;


/// The setting of the GTK theme: the GSettings key that toggle-theme sets.
pub const namespace = "org.gnome.desktop.interface";
pub const key = "gtk-theme";


/// The name of the GTK theme in a setting of the settings portal. null: the
/// setting is an other one, or the name is empty.
pub fn gtk_theme(setting_namespace: []const u8, setting_key: []const u8, value: []const u8) ?[]const u8 {
    if (!mem.eql(u8, setting_namespace, namespace)) return null;
    if (!mem.eql(u8, setting_key, key)) return null;
    // GTK_THEME can give a variant after the name: "Name:dark". GSettings
    // does not, but the name is the part before the colon in both.
    const name = mem.trim(u8, value[0 .. mem.indexOfScalar(u8, value, ':') orelse value.len], " \t");
    if (name.len == 0) return null;
    return name;
}


test "gtk_theme: the GTK theme key" {
    try testing.expectEqualStrings("win-classic-dark", gtk_theme(namespace, key, "win-classic-dark").?);
    try testing.expectEqualStrings("win-classic-dark", gtk_theme(namespace, key, " win-classic-dark:dark").?);
}

test "gtk_theme: other settings and empty names" {
    try testing.expectEqual(@as(?[]const u8, null), gtk_theme(namespace, "icon-theme", "Papirus"));
    try testing.expectEqual(@as(?[]const u8, null), gtk_theme("org.freedesktop.appearance", key, "x"));
    try testing.expectEqual(@as(?[]const u8, null), gtk_theme(namespace, key, ""));
    try testing.expectEqual(@as(?[]const u8, null), gtk_theme(namespace, key, ":dark"));
}
