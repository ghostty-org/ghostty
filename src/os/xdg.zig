//! Implementation of the XDG Base Directory specification
//! (https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html)

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const posix = std.posix;
const homedir = @import("homedir.zig");

pub const Options = struct {
    /// Subdirectories to join to the base. This avoids extra allocations
    /// when building up the directory. This is commonly the application.
    subdir: ?[]const u8 = null,

    /// The home directory for the user. If this is not set, we will attempt
    /// to look it up which is an expensive process. By setting this, you can
    /// avoid lookups.
    home: ?[]const u8 = null,
};

/// Get the XDG user config directory. The returned value is allocated.
pub fn config(alloc: Allocator, opts: Options) ![]u8 {
    return try dir(alloc, opts, .{
        .env = "XDG_CONFIG_HOME",
        .windows_env = "LOCALAPPDATA",
        .default_subdir = ".config",
    });
}

/// Get the XDG cache directory. The returned value is allocated.
pub fn cache(alloc: Allocator, opts: Options) ![]u8 {
    return try dir(alloc, opts, .{
        .env = "XDG_CACHE_HOME",
        .windows_env = "LOCALAPPDATA",
        .default_subdir = ".cache",
    });
}

/// Get the XDG state directory. The returned value is allocated.
pub fn state(alloc: Allocator, opts: Options) ![]u8 {
    return try dir(alloc, opts, .{
        .env = "XDG_STATE_HOME",
        .windows_env = "LOCALAPPDATA",
        .default_subdir = ".local/state",
    });
}

const InternalOptions = struct {
    env: []const u8,
    windows_env: []const u8,
    default_subdir: []const u8,
};

/// Unified helper to get XDG directories that follow a common pattern.
fn dir(
    alloc: Allocator,
    opts: Options,
    internal_opts: InternalOptions,
) ![]u8 {
    // If we have a cached home dir, use that.
    if (opts.home) |home| {
        return try std.fs.path.join(alloc, &[_][]const u8{
            home,
            internal_opts.default_subdir,
            opts.subdir orelse "",
        });
    }

    // Try to get environment variable value
    const env_result = getEnvVar(alloc, internal_opts);
    defer env_result.deinit(alloc);

    if (env_result.value) |env| {
        // Only use non-empty environment variables
        if (env.len > 0) {
            if (opts.subdir) |subdir| {
                return try std.fs.path.join(alloc, &[_][]const u8{ env, subdir });
            }
            return try alloc.dupe(u8, env);
        }
        // Empty env var falls through to home directory fallback
    }

    // Fallback to home directory
    return getHomeDirPath(alloc, internal_opts, opts.subdir);
}

const EnvResult = struct {
    value: ?[]const u8,
    owned: bool,

    fn deinit(self: EnvResult, alloc: Allocator) void {
        if (self.owned and self.value != null) {
            alloc.free(self.value.?);
        }
    }
};

/// Get environment variable value with proper memory ownership tracking.
/// On Windows, tries primary env var first, then falls back to windows_env.
fn getEnvVar(alloc: Allocator, internal_opts: InternalOptions) EnvResult {
    switch (builtin.os.tag) {
        .windows => return getWindowsEnvVar(alloc, internal_opts),
        else => return .{
            .value = posix.getenv(internal_opts.env),
            .owned = false
        },
    }
}

fn getWindowsEnvVar(alloc: Allocator, internal_opts: InternalOptions) EnvResult {
    // Try primary environment variable first
    if (std.process.getEnvVarOwned(alloc, internal_opts.env)) |env| {
        return .{ .value = env, .owned = true };
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        // Treat other errors (like OutOfMemory) as if env var doesn't exist
        else => return .{ .value = null, .owned = false },
    }

    // Try Windows fallback environment variable (LOCALAPPDATA)
    if (std.process.getEnvVarOwned(alloc, internal_opts.windows_env)) |env| {
        return .{ .value = env, .owned = true };
    } else |_| {
        return .{ .value = null, .owned = false };
    }
}

/// Build path using home directory and default subdirectory.
fn getHomeDirPath(alloc: Allocator, internal_opts: InternalOptions, subdir: ?[]const u8) ![]u8 {
    var buf: [1024]u8 = undefined;
    if (try homedir.home(&buf)) |home| {
        return try std.fs.path.join(alloc, &[_][]const u8{
            home,
            internal_opts.default_subdir,
            subdir orelse "",
        });
    }
    return error.NoHomeDir;
}

/// Parses the xdg-terminal-exec specification. This expects argv[0] to
/// be "xdg-terminal-exec".
pub fn parseTerminalExec(argv: []const [*:0]const u8) ?[]const [*:0]const u8 {
    if (!std.mem.eql(
        u8,
        std.fs.path.basename(std.mem.sliceTo(argv[0], 0)),
        "xdg-terminal-exec",
    )) return null;

    // We expect at least one argument
    if (argv.len < 2) return &.{};

    // If the first argument is "-e" we skip it.
    const start: usize = if (std.mem.eql(u8, std.mem.sliceTo(argv[1], 0), "-e")) 2 else 1;
    return argv[start..];
}

test {
    const testing = std.testing;
    const alloc = testing.allocator;

    {
        const value = try config(alloc, .{});
        defer alloc.free(value);
        try testing.expect(value.len > 0);
    }
}

test "cache directory paths" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const mock_home = "/Users/test";

    // Test when XDG_CACHE_HOME is not set
    {
        // Test base path
        {
            const cache_path = try cache(alloc, .{ .home = mock_home });
            defer alloc.free(cache_path);
            try testing.expectEqualStrings("/Users/test/.cache", cache_path);
        }

        // Test with subdir
        {
            const cache_path = try cache(alloc, .{
                .home = mock_home,
                .subdir = "ghostty",
            });
            defer alloc.free(cache_path);
            try testing.expectEqualStrings("/Users/test/.cache/ghostty", cache_path);
        }
    }
}

test "xdg directories fallback to home when env empty" {
    if (builtin.os.tag == .windows) return;

    const testing = std.testing;
    const alloc = testing.allocator;
    const env_os = @import("env.zig");

    // Save original HOME to restore after test
    const saved_home = blk: {
        if (posix.getenv("HOME")) |value| {
            break :blk try alloc.dupeZ(u8, value);
        }
        break :blk null;
    };
    defer {
        if (saved_home) |value| {
            _ = env_os.setenv("HOME", value);
            alloc.free(value);
        } else {
            _ = env_os.unsetenv("HOME");
        }
    };

    // Set up a controlled HOME directory for testing
    const temp_home_z: [:0]const u8 = "/tmp/ghostty-test-home";
    const temp_home = std.mem.span(temp_home_z);
    _ = env_os.setenv("HOME", temp_home_z);

    const DirCase = struct {
        name: [:0]const u8,
        func: fn (Allocator, Options) anyerror![]u8,
        default_subdir: []const u8,
    };

    const cases = [_]DirCase{
        .{ .name = "XDG_CONFIG_HOME", .func = config, .default_subdir = ".config" },
        .{ .name = "XDG_CACHE_HOME", .func = cache, .default_subdir = ".cache" },
        .{ .name = "XDG_STATE_HOME", .func = state, .default_subdir = ".local/state" },
    };

    for (cases) |case| {
    // Save and restore each environment variable
        const saved_env = blk: {
            if (posix.getenv(case.name)) |value| {
                break :blk try alloc.dupeZ(u8, value);
            }
            break :blk null;
    };
    defer {
        if (saved_env) |value| {
            _ = env_os.setenv(case.name, value);
            alloc.free(value);
        } else {
            _ = env_os.unsetenv(case.name);
        }
    };

    // Test with empty string - should fallback to home
    _ = env_os.setenv(case.name, "");

    const result = try case.func(alloc, .{});
    defer alloc.free(result);

    const expected = try std.fs.path.join(alloc, &[_][]const u8{
        temp_home,
        case.default_subdir,
    });
    defer alloc.free(expected);

    try testing.expectEqualStrings(expected, result);
    }
}

// Test with subdirectories when environment variables are empty
test "xdg directories with subdir when env empty" {
    if (builtin.os.tag == .windows) return;

    const testing = std.testing;
    const alloc = testing.allocator;
    const env_os = @import("env.zig");

    // Save original HOME
    const saved_home = blk: {
        if (posix.getenv("HOME")) |value| {
            break :blk try alloc.dupeZ(u8, value);
        }
        break :blk null;
    };
    defer {
        if (saved_home) |value| {
            _ = env_os.setenv("HOME", value);
            alloc.free(value);
        } else {
            _ = env_os.unsetenv("HOME");
        }
    };

    const temp_home = "/tmp/ghostty-test-home";
    _ = env_os.setenv("HOME", temp_home);

    // Save and clear XDG_CONFIG_HOME
    const saved_config = blk: {
        if (posix.getenv("XDG_CONFIG_HOME")) |value| {
            break :blk try alloc.dupeZ(u8, value);
        }
        break :blk null;
    };
    defer {
        if (saved_config) |value| {
            _ = env_os.setenv("XDG_CONFIG_HOME", value);
            alloc.free(value);
        } else {
            _ = env_os.unsetenv("XDG_CONFIG_HOME");
        }
    };

    // Test that empty env var with subdir falls back correctly
    _ = env_os.setenv("XDG_CONFIG_HOME", "");

    const result = try config(alloc, .{ .subdir = "myapp" });
    defer alloc.free(result);

    const expected = try std.fs.path.join(alloc, &[_][]const u8{
        temp_home,
        ".config",
        "myapp",
    });
    defer alloc.free(expected);

    try testing.expectEqualStrings(expected, result);
}

test parseTerminalExec {
    const testing = std.testing;

    {
        const actual = parseTerminalExec(&.{ "a", "b", "c" });
        try testing.expect(actual == null);
    }
    {
        const actual = parseTerminalExec(&.{"xdg-terminal-exec"}).?;
        try testing.expectEqualSlices([*:0]const u8, actual, &.{});
    }
    {
        const actual = parseTerminalExec(&.{ "xdg-terminal-exec", "a", "b", "c" }).?;
        try testing.expectEqualSlices([*:0]const u8, actual, &.{ "a", "b", "c" });
    }
    {
        const actual = parseTerminalExec(&.{ "xdg-terminal-exec", "-e", "a", "b", "c" }).?;
        try testing.expectEqualSlices([*:0]const u8, actual, &.{ "a", "b", "c" });
    }
    {
        const actual = parseTerminalExec(&.{ "xdg-terminal-exec", "a", "-e", "b", "c" }).?;
        try testing.expectEqualSlices([*:0]const u8, actual, &.{ "a", "-e", "b", "c" });
    }
}
