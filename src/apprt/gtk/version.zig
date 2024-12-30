const c = @import("c.zig").c;

/// Verifies that the GTK version is at least the given version.
///
/// This can be run in both a comptime and runtime context. If it
/// is run in a comptime context, it will only check the version
/// in the headers. If it is run in a runtime context, it will
/// check the actual version of the library we are linked against.
///
/// This is inlined so that the comptime checks will disable the
/// runtime checks if the comptime checks fail.
pub inline fn atLeast(
    comptime major: u16,
    comptime minor: u16,
    comptime micro: u16,
) bool {
    // If our header has lower versions than the given version,
    // we can return false immediately. This prevents us from
    // compiling against unknown symbols and makes runtime checks
    // very slightly faster.
    if (comptime c.GTK_MAJOR_VERSION < major or
        (c.GTK_MAJOR_VERSION == major and c.GTK_MINOR_VERSION < minor) or
        (c.GTK_MAJOR_VERSION == major and c.GTK_MINOR_VERSION == minor and c.GTK_MICRO_VERSION < micro))
        return false;

    // If we're in comptime then we can't check the runtime version.
    if (@inComptime()) return true;

    // We use the functions instead of the constants such as
    // c.GTK_MINOR_VERSION because the function gets the actual
    // runtime version.
    if (c.gtk_get_major_version() >= major) {
        if (c.gtk_get_major_version() > major) return true;
        if (c.gtk_get_minor_version() >= minor) {
            if (c.gtk_get_minor_version() > minor) return true;
            return c.gtk_get_micro_version() >= micro;
        }
    }

    return false;
}

test "atLeast" {
    const std = @import("std");
    const testing = std.testing;

    try testing.expectEqual(true, atLeast(c.GTK_MAJOR_VERSION, c.GTK_MINOR_VERSION, c.GTK_MICRO_VERSION));

    try testing.expectEqual(false, atLeast(c.GTK_MAJOR_VERSION, c.GTK_MINOR_VERSION, c.GTK_MICRO_VERSION + 1));
    try testing.expectEqual(false, atLeast(c.GTK_MAJOR_VERSION, c.GTK_MINOR_VERSION + 1, c.GTK_MICRO_VERSION));
    try testing.expectEqual(false, atLeast(c.GTK_MAJOR_VERSION + 1, c.GTK_MINOR_VERSION, c.GTK_MICRO_VERSION));

    try testing.expectEqual(true, atLeast(c.GTK_MAJOR_VERSION - 1, c.GTK_MINOR_VERSION, c.GTK_MICRO_VERSION));
    try testing.expectEqual(true, atLeast(c.GTK_MAJOR_VERSION - 1, c.GTK_MINOR_VERSION + 1, c.GTK_MICRO_VERSION));
    try testing.expectEqual(true, atLeast(c.GTK_MAJOR_VERSION - 1, c.GTK_MINOR_VERSION, c.GTK_MICRO_VERSION + 1));

    try testing.expectEqual(true, atLeast(c.GTK_MAJOR_VERSION, c.GTK_MINOR_VERSION - 1, c.GTK_MICRO_VERSION + 1));
}
