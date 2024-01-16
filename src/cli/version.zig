const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const xev = @import("xev");
const renderer = @import("../renderer.zig");

/// The `version` command is used to display information
/// about Ghostty.
pub fn run() !u8 {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("Ghostty {s}\n\n", .{build_config.version_string});
    try stdout.print("Build Config\n", .{});
    try stdout.print("  - build mode : {}\n", .{builtin.mode});
    try stdout.print("  - app runtime: {}\n", .{build_config.app_runtime});
    try stdout.print("  - font engine: {}\n", .{build_config.font_backend});
    try stdout.print("  - renderer   : {}\n", .{renderer.Renderer});
    try stdout.print("  - libxev     : {}\n", .{xev.backend});
    return 0;
}
