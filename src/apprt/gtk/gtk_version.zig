const std = @import("std");

// Until the gobject bindings are built at the same time we are building
// Ghostty, we need to import `gtk/gtk.h` directly to ensure that the version
// macros match the version of `gtk4` that we are building/linking against.
const c = @cImport({
    @cInclude("gtk/gtk.h");
});

const gtk = @import("gtk");

const log = std.log.scoped(.gtk);

pub const comptime_version: std.SemanticVersion = .{
    .major = c.GTK_MAJOR_VERSION,
    .minor = c.GTK_MINOR_VERSION,
    .patch = c.GTK_MICRO_VERSION,
};

pub fn getRuntimeVersion() std.SemanticVersion {
    return .{
        .major = gtk.getMajorVersion(),
        .minor = gtk.getMinorVersion(),
        .patch = gtk.getMicroVersion(),
    };
}

pub fn logVersion() void {
    log.info("GTK version build={} runtime={}", .{
        comptime_version,
        getRuntimeVersion(),
    });
}

/// Verifies that the GTK version is at least the given version.
///
/// This can be run in both a comptime and runtime context. If it is run in a
/// comptime context, it will only check the version in the headers. If it is
/// run in a runtime context, it will check the actual version of the library we
/// are linked against.
///
/// This function should be used in cases where the version check would affect
/// code generation, such as using symbols that are only available beyond a
/// certain version. For checks which only depend on GTK's runtime behavior,
/// use `runtimeAtLeast`.
///
/// This is inlined so that the comptime checks will disable the runtime checks
/// if the comptime checks fail.
pub inline fn atLeast(
    comptime major: u16,
    comptime minor: u16,
    comptime micro: u16,
) bool {
    // If our header has lower versions than the given version,
    // we can return false immediately. This prevents us from
    // compiling against unknown symbols and makes runtime checks
    // very slightly faster.
    if (comptime comptime_version.order(.{
        .major = major,
        .minor = minor,
        .patch = micro,
    }) == .lt) return false;

    // If we're in comptime then we can't check the runtime version.
    if (@inComptime()) return true;

    return runtimeAtLeast(major, minor, micro);
}

/// Verifies that the GTK version at runtime is at least the given version.
///
/// This function should be used in cases where the only the runtime behavior
/// is affected by the version check. For checks which would affect code
/// generation, use `atLeast`.
pub inline fn runtimeAtLeast(
    comptime major: u16,
    comptime minor: u16,
    comptime micro: u16,
) bool {
    // We use the functions instead of the constants such as c.GTK_MINOR_VERSION
    // because the function gets the actual runtime version.
    const runtime_version = getRuntimeVersion();
    return runtime_version.order(.{
        .major = major,
        .minor = minor,
        .patch = micro,
    }) != .lt;
}

pub inline fn runtimeUntil(
    comptime major: u16,
    comptime minor: u16,
    comptime micro: u16,
) bool {
    const runtime_version = getRuntimeVersion();
    return runtime_version.order(.{
        .major = major,
        .minor = minor,
        .patch = micro,
    }) == .lt;
}

test "atLeast" {
    const testing = std.testing;

    const funs = &.{ atLeast, runtimeAtLeast, runtimeUntil };
    inline for (funs) |fun| {
        try testing.expect(fun(c.GTK_MAJOR_VERSION, c.GTK_MINOR_VERSION, c.GTK_MICRO_VERSION));

        try testing.expect(!fun(c.GTK_MAJOR_VERSION, c.GTK_MINOR_VERSION, c.GTK_MICRO_VERSION + 1));
        try testing.expect(!fun(c.GTK_MAJOR_VERSION, c.GTK_MINOR_VERSION + 1, c.GTK_MICRO_VERSION));
        try testing.expect(!fun(c.GTK_MAJOR_VERSION + 1, c.GTK_MINOR_VERSION, c.GTK_MICRO_VERSION));

        try testing.expect(fun(c.GTK_MAJOR_VERSION - 1, c.GTK_MINOR_VERSION, c.GTK_MICRO_VERSION));
        try testing.expect(fun(c.GTK_MAJOR_VERSION - 1, c.GTK_MINOR_VERSION + 1, c.GTK_MICRO_VERSION));
        try testing.expect(fun(c.GTK_MAJOR_VERSION - 1, c.GTK_MINOR_VERSION, c.GTK_MICRO_VERSION + 1));

        try testing.expect(fun(c.GTK_MAJOR_VERSION, c.GTK_MINOR_VERSION - 1, c.GTK_MICRO_VERSION + 1));
    }
}
