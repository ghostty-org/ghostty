const std = @import("std");
const builtin = @import("builtin");
const global_state = &@import("../global.zig").state;
const Allocator = std.mem.Allocator;
const posix = std.posix;
const isFlatpak = @import("flatpak.zig").isFlatpak;

pub const Error = Allocator.Error;

/// Create the environment map for a new surface.
pub fn getSurfaceEnvMap(
    alloc: Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
) !std.process.Environ.Map {
    return if (isFlatpak(io))
        .init(alloc)
    else
        env.clone(alloc);
}

/// Create an environment map from to the current libc `std.c.environ` variable.
///
/// This should only be used in the C API. Zig code should always accept an
/// environment map as a parameter. Returns an empty map if reading from
/// `std.c.environ` fails.
pub fn getEnvMapC(alloc: Allocator) std.process.Environ.Map {
    var env: std.process.Environ.Map = .init(alloc);
    const posix_block: std.process.Environ.PosixBlock = .{
        .slice = std.mem.sliceTo(std.c.environ, null),
    };
    env.putPosixBlock(posix_block.view()) catch {};
    return env;
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
        std.Io.Dir.path.delimiter,
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
        std.Io.Dir.path.delimiter,
        current,
    });
}

pub fn setenv(key: [:0]const u8, value: [:0]const u8) c_int {
    return switch (builtin.os.tag) {
        .windows => c._putenv_s(key.ptr, value.ptr),
        else => c.setenv(key.ptr, value.ptr, 1),
    };
}

pub fn unsetenv(key: [:0]const u8) c_int {
    return switch (builtin.os.tag) {
        .windows => c._putenv_s(key.ptr, ""),
        else => c.unsetenv(key.ptr),
    };
}

const c = struct {
    // POSIX
    extern "c" fn setenv(name: ?[*]const u8, value: ?[*]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: ?[*]const u8) c_int;

    // Windows
    extern "c" fn _putenv_s(varname: ?[*]const u8, value_string: ?[*]const u8) c_int;
};

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
