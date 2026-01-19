const std = @import("std");
const gtk = @import("gtk");
const gobject = @import("gobject");

/// GTK Settings keys with well-defined types.
pub const Key = enum {
    gtk_enable_primary_paste,
    gtk_xft_dpi,
    gtk_font_name,

    fn Type(comptime self: Key) type {
        return switch (self) {
            .gtk_enable_primary_paste => bool,
            .gtk_xft_dpi => c_int,
            .gtk_font_name => []const u8,
        };
    }

    fn GValueType(comptime self: Key) type {
        return switch (self) {
            // Booleans are stored as integers in GTK's internal representation
            .gtk_enable_primary_paste,
            => c_int,

            // Integer types
            .gtk_xft_dpi,
            => c_int,

            // String types (returned as null-terminated C strings from GTK)
            .gtk_font_name,
            => ?[*:0]const u8,
        };
    }

    fn propertyName(comptime self: Key) [*:0]const u8 {
        return switch (self) {
            .gtk_enable_primary_paste => "gtk-enable-primary-paste",
            .gtk_xft_dpi => "gtk-xft-dpi",
            .gtk_font_name => "gtk-font-name",
        };
    }

    /// Returns true if this setting type requires memory allocation.
    /// this is defensive: types that do not need allocation need to be
    /// explicitly marked here
    fn requiresAllocation(comptime self: Key) bool {
        const T = self.Type();
        return switch (T) {
            bool, c_int => false,
            else => true,
        };
    }
};

/// Reads a GTK setting using the GTK Settings API for non-allocating types.
/// This automatically uses XDG Desktop Portal in Flatpak environments.
///
/// No allocator is required or used. Returns null if the setting is not available or cannot be read.
///
/// Example usage:
///   const enabled = get(.gtk_enable_primary_paste);
///   const dpi = get(.gtk_xft_dpi);
pub fn get(comptime key: Key) ?key.Type() {
    if (comptime key.requiresAllocation()) {
        @compileError("Allocating types require an allocator; use getAlloc() instead");
    }
    const settings = gtk.Settings.getDefault() orelse return null;
    return getImpl(settings, null, key) catch unreachable;
}

/// Reads a GTK setting using the GTK Settings API, allocating if necessary.
/// This automatically uses XDG Desktop Portal in Flatpak environments.
///
/// The caller must free any returned allocated memory with the provided allocator.
/// Returns null if the setting is not available or cannot be read.
/// May return an allocation error if memory allocation fails.
///
/// Example usage:
///   const theme = try getAlloc(allocator, .gtk_theme_name);
///   defer if (theme) |t| allocator.free(t);
pub fn getAlloc(allocator: std.mem.Allocator, comptime key: Key) !?key.Type() {
    const settings = gtk.Settings.getDefault() orelse return null;
    return getImpl(settings, allocator, key);
}

/// Shared implementation for reading GTK settings.
/// If allocator is null, only non-allocating types can be used.
/// Note: When adding a new type, research if it requires allocation (strings and boxed types do)
/// if allocation is NOT needed, list it inside the switch statement in the function requiresAllocation()
fn getImpl(settings: *gtk.Settings, allocator: ?std.mem.Allocator, comptime key: Key) !?key.Type() {
    const GValType = key.GValueType();
    var value = gobject.ext.Value.new(GValType);
    defer value.unset();

    settings.as(gobject.Object).getProperty(key.propertyName(), &value);

    return switch (key) {
        // Booleans are stored as integers in GTK, convert to bool
        .gtk_enable_primary_paste,
        => value.getInt() != 0,

        // Integer types are returned directly
        .gtk_xft_dpi,
        => value.getInt(),

        // Strings: GTK owns the GValue's pointer, so we must duplicate it
        // before the GValue is destroyed by defer value.unset()
        .gtk_font_name,
        => blk: {
            // This is defensive: we have already checked at compile-time that
            // an allocator is provided for allocating types
            const alloc = allocator.?;
            const ptr = value.getString() orelse break :blk null;
            const str = std.mem.span(ptr);
            break :blk try alloc.dupe(u8, str);
        },
    };
}

test "Key.Type returns correct types" {
    try std.testing.expectEqual(bool, Key.gtk_enable_primary_paste.Type());
    try std.testing.expectEqual(c_int, Key.gtk_xft_dpi.Type());
    try std.testing.expectEqual([]const u8, Key.gtk_font_name.Type());
}

test "Key.requiresAllocation identifies allocating types" {
    try std.testing.expectEqual(false, Key.gtk_enable_primary_paste.requiresAllocation());
    try std.testing.expectEqual(false, Key.gtk_xft_dpi.requiresAllocation());
    try std.testing.expectEqual(true, Key.gtk_font_name.requiresAllocation());
}

test "Key.GValueType returns correct GObject types" {
    try std.testing.expectEqual(c_int, Key.gtk_enable_primary_paste.GValueType());
    try std.testing.expectEqual(c_int, Key.gtk_xft_dpi.GValueType());
    try std.testing.expectEqual(?[*:0]const u8, Key.gtk_font_name.GValueType());
}

test "Key.propertyName returns correct GTK property names" {
    try std.testing.expectEqualSlices(u8, "gtk-enable-primary-paste", std.mem.span(Key.gtk_enable_primary_paste.propertyName()));
    try std.testing.expectEqualSlices(u8, "gtk-xft-dpi", std.mem.span(Key.gtk_xft_dpi.propertyName()));
    try std.testing.expectEqualSlices(u8, "gtk-font-name", std.mem.span(Key.gtk_font_name.propertyName()));
}
