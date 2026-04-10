const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const isFlatpak = @import("flatpak.zig").isFlatpak;

pub const Error = Allocator.Error;

/// Get the environment map.
pub fn getEnvMap(alloc: Allocator, env: std.process.Environ) !std.process.Environ.Map {
    return if (isFlatpak()) .init(alloc) else env.createMap(alloc);
}

/// Append a value to an environment variable such as PATH.
/// The returned value is always allocated so it must be freed.
pub fn appendEnv(
    alloc: Allocator,
    current: []const u8,
    value: []const u8,
) Error![]u8 {
    // If there is no prior value, we return it as-is
    if (current.len == 0) return try alloc.dupe(u8, value);

    // Otherwise we must prefix.
    return try appendEnvAlways(alloc, current, value);
}

/// Always append value to environment, even when it is empty.
/// This is useful because some env vars (like MANPATH) want there
/// to be an empty prefix to preserve existing values.
///
/// The returned value is always allocated so it must be freed.
pub fn appendEnvAlways(
    alloc: Allocator,
    current: []const u8,
    value: []const u8,
) Error![]u8 {
    return try std.fmt.allocPrint(alloc, "{s}{c}{s}", .{
        current,
        std.fs.path.delimiter,
        value,
    });
}

/// Prepend a value to an environment variable such as PATH.
/// The returned value is always allocated so it must be freed.
pub fn prependEnv(
    alloc: Allocator,
    current: []const u8,
    value: []const u8,
) Error![]u8 {
    // If there is no prior value, we return it as-is
    if (current.len == 0) return try alloc.dupe(u8, value);

    return try std.fmt.allocPrint(alloc, "{s}{c}{s}", .{
        value,
        std.fs.path.delimiter,
        current,
    });
}

test "appendEnv empty" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = try appendEnv(alloc, "", "foo");
    defer alloc.free(result);
    try testing.expectEqualStrings(result, "foo");
}

test "appendEnv existing" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = try appendEnv(alloc, "a:b", "foo");
    defer alloc.free(result);
    if (builtin.os.tag == .windows) {
        try testing.expectEqualStrings(result, "a:b;foo");
    } else {
        try testing.expectEqualStrings(result, "a:b:foo");
    }
}

test "prependEnv empty" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = try prependEnv(alloc, "", "foo");
    defer alloc.free(result);
    try testing.expectEqualStrings(result, "foo");
}

test "prependEnv existing" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = try prependEnv(alloc, "a:b", "foo");
    defer alloc.free(result);
    if (builtin.os.tag == .windows) {
        try testing.expectEqualStrings(result, "foo;a:b");
    } else {
        try testing.expectEqualStrings(result, "foo:a:b");
    }
}
