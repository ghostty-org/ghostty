//! Nerd Font glyph constraints.
//!
//! `table` is a 3-level codepoint lookup, same shape as
//! `unicode/symbols_table.zig`. Pages with no constrained glyphs share
//! one stage2 block and return null after the stage1 load.

const std = @import("std");
const lut = @import("../unicode/lut.zig");
const Constraint = @import("Glyph.zig").RenderOptions.Constraint;
const generated = @import("nerd_font_tables.zig").Tables(?Constraint);

/// 3-level codepoint lookup. Same shape as `unicode/symbols_table.zig`.
pub const table: lut.Tables(?Constraint) = .{
    .stage1 = &generated.stage1,
    .stage2 = &generated.stage2,
    .stage3 = &generated.stage3,
};

// lut.zig pages are 256 codepoints. The generator stores the all-null
// page at stage2 offset 0, and stage3 index 0 is null.
const empty_block: u16 = 0;

comptime {
    // One stage1 entry for every high byte of a u21.
    if (generated.stage1.len != 0x2000) @compileError("stage1 must cover every u21 page");
    if (generated.stage3.len == 0 or generated.stage3[0] != null) {
        @compileError("stage3[0] must be null");
    }
    for (generated.stage2[0..256]) |entry| {
        if (entry != 0) @compileError("empty nerd-font page must be stage2 offset 0");
    }
}

/// Nerd Font constraint for `cp`, or null when the codepoint has none.
/// Pages with no constrained glyphs return after the stage1 load.
pub inline fn getConstraint(cp: u21) ?Constraint {
    if (table.stage1[cp >> 8] == empty_block) return null;
    return table.get(cp);
}

test "Constraints lookup table" {
    const testing = std.testing;
    try testing.expect(getConstraint('A') == null);
    try testing.expect(getConstraint(0x30A2) == null); // katakana
    try testing.expect(getConstraint(0xFF66) == null); // halfwidth katakana
    try testing.expect(getConstraint(0x2630) != null);
    try testing.expect(getConstraint(0x110000) == null);
    try testing.expect(getConstraint(std.math.maxInt(u21)) == null);

    var cp: u32 = 0;
    while (cp <= 0x10FFFF) {
        const scalar: u21 = @intCast(cp);
        if (table.stage1[scalar >> 8] == empty_block) {
            try testing.expect(getConstraint(scalar) == null);
            cp = (cp & ~@as(u32, 0xFF)) + 256;
            continue;
        }
        const full = table.get(scalar);
        const fast = getConstraint(scalar);
        if (full) |value| {
            try testing.expectEqual(value, fast.?);
        } else {
            try testing.expect(fast == null);
        }
        cp += 1;
    }
}
