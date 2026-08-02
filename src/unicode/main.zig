pub const lut = @import("lut.zig");

const grapheme = @import("grapheme.zig");
pub const table = @import("props_table.zig").table;
pub const Properties = @import("props.zig").Properties;
pub const GraphemeWidthEffect = grapheme.GraphemeWidthEffect;
pub const GraphemeWidth = grapheme.GraphemeWidth;
pub const graphemeBreak = grapheme.graphemeBreak;
pub const graphemeWidth = grapheme.graphemeWidth;
pub const graphemeWidthEffect = grapheme.graphemeWidthEffect;

const bidi_props = @import("bidi_props.zig");
pub const bidi_table = @import("bidi_table.zig").table;
pub const BidiClass = bidi_props.BidiClass;
pub const BidiPairedBracketType = bidi_props.BidiPairedBracketType;
pub const BidiProperties = bidi_props.BidiProperties;

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

/// Returns the full set of Unicode Bidirectional Algorithm (UAX #9)
/// properties for a codepoint.
///
/// Prefer the narrower accessors below unless you need more than one
/// property; they all resolve through this single table lookup, so reading
/// the struct once and using it is cheaper than calling several of them.
pub fn bidiProperties(cp: u21) BidiProperties {
    return bidi_table.get(cp);
}

/// Returns the Bidi_Class of a codepoint (UAX #9, Table 4).
///
/// Unassigned codepoints do NOT all resolve to `.l`. The default varies by
/// block: unassigned codepoints in the Hebrew range resolve to `.r`, in the
/// Arabic ranges to `.al`, and in the Currency Symbols range to `.et`. See
/// the `@missing` lines in DerivedBidiClass.txt.
pub fn bidiClass(cp: u21) BidiClass {
    return bidi_table.get(cp).class;
}

/// Returns whether a codepoint has Bidi_Mirrored=Y, i.e. whether rule L4
/// mirrors it when its resolved embedding level is odd.
///
/// This is a strict superset of the codepoints that have a mirroring glyph;
/// see bidiMirroringGlyph.
pub fn isBidiMirrored(cp: u21) bool {
    return bidi_table.get(cp).mirrored;
}

/// Returns the Bidi_Mirroring_Glyph of a codepoint, or null if it has none.
///
/// A null return does not imply the codepoint is unmirrored. U+2202 PARTIAL
/// DIFFERENTIAL has Bidi_Mirrored=Y but no designated mirroring glyph; rule
/// L4 still applies and the font is expected to supply the mirrored form.
/// Use isBidiMirrored to test for mirroring.
pub fn bidiMirroringGlyph(cp: u21) ?u21 {
    return bidi_table.get(cp).mirroringGlyph(cp);
}

/// Returns the Bidi_Paired_Bracket_Type of a codepoint, used by rule N0.
pub fn bidiPairedBracketType(cp: u21) BidiPairedBracketType {
    return bidi_table.get(cp).bracket;
}

/// Returns the Bidi_Paired_Bracket of a codepoint, or null if the codepoint
/// is not a paired bracket.
pub fn bidiPairedBracket(cp: u21) ?u21 {
    return bidi_table.get(cp).pairedBracket(cp);
}

test "bidiClass: strong types" {
    const testing = @import("std").testing;

    try testing.expectEqual(BidiClass.l, bidiClass('a'));
    try testing.expectEqual(BidiClass.l, bidiClass('Z'));
    try testing.expectEqual(BidiClass.r, bidiClass(0x05D0)); // HEBREW ALEF
    try testing.expectEqual(BidiClass.r, bidiClass(0x05BE)); // HEBREW MAQAF
    try testing.expectEqual(BidiClass.al, bidiClass(0x0627)); // ARABIC ALEF
    try testing.expectEqual(BidiClass.al, bidiClass(0x0645)); // ARABIC MEEM
    try testing.expectEqual(BidiClass.al, bidiClass(0x06CC)); // FARSI YEH
}

test "bidiClass: numbers" {
    const testing = @import("std").testing;

    // ASCII digits are European Number.
    try testing.expectEqual(BidiClass.en, bidiClass('0'));
    try testing.expectEqual(BidiClass.en, bidiClass('9'));

    // Arabic-Indic digits are Arabic Number...
    try testing.expectEqual(BidiClass.an, bidiClass(0x0660));
    try testing.expectEqual(BidiClass.an, bidiClass(0x0669));

    // ...but Extended Arabic-Indic digits, used for Persian, are European
    // Number. Confusing the two is a classic source of "the phone number
    // renders backwards" bugs.
    try testing.expectEqual(BidiClass.en, bidiClass(0x06F0));
    try testing.expectEqual(BidiClass.en, bidiClass(0x06F9));

    // U+0600 ARABIC NUMBER SIGN is AN despite living in a block whose
    // unassigned default is AL.
    try testing.expectEqual(BidiClass.an, bidiClass(0x0600));

    // Separators and terminators.
    try testing.expectEqual(BidiClass.es, bidiClass('+'));
    try testing.expectEqual(BidiClass.es, bidiClass('-'));
    try testing.expectEqual(BidiClass.cs, bidiClass(','));
    try testing.expectEqual(BidiClass.cs, bidiClass('.'));
    try testing.expectEqual(BidiClass.cs, bidiClass(':'));
    try testing.expectEqual(BidiClass.et, bidiClass('#'));
    try testing.expectEqual(BidiClass.et, bidiClass('%'));
    try testing.expectEqual(BidiClass.et, bidiClass('$'));
}

test "bidiClass: neutrals and whitespace" {
    const testing = @import("std").testing;

    try testing.expectEqual(BidiClass.ws, bidiClass(' '));
    try testing.expectEqual(BidiClass.ws, bidiClass(0x000C)); // FORM FEED
    try testing.expectEqual(BidiClass.s, bidiClass(0x0009)); // TAB
    try testing.expectEqual(BidiClass.b, bidiClass(0x000A)); // LINE FEED
    try testing.expectEqual(BidiClass.b, bidiClass(0x2029)); // PARA SEPARATOR
    try testing.expectEqual(BidiClass.on, bidiClass('('));
    try testing.expectEqual(BidiClass.on, bidiClass('!'));
    try testing.expectEqual(BidiClass.bn, bidiClass(0x0000)); // NUL
    try testing.expectEqual(BidiClass.bn, bidiClass(0x200B)); // ZWSP
    try testing.expectEqual(BidiClass.bn, bidiClass(0x200C)); // ZWNJ
    try testing.expectEqual(BidiClass.bn, bidiClass(0x200D)); // ZWJ
    try testing.expectEqual(BidiClass.nsm, bidiClass(0x0300)); // COMBINING GRAVE
    try testing.expectEqual(BidiClass.nsm, bidiClass(0x05B4)); // HEBREW HIRIQ
    try testing.expectEqual(BidiClass.nsm, bidiClass(0x064B)); // ARABIC FATHATAN
}

test "bidiClass: explicit formatting characters" {
    const testing = @import("std").testing;

    try testing.expectEqual(BidiClass.l, bidiClass(0x200E)); // LRM
    try testing.expectEqual(BidiClass.r, bidiClass(0x200F)); // RLM
    try testing.expectEqual(BidiClass.al, bidiClass(0x061C)); // ALM

    try testing.expectEqual(BidiClass.lre, bidiClass(0x202A));
    try testing.expectEqual(BidiClass.rle, bidiClass(0x202B));
    try testing.expectEqual(BidiClass.pdf, bidiClass(0x202C));
    try testing.expectEqual(BidiClass.lro, bidiClass(0x202D));
    try testing.expectEqual(BidiClass.rlo, bidiClass(0x202E));

    try testing.expectEqual(BidiClass.lri, bidiClass(0x2066));
    try testing.expectEqual(BidiClass.rli, bidiClass(0x2067));
    try testing.expectEqual(BidiClass.fsi, bidiClass(0x2068));
    try testing.expectEqual(BidiClass.pdi, bidiClass(0x2069));

    // The override characters are the Trojan Source vector. They must be
    // classified, not swallowed, so the paste guard can find them later.
    try testing.expect(bidiClass(0x202D).isExplicitFormatting());
    try testing.expect(bidiClass(0x202E).isExplicitFormatting());
}

test "bidiClass: unassigned codepoints use block defaults, not L" {
    const testing = @import("std").testing;

    // This is the single easiest way to get a bidi table wrong. Every
    // codepoint below is UNASSIGNED, and each one must pick up the
    // `@missing` default for its block rather than falling back to L.
    // If any of these returns `.l`, the table generation dropped the
    // @missing lines from DerivedBidiClass.txt.
    try testing.expectEqual(BidiClass.r, bidiClass(0x0590)); // Hebrew block
    try testing.expectEqual(BidiClass.al, bidiClass(0x070E)); // Syriac block
    try testing.expectEqual(BidiClass.r, bidiClass(0x07FB)); // NKo block
    try testing.expectEqual(BidiClass.et, bidiClass(0x20C2)); // Currency
    try testing.expectEqual(BidiClass.al, bidiClass(0x10D28)); // Hanifi Rohingya
    try testing.expectEqual(BidiClass.al, bidiClass(0x1EE04)); // Arabic Math
    try testing.expectEqual(BidiClass.r, bidiClass(0x1EF00)); // unassigned RTL

    // An unassigned codepoint outside any RTL block does default to L.
    try testing.expectEqual(BidiClass.l, bidiClass(0x2FE0));
}

test "isBidiMirrored and bidiMirroringGlyph" {
    const testing = @import("std").testing;

    try testing.expect(isBidiMirrored('('));
    try testing.expect(isBidiMirrored(')'));
    try testing.expect(isBidiMirrored('<'));
    try testing.expect(!isBidiMirrored('a'));
    try testing.expect(!isBidiMirrored(' '));

    try testing.expectEqual(@as(?u21, ')'), bidiMirroringGlyph('('));
    try testing.expectEqual(@as(?u21, '('), bidiMirroringGlyph(')'));
    try testing.expectEqual(@as(?u21, '>'), bidiMirroringGlyph('<'));
    try testing.expectEqual(@as(?u21, ']'), bidiMirroringGlyph('['));
    try testing.expectEqual(@as(?u21, '}'), bidiMirroringGlyph('{'));
    try testing.expectEqual(@as(?u21, null), bidiMirroringGlyph('a'));

    // A large delta, exercising the wide end of the i13 encoding.
    try testing.expectEqual(@as(?u21, 0x2997), bidiMirroringGlyph(0x2998));

    // Mirrored with no designated glyph: both facts must be representable
    // at once, which is why `mirrored` is stored separately from the delta.
    try testing.expect(isBidiMirrored(0x2202)); // PARTIAL DIFFERENTIAL
    try testing.expectEqual(@as(?u21, null), bidiMirroringGlyph(0x2202));
}

test "bidiMirroringGlyph is an involution" {
    const std = @import("std");
    const testing = std.testing;

    // mirror(mirror(cp)) == cp for every codepoint that has a mirroring
    // glyph. This is a UCD invariant and a cheap whole-table integrity
    // check: a corrupted delta almost certainly breaks it.
    for (0..std.math.maxInt(u21) + 1) |i| {
        const cp: u21 = @intCast(i);
        const m = bidiMirroringGlyph(cp) orelse continue;
        try testing.expectEqual(@as(?u21, cp), bidiMirroringGlyph(m));
    }
}

test "bidiPairedBracket" {
    const testing = @import("std").testing;

    try testing.expectEqual(BidiPairedBracketType.open, bidiPairedBracketType('('));
    try testing.expectEqual(BidiPairedBracketType.close, bidiPairedBracketType(')'));
    try testing.expectEqual(BidiPairedBracketType.open, bidiPairedBracketType('['));
    try testing.expectEqual(BidiPairedBracketType.close, bidiPairedBracketType(']'));
    try testing.expectEqual(BidiPairedBracketType.open, bidiPairedBracketType('{'));
    try testing.expectEqual(BidiPairedBracketType.close, bidiPairedBracketType('}'));

    // Angle brackets are mirrored but are NOT paired brackets for rule N0.
    try testing.expectEqual(BidiPairedBracketType.none, bidiPairedBracketType('<'));
    try testing.expect(isBidiMirrored('<'));

    try testing.expectEqual(BidiPairedBracketType.none, bidiPairedBracketType('a'));

    try testing.expectEqual(@as(?u21, ')'), bidiPairedBracket('('));
    try testing.expectEqual(@as(?u21, '('), bidiPairedBracket(')'));
    try testing.expectEqual(@as(?u21, 0x2997), bidiPairedBracket(0x2998));
    try testing.expectEqual(@as(?u21, null), bidiPairedBracket('<'));
    try testing.expectEqual(@as(?u21, null), bidiPairedBracket('a'));
}

test "bidiProperties: single lookup agrees with narrow accessors" {
    const testing = @import("std").testing;

    for ([_]u21{ 'a', '(', ')', 0x05D0, 0x0627, 0x2202, 0x202E, 0x2998, 0x0590 }) |cp| {
        const p = bidiProperties(cp);
        try testing.expectEqual(bidiClass(cp), p.class);
        try testing.expectEqual(isBidiMirrored(cp), p.mirrored);
        try testing.expectEqual(bidiPairedBracketType(cp), p.bracket);
        try testing.expectEqual(bidiMirroringGlyph(cp), p.mirroringGlyph(cp));
        try testing.expectEqual(bidiPairedBracket(cp), p.pairedBracket(cp));
    }
}

test {
    @import("std").testing.refAllDecls(@This());

    // Internals
    _ = @import("bidi_props.zig");
}
