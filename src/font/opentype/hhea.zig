const std = @import("std");
const sfnt = @import("sfnt.zig");

/// Horizontal Header Table
///
/// References:
/// - https://learn.microsoft.com/en-us/typography/opentype/spec/hhea
///
/// Field names are in camelCase to match names in spec.
pub const Hhea = extern struct {
    /// Major version number of the horizontal header table — set to 1.
    majorVersion: sfnt.uint16 align(1),

    /// Minor version number of the horizontal header table — set to 0.
    minorVersion: sfnt.uint16 align(1),

    /// Typographic ascent—see remarks below.
    ascender: sfnt.FWORD align(1),

    /// Typographic descent—see remarks below.
    descender: sfnt.FWORD align(1),

    /// Typographic line gap.
    ///
    /// Negative lineGap values are treated as zero
    /// in some legacy platform implementations.
    lineGap: sfnt.FWORD align(1),

    /// Maximum advance width value in 'hmtx' table.
    advanceWidthMax: sfnt.UFWORD align(1),

    /// Minimum left sidebearing value in 'hmtx' table for
    /// glyphs with contours (empty glyphs should be ignored).
    minLeftSideBearing: sfnt.FWORD align(1),

    /// Minimum right sidebearing value; calculated as
    /// min(aw - (lsb + xMax - xMin)) for glyphs with
    /// contours (empty glyphs should be ignored).
    minRightSideBearing: sfnt.FWORD align(1),

    /// Max(lsb + (xMax - xMin)).
    xMaxExtent: sfnt.FWORD align(1),

    /// Used to calculate the slope of the cursor (rise/run); 1 for vertical.
    caretSlopeRise: sfnt.int16 align(1),

    /// 0 for vertical.
    caretSlopeRun: sfnt.int16 align(1),

    /// The amount by which a slanted highlight on a glyph needs to be shifted
    /// to produce the best appearance. Set to 0 for non-slanted fonts
    caretOffset: sfnt.int16 align(1),

    /// set to 0
    _reserved0: sfnt.int16 align(1),

    /// set to 0
    _reserved1: sfnt.int16 align(1),

    /// set to 0
    _reserved2: sfnt.int16 align(1),

    /// set to 0
    _reserved3: sfnt.int16 align(1),

    /// 0 for current format.
    metricDataFormat: sfnt.int16 align(1),

    /// Number of hMetric entries in 'hmtx' table
    numberOfHMetrics: sfnt.uint16 align(1),

    /// Parse the table from raw data.
    pub fn init(data: []const u8) !Hhea {
        var fbs = std.io.fixedBufferStream(data);
        const reader = fbs.reader();

        return try reader.readStructEndian(Hhea, .big);
    }
};

test "hhea" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const test_font = @import("../embedded.zig").julia_mono;

    const font = try sfnt.SFNT.init(test_font, alloc);
    defer font.deinit(alloc);

    const table = font.getTable("hhea").?;

    const hhea = try Hhea.init(table);

    try testing.expectEqualDeep(
        Hhea{
            .majorVersion = 1,
            .minorVersion = 0,
            .ascender = 1900,
            .descender = -450,
            .lineGap = 0,
            .advanceWidthMax = 1200,
            .minLeftSideBearing = -1000,
            .minRightSideBearing = -1889,
            .xMaxExtent = 3089,
            .caretSlopeRise = 1,
            .caretSlopeRun = 0,
            .caretOffset = 0,
            ._reserved0 = 0,
            ._reserved1 = 0,
            ._reserved2 = 0,
            ._reserved3 = 0,
            .metricDataFormat = 0,
            .numberOfHMetrics = 2,
        },
        hhea,
    );
}
