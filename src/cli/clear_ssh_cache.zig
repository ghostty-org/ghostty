const std = @import("std");
const Allocator = std.mem.Allocator;
const args = @import("args.zig");
const Action = @import("action.zig").Action;
const ssh_cache = @import("ssh_cache.zig");

pub const Options = struct {
    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables `-h` and `--help` to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// Clear the Ghostty SSH terminfo cache.
///
/// This command removes the cache of hosts where Ghostty's terminfo has been installed
/// via the ssh-terminfo shell integration feature. After clearing, terminfo will be
/// reinstalled on the next SSH connection to previously cached hosts.
///
/// Use this if you need to force reinstallation of terminfo or clean up old entries.
pub fn run(alloc: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(alloc);
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    const stdout = std.io.getStdOut().writer();
    try ssh_cache.clearCache(alloc, stdout);

    return 0;
}
