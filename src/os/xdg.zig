//! Implementation of the XDG Base Directory specification
//! (https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html)

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const homedir = @import("homedir.zig");
const env_os = @import("env.zig");

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
pub fn config(alloc: Allocator, io: std.Io, env: *const std.process.Environ.Map, opts: Options) ![]u8 {
    return try dir(alloc, opts, io, env, .{
        .env = "XDG_CONFIG_HOME",
        .windows_env = "LOCALAPPDATA",
        .default_subdir = ".config",
    });
}

/// Get the XDG cache directory. The returned value is allocated.
pub fn cache(alloc: Allocator, io: std.Io, env: *const std.process.Environ.Map, opts: Options) ![]u8 {
    return try dir(alloc, opts, io, env, .{
        .env = "XDG_CACHE_HOME",
        .windows_env = "LOCALAPPDATA",
        .default_subdir = ".cache",
    });
}

/// Get the XDG state directory. The returned value is allocated.
pub fn state(alloc: Allocator, io: std.Io, env: *const std.process.Environ.Map, opts: Options) ![]u8 {
    return try dir(alloc, opts, io, env, .{
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
    io: std.Io,
    env: *const std.process.Environ.Map,
    internal_opts: InternalOptions,
) ![]u8 {
    // If we have a cached home dir, use that.
    if (opts.home) |home| {
        return try std.Io.Dir.path.join(alloc, &[_][]const u8{
            home,
            internal_opts.default_subdir,
            opts.subdir orelse "",
        });
    }

    // First check the env var. On Windows we have to allocate so this tracks
    // both whether we have the env var and whether we own it.
    // on Windows we treat `LOCALAPPDATA` as a fallback for `XDG_CONFIG_HOME`
    const env_var_ = v: {
        if (env.get(internal_opts.env)) |v| {
            if (v.len > 0) break :v v;
        }

        if (comptime builtin.os.tag != .windows) break :v null;

        if (env.get(internal_opts.windows_env)) |v| {
            if (v.len > 0) break :v v;
        }
        break :v null;
    };
    defer if (env_var_) |v| alloc.free(v);

    if (env_var_) |env_var| {
        // If we have a subdir, then we use the env as-is to avoid a copy.
        if (opts.subdir) |subdir| {
            return try std.Io.Dir.path.join(alloc, &.{
                env_var,
                subdir,
            });
        }

        return try alloc.dupe(u8, env_var);
    }

    // Get our home dir
    var buf: [1024]u8 = undefined;
    if (try homedir.home(io, env, &buf)) |home| {
        return try std.Io.Dir.path.join(alloc, &[_][]const u8{
            home,
            internal_opts.default_subdir,
            opts.subdir orelse "",
        });
    }

    return error.NoHomeDir;
}

/// Parses the xdg-terminal-exec specification. This expects argv[0] to
/// be "xdg-terminal-exec".
pub fn parseTerminalExec(argv: []const [*:0]const u8) ?[]const [*:0]const u8 {
    if (!std.mem.eql(
        u8,
        std.Io.Dir.path.basename(std.mem.sliceTo(argv[0], 0)),
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
    const mock_home = if (builtin.os.tag == .windows) "C:\\Users\\test" else "/Users/test";

    // Test when XDG_CACHE_HOME is not set
    {
        // Test base path
        {
            const cache_path = try cache(alloc, .{ .home = mock_home });
            defer alloc.free(cache_path);
            const expected = try std.Io.Dir.path.join(alloc, &.{ mock_home, ".cache" });
            defer alloc.free(expected);
            try testing.expectEqualStrings(expected, cache_path);
        }

        // Test with subdir
        {
            const cache_path = try cache(alloc, .{
                .home = mock_home,
                .subdir = "ghostty",
            });
            defer alloc.free(cache_path);
            const expected = try std.Io.Dir.path.join(alloc, &.{ mock_home, ".cache", "ghostty" });
            defer alloc.free(expected);
            try testing.expectEqualStrings(expected, cache_path);
        }
    }
}

test "fallback when xdg env empty" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;

    const saved_home = home: {
        const home = std.posix.getenv("HOME") orelse break :home null;
        break :home try alloc.dupeZ(u8, home);
    };
    defer env: {
        const home = saved_home orelse {
            _ = env_os.unsetenv("HOME");
            break :env;
        };
        _ = env_os.setenv("HOME", home);
        std.testing.allocator.free(home);
    }
    const temp_home = "/tmp/ghostty-test-home";
    _ = env_os.setenv("HOME", temp_home);

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

    inline for (cases) |case| {
        // Save and restore each environment variable
        const saved_env = blk: {
            const value = std.posix.getenv(case.name) orelse break :blk null;
            break :blk try alloc.dupeZ(u8, value);
        };
        defer env: {
            const value = saved_env orelse {
                _ = env_os.unsetenv(case.name);
                break :env;
            };
            _ = env_os.setenv(case.name, value);
            alloc.free(value);
        }

        const expected = try std.Io.Dir.path.join(alloc, &[_][]const u8{
            temp_home,
            case.default_subdir,
        });
        defer alloc.free(expected);

        // Test with empty string - should fallback to home
        _ = env_os.setenv(case.name, "");
        const actual = try case.func(alloc, .{});
        defer alloc.free(actual);

        try std.testing.expectEqualStrings(expected, actual);
    }
}

test "fallback when xdg env empty and subdir" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const env = @import("env.zig");
    const alloc = std.testing.allocator;

    const saved_home = home: {
        const home = std.posix.getenv("HOME") orelse break :home null;
        break :home try alloc.dupeZ(u8, home);
    };
    defer env: {
        const home = saved_home orelse {
            _ = env.unsetenv("HOME");
            break :env;
        };
        _ = env.setenv("HOME", home);
        std.testing.allocator.free(home);
    }

    const temp_home = "/tmp/ghostty-test-home";
    _ = env.setenv("HOME", temp_home);

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

    inline for (cases) |case| {
        // Save and restore each environment variable
        const saved_env = blk: {
            const value = std.posix.getenv(case.name) orelse break :blk null;
            break :blk try alloc.dupeZ(u8, value);
        };
        defer env: {
            const value = saved_env orelse {
                _ = env.unsetenv(case.name);
                break :env;
            };
            _ = env.setenv(case.name, value);
            alloc.free(value);
        }

        const expected = try std.Io.Dir.path.join(alloc, &[_][]const u8{
            temp_home,
            case.default_subdir,
            "ghostty",
        });
        defer alloc.free(expected);

        // Test with empty string - should fallback to home
        _ = env.setenv(case.name, "");
        const actual = try case.func(alloc, .{ .subdir = "ghostty" });
        defer alloc.free(actual);

        try std.testing.expectEqualStrings(expected, actual);
    }
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
