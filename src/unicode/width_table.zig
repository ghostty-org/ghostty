//! The width of a codepoint as the terminal prints it: 1 for every
//! codepoint up to 0xFF, and the width from the property table otherwise.
//! The rule for 0..0xFF is part of the table, so a lookup has no branch.
//! See width_lut.zig for how the table is built.

const width_lut = @import("width_lut.zig");

// This is only available after running a generator as part of the Ghostty
// build.zig process, but due to Zig's lazy analysis we can still reference
// it here.
//
// The generator is the `main` in `props_uucode.zig`.
const generated = @import("unicode_tables");

/// Returns the print-path width of a codepoint: the same value as
/// `if (cp <= 0xFF) 1 else table.get(cp).width`.
pub inline fn get(cp: u21) u2 {
    const block: u32 = generated.width_index[cp >> width_lut.block_bits];
    const low = cp & ((1 << width_lut.block_bits) - 1);
    return @intCast(generated.width_leaf[(block << width_lut.block_bits) | low]);
}

test "width table: matches the property table on every codepoint" {
    const std = @import("std");
    if (std.valgrind.runningOnValgrind() > 0) return error.SkipZigTest;

    const testing = std.testing;
    const table = @import("props_table.zig").table;
    for (0..std.math.maxInt(u21) + 1) |cp| {
        const want: u2 = if (cp <= 0xFF) 1 else table.get(@intCast(cp)).width;
        try testing.expectEqual(want, get(@intCast(cp)));
    }
}
