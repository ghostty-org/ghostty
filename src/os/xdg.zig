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

const InternalOptions = struct {
    env: []const u8,
    // FIXME: Windows is an unsupported target, but does libghostty-vt touch xdg.zig?
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
    const env_ = try env_os.getenvNotEmpty(alloc, internal_opts.env) orelse switch (builtin.os.tag) {
        else => null,
        .windows => try env_os.getenvNotEmpty(alloc, internal_opts.windows_env),
    };
    defer if (env_) |env| env.deinit(alloc);

    if (env_) |env| {
        // If we have a subdir, then we use the env as-is to avoid a copy.
        if (opts.subdir) |subdir| {
            return try std.fs.path.join(alloc, &[_][]const u8{
                env.value,
                subdir,
            });
        }

        return try alloc.dupe(u8, env.value);
    }

    // Get our home dir
    var buf: [std.c.PATH_MAX]u8 = undefined;
    if (try homedir.home(&buf)) |home| {
        return try std.fs.path.join(alloc, &[_][]const u8{
            home,
            internal_opts.default_subdir,
            opts.subdir orelse "",
        });
    }

    return error.NoHomeDir;
}

/// XDG user directories for program config, data, cache, or, state
pub const UserDir = enum {
    config,
    data,
    cache,
    state,

    pub fn path(
        self: UserDir,
        alloc: Allocator,
        opts: Options,
    ) ![]u8 {
        const internal_opts: InternalOptions = switch (self) {
            .config => .{
                .env = "XDG_CONFIG_HOME",
                .windows_env = "LOCALAPPDATA",
                .default_subdir = ".config",
            },
            .data => .{
                .env = "XDG_DATA_HOME",
                .windows_env = "LOCALAPPDATA",
                .default_subdir = ".local/share",
            },
            .cache => .{
                .env = "XDG_CACHE_HOME",
                .windows_env = "LOCALAPPDATA",
                .default_subdir = ".cache",
            },
            .state => .{
                .env = "XDG_STATE_HOME",
                .windows_env = "LOCALAPPDATA",
                .default_subdir = ".local/state",
            },
        };
        return dir(alloc, opts, internal_opts);
    }
};
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
        const value = try UserDir.config.path(alloc, .{});
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
            const cache_path = try UserDir.cache.path(alloc, .{ .home = mock_home });
            defer alloc.free(cache_path);
            const expected = try std.fs.path.join(alloc, &.{ mock_home, ".cache" });
            defer alloc.free(expected);
            try testing.expectEqualStrings(expected, cache_path);
        }

        // Test with subdir
        {
            const cache_path = try UserDir.cache.path(alloc, .{
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
        dir_type: UserDir,
        default_subdir: []const u8,
    };

    const cases = [_]DirCase{
        .{ .name = "XDG_CONFIG_HOME", .dir_type = UserDir.config, .default_subdir = ".config" },
        .{ .name = "XDG_CACHE_HOME", .dir_type = UserDir.cache, .default_subdir = ".cache" },
        .{ .name = "XDG_STATE_HOME", .dir_type = UserDir.state, .default_subdir = ".local/state" },
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

        const expected = try std.fs.path.join(alloc, &[_][]const u8{
            temp_home,
            case.default_subdir,
        });
        defer alloc.free(expected);

        // Test with empty string - should fallback to home
        _ = env_os.setenv(case.name, "");
        const actual = try case.dir_type.path(alloc, .{});
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
        dir_type: UserDir,
        default_subdir: []const u8,
    };

    const cases = [_]DirCase{
        .{ .name = "XDG_CONFIG_HOME", .dir_type = UserDir.config, .default_subdir = ".config" },
        .{ .name = "XDG_CACHE_HOME", .dir_type = UserDir.cache, .default_subdir = ".cache" },
        .{ .name = "XDG_STATE_HOME", .dir_type = UserDir.state, .default_subdir = ".local/state" },
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

        const expected = try std.fs.path.join(alloc, &[_][]const u8{
            temp_home,
            case.default_subdir,
            "ghostty",
        });
        defer alloc.free(expected);

        // Test with empty string - should fallback to home
        _ = env.setenv(case.name, "");
        const actual = try case.dir_type.path(alloc, .{ .subdir = "ghostty" });
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

/// Iterator over XDG directories system directories and user directories
/// wraps SystemDirIterator using any values from that iterator and then
/// the path from UserDir.path()
const DirIterator = struct {
    alloc: Allocator,
    opts: Options,
    user_dir: UserDir,
    sys_dir_it: SystemDirIterator,
    emited_user_dir: bool = false,
    const Self = @This();
    pub fn next(self: *Self) !?[]const u8 {
        // TODO ignore relative paths where
        // path[0] != "/" and path not contains "/../?"
        if (self.sys_dir_it.next()) |path| {
            return try std.fs.path.join(self.alloc, &[_][]const u8{
                path,
                self.opts.subdir orelse "",
            });
        }

        if (!self.emited_user_dir) {
            self.emited_user_dir = true;
            return self.user_dir.path(self.alloc, self.opts) catch |err| switch (err) {
                error.NoHomeDir => null,
                else => err,
            };
        }

        return null;
    }
};

/// System and home directories for program configs and data,
/// these are the environment variables $XDG_CONFIG_DIRS:$XDG_CONFIG_HOME, and,
/// $XDG_DATA_DIRS:$XDG_DATA_HOME respectively
pub const Dir = enum {
    config,
    data,

    const Self = @This();
    fn as_system_dir(self: Self) SystemDir {
        // TODO: this cast could break if SystemDir or UserDir are reordered consider using a switch
        return @enumFromInt(@intFromEnum(self));
    }

    fn as_user_dir(self: Self) UserDir {
        // TODO: this cast could break if SystemDir or UserDir are reordered consider using a switch
        return @enumFromInt(@intFromEnum(self));
    }

    pub fn iter(self: Dir, alloc: Allocator, opts: Options) DirIterator {
        const sys_dir: SystemDir = self.as_system_dir();
        const user_dir: UserDir = self.as_user_dir();
        return .{ .alloc = alloc, .opts = opts, .sys_dir_it = sys_dir.iter(), .user_dir = user_dir };
    }
};

/// Iterator over system directories in order from least importance to most
/// importance, reverse order to how they are defined in XDG_*_DIRS
const SystemDirIterator = struct {
    data: []const u8,
    iterator: std.mem.SplitBackwardsIterator(u8, .scalar),

    const Self = @This();

    pub fn next(self: *Self) ?[]const u8 {
        return self.iterator.next();
    }
};

/// XDG system directory for program configs or data
pub const SystemDir = enum {
    config,
    data,

    pub fn key(self: SystemDir) [:0]const u8 {
        return switch (self) {
            .config => "XDG_CONFIG_DIRS",
            .data => "XDG_DATA_DIRS",
        };
    }

    pub fn default(self: SystemDir) [:0]const u8 {
        return switch (self) {
            .config => "/etc/xdg",
            .data => "/usr/local/share:/usr/share",
        };
    }

    pub fn iter(self: SystemDir) SystemDirIterator {
        const data = data: {
            if (posix.getenv(self.key())) |data| {
                if (std.mem.trim(u8, data, &std.ascii.whitespace).len > 0)
                    break :data data;
            }
            break :data self.default();
        };
        return .{
            .data = data,
            .iterator = std.mem.splitBackwardsScalar(u8, data, ':'),
        };
    }
};

test "xdg dirs" {
    const c = @cImport({
        @cInclude("stdlib.h");
    });

    const testing = std.testing;
    {
        _ = c.unsetenv(SystemDir.config.key());
        var it = SystemDir.config.iter();
        try testing.expectEqualStrings("/etc/xdg", it.next().?);
        try testing.expect(it.next() == null);
    }
    {
        _ = c.unsetenv(SystemDir.data.key());
        var it = SystemDir.data.iter();
        try testing.expectEqualStrings("/usr/share", it.next().?);
        try testing.expectEqualStrings("/usr/local/share", it.next().?);
        try testing.expect(it.next() == null);
    }
    {
        _ = c.setenv(SystemDir.config.key(), "a:b:c", 1);
        var it = SystemDir.config.iter();
        try testing.expectEqualStrings("c", it.next().?);
        try testing.expectEqualStrings("b", it.next().?);
        try testing.expectEqualStrings("a", it.next().?);
        try testing.expect(it.next() == null);
    }
}
