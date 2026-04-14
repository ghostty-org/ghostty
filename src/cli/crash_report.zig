const std = @import("std");
const Allocator = std.mem.Allocator;
const args = @import("args.zig");
const Action = @import("ghostty.zig").Action;
const Config = @import("../config.zig").Config;
const crash = @import("../crash/main.zig");

pub const Options = struct {
    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `crash-report` command is used to inspect and send crash reports.
///
/// When executed without any arguments, this will list existing crash reports.
///
/// This command currently only supports listing crash reports. Viewing
/// and sending crash reports is unimplemented and will be added in the future.
pub fn run(
    alloc_gpa: Allocator,
    io: std.Io,
    proc_args: std.process.Args,
) !u8 {
    // Use an arena for the whole command to avoid manual memory management.
    var arena = std.heap.ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(proc_args, alloc_gpa);
        defer iter.deinit();
        try args.parse(Options, alloc_gpa, &opts, &iter);
    }

    var buffer: [1024]u8 = undefined;
    var stdout_file: std.Io.File = .stdout();
    var stdout_writer = stdout_file.writer(io, &buffer);
    const stdout = &stdout_writer.interface;

    const result = runInner(io, alloc, &stdout_file, stdout);
    stdout.flush() catch {};
    return result;
}

fn runInner(
    io: std.Io,
    alloc: Allocator,
    stdout_file: *std.Io.File,
    stdout: *std.Io.Writer,
) !u8 {
    const crash_dir = try crash.defaultDir(io, alloc);
    var reports: std.ArrayList(crash.Report) = .empty;
    errdefer reports.deinit(alloc);

    var it = try crash_dir.iterator();
    while (try it.next()) |report| try reports.append(alloc, .{
        .name = try alloc.dupe(u8, report.name),
        .mtime = report.mtime,
    });

    // If we have no reports, then we're done. If we have a tty then we
    // print a message, otherwise we do nothing.
    if (reports.items.len == 0) {
        if (stdout_file.isTty(io) catch false) {
            try stdout.writeAll("No crash reports! 👻\n");
        }
        return 0;
    }

    std.mem.sort(crash.Report, reports.items, {}, lt);

    for (reports.items) |report| {
        var buf: [128]u8 = undefined;
        const now = std.Io.Timestamp.now(io, .real).toNanoseconds();
        const diff = now - report.mtime;
        const since = if (diff <= 0) "now" else s: {
            const d = Config.Duration{ .duration = @intCast(diff) };
            break :s try std.fmt.bufPrint(&buf, "{f} ago", .{d.round(std.time.ns_per_s)});
        };
        try stdout.print("{s} ({s})\n", .{ report.name, since });
    }

    return 0;
}

fn lt(_: void, lhs: crash.Report, rhs: crash.Report) bool {
    return lhs.mtime > rhs.mtime;
}
