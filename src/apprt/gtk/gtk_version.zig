const std = @import("std");

// Until the gobject bindings are built at the same time we are building
// Ghostty, we need to import `gtk/gtk.h` directly to ensure that the version
// macros match the version of `gtk4` that we are building/linking against.
const c = @cImport({
    @cInclude("gtk/gtk.h");
});

const gtk = @import("gtk");
const VersionChecked = @import("version.zig").VersionChecked;
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

const GTKVersion = VersionChecked("GTK", getRuntimeVersion, comptime_version);

pub const atLeast = GTKVersion.atLeast;
pub const until = GTKVersion.until;
pub const runtimeAtLeast = GTKVersion.runtimeAtLeast;
pub const runtimeUntil = GTKVersion.runtimeUntil;

pub fn logVersion() void {
    log.info("{s}", .{GTKVersion.logFormat()});
}
