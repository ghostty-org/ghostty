const std = @import("std");
const sfnt = @import("sfnt.zig");

/// Font Header Table
///
/// References:
/// - https://learn.microsoft.com/en-us/typography/opentype/spec/head
///
/// Field names are in camelCase to match names in spec.
pub const Head = extern struct {
    /// Major version number of the font header table — set to 1.
    majorVersion: sfnt.uint16 align(1),

    /// Minor version number of the font header table — set to 0.
    minorVersion: sfnt.uint16 align(1),

    /// Set by font manufacturer.
    fontRevision: sfnt.Fixed align(1),

    /// To compute: set it to 0, sum the entire font as uint32, then store
    /// 0xB1B0AFBA - sum. If the font is used as a component in a font
    /// collection file, the value of this field will be invalidated by
    /// changes to the file structure and font table directory, and must
    /// be ignored.
    checksumAdjustment: sfnt.uint32 align(1),

    /// Set to 0x5F0F3CF5.
    magicNumber: sfnt.uint32 align(1),

    /// Bit 0: Baseline for font at y=0.
    ///
    /// Bit 1: Left sidebearing point at x=0
    ///        (relevant only for TrueType rasterizers)
    ///
    /// Bit 2: Instructions may depend on point size.
    ///
    /// Bit 3: Force ppem to integer values for all internal scaler math; may
    ///        use fractional ppem sizes if this bit is clear. It is strongly
    ///        recommended that this be set in hinted fonts.
    ///
    /// Bit 4: Instructions may alter advance width
    ///        (the advance widths might not scale linearly).
    ///
    /// Bit 5: This bit is not used in OpenType, and should not be set in order
    ///        to ensure compatible behavior on all platforms. If set, it may
    ///        result in different behavior for vertical layout in some
    ///        platforms.
    ///
    ///        (See Apple’s specification for details
    ///        regarding behavior in Apple platforms.)
    ///
    /// Bits 6 – 10: These bits are not used in OpenType and should always be
    ///              cleared.
    ///
    ///              (See Apple’s specification for details
    ///              regarding legacy use in Apple platforms.)
    ///
    /// Bit 11: Font data is “lossless” as a result of having been
    ///         subjected to optimizing transformation and/or compression
    ///         (such as compression mechanisms defined by ISO/IEC 14496-18,
    ///         MicroType® Express, WOFF 2.0, or similar) where the original
    ///         font functionality and features are retained but the binary
    ///         compatibility between input and output font files is not
    ///         guaranteed. As a result of the applied transform, the DSIG
    ///         table may also be invalidated.
    ///
    /// Bit 12: Font converted (produce compatible metrics).
    ///
    /// Bit 13: Font optimized for ClearType®. Note, fonts that rely on embedded
    ///         bitmaps (EBDT) for rendering should not be considered optimized
    ///         for ClearType, and therefore should keep this bit cleared.
    ///
    /// Bit 14: Last Resort font. If set, indicates that the glyphs encoded in
    ///         the 'cmap' subtables are simply generic symbolic representations
    ///         of code point ranges and do not truly represent support for
    ///         those code points. If unset, indicates that the glyphs encoded
    ///         in the 'cmap' subtables represent proper support for those code
    ///         points.
    ///
    /// Bit 15: Reserved, set to 0.
    flags: sfnt.uint16 align(1),

    /// Set to a value from 16 to 16384. Any value in this range is valid.
    ///
    /// In fonts that have TrueType outlines, a power of 2 is recommended
    /// as this allows performance optimization in some rasterizers.
    unitsPerEm: sfnt.uint16 align(1),

    /// Number of seconds since 12:00 midnight that started
    /// January 1st, 1904, in GMT/UTC time zone.
    created: sfnt.LONGDATETIME align(1),

    /// Number of seconds since 12:00 midnight that started
    /// January 1st, 1904, in GMT/UTC time zone.
    modified: sfnt.LONGDATETIME align(1),

    /// Minimum x coordinate across all glyph bounding boxes.
    xMin: sfnt.int16 align(1),

    /// Minimum y coordinate across all glyph bounding boxes.
    yMin: sfnt.int16 align(1),

    /// Maximum x coordinate across all glyph bounding boxes.
    xMax: sfnt.int16 align(1),

    /// Maximum y coordinate across all glyph bounding boxes.
    yMax: sfnt.int16 align(1),

    /// Bit 0: Bold (if set to 1);
    /// Bit 1: Italic (if set to 1)
    /// Bit 2: Underline (if set to 1)
    /// Bit 3: Outline (if set to 1)
    /// Bit 4: Shadow (if set to 1)
    /// Bit 5: Condensed (if set to 1)
    /// Bit 6: Extended (if set to 1)
    /// Bits 7 – 15: Reserved (set to 0).
    macStyle: sfnt.uint16 align(1),

    /// Smallest readable size in pixels.
    lowestRecPPEM: sfnt.uint16 align(1),

    /// Deprecated (Set to 2).
    /// 0: Fully mixed directional glyphs;
    /// 1: Only strongly left to right;
    /// 2: Like 1 but also contains neutrals;
    /// -1: Only strongly right to left;
    /// -2: Like -1 but also contains neutrals.
    fontDirectionHint: sfnt.int16 align(1),

    /// 0 for short offsets (Offset16), 1 for long (Offset32).
    indexToLocFormat: sfnt.int16 align(1),

    /// 0 for current format.
    glyphDataFormat: sfnt.int16 align(1),

    /// Parse the table from raw data.
    pub fn init(data: []const u8) error{EndOfStream}!Head {
        var fbs = std.io.fixedBufferStream(data);
        const reader = fbs.reader();
        return try reader.readStructEndian(Head, .big);
    }
};

test "head" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const test_font = @import("../embedded.zig").julia_mono;

    const font = try sfnt.SFNT.init(test_font, alloc);
    defer font.deinit(alloc);

    const table = font.getTable("head").?;

    const head = try Head.init(table);

    try testing.expectEqualDeep(
        Head{
            .majorVersion = 1,
            .minorVersion = 0,
            .fontRevision = sfnt.Fixed.from(0.05499267578125),
            .checksumAdjustment = 1007668681,
            .magicNumber = 1594834165,
            .flags = 7,
            .unitsPerEm = 2000,
            .created = 3797757830,
            .modified = 3797760444,
            .xMin = -1000,
            .yMin = -1058,
            .xMax = 3089,
            .yMax = 2400,
            .macStyle = 0,
            .lowestRecPPEM = 7,
            .fontDirectionHint = 2,
            .indexToLocFormat = 1,
            .glyphDataFormat = 0,
        },
        head,
    );
}
