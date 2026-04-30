const std = @import("std");
const gtk = @import("gtk");
const gobject = @import("gobject");

/// GTK Settings keys with well-defined types.
pub const Key = enum {
    @"gtk-enable-primary-paste",
    @"gtk-xft-dpi",
    @"gtk-font-name",

    fn Type(comptime self: Key) type {
        return switch (self) {
            .@"gtk-enable-primary-paste" => bool,
            .@"gtk-xft-dpi" => c_int,
            .@"gtk-font-name" => []const u8,
        };
    }

    fn GValueType(comptime self: Key) type {
        return switch (self.Type()) {
            bool => c_int,
            c_int => c_int,
            []const u8 => ?[*:0]const u8,
            else => @compileError("Unsupported type for GTK settings"),
        };
    }

    /// Returns true if this setting type requires memory allocation.
    /// Types that do not need allocation must be explicitly marked.
    fn requiresAllocation(comptime self: Key) bool {
        const T = self.Type();
        return switch (T) {
            bool, c_int => false,
            else => true,
        };
    }
};

/// Reads a GTK setting for non-allocating types.
/// Automatically uses XDG Desktop Portal in Flatpak environments.
/// Returns null if the setting is unavailable.
pub fn get(comptime key: Key) ?key.Type() {
    if (comptime key.requiresAllocation()) {
        @compileError("Allocating types require an allocator; use getAlloc() instead");
    }
    const settings = gtk.Settings.getDefault() orelse return null;
    return getImpl(settings, null, key) catch unreachable;
}

/// Reads a GTK setting, allocating memory if necessary.
/// Automatically uses XDG Desktop Portal in Flatpak environments.
/// Caller must free returned memory with the provided allocator.
/// Returns null if the setting is unavailable.
pub fn getAlloc(allocator: std.mem.Allocator, comptime key: Key) !?key.Type() {
    const settings = gtk.Settings.getDefault() orelse return null;
    return getImpl(settings, allocator, key);
}

fn getImpl(settings: *gtk.Settings, allocator: ?std.mem.Allocator, comptime key: Key) !?key.Type() {
    const GValType = key.GValueType();
    var value = gobject.ext.Value.new(GValType);
    defer value.unset();

    settings.as(gobject.Object).getProperty(@tagName(key).ptr, &value);

    return switch (key.Type()) {
        bool => value.getInt() != 0,
        c_int => value.getInt(),
        []const u8 => blk: {
            const alloc = allocator.?;
            const ptr = value.getString() orelse break :blk null;
            const str = std.mem.span(ptr);
            break :blk try alloc.dupe(u8, str);
        },
        else => @compileError("Unsupported type for GTK settings"),
    };
}

test "Key.Type returns correct types" {
    try std.testing.expectEqual(bool, Key.@"gtk-enable-primary-paste".Type());
    try std.testing.expectEqual(c_int, Key.@"gtk-xft-dpi".Type());
    try std.testing.expectEqual([]const u8, Key.@"gtk-font-name".Type());
}

test "Key.requiresAllocation identifies allocating types" {
    try std.testing.expectEqual(false, Key.@"gtk-enable-primary-paste".requiresAllocation());
    try std.testing.expectEqual(false, Key.@"gtk-xft-dpi".requiresAllocation());
    try std.testing.expectEqual(true, Key.@"gtk-font-name".requiresAllocation());
}

test "Key.GValueType returns correct GObject types" {
    try std.testing.expectEqual(c_int, Key.@"gtk-enable-primary-paste".GValueType());
    try std.testing.expectEqual(c_int, Key.@"gtk-xft-dpi".GValueType());
    try std.testing.expectEqual(?[*:0]const u8, Key.@"gtk-font-name".GValueType());
}

test "@tagName returns correct GTK property names" {
    try std.testing.expectEqualStrings("gtk-enable-primary-paste", @tagName(Key.@"gtk-enable-primary-paste"));
    try std.testing.expectEqualStrings("gtk-xft-dpi", @tagName(Key.@"gtk-xft-dpi"));
    try std.testing.expectEqualStrings("gtk-font-name", @tagName(Key.@"gtk-font-name"));
}
