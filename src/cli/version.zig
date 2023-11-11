const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const xev = @import("xev");
const renderer = @import("../renderer.zig");
const Allocator = std.mem.Allocator;

/// ignored argument is needed to conform to duck-typing at the call sites
pub fn run(_: anytype) !u8 {
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


pub fn help(
    alloc: Allocator, // in case of dynamically generated help
    writer: anytype, // duck-typing, print to any writer including ArrayList
    short: bool // short one-line (<68 letters, no NL) or long (unlimited size) help
) !u8 {
    _ = alloc;
    if (short) {
        try writer.print("print version information. Also available as --version option", .{});
    } else {
        try writer.print(
            \\Usage:
            \\  ghostty --version
            \\
            \\Print Ghostty version information including build config, run-time, font engine, etc.
            \\ Can use +version (action syntax) in place of --version (option syntax).
            \\
            , .{});
    }

    return 11;
}