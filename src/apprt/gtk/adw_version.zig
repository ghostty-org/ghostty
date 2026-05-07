const std = @import("std");

const adw = @import("adw");

const log = std.log.scoped(.gtk);

// Until the gobject bindings are built at the same time we are building
// Ghostty, we need to ensure that the version macros match the version of
// `libadwaita` that we are building/linking against.
//
// We pull this in through pkg-config, see src/build/SharedDeps.zig for more
// details.
pub const comptime_version = @import("adw_semver").version;

pub fn getRuntimeVersion() std.SemanticVersion {
    return .{
        .major = adw.getMajorVersion(),
        .minor = adw.getMinorVersion(),
        .patch = adw.getMicroVersion(),
    };
}

pub fn logVersion() void {
    log.info("libadwaita version build={f} runtime={f}", .{
        comptime_version,
        getRuntimeVersion(),
    });
}

/// Verifies that the running libadwaita version is at least the given
/// version. This will return false if Ghostty is configured to not build with
/// libadwaita.
///
/// This can be run in both a comptime and runtime context. If it is run in a
/// comptime context, it will only check the version in the headers. If it is
/// run in a runtime context, it will check the actual version of the library we
/// are linked against. So generally  you probably want to do both checks!
///
/// This is inlined so that the comptime checks will disable the runtime checks
/// if the comptime checks fail.
pub inline fn atLeast(
    comptime major: u16,
    comptime minor: u16,
    comptime micro: u16,
) bool {
    // If our header has lower versions than the given version, we can return
    // false immediately. This prevents us from compiling against unknown
    // symbols and makes runtime checks very slightly faster.
    if (comptime comptime_version.order(.{
        .major = major,
        .minor = minor,
        .patch = micro,
    }) == .lt) return false;

    // If we're in comptime then we can't check the runtime version.
    if (@inComptime()) return true;

    return runtimeAtLeast(major, minor, micro);
}

/// Verifies that the libadwaita version at runtime is at least the given version.
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

test "versionAtLeast" {
    const testing = std.testing;

    const funs = &.{ atLeast, runtimeAtLeast };
    inline for (funs) |fun| {
        try testing.expect(fun(comptime_version.major, comptime_version.minor, comptime_version.patch));
        try testing.expect(!fun(comptime_version.major, comptime_version.minor, comptime_version.patch + 1));
        try testing.expect(!fun(comptime_version.major, comptime_version.minor + 1, comptime_version.patch));
        try testing.expect(!fun(comptime_version.major + 1, comptime_version.minor, comptime_version.patch));
        try testing.expect(fun(comptime_version.major - 1, comptime_version.minor, comptime_version.patch));
        try testing.expect(fun(comptime_version.major - 1, comptime_version.minor + 1, comptime_version.patch));
        try testing.expect(fun(comptime_version.major - 1, comptime_version.minor, comptime_version.patch + 1));
        try testing.expect(fun(comptime_version.major, comptime_version.minor - 1, comptime_version.patch + 1));
    }
}

// Whether AdwDialog, AdwAlertDialog, etc. are supported (1.5+)
pub inline fn supportsDialogs() bool {
    return atLeast(1, 5, 0);
}

pub inline fn supportsTabOverview() bool {
    return atLeast(1, 4, 0);
}

pub inline fn supportsSwitchRow() bool {
    return atLeast(1, 4, 0);
}

pub inline fn supportsToolbarView() bool {
    return atLeast(1, 4, 0);
}

pub inline fn supportsBanner() bool {
    return atLeast(1, 3, 0);
}
