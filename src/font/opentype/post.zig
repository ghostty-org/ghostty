const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const sfnt = @import("sfnt.zig");

/// PostScript Table
///
/// This implementation doesn't parse the
/// extra fields in versions 2.0 and 2.5.
///
/// References:
/// - https://learn.microsoft.com/en-us/typography/opentype/spec/post
///
/// Field names are in camelCase to match names in spec.
pub const Post = extern struct {
    version: sfnt.Version16Dot16 align(1),

    /// Italic angle in counter-clockwise degrees from the vertical.
    /// Zero for upright text, negative for text that leans to the
    /// right (forward).
    italicAngle: sfnt.Fixed align(1),

    /// Suggested y-coordinate of the top of the underline.
    underlinePosition: sfnt.FWORD align(1),

    /// Suggested values for the underline thickness.
    /// In general, the underline thickness should match the thickness of
    /// the underscore character (U+005F LOW LINE), and should also match
    /// the strikeout thickness, which is specified in the OS/2 table.
    underlineThickness: sfnt.FWORD align(1),

    /// Set to 0 if the font is proportionally spaced, non-zero if
    /// the font is not proportionally spaced (i.e. monospaced).
    isFixedPitch: sfnt.uint32 align(1),

    /// Minimum memory usage when an OpenType font is downloaded.
    minMemType42: sfnt.uint32 align(1),

    /// Maximum memory usage when an OpenType font is downloaded.
    maxMemType42: sfnt.uint32 align(1),

    /// Minimum memory usage when an OpenType
    /// font is downloaded as a Type 1 font.
    minMemType1: sfnt.uint32 align(1),

    /// Maximum memory usage when an OpenType
    /// font is downloaded as a Type 1 font.
    maxMemType1: sfnt.uint32 align(1),

    /// Parse the table from raw data.
    pub fn init(data: []const u8) error{EndOfStream}!Post {
        var fbs = std.io.fixedBufferStream(data);
        const reader = fbs.reader();
        return try reader.readStructEndian(Post, .big);
    }
};

test "post" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const test_font = @import("../embedded.zig").julia_mono;

    const font = try sfnt.SFNT.init(test_font, alloc);
    defer font.deinit(alloc);

    const table = font.getTable("post").?;

    const post = try Post.init(table);

    try testing.expectEqualDeep(
        Post{
            .version = sfnt.Version16Dot16{ .minor = 0, .major = 2 },
            .italicAngle = sfnt.Fixed.from(0.0),
            .underlinePosition = -200,
            .underlineThickness = 100,
            .isFixedPitch = 1,
            .minMemType42 = 0,
            .maxMemType42 = 0,
            .minMemType1 = 0,
            .maxMemType1 = 0,
        },
        post,
    );
}
