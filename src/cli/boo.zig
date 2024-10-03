const std = @import("std");

const Allocator = std.mem.Allocator;

const GHOST_ASCII_ART = @embedFile("ghost_ascii.txt");

/// Spooky time
pub fn run(alloc: Allocator) !u8 {
    _ = alloc;
    const stdout = std.io.getStdOut().writer();

    try stdout.writeAll(GHOST_ASCII_ART);

    return 0;
}
