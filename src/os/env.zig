const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const isFlatpak = @import("flatpak.zig").isFlatpak;

pub const Error = Allocator.Error;

/// Get the environment map.
pub fn getEnvMap(alloc: Allocator) !std.process.EnvMap {
    return if (isFlatpak())
        std.process.EnvMap.init(alloc)
    else
        try std.process.getEnvMap(alloc);
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

/// The result of getenv, with a shared deinit to properly handle allocation
/// on Windows.
pub const GetEnvResult = struct {
    value: []const u8,

    pub fn deinit(self: GetEnvResult, alloc: Allocator) void {
        switch (builtin.os.tag) {
            .windows => alloc.free(self.value),
            else => {},
        }
    }
};

/// Gets the value of an environment variable, or null if not found.
/// This will allocate on Windows but not on other platforms. The returned
/// value should have deinit called to do the proper cleanup no matter what
/// platform you are on.
pub fn getenv(alloc: Allocator, key: []const u8) Error!?GetEnvResult {
    return switch (builtin.os.tag) {
        // Non-Windows doesn't need to allocate
        else => if (posix.getenv(key)) |v| .{ .value = v } else null,

        // Windows needs to allocate
        .windows => if (std.process.getEnvVarOwned(alloc, key)) |v| .{
            .value = v,
        } else |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            error.InvalidWtf8 => null,
            else => |e| e,
        },
    };
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
