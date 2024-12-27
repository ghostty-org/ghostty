const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Open a URL in the default handling application.
///
/// Any output on stderr is logged as a warning in the application logs.
/// Output on stdout is ignored.
pub fn open(alloc: Allocator, url: []const u8) !void {
    // Some opener commands terminate after opening (macOS open) and some do not
    // (xdg-open). For those which do not terminate, we do not want to wait for
    // the process to exit to collect stderr.
    const argv, const wait = switch (builtin.os.tag) {
        .linux => .{ &.{ "xdg-open", url }, false },
        .macos => .{ &.{ "open -t", url }, true },
        .windows => .{ &.{ "rundll32", "url.dll,FileProtocolHandler", url }, false },
        .ios => return error.Unimplemented,
        else => @compileError("unsupported OS"),
    };

    var exe = std.process.Child.init(argv, alloc);

    if (comptime wait) {
        // Pipe stdout/stderr so we can collect output from the command
        exe.stdout_behavior = .Pipe;
        exe.stderr_behavior = .Pipe;
    }

    try exe.spawn();

    if (comptime wait) {
        // 50 KiB is the default value used by std.process.Child.run
        const output_max_size = 50 * 1024;

        var stdout = std.ArrayList(u8).init(alloc);
        var stderr = std.ArrayList(u8).init(alloc);
        defer {
            stdout.deinit();
            stderr.deinit();
        }

        try exe.collectOutput(&stdout, &stderr, output_max_size);
        _ = try exe.wait();

        // If we have any stderr output we log it. This makes it easier for
        // users to debug why some open commands may not work as expected.
        if (stderr.items.len > 0) std.log.err("open stderr={s}", .{stderr.items});
    }
}
