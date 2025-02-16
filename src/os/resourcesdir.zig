const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Gets the directory to the bundled resources directory, if it
/// exists (not all platforms or packages have it). The output is
/// owned by the caller.
///
/// This is highly Ghostty-specific and can likely be generalized at
/// some point but we can cross that bridge if we ever need to.
pub fn resourcesDir(alloc: std.mem.Allocator) !?[]const u8 {
    // If we have an environment variable set, we always use that.
    // Note: we ALWAYS want to allocate here because the result is always
    // freed, do not try to use internal_os.getenv or posix getenv.
    if (std.process.getEnvVarOwned(alloc, "GHOSTTY_RESOURCES_DIR")) |dir| {
        if (dir.len > 0) return dir;
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }

    // This is the sentinel value we look for in the path to know
    // we've found the resources directory.
    const sentinel = switch (comptime builtin.target.os.tag) {
        .windows => "terminfo/ghostty.terminfo",
        .macos => "terminfo/78/xterm-ghostty",
        else => "terminfo/x/xterm-ghostty",
    };

    // Get the path to our running binary
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    var exe: []const u8 = std.fs.selfExePath(&exe_buf) catch return null;

    // We have an exe path! Climb the tree looking for the terminfo
    // bundle as we expect it.
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (std.fs.path.dirname(exe)) |dir| {
        exe = dir;

        // On MacOS, we look for the app bundle path.
        if (comptime builtin.target.isDarwin()) {
            if (try maybeDir(&dir_buf, dir, "Contents/Resources", sentinel)) |v| {
                return try std.fs.path.join(alloc, &.{ v, "ghostty" });
            }
        }

        // On all platforms, we look for a /usr/share style path. This
        // is valid even on Mac since there is nothing that requires
        // Ghostty to be in an app bundle.
        if (try maybeDir(&dir_buf, dir, "share", sentinel)) |v| {
            return try std.fs.path.join(alloc, &.{ v, "ghostty" });
        }
    }

    return null;
}

/// Little helper to check if the "base/sub/suffix" directory exists and
/// if so return true. The "suffix" is just used as a way to verify a directory
/// seems roughly right.
///
/// "buf" must be large enough to fit base + sub + suffix. This is generally
/// max_path_bytes so its not a big deal.
pub fn maybeDir(
    buf: []u8,
    base: []const u8,
    sub: []const u8,
    suffix: []const u8,
) !?[]const u8 {
    const path = try std.fmt.bufPrint(buf, "{s}/{s}/{s}", .{ base, sub, suffix });

    if (std.fs.accessAbsolute(path, .{})) {
        const len = path.len - suffix.len - 1;
        return buf[0..len];
    } else |_| {
        // Folder doesn't exist. If a different error happens its okay
        // we just ignore it and move on.
    }

    return null;
}
