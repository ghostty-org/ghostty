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
                break :windows .{ env, true };
            } else |err| switch (err) {
                error.EnvironmentVariableNotFound => {
                    if (std.process.getEnvVarOwned(alloc, internal_opts.windows_env)) |env| {
                        break :windows .{ env, true };
                    } else |err2| switch (err2) {
                        error.EnvironmentVariableNotFound => break :windows .{ null, false },
                        else => return err,
                    }
                },
                else => return err,
            }
        },
    };
    defer if (owned) if (env_) |v| alloc.free(v);

    if (env_) |env| {
        // If we have a subdir, then we use the env as-is to avoid a copy.
        if (opts.subdir) |subdir| {
            return try std.fs.path.join(alloc, &[_][]const u8{
                env,
                subdir,
            });
        }

        return try alloc.dupe(u8, env);
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

/// https://specifications.freedesktop.org/basedir-spec/latest/
pub const Dir = enum {
    config,
    data,

    pub fn key(self: Dir) [:0]const u8 {
        return switch (self) {
            .config => "XDG_CONFIG_DIRS",
            .data => "XDG_DATA_DIRS",
        };
    }

    pub fn default(self: Dir) [:0]const u8 {
        return switch (self) {
            .config => "/etc/xdg",
            .data => "/usr/local/share:/usr/share",
        };
    }
};

pub const DirIterator = struct {
    data: []const u8,
    iterator: std.mem.SplitIterator(u8, .scalar),

    /// https://specifications.freedesktop.org/basedir-spec/latest/
    pub fn init(key: Dir) DirIterator {
        const data = data: {
            if (posix.getenv(key.key())) |data| {
                if (std.mem.trim(u8, data, &std.ascii.whitespace).len > 0) break :data data;
            }

            break :data key.default();
        };

        return .{
            .data = data,
            .iterator = std.mem.splitScalar(u8, data, ':'),
        };
    }

    pub fn next(self: *DirIterator) ?[]const u8 {
        return self.iterator.next();
    }
};

test "xdg dirs" {
    const c = @cImport({
        @cInclude("stdlib.h");
    });

    const testing = std.testing;
    {
        _ = c.unsetenv(Dir.config.key());
        var it = DirIterator.init(.config);
        try testing.expectEqualStrings("/etc/xdg", it.next().?);
        try testing.expect(it.next() == null);
    }
    {
        _ = c.unsetenv(Dir.data.key());
        var it = DirIterator.init(.data);
        try testing.expectEqualStrings("/usr/local/share", it.next().?);
        try testing.expectEqualStrings("/usr/share", it.next().?);
        try testing.expect(it.next() == null);
    }
    {
        _ = c.setenv(Dir.config.key(), "a:b:c", 1);
        var it = DirIterator.init(.config);
        try testing.expectEqualStrings("a", it.next().?);
        try testing.expectEqualStrings("b", it.next().?);
        try testing.expectEqualStrings("c", it.next().?);
        try testing.expect(it.next() == null);
    }
}
