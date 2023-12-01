const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const objc = @import("objc");

/// Verifies that the running macOS system version is at least the given version.
pub fn macosVersionAtLeast(major: i64, minor: i64, patch: i64) bool {
    assert(builtin.target.isDarwin());

    const NSProcessInfo = objc.getClass("NSProcessInfo").?;
    const info = NSProcessInfo.msgSend(objc.Object, objc.sel("processInfo"), .{});
    return info.msgSend(bool, objc.sel("isOperatingSystemAtLeastVersion:"), .{
        NSOperatingSystemVersion{ .major = major, .minor = minor, .patch = patch },
    });
}

pub const NSOperatingSystemVersion = extern struct {
    major: i64,
    minor: i64,
    patch: i64,
};
