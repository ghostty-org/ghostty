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

/// List hosts with Ghostty SSH terminfo installed via the ssh-terminfo shell integration feature.
///
/// This command shows all remote hosts where Ghostty's terminfo has been successfully
/// installed through the SSH integration. The cache is automatically maintained when
/// connecting to remote hosts with `shell-integration-features = ssh-terminfo` enabled.
///
/// Use `+clear-ssh-cache` to remove cached entries if you need to force terminfo
/// reinstallation or clean up stale host entries.
pub fn run(alloc: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(alloc);
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    const stdout = std.io.getStdOut().writer();
    try ssh_cache.listCachedHosts(alloc, stdout);

    return 0;
}
