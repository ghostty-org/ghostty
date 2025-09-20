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

    // First check the env var. On Windows we have to allocate so this tracks
    // both whether we have the env var and whether we own it.
    // on Windows we treat `LOCALAPPDATA` as a fallback for `XDG_CONFIG_HOME`
    const env_, const owned = switch (builtin.os.tag) {
        else => .{ posix.getenv(internal_opts.env), false },
        .windows => windows: {
            if (std.process.getEnvVarOwned(alloc, internal_opts.env)) |env| {
                if (env.len == 0) {
                    alloc.free(env);
                } else {
                    break :windows .{ env, true };
                }
            } else |err| switch (err) {
                error.EnvironmentVariableNotFound => {},
                else => return err,
            };

            if (std.process.getEnvVarOwned(alloc, internal_opts.windows_env)) |env| {
                if (env.len == 0) {
                    alloc.free(env);
                    break :windows .{ null, false };
                }
                break :windows .{ env, true };
            } else |err| switch (err) {
                error.EnvironmentVariableNotFound => break :windows .{ null, false },
                else => return err,
            };
        },
    };
    defer if (owned) if (env_) |v| alloc.free(v);

    if (env_) |env| {
        if (env.len == 0) {
            // Treat empty environment variables the same as if they were unset.
            // Owned allocations are freed by the deferred cleanup above.
        } else {
            // If we have a subdir, then we use the env as-is to avoid a copy.
            if (opts.subdir) |subdir| {
                return try std.fs.path.join(alloc, &[_][]const u8{
                    env,
                    subdir,
                });
            }

            return try alloc.dupe(u8, env);
        }
    }

    // Get our home dir
    var buf: [1024]u8 = undefined;
    if (try homedir.home(&buf)) |home| {
        return try std.fs.path.join(alloc, &[_][]const u8{
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
    const posix = std.posix;

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
        {
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

            _ = env_os.setenv(case.name, "");

            const result = try case.func(alloc, .{});
            defer alloc.free(result);

            const expected = try std.fs.path.join(alloc, &[_][]const u8{
                temp_home,
                case.default_subdir,
                "",
            });
            defer alloc.free(expected);

            try testing.expectEqualStrings(expected, result);
        }
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
