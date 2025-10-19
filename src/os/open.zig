const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const apprt = @import("../apprt.zig");
const internal_os = @import("main.zig");

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
    alloc: Allocator,
    kind: apprt.action.OpenUrl.Kind,
    url: []const u8,
) !void {
    // Trim trailing punctuation that may have been captured by the regex
    var trimmed_url = url;
    while (trimmed_url.len > 0 and (trimmed_url[trimmed_url.len - 1] == ':' or
                                     trimmed_url[trimmed_url.len - 1] == ',' or
                                     trimmed_url[trimmed_url.len - 1] == '.')) {
        trimmed_url = trimmed_url[0..trimmed_url.len - 1];
    }

    // Expand tilde paths before opening
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const expanded_url = internal_os.expandHome(trimmed_url, &path_buf) catch trimmed_url;

    var exe: std.process.Child = switch (builtin.os.tag) {
        .linux, .freebsd => .init(
            &.{ "xdg-open", expanded_url },
            alloc,
        ),

        .windows => .init(
            &.{ "rundll32", "url.dll,FileProtocolHandler", expanded_url },
            alloc,
        ),

        .macos => .init(
            switch (kind) {
                .text => &.{ "open", "-t", expanded_url },
                .unknown => &.{ "open", expanded_url },
            },
            alloc,
        ),

        .ios => return error.Unimplemented,
        else => @compileError("unsupported OS"),
    };

    // Pipe stdout/stderr so we can collect output from the command.
    // This must be set before spawning the process.
    exe.stdout_behavior = .Pipe;
    exe.stderr_behavior = .Pipe;

    // Spawn the process on our same thread so we can detect failure
    // quickly.
    try exe.spawn();

    // Create a thread that handles collecting output and reaping
    // the process. This is done in a separate thread because SOME
    // open implementations block and some do not. It's easier to just
    // spawn a thread to handle this so that we never block.
    const thread = try std.Thread.spawn(.{}, openThread, .{ alloc, exe });
    thread.detach();
}

fn openThread(alloc: Allocator, exe_: std.process.Child) !void {
    // 50 KiB is the default value used by std.process.Child.run and should
    // be enough to get the output we care about.
    const output_max_size = 50 * 1024;

    var stdout: std.ArrayListUnmanaged(u8) = .{};
    var stderr: std.ArrayListUnmanaged(u8) = .{};
    defer {
        stdout.deinit(alloc);
        stderr.deinit(alloc);
    }

    // Copy the exe so it is non-const. This is necessary because wait()
    // requires a mutable reference and we can't have one as a thread
    // param.
    var exe = exe_;
    try exe.collectOutput(alloc, &stdout, &stderr, output_max_size);
    _ = try exe.wait();

    // If we have any stderr output we log it. This makes it easier for
    // users to debug why some open commands may not work as expected.
    if (stderr.items.len > 0) log.warn("wait stderr={s}", .{stderr.items});
}
