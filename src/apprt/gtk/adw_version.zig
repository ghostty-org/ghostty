const std = @import("std");

// Until the gobject bindings are built at the same time we are building
// Ghostty, we need to import `adwaita.h` directly to ensure that the version
// macros match the version of `libadwaita` that we are building/linking
// against.
const c = @cImport({
    @cInclude("adwaita.h");
});

const adw = @import("adw");
const VersionChecked = @import("version.zig").VersionChecked;

const log = std.log.scoped(.gtk);

pub const comptime_version: std.SemanticVersion = .{
    .major = c.ADW_MAJOR_VERSION,
    .minor = c.ADW_MINOR_VERSION,
    .patch = c.ADW_MICRO_VERSION,
};

pub fn getRuntimeVersion() std.SemanticVersion {
    return .{
        .major = adw.getMajorVersion(),
        .minor = adw.getMinorVersion(),
        .patch = adw.getMicroVersion(),
    };
}

const AdwaitaVersion = VersionChecked("libadwaita", getRuntimeVersion, comptime_version);

pub const atLeast = AdwaitaVersion.atLeast;
pub const until = AdwaitaVersion.until;
pub const runtimeAtLeast = AdwaitaVersion.runtimeAtLeast;
pub const runtimeUntil = AdwaitaVersion.runtimeUntil;

pub fn logVersion() void {
    log.info("{s}", .{AdwaitaVersion.logFormat()});
}

// Whether AdwDialog, AdwAlertDialog, etc. are supported (1.5+)
pub inline fn supportsDialogs() bool {
    return atLeast(1, 5, 0);
}

pub inline fn supportsTabOverview() bool {
    return atLeast(1, 4, 0);
}

pub inline fn supportsToolbarView() bool {
    return atLeast(1, 4, 0);
}

pub inline fn supportsBanner() bool {
    return atLeast(1, 3, 0);
}
