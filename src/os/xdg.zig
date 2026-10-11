//! Implementation of the XDG Base Directory specification
//! (https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html)

const std = @import("std");
const builtin = @import("builtin");
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

/// Iterates over XDG_CONFIG_DIRS from lowest to highest priority, so callers
/// can load each configuration and let the more important directories win.
/// Returned paths borrow from the input value. Empty and relative entries
/// are ignored; an unset or empty value defaults to /etc/xdg. Duplicate
/// entries are visited only at their highest-priority position.
pub const ConfigDirsIterator = struct {
    inner: std.mem.SplitBackwardsIterator(u8, .scalar),

    pub fn init(value: ?[]const u8) ConfigDirsIterator {
        const dirs = value orelse "";
        return .{ .inner = std.mem.splitBackwardsScalar(
            u8,
            if (dirs.len > 0) dirs else "/etc/xdg",
            ':',
        ) };
    }

    pub fn next(self: *ConfigDirsIterator) ?[]const u8 {
        paths: while (self.inner.next()) |dir_path| {
            if (dir_path.len == 0 or !std.fs.path.isAbsolute(dir_path)) continue;

            // A matching entry earlier in the list has higher priority.
            var remaining = std.mem.splitScalar(u8, self.inner.rest(), ':');
            while (remaining.next()) |other| {
                if (std.mem.eql(u8, dir_path, other)) continue :paths;
            }
            return dir_path;
        }
        return null;
    }
};

test "xdg config directories" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const testing = std.testing;
    const Case = struct {
        value: ?[]const u8,
        expected: []const []const u8,
    };
    const cases = [_]Case{
        .{ .value = null, .expected = &.{"/etc/xdg"} },
        .{ .value = "", .expected = &.{"/etc/xdg"} },
        .{ .value = "/first:/second:/last", .expected = &.{ "/last", "/second", "/first" } },
        .{ .value = ":/first::relative:./relative:/last:", .expected = &.{ "/last", "/first" } },
        .{ .value = "/first:/second:/first", .expected = &.{ "/second", "/first" } },
        .{ .value = "/first:/first", .expected = &.{"/first"} },
        .{ .value = ":::", .expected = &.{} },
        .{ .value = "relative", .expected = &.{} },
    };
    for (cases) |case| {
        var it = ConfigDirsIterator.init(case.value);
        for (case.expected) |expected| {
            try testing.expectEqualStrings(expected, it.next().?);
        }
        try testing.expect(it.next() == null);
        try testing.expect(it.next() == null);
    }
}

/// Get the XDG user config directory. The returned value is allocated.
pub fn config(io: std.Io, alloc: Allocator, environ_map: *const std.process.Environ.Map, opts: Options) ![]u8 {
    return try dir(io, alloc, environ_map, opts, .{
        .env = "XDG_CONFIG_HOME",
        .windows_env = "LOCALAPPDATA",
        .default_subdir = ".config",
    });
}

/// Get the XDG cache directory. The returned value is allocated.
pub fn cache(io: std.Io, alloc: Allocator, environ_map: *const std.process.Environ.Map, opts: Options) ![]u8 {
    return try dir(io, alloc, environ_map, opts, .{
        .env = "XDG_CACHE_HOME",
        .windows_env = "LOCALAPPDATA",
        .default_subdir = ".cache",
    });
}

/// Get the XDG state directory. The returned value is allocated.
pub fn state(io: std.Io, alloc: Allocator, environ_map: *const std.process.Environ.Map, opts: Options) ![]u8 {
    return try dir(io, alloc, environ_map, opts, .{
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
    io: std.Io,
    alloc: Allocator,
    environ_map: *const std.process.Environ.Map,
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

    // First check the env var. On Windows we treat `LOCALAPPDATA` as a
    // fallback for `XDG_CONFIG_HOME`
    const env = switch (builtin.os.tag) {
        .windows => environ_map.get(internal_opts.env) orelse environ_map.get(internal_opts.windows_env) orelse "",
        else => environ_map.get(internal_opts.env) orelse "",
    };

    if (env.len > 0) {
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
    if (try homedir.home(io, environ_map, &buf)) |home| {
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
    const io = testing.io;
    const alloc = testing.allocator;
    var environ_map = try testing.environ.createMap(alloc);
    defer environ_map.deinit();

    {
        const value = try config(io, alloc, &environ_map, .{});
        defer alloc.free(value);
        try testing.expect(value.len > 0);
    }
}

test "cache directory paths" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    const mock_home = if (builtin.os.tag == .windows) "C:\\Users\\test" else "/Users/test";
    var environ_map = try testing.environ.createMap(alloc);
    defer environ_map.deinit();

    // Test when XDG_CACHE_HOME is not set
    {
        // Test base path
        {
            const cache_path = try cache(io, alloc, &environ_map, .{ .home = mock_home });
            defer alloc.free(cache_path);
            const expected = try std.fs.path.join(alloc, &.{ mock_home, ".cache" });
            defer alloc.free(expected);
            try testing.expectEqualStrings(expected, cache_path);
        }

        // Test with subdir
        {
            const cache_path = try cache(io, alloc, &environ_map, .{
                .home = mock_home,
                .subdir = "ghostty",
            });
            defer alloc.free(cache_path);
            const expected = try std.fs.path.join(alloc, &.{ mock_home, ".cache", "ghostty" });
            defer alloc.free(expected);
            try testing.expectEqualStrings(expected, cache_path);
        }
    }
}

test "fallback when xdg env empty" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const io = std.testing.io;
    const alloc = std.testing.allocator;

    const DirCase = struct {
        name: [:0]const u8,
        func: fn (std.Io, Allocator, *std.process.Environ.Map, Options) anyerror![]u8,
        default_subdir: []const u8,
    };

    const cases = [_]DirCase{
        .{ .name = "XDG_CONFIG_HOME", .func = config, .default_subdir = ".config" },
        .{ .name = "XDG_CACHE_HOME", .func = cache, .default_subdir = ".cache" },
        .{ .name = "XDG_STATE_HOME", .func = state, .default_subdir = ".local/state" },
    };

    inline for (cases) |case| {
        var environ_map = try std.testing.environ.createMap(alloc);
        defer environ_map.deinit();
        const temp_home = "/tmp/ghostty-test-home";
        try environ_map.put("HOME", temp_home);

        const expected = try std.fs.path.join(alloc, &[_][]const u8{
            temp_home,
            case.default_subdir,
        });
        defer alloc.free(expected);

        // Test with empty string - should fallback to home
        try environ_map.put(case.name, "");
        const actual = try case.func(io, alloc, &environ_map, .{});
        defer alloc.free(actual);

        try std.testing.expectEqualStrings(expected, actual);
    }
}

test "fallback when xdg env empty and subdir" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const io = std.testing.io;
    const alloc = std.testing.allocator;

    const DirCase = struct {
        name: [:0]const u8,
        func: fn (std.Io, Allocator, *const std.process.Environ.Map, Options) anyerror![]u8,
        default_subdir: []const u8,
    };

    const cases = [_]DirCase{
        .{ .name = "XDG_CONFIG_HOME", .func = config, .default_subdir = ".config" },
        .{ .name = "XDG_CACHE_HOME", .func = cache, .default_subdir = ".cache" },
        .{ .name = "XDG_STATE_HOME", .func = state, .default_subdir = ".local/state" },
    };

    inline for (cases) |case| {
        var environ_map = try std.testing.environ.createMap(alloc);
        defer environ_map.deinit();
        const temp_home = "/tmp/ghostty-test-home";
        try environ_map.put("HOME", temp_home);

        const expected = try std.fs.path.join(alloc, &[_][]const u8{
            temp_home,
            case.default_subdir,
            "ghostty",
        });
        defer alloc.free(expected);

        // Test with empty string - should fallback to home
        try environ_map.put(case.name, "");
        const actual = try case.func(io, alloc, &environ_map, .{ .subdir = "ghostty" });
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
