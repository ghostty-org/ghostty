const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.@"os-open");

/// The type of the data at the URL to open. This is used as a hint
/// to potentially open the URL in a different way.
pub const Type = enum {
    text,
    unknown,
};

/// Open a URL in the default handling application.
///
/// Any output on stderr is logged as a warning in the application logs.
/// Output on stdout is ignored. The allocator is used to buffer the
/// log output and may allocate from another thread.
pub fn open(
    alloc: Allocator,
    typ: Type,
    url: []const u8,
) !void {
    var exe: std.process.Child = switch (builtin.os.tag) {
        .linux, .freebsd => .init(
            &.{ "xdg-open", url },
            alloc,
        ),

        .windows => .init(
            &.{ "rundll32", "url.dll,FileProtocolHandler", url },
            alloc,
        ),

        .macos => .init(
            switch (typ) {
                .text => &.{ "open", "-t", url },
                .unknown => &.{ "open", url },
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
