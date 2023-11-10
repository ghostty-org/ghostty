const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const xev = @import("xev");
const renderer = @import("../renderer.zig");
const args = @import("args.zig");
const help = @import("help.zig");
const Allocator = std.mem.Allocator;

pub const Options = struct { help: bool = false, version: bool = false };

/// The "version" command is used to display information
/// about Ghostty.
pub fn run(alloc: Allocator) !u8 {
    var opts: Options = .{};

    {
        var iter = try std.process.argsWithAllocator(alloc);
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    const stdout = std.io.getStdOut().writer();

    if (opts.help) {
        try help.searchActionsAst("version", alloc, &stdout);
        return 0;
    }

    try stdout.print("Ghostty {s}\n\n", .{build_config.version_string});
    try stdout.print("Build Config\n", .{});
    try stdout.print("  - build mode : {}\n", .{builtin.mode});
    try stdout.print("  - app runtime: {}\n", .{build_config.app_runtime});
    try stdout.print("  - font engine: {}\n", .{build_config.font_backend});
    try stdout.print("  - renderer   : {}\n", .{renderer.Renderer});
    try stdout.print("  - libxev     : {}\n", .{xev.backend});
    return 0;
}
