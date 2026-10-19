const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const build_config = @import("../build_config.zig");
const apprt = @import("../apprt.zig");
const global = @import("../global.zig");

const log = std.log.scoped(.@"os-open");

/// Open a URL in the default handling application.
///
/// Any output on stderr is logged as a warning in the application logs.
/// Output on stdout is ignored.
///
/// This function is purposely simple for the sake of providing some portable
/// way to open URLs. If you are implementing an apprt for Ghostty, you should
/// consider doing something special-cased for your platform.
///
/// On macOS, untrusted kinds (`unknown`, `osc8`) return `error.UntrustedLink`
/// because the apprt must check them first.
pub fn open(
    kind: apprt.action.OpenUrl.Kind,
    url: []const u8,
) !void {
    // If an embedder declines an untrusted URL, refuse it rather than skip
    // the apprt's safety checks by passing it to `open`.
    if (comptime builtin.os.tag == .macos) {
        switch (kind) {
            .unknown, .osc8 => return error.UntrustedLink,
            .text, .html => {},
        }
    }

    var spawn_opts: std.process.SpawnOptions = switch (builtin.os.tag) {
        .linux, .freebsd => .{ .argv = &.{ "xdg-open", url } },
        .windows => .{ .argv = &.{ "rundll32", "url.dll,FileProtocolHandler", url } },
        .macos => switch (kind) {
            .text => .{ .argv = &.{ "open", "-t", url } },
            .html => .{ .argv = &.{ "open", url } },
            .unknown, .osc8 => unreachable,
        },
        .ios => return error.Unimplemented,
        else => @compileError("unsupported OS"),
    };
    // Ignore anything from stdout. This must be set before spawning the
    // process.
    spawn_opts.stdout = .ignore;
    // Pipe stderr so we can log the stderr from the command. This must be set
    // before spawning the process.
    spawn_opts.stderr = .pipe;

    const exe = if (comptime build_config.snap) local_env: {
        // In the snap on Linux the launcher exports LD_LIBRARY_PATH
        // pointing at the snap's bundled libraries. Leaking this into
        // child process can can be problematic, so let's drop it from the
        // env.
        //
        // Note that `spawn` copies the passed in `Environ.Map` into a
        // fresh `Environ` block, so this is safe to release immediately
        // after spawn.
        var environ_map = try global.environMap();
        defer environ_map.deinit();
        _ = environ_map.orderedRemove("LD_LIBRARY_PATH");
        spawn_opts.environ_map = &environ_map;
        break :local_env try std.process.spawn(global.io(), spawn_opts);
    } else
        // Non-snap releases don't need to alter the env.
        try std.process.spawn(global.io(), spawn_opts);

    const thread = try std.Thread.spawn(.{}, openThread, .{ global.io(), exe });
    thread.detach();
}

test "macOS untrusted links have no generic opener fallback" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    try std.testing.expectError(
        error.UntrustedLink,
        open(.osc8, "file:///tmp/payload.command"),
    );
    try std.testing.expectError(
        error.UntrustedLink,
        open(.unknown, "file:///tmp/payload.command"),
    );
}

fn openThread(io: std.Io, exe_: std.process.Child) void {
    // Copy the exe so it is non-const. This is necessary because wait()
    // requires a mutable reference and we can't have one as a thread
    // param.
    var exe = exe_;
    if (exe.stderr) |stderr| {
        var buffer: [256]u8 = undefined;
        var stream = stderr.readerStreaming(io, &buffer);
        const reader = &stream.interface;
        while (true) {
            // Read inclusively so the delimiter is consumed:
            // takeDelimiterExclusive leaves the '\n' buffered, so once the
            // child writes a line this loop would receive an empty slice
            // forever, pinning a core and spamming empty warnings.
            const line = reader.takeDelimiterInclusive('\n') catch |outer| switch (outer) {
                error.EndOfStream => break,
                error.ReadFailed => break,
                error.StreamTooLong => reader.take(buffer.len) catch |inner| switch (inner) {
                    error.ReadFailed => break,
                    error.EndOfStream => break,
                },
            };
            log.warn("open stderr={s}", .{std.mem.trimEnd(u8, line, "\n")});
        }
    }
    _ = exe.wait(io) catch {};
}
