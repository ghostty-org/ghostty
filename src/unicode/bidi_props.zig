//! Unicode Bidirectional Algorithm (UAX #9) properties per codepoint.
//!
//! These live in a lookup table separate from `props.zig` on purpose. The
//! properties in `Properties` are read for every printed cell by
//! `codepointWidth` and `graphemeBreak`; the properties here are only read
//! by the bidi implementation. Folding them together would widen the hot
//! table for no benefit to the common path.
//!
//! The values are derived from the UCD at build time (see `bidi_uucode.zig`),
//! so this file only describes the shape of the data, never the data itself.

const std = @import("std");

/// Bidi_Class (UAX #9, Table 4).
///
/// Names are the standard UAX #9 abbreviations rather than the spelled-out
/// UCD long names. Every rule in the specification (W1-W7, N0-N2, I1-I2,
/// ...) is written in terms of these abbreviations, so matching them keeps
/// an implementation reviewable against the spec side by side.
///
/// The default for an *unassigned* codepoint is not `l`. It varies by block
/// (see the `@missing` lines in `DerivedBidiClass.txt`): unassigned
/// codepoints in the Hebrew block default to `r`, in the Arabic blocks to
/// `al`, and in the Currency Symbols block to `et`. The generated table
/// encodes those defaults; callers must not assume `l` for unknown input.
pub const BidiClass = enum(u5) {
    // Strong
    /// L: Left_To_Right
    l,
    /// R: Right_To_Left
    r,
    /// AL: Arabic_Letter
    al,

    // Weak
    /// EN: European_Number
    en,
    /// ES: European_Separator
    es,
    /// ET: European_Terminator
    et,
    /// AN: Arabic_Number
    an,
    /// CS: Common_Separator
    cs,
    /// NSM: Nonspacing_Mark
    nsm,
    /// BN: Boundary_Neutral
    bn,

    // Neutral
    /// B: Paragraph_Separator
    b,
    /// S: Segment_Separator
    s,
    /// WS: White_Space
    ws,
    /// ON: Other_Neutral
    on,

    // Explicit formatting
    /// LRE: Left_To_Right_Embedding
    lre,
    /// LRO: Left_To_Right_Override
    lro,
    /// RLE: Right_To_Left_Embedding
    rle,
    /// RLO: Right_To_Left_Override
    rlo,
    /// PDF: Pop_Directional_Format
    pdf,
    /// LRI: Left_To_Right_Isolate
    lri,
    /// RLI: Right_To_Left_Isolate
    rli,
    /// FSI: First_Strong_Isolate
    fsi,
    /// PDI: Pop_Directional_Isolate
    pdi,

    /// True for the strong classes (L, R, AL). These are the classes that
    /// determine paragraph direction under rules P2/P3.
    pub fn isStrong(self: BidiClass) bool {
        return switch (self) {
            .l, .r, .al => true,
            else => false,
        };
    }

    /// True for the isolate initiators (LRI, RLI, FSI). Note this
    /// deliberately excludes PDI, which terminates an isolate rather
    /// than initiating one.
    pub fn isIsolateInitiator(self: BidiClass) bool {
        return switch (self) {
            .lri, .rli, .fsi => true,
            else => false,
        };
    }

    /// True for the explicit embedding and override formatting characters
    /// (LRE, LRO, RLE, RLO, PDF). Isolates are not included: they are
    /// retained by rule X9 whereas these are removed.
    pub fn isExplicitFormatting(self: BidiClass) bool {
        return switch (self) {
            .lre, .lro, .rle, .rlo, .pdf => true,
            else => false,
        };
    }

    /// True for characters removed by rule X9 (the explicit formatting
    /// characters plus BN). Implementations that do not literally remove
    /// them must treat them as no-ops per X9's "retaining" note.
    pub fn isRemovedByX9(self: BidiClass) bool {
        return switch (self) {
            .lre, .lro, .rle, .rlo, .pdf, .bn => true,
            else => false,
        };
    }
};

/// Bidi_Paired_Bracket_Type (UAX #9, used by rule N0).
pub const BidiPairedBracketType = enum(u2) {
    /// n: not a paired bracket
    none,
    /// o: opening paired bracket
    open,
    /// c: closing paired bracket
    close,
};

/// The bidi property set for a single codepoint.
///
/// ## Encoding
///
/// `Bidi_Mirroring_Glyph` and `Bidi_Paired_Bracket` are codepoint-valued
/// properties. Storing them as absolute codepoints would give the generated
/// table one distinct entry per mirrored codepoint (428 as of Unicode 17).
/// They are stored as *deltas* from the codepoint instead, which collapses
/// them to 36 and 6 distinct values respectively, because mirrored pairs are
/// overwhelmingly adjacent (`(` / `)` differ by one). The whole table has 67
/// distinct entries as a result, which keeps both the generated stage3 array
/// and the generator's dedup cost small.
///
/// A delta of zero means "no mapping". That is unambiguous: no codepoint in
/// `BidiMirroring.txt` maps to itself. `bidi_uucode.zig` asserts this when
/// generating the table, so the invariant cannot silently rot across a UCD
/// update.
///
/// Note that `mirrored` is *not* redundant with `mirror_delta`. Bidi_Mirrored
/// is a strict superset of Bidi_Mirroring_Glyph: 554 codepoints have
/// Bidi_Mirrored=Y but only 428 have a mirroring glyph. U+2202 PARTIAL
/// DIFFERENTIAL is mirrored with no designated glyph, and rule L4 still
/// applies to it.
pub const BidiProperties = packed struct(u32) {
    /// Bidi_Class.
    class: BidiClass = .l,

    /// Bidi_Paired_Bracket_Type.
    bracket: BidiPairedBracketType = .none,

    /// Bidi_Mirrored. Rule L4 mirrors a character when this is set and the
    /// resolved embedding level is odd.
    mirrored: bool = false,

    /// Bidi_Paired_Bracket as a delta from the codepoint. Zero means the
    /// codepoint has no paired bracket. Observed range is [-3, 3].
    bracket_delta: i3 = 0,

    /// Bidi_Mirroring_Glyph as a delta from the codepoint. Zero means the
    /// codepoint has no mirroring glyph. Observed range is [-2527, 2527].
    mirror_delta: i13 = 0,

    /// Explicit padding to give the struct a power-of-two backing integer.
    /// See the equivalent note in `props.zig`: a non-power-of-two backing
    /// integer makes Zig lower loads and stores through exotic-width LLVM
    /// integer types, which blocks register promotion in hot paths.
    _padding: u8 = 0,

    /// The mirroring glyph for this codepoint, or null if it has none.
    /// `cp` must be the codepoint these properties were looked up with.
    pub fn mirroringGlyph(self: BidiProperties, cp: u21) ?u21 {
        if (self.mirror_delta == 0) return null;
        const v: i32 = @as(i32, cp) + @as(i32, self.mirror_delta);
        return std.math.cast(u21, v);
    }

    /// The paired bracket for this codepoint, or null if it is not a paired
    /// bracket. `cp` must be the codepoint these properties were looked up
    /// with.
    pub fn pairedBracket(self: BidiProperties, cp: u21) ?u21 {
        if (self.bracket == .none) return null;
        const v: i32 = @as(i32, cp) + @as(i32, self.bracket_delta);
        return std.math.cast(u21, v);
    }

    // Needed for lut.Generator
    pub fn eql(a: BidiProperties, b: BidiProperties) bool {
        return a.class == b.class and
            a.bracket == b.bracket and
            a.mirrored == b.mirrored and
            a.bracket_delta == b.bracket_delta and
            a.mirror_delta == b.mirror_delta;
    }

    // Needed for lut.Generator
    pub fn format(
        self: BidiProperties,
        writer: *std.Io.Writer,
    ) !void {
        try writer.print(
            \\.{{
            \\    .class= .{s},
            \\    .bracket= .{s},
            \\    .mirrored= {},
            \\    .bracket_delta= {},
            \\    .mirror_delta= {},
            \\}}
        , .{
            @tagName(self.class),
            @tagName(self.bracket),
            self.mirrored,
            self.bracket_delta,
            self.mirror_delta,
        });
    }
};

test "BidiClass predicates" {
    const testing = std.testing;

    try testing.expect(BidiClass.l.isStrong());
    try testing.expect(BidiClass.r.isStrong());
    try testing.expect(BidiClass.al.isStrong());
    try testing.expect(!BidiClass.en.isStrong());
    try testing.expect(!BidiClass.on.isStrong());

    try testing.expect(BidiClass.lri.isIsolateInitiator());
    try testing.expect(BidiClass.rli.isIsolateInitiator());
    try testing.expect(BidiClass.fsi.isIsolateInitiator());
    // PDI terminates an isolate, it does not initiate one.
    try testing.expect(!BidiClass.pdi.isIsolateInitiator());

    try testing.expect(BidiClass.lre.isExplicitFormatting());
    try testing.expect(BidiClass.rlo.isExplicitFormatting());
    try testing.expect(BidiClass.pdf.isExplicitFormatting());
    // Isolates are retained by X9, not explicit formatting.
    try testing.expect(!BidiClass.lri.isExplicitFormatting());
    try testing.expect(!BidiClass.bn.isExplicitFormatting());

    try testing.expect(BidiClass.bn.isRemovedByX9());
    try testing.expect(BidiClass.pdf.isRemovedByX9());
    try testing.expect(!BidiClass.lri.isRemovedByX9());
    try testing.expect(!BidiClass.l.isRemovedByX9());
}

test "BidiProperties delta decoding" {
    const testing = std.testing;

    // U+0028 LEFT PARENTHESIS mirrors to and pairs with U+0029.
    const paren: BidiProperties = .{
        .class = .on,
        .bracket = .open,
        .mirrored = true,
        .bracket_delta = 1,
        .mirror_delta = 1,
    };
    try testing.expectEqual(@as(?u21, 0x0029), paren.mirroringGlyph(0x0028));
    try testing.expectEqual(@as(?u21, 0x0029), paren.pairedBracket(0x0028));

    // Negative deltas.
    const close: BidiProperties = .{
        .class = .on,
        .bracket = .close,
        .mirrored = true,
        .bracket_delta = -1,
        .mirror_delta = -1,
    };
    try testing.expectEqual(@as(?u21, 0x0028), close.mirroringGlyph(0x0029));
    try testing.expectEqual(@as(?u21, 0x0028), close.pairedBracket(0x0029));

    // Mirrored with no designated glyph, e.g. U+2202. `mirrored` must not
    // be inferred from `mirror_delta`.
    const partial: BidiProperties = .{ .class = .on, .mirrored = true };
    try testing.expect(partial.mirrored);
    try testing.expectEqual(@as(?u21, null), partial.mirroringGlyph(0x2202));
    try testing.expectEqual(@as(?u21, null), partial.pairedBracket(0x2202));

    // Plain letter: no mirroring, no bracket.
    const a: BidiProperties = .{ .class = .l };
    try testing.expectEqual(@as(?u21, null), a.mirroringGlyph('a'));
    try testing.expectEqual(@as(?u21, null), a.pairedBracket('a'));
}

test "BidiProperties is a word wide" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 4), @sizeOf(BidiProperties));
    try testing.expectEqual(@as(usize, 32), @bitSizeOf(BidiProperties));
}
