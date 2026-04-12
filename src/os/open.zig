const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const build_config = @import("../build_config.zig");
const apprt = @import("../apprt.zig");

const log = std.log.scoped(.@"os-open");

/// Open a URL in the default handling application.
///
/// Any output on stderr is logged as a warning in the application logs.
/// Output on stdout is ignored. The allocator is used to buffer the
/// log output and may allocate from another thread.
///
/// This function is purposely simple for the sake of providing
/// some portable way to open URLs. If you are implementing an
/// apprt for Ghostty, you should consider doing something special-cased
/// for your platform.
pub fn open(
    io: std.Io,
    env_map: std.process.Environ.Map,
    kind: apprt.action.OpenUrl.Kind,
    url: []const u8,
) !void {
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .linux, .freebsd => &.{ "xdg-open", url },

        .windows => &.{ "rundll32", "url.dll,FileProtocolHandler", url },

        .macos => switch (kind) {
            .text => &.{ "open", "-t", url },
            .html, .unknown => &.{ "open", url },
        },

        .ios => return error.Unimplemented,
        else => @compileError("unsupported OS"),
    };

    // In the snap on Linux the launcher exports LD_LIBRARY_PATH pointing at
    // the snap's bundled libraries. Leaking this into child process can
    // can be problematic, so let's drop it from the env
    var env = env_map;
    if (comptime build_config.snap) {
        env.remove("LD_LIBRARY_PATH");
    }

    // Spawn the process so we can detect failure quickly.
    const child = try std.process.spawn(io, .{
        .argv = argv,
        // Pipe stdout/stderr so we can collect output from the command.
        // This must be set before spawning the process.
        .stdout = .pipe,
        .stderr = .pipe,
        .environ_map = if (comptime build_config.snap) &env else null,
    });

    // Create a task that handles collecting output and reaping
    // the process. This is done in a separate task because SOME
    // open implementations block and some do not. It's easier to just
    // spawn a task to handle this so that we never block.
    io.async(openTask, .{ io, child });
}

fn openTask(io: std.Io, exe_: std.process.Child) !void {
    // Copy the exe so it is non-const. This is necessary because wait()
    // requires a mutable reference and we can't have one as a thread
    // param.
    var exe = exe_;
    _ = try exe.wait();

    const stderr = exe.stderr.?;

    // If we have any stderr output we log it. This makes it easier for
    // users to debug why some open commands may not work as expected.
    var buf: [5 * 1024]u8 = undefined;
    const count = try stderr.readPositionalAll(io, &buf, 0);
    if (count > 0) {
        log.warn("wait stderr={s}", .{buf[0..count]});
    }
}
