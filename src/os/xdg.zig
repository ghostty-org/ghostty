//! Implementation of the XDG Base Directory specification
//! (https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html)

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
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
    // First check the env var. On Windows we have to allocate so this tracks
    // both whether we have the env var and whether we own it.
    // on Windows we treat `LOCALAPPDATA` as a fallback for `XDG_CONFIG_HOME`
    const env_, const owned = switch (builtin.os.tag) {
        else => .{ std.os.getenv("XDG_CONFIG_HOME"), false },
        .windows => windows: {
            if (std.process.getEnvVarOwned(alloc, "XDG_CONFIG_HOME")) |env| {
                break :windows .{ env, true };
            } else |err| switch (err) {
                error.EnvironmentVariableNotFound => {
                    if (std.process.getEnvVarOwned(alloc, "LOCALAPPDATA")) |env| {
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

    // If we have a cached home dir, use that.
    if (opts.home) |home| {
        return try std.fs.path.join(alloc, &[_][]const u8{
            home,
            ".config",
            opts.subdir orelse "",
        });
    }

    // Get our home dir
    var buf: [1024]u8 = undefined;
    if (try homedir.home(&buf)) |home| {
        return try std.fs.path.join(alloc, &[_][]const u8{
            home,
            ".config",
            opts.subdir orelse "",
        });
    }

    return error.NoHomeDir;
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
