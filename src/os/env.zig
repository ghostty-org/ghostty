const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const isFlatpak = @import("flatpak.zig").isFlatpak;
const global = @import("../global.zig");

pub const Error = Allocator.Error;

/// Get the environment map.
pub fn getEnvMap(alloc: Allocator) Error!std.process.EnvMap {
    var new: std.process.EnvMap = .init(alloc);
    var it = global.state.environ_map.iterator();
    while (it.next()) |kv| {
        try new.put(kv.key_ptr.*, kv.value_ptr.*);
    }
    return new;
}

/// This is basically a clone of `std.process.EnvironMap.Map.createPosixBlock`
/// from Zig 0.16. This can be removed once Ghostty is ported to Zig 0.16.
pub fn createPosixBlock(alloc: Allocator) Error![:null]?[*:0]u8 {
    var blk = try alloc.allocSentinel(?[*:0]u8, global.state.environ_map.count(), null);
    var i: usize = 0;
    errdefer {
        for (0..i) |j| alloc.free(std.mem.span(blk[j].?));
        alloc.free(blk);
    }
    var it = global.state.environ_map.iterator();
    while (it.next()) |kv| : (i += 1) {
        blk[i] = try std.fmt.allocPrintSentinel(
            alloc,
            "{s}={s}",
            .{ kv.key_ptr.*, kv.value_ptr.* },
            0,
        );
    }
    return blk;
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

/// Gets the value of an environment variable, or null if not found.
/// The returned value should not be modified or freed.
pub fn getenv(key: []const u8) ?[]const u8 {
    return global.state.environ_map.get(key);
}

/// Gets the value of an environment variable, or null if not found.
/// The returned value is owned by the caller and must be freed.
pub fn getenvOwned(alloc: Allocator, key: []const u8) Error!?[]const u8 {
    return try alloc.dupe(u8, global.state.environ_map.get(key) orelse return null);
}

/// Gets the value of an environment variable. Returns null if not found or the
/// value is empty. The returned value should not be freed or modified.
pub fn getenvNotEmpty(key: []const u8) ?[]const u8 {
    const result = global.state.environ_map.get(key) orelse return null;
    if (result.len == 0) return null;
    return result;
}

pub fn setenv(key: []const u8, value: []const u8) c_int {
    const keyZ = global.state.alloc.dupeZ(u8, key) catch return -1;
    defer global.state.alloc.free(keyZ);

    const valueZ = global.state.alloc.dupeZ(u8, value) catch return -1;
    defer global.state.alloc.free(valueZ);

    global.state.environ_map.put(key, value) catch return -1;

    return switch (builtin.os.tag) {
        .windows => c._putenv_s(keyZ.ptr, valueZ.ptr),
        else => c.setenv(keyZ.ptr, valueZ.ptr, 1),
    };
}

pub fn unsetenv(key: []const u8) c_int {
    const keyZ = global.state.alloc.dupeZ(u8, key) catch return -1;
    defer global.state.alloc.free(keyZ);

    return switch (builtin.os.tag) {
        .windows => c._putenv_s(keyZ.ptr, ""),
        else => c.unsetenv(keyZ.ptr),
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
