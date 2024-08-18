const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const isFlatpak = @import("flatpak.zig").isFlatpak;

fn execute(alloc: Allocator, argv: []const []const u8, comptime wait: bool) !void {
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

/// Run a command using the system shell to simplify parsing the command line
pub fn run(gpa_alloc: Allocator, cmd: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa_alloc);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    const argv, const wait = switch (builtin.os.tag) {
        .ios => return error.Unimplemented,
        .windows => result: {
            // We run our shell wrapped in `cmd.exe` so that we don't have
            // to parse the command line ourselves if it has arguments.

            // Note we don't free any of the memory below since it is
            // allocated in the arena.
            var list = std.ArrayList([]const u8).init(arena_alloc);
            const windir = try std.process.getEnvVarOwned(arena_alloc, "WINDIR");
            const shell = try std.fs.path.join(arena_alloc, &[_][]const u8{
                windir,
                "System32",
                "cmd.exe",
            });

            try list.append(shell);
            try list.append("/C");
            try list.append(cmd);
            break :result .{ try list.toOwnedSlice(), false };
        },
        else => result: {
            // We run our shell wrapped in `/bin/sh` so that we don't have
            // to parse the command line ourselves if it has arguments.
            // Additionally, some environments (NixOS, I found) use /bin/sh
            // to setup some environment variables that are important to
            // have set.
            var list = std.ArrayList([]const u8).init(arena_alloc);
            try list.append("/bin/sh");
            if (isFlatpak()) try list.append("-l");
            try list.append("-c");
            try list.append(cmd);
            break :result .{ try list.toOwnedSlice(), true };
        },
    };

    try execute(gpa_alloc, argv, wait);
}

/// Open a URL in the default handling application.
///
/// Any output on stderr is logged as a warning in the application logs.
/// Output on stdout is ignored.
pub fn open(gpa_alloc: Allocator, url: []const u8) !void {
    // Some opener commands terminate after opening (macOS open) and some do not
    // (xdg-open). For those which do not terminate, we do not want to wait for
    // the process to exit to collect stderr.
    const argv, const wait = switch (builtin.os.tag) {
        .linux => .{ &.{ "xdg-open", url }, false },
        .macos => .{ &.{ "open", url }, true },
        .windows => .{ &.{ "rundll32", "url.dll,FileProtocolHandler", url }, false },
        .ios => return error.Unimplemented,
        else => @compileError("unsupported OS"),
    };

    try execute(gpa_alloc, argv, wait);
}
