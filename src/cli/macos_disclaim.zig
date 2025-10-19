const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const posix_spawn = @import("../os/posix_spawn.zig");

const log = std.log.scoped(.macos_disclaim);

pub const Options = struct {
    pub fn deinit(self: Options) void {
        _ = self;
    }
};

/// The `_macos-disclaim` command is an internal-only Ghostty command that
/// is only available on macOS. It uses private posix_spawn APIs to
/// make the child process the "responssible process" in macOS so it is
/// in charge of its own TCC (permissions like Downloads folder access or
/// camera) and resource accounting rather than Ghostty.
pub fn run(alloc: Allocator) !u8 {
    // This helper is only for Apple systems. POSIX in general has posix_spawn
    // but we only use it on Apple platforms because it lets us shed our
    // responsible process bit.
    if (comptime builtin.os.tag != .macos) {
        log.warn("macos-disclaim is only supported on macOS", .{});
        return 1;
    }

    // Get the command to exec from the remaining args
    // Skip arg 0 (our program name) and arg 1 (the action "+_macos-disclaim")
    var arg_iter = try std.process.argsWithAllocator(alloc);
    defer arg_iter.deinit();
    _ = arg_iter.skip();
    _ = arg_iter.skip();

    // Collect remaining args for exec
    var args: std.ArrayList(?[*:0]const u8) = .empty;
    defer args.deinit(alloc);
    while (arg_iter.next()) |arg| try args.append(alloc, arg);
    if (args.items.len == 0) {
        log.err("no command specified to exec", .{});
        return 1;
    }
    try args.append(alloc, null);

    var attrs = try posix_spawn.spawn_attr.create();
    defer posix_spawn.spawn_attr.destroy(&attrs);
    {
        try posix_spawn.spawn_attr.setflags(&attrs, .{
            // Act like exec(): replace this process.
            .setexec = true,
        });

        // This is the magical private API that makes it so that this
        // child process doesn't get looped into the TCC and resource
        // accounting of Ghostty.
        try posix_spawn.spawn_attr.disclaim(&attrs, true);
    }

    _ = posix_spawn.spawnp(
        std.mem.span(args.items[0].?),
        null,
        &attrs,
        args.items[0 .. args.items.len - 1 :null].ptr,
        std.c.environ,
    ) catch |err| {
        log.err("failed to posix_spawn command '{s}': {}", .{
            std.mem.span(args.items[0].?),
            err,
        });
        return 1;
    };

    // We set the exec flag so we can't reach this point.
    unreachable;
}
