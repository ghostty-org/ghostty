const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("action.zig").Action;
const args = @import("args.zig");

const log = std.log.scoped(.notify);

pub const Config = struct {
    /// This is set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    /// The title of the notifiction.
    title: [:0]const u8 = "Ghostty",

    /// The body of the notification.
    body: ?[:0]const u8 = null,

    pub fn deinit(self: *Config) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Config) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `notify` command is used to send a desktop notification to the user
/// using OSC 777.
///
/// The `--title` argument is used to set the title of the notification. If
/// unspecified, the default of "Ghostty" will be used.
///
/// The `--body` argument is used to set the body of the notification. This
/// argument is required.
pub fn run(alloc: Allocator) !u8 {
    var iter = try std.process.argsWithAllocator(alloc);
    defer iter.deinit();
    return try runArgs(alloc, &iter);
}

fn runArgs(alloc_gpa: Allocator, argsIter: anytype) !u8 {
    var config: Config = .{};
    defer config.deinit();
    try args.parse(Config, alloc_gpa, &config, argsIter);

    const body = config.body orelse {
        return Action.help_error;
    };

    var buffer: [2048]u8 = undefined;
    const message = try std.fmt.bufPrint(&buffer, "\x1b]777;notify;{s};{s}\x1b\\", .{ config.title, body });

    const stdout = std.io.getStdOut();
    try stdout.writeAll(message);

    return 0;
}
