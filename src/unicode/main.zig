pub const lut = @import("lut.zig");

const grapheme = @import("grapheme.zig");
pub const table = @import("props_table.zig").table;
pub const Properties = @import("props.zig").Properties;
pub const GraphemeWidthEffect = grapheme.GraphemeWidthEffect;
pub const GraphemeWidth = grapheme.GraphemeWidth;
pub const graphemeBreak = grapheme.graphemeBreak;
pub const graphemeWidth = grapheme.graphemeWidth;
pub const graphemeWidthEffect = grapheme.graphemeWidthEffect;

/// Returns the terminal display width of a codepoint in terminal
/// grid cells: 0, 1, or 2.
///
/// This is the same width table the terminal uses when laying out
/// printed text: 0 for zero-width codepoints (controls, combining
/// marks, default-ignorables, surrogates), 2 for wide codepoints
/// (East Asian Wide/Fullwidth, regional indicators, clamped at 2),
/// and 1 otherwise.
///
/// This operates on a single codepoint and cannot account for
/// grapheme-cluster-level width rules (VS16, combining sequences);
/// callers needing cluster-accurate widths should use graphemeWidth().
/// Summing per-codepoint widths is only correct when mode 2027 is
/// disabled.
pub fn codepointWidth(cp: u21) u2 {
    return table.get(cp).width;
}

test "codepointWidth" {
    const testing = @import("std").testing;

    // Narrow (width 1)
    try testing.expectEqual(1, codepointWidth('a'));
    try testing.expectEqual(1, codepointWidth(' '));
    try testing.expectEqual(1, codepointWidth(0x10FFFF)); // max codepoint

    // C0/C1 control characters (width 0)
    try testing.expectEqual(0, codepointWidth(0x00)); // NUL
    try testing.expectEqual(0, codepointWidth(0x07)); // BEL
    try testing.expectEqual(0, codepointWidth(0x1B)); // ESC
    try testing.expectEqual(0, codepointWidth(0x7F)); // DEL
    try testing.expectEqual(0, codepointWidth(0x80)); // C1 PAD

    // Zero-width codepoints
    try testing.expectEqual(0, codepointWidth(0x0301)); // combining acute
    try testing.expectEqual(0, codepointWidth(0x200B)); // zero width space
    try testing.expectEqual(0, codepointWidth(0x200D)); // ZWJ
    try testing.expectEqual(0, codepointWidth(0xFE0F)); // VS16
    try testing.expectEqual(0, codepointWidth(0xD800)); // surrogate

    // Wide (width 2)
    try testing.expectEqual(2, codepointWidth(0x4E00)); // CJK ideograph
    try testing.expectEqual(2, codepointWidth(0xFF21)); // fullwidth A
    try testing.expectEqual(2, codepointWidth(0xAC00)); // Hangul syllable
    try testing.expectEqual(2, codepointWidth(0x1F600)); // emoji
    try testing.expectEqual(2, codepointWidth(0x1F1E6)); // regional indicator
    try testing.expectEqual(2, codepointWidth(0x2E3B)); // three-em dash (clamped)
}

test {
    @import("std").testing.refAllDecls(@This());
}
