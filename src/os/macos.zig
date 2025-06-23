const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const assert = std.debug.assert;
const objc = @import("objc");
const Allocator = std.mem.Allocator;

/// Verifies that the running macOS system version is at least the given version.
pub fn isAtLeastVersion(major: i64, minor: i64, patch: i64) bool {
    comptime assert(builtin.target.os.tag.isDarwin());

    const NSProcessInfo = objc.getClass("NSProcessInfo").?;
    const info = NSProcessInfo.msgSend(objc.Object, objc.sel("processInfo"), .{});
    return info.msgSend(bool, objc.sel("isOperatingSystemAtLeastVersion:"), .{
        NSOperatingSystemVersion{ .major = major, .minor = minor, .patch = patch },
    });
}

pub const AppSupportDirError = Allocator.Error || error{AppleAPIFailed};

/// Return the path to the application support directory for Ghostty
/// with the given sub path joined. This allocates the result using the
/// given allocator.
pub fn appSupportDir(
    alloc: Allocator,
    sub_path: []const u8,
) AppSupportDirError![]const u8 {
    return try commonDir(
        alloc,
        .NSApplicationSupportDirectory,
        &.{ build_config.bundle_id, sub_path },
    );
}

pub const CacheDirError = Allocator.Error || error{AppleAPIFailed};

/// Return the path to the system cache directory with the given sub path joined.
/// This allocates the result using the given allocator.
pub fn cacheDir(
    alloc: Allocator,
    sub_path: []const u8,
) CacheDirError![]const u8 {
    return try commonDir(
        alloc,
        .NSCachesDirectory,
        &.{ build_config.bundle_id, sub_path },
    );
}

pub const SetQosClassError = error{
    // The thread can't have its QoS class changed usually because
    // a different pthread API was called that makes it an invalid
    // target.
    ThreadIncompatible,
};

/// Set the QoS class of the running thread.
///
/// https://developer.apple.com/documentation/apple-silicon/tuning-your-code-s-performance-for-apple-silicon?preferredLanguage=occ
pub fn setQosClass(class: QosClass) !void {
    return switch (std.posix.errno(pthread_set_qos_class_self_np(
        class,
        0,
    ))) {
        .SUCCESS => {},
        .PERM => error.ThreadIncompatible,

        // EPERM is the only known error that can happen based on
        // the man pages for pthread_set_qos_class_self_np. I haven't
        // checked the XNU source code to see if there are other
        // possible errors.
        else => @panic("unexpected pthread_set_qos_class_self_np error"),
    };
}

/// https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/PrioritizeWorkAtTheTaskLevel.html#//apple_ref/doc/uid/TP40013929-CH35-SW1
pub const QosClass = enum(c_uint) {
    user_interactive = 0x21,
    user_initiated = 0x19,
    default = 0x15,
    utility = 0x11,
    background = 0x09,
    unspecified = 0x00,
};

extern "c" fn pthread_set_qos_class_self_np(
    qos_class: QosClass,
    relative_priority: c_int,
) c_int;

pub extern "c" fn pthread_setname_np(
    name: [*:0]const u8,
) void;

pub const NSOperatingSystemVersion = extern struct {
    major: i64,
    minor: i64,
    patch: i64,
};

pub const NSSearchPathDirectory = enum(c_ulong) {
    NSCachesDirectory = 13,
    NSApplicationSupportDirectory = 14,
};

pub const NSSearchPathDomainMask = enum(c_ulong) {
    NSUserDomainMask = 1,
};

fn commonDir(
    alloc: Allocator,
    directory: NSSearchPathDirectory,
    sub_paths: []const []const u8,
) (error{AppleAPIFailed} || Allocator.Error)![]const u8 {
    comptime assert(builtin.target.os.tag.isDarwin());

    const NSFileManager = objc.getClass("NSFileManager").?;
    const manager = NSFileManager.msgSend(
        objc.Object,
        objc.sel("defaultManager"),
        .{},
    );

    const url = manager.msgSend(
        objc.Object,
        objc.sel("URLForDirectory:inDomain:appropriateForURL:create:error:"),
        .{
            directory,
            NSSearchPathDomainMask.NSUserDomainMask,
            @as(?*anyopaque, null),
            true,
            @as(?*anyopaque, null),
        },
    );

    if (url.value == null) return error.AppleAPIFailed;

    const path = url.getProperty(objc.Object, "path");
    const c_str = path.getProperty(?[*:0]const u8, "UTF8String") orelse
        return error.AppleAPIFailed;
    const base_dir = std.mem.sliceTo(c_str, 0);

    // Create a new array with base_dir as the first element
    var paths = try alloc.alloc([]const u8, sub_paths.len + 1);
    paths[0] = base_dir;
    @memcpy(paths[1..], sub_paths);
    defer alloc.free(paths);

    return try std.fs.path.join(alloc, paths);
}

test "cacheDir paths" {
    if (!builtin.target.os.tag.isDarwin()) return;

    const testing = std.testing;
    const alloc = testing.allocator;

    // Test base path
    {
        const cache_path = try cacheDir(alloc, "");
        defer alloc.free(cache_path);
        try testing.expect(std.mem.indexOf(u8, cache_path, "Caches") != null);
        try testing.expect(std.mem.indexOf(u8, cache_path, build_config.bundle_id) != null);
    }

    // Test with subdir
    {
        const cache_path = try cacheDir(alloc, "test");
        defer alloc.free(cache_path);
        try testing.expect(std.mem.indexOf(u8, cache_path, "Caches") != null);
        try testing.expect(std.mem.indexOf(u8, cache_path, build_config.bundle_id) != null);

        const bundle_path = try std.fmt.allocPrint(alloc, "{s}/test", .{build_config.bundle_id});
        defer alloc.free(bundle_path);
        try testing.expect(std.mem.indexOf(u8, cache_path, bundle_path) != null);
    }
}
