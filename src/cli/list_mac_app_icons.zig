const std = @import("std");
const builtin = @import("builtin");
const Action = @import("action.zig").Action;
const args = @import("args.zig");
const Config = @import("../config/Config.zig");

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

/// The `list-mac-app-icons` command is used to list all available macOS app icons
/// that can be used with the `macos-icon` configuration option in Ghostty.
pub fn run(alloc: std.mem.Allocator) !u8 {
    if (comptime !builtin.target.isDarwin()) {
        const stderr = std.io.getStdErr().writer();
        try stderr.writeAll("This command is only supported on macOS\n");
        return 1;
    }

    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(alloc);
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    const stdout = std.io.getStdOut().writer();

    inline for (@typeInfo(Config.MacAppIcon).Enum.fields) |field| {
        try stdout.print("{s}\n", .{field.name});
    }

    return 0;
}
