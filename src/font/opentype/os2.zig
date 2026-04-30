const std = @import("std");
const sfnt = @import("sfnt.zig");

pub const FSSelection = packed struct(sfnt.uint16) {
    /// Font contains italic or oblique glyphs, otherwise they are upright.
    italic: bool = false,

    /// Glyphs are underscored.
    underscore: bool = false,

    /// Glyphs have their foreground and background reversed.
    negative: bool = false,

    /// Outline (hollow) glyphs, otherwise they are solid.
    outlined: bool = false,

    /// Glyphs are overstruck.
    strikeout: bool = false,

    /// Glyphs are emboldened.
    bold: bool = false,

    /// Glyphs are in the standard weight/style for the font.
    regular: bool = false,

    /// If set, it is strongly recommended that applications use
    /// OS/2.sTypoAscender - OS/2.sTypoDescender + OS/2.sTypoLineGap
    /// as the default line spacing for this font.
    use_typo_metrics: bool = false,

    /// The font has 'name' table strings consistent with a weight/width/slope
    /// family without requiring use of name IDs 21 and 22.
    wws: bool = false,

    /// Font contains oblique glyphs.
    oblique: bool = false,

    _reserved: u6 = 0,
};

/// OS/2 and Windows Metrics Table
///
/// References:
/// - https://learn.microsoft.com/en-us/typography/opentype/spec/os2
///
/// Field names are in camelCase to match names in spec.
pub const OS2v5 = extern struct {
    version: sfnt.uint16 align(1),
    xAvgCharWidth: sfnt.FWORD align(1),
    usWeightClass: sfnt.uint16 align(1),
    usWidthClass: sfnt.uint16 align(1),
    fsType: sfnt.uint16 align(1),
    ySubscriptXSize: sfnt.FWORD align(1),
    ySubscriptYSize: sfnt.FWORD align(1),
    ySubscriptXOffset: sfnt.FWORD align(1),
    ySubscriptYOffset: sfnt.FWORD align(1),
    ySuperscriptXSize: sfnt.FWORD align(1),
    ySuperscriptYSize: sfnt.FWORD align(1),
    ySuperscriptXOffset: sfnt.FWORD align(1),
    ySuperscriptYOffset: sfnt.FWORD align(1),
    yStrikeoutSize: sfnt.FWORD align(1),
    yStrikeoutPosition: sfnt.FWORD align(1),
    sFamilyClass: sfnt.int16 align(1),
    panose: [10]sfnt.uint8 align(1),
    ulUnicodeRange1: sfnt.uint32 align(1),
    ulUnicodeRange2: sfnt.uint32 align(1),
    ulUnicodeRange3: sfnt.uint32 align(1),
    ulUnicodeRange4: sfnt.uint32 align(1),
    achVendID: sfnt.Tag align(1),
    fsSelection: FSSelection align(1),
    usFirstCharIndex: sfnt.uint16 align(1),
    usLastCharIndex: sfnt.uint16 align(1),
    sTypoAscender: sfnt.FWORD align(1),
    sTypoDescender: sfnt.FWORD align(1),
    sTypoLineGap: sfnt.FWORD align(1),
    usWinAscent: sfnt.UFWORD align(1),
    usWinDescent: sfnt.UFWORD align(1),
    ulCodePageRange1: sfnt.uint32 align(1),
    ulCodePageRange2: sfnt.uint32 align(1),
    sxHeight: sfnt.FWORD align(1),
    sCapHeight: sfnt.FWORD align(1),
    usDefaultChar: sfnt.uint16 align(1),
    usBreakChar: sfnt.uint16 align(1),
    usMaxContext: sfnt.uint16 align(1),
    usLowerOpticalPointSize: sfnt.uint16 align(1),
    usUpperOpticalPointSize: sfnt.uint16 align(1),
};

pub const OS2v4_3_2 = extern struct {
    version: sfnt.uint16 align(1),
    xAvgCharWidth: sfnt.FWORD align(1),
    usWeightClass: sfnt.uint16 align(1),
    usWidthClass: sfnt.uint16 align(1),
    fsType: sfnt.uint16 align(1),
    ySubscriptXSize: sfnt.FWORD align(1),
    ySubscriptYSize: sfnt.FWORD align(1),
    ySubscriptXOffset: sfnt.FWORD align(1),
    ySubscriptYOffset: sfnt.FWORD align(1),
    ySuperscriptXSize: sfnt.FWORD align(1),
    ySuperscriptYSize: sfnt.FWORD align(1),
    ySuperscriptXOffset: sfnt.FWORD align(1),
    ySuperscriptYOffset: sfnt.FWORD align(1),
    yStrikeoutSize: sfnt.FWORD align(1),
    yStrikeoutPosition: sfnt.FWORD align(1),
    sFamilyClass: sfnt.int16 align(1),
    panose: [10]sfnt.uint8 align(1),
    ulUnicodeRange1: sfnt.uint32 align(1),
    ulUnicodeRange2: sfnt.uint32 align(1),
    ulUnicodeRange3: sfnt.uint32 align(1),
    ulUnicodeRange4: sfnt.uint32 align(1),
    achVendID: sfnt.Tag align(1),
    fsSelection: FSSelection align(1),
    usFirstCharIndex: sfnt.uint16 align(1),
    usLastCharIndex: sfnt.uint16 align(1),
    sTypoAscender: sfnt.FWORD align(1),
    sTypoDescender: sfnt.FWORD align(1),
    sTypoLineGap: sfnt.FWORD align(1),
    usWinAscent: sfnt.UFWORD align(1),
    usWinDescent: sfnt.UFWORD align(1),
    ulCodePageRange1: sfnt.uint32 align(1),
    ulCodePageRange2: sfnt.uint32 align(1),
    sxHeight: sfnt.FWORD align(1),
    sCapHeight: sfnt.FWORD align(1),
    usDefaultChar: sfnt.uint16 align(1),
    usBreakChar: sfnt.uint16 align(1),
    usMaxContext: sfnt.uint16 align(1),
};

pub const OS2v1 = extern struct {
    version: sfnt.uint16 align(1),
    xAvgCharWidth: sfnt.FWORD align(1),
    usWeightClass: sfnt.uint16 align(1),
    usWidthClass: sfnt.uint16 align(1),
    fsType: sfnt.uint16 align(1),
    ySubscriptXSize: sfnt.FWORD align(1),
    ySubscriptYSize: sfnt.FWORD align(1),
    ySubscriptXOffset: sfnt.FWORD align(1),
    ySubscriptYOffset: sfnt.FWORD align(1),
    ySuperscriptXSize: sfnt.FWORD align(1),
    ySuperscriptYSize: sfnt.FWORD align(1),
    ySuperscriptXOffset: sfnt.FWORD align(1),
    ySuperscriptYOffset: sfnt.FWORD align(1),
    yStrikeoutSize: sfnt.FWORD align(1),
    yStrikeoutPosition: sfnt.FWORD align(1),
    sFamilyClass: sfnt.int16 align(1),
    panose: [10]sfnt.uint8 align(1),
    ulUnicodeRange1: sfnt.uint32 align(1),
    ulUnicodeRange2: sfnt.uint32 align(1),
    ulUnicodeRange3: sfnt.uint32 align(1),
    ulUnicodeRange4: sfnt.uint32 align(1),
    achVendID: sfnt.Tag align(1),
    fsSelection: FSSelection align(1),
    usFirstCharIndex: sfnt.uint16 align(1),
    usLastCharIndex: sfnt.uint16 align(1),
    sTypoAscender: sfnt.FWORD align(1),
    sTypoDescender: sfnt.FWORD align(1),
    sTypoLineGap: sfnt.FWORD align(1),
    usWinAscent: sfnt.UFWORD align(1),
    usWinDescent: sfnt.UFWORD align(1),
    ulCodePageRange1: sfnt.uint32 align(1),
    ulCodePageRange2: sfnt.uint32 align(1),
};

pub const OS2v0 = extern struct {
    version: sfnt.uint16 align(1),
    xAvgCharWidth: sfnt.FWORD align(1),
    usWeightClass: sfnt.uint16 align(1),
    usWidthClass: sfnt.uint16 align(1),
    fsType: sfnt.uint16 align(1),
    ySubscriptXSize: sfnt.FWORD align(1),
    ySubscriptYSize: sfnt.FWORD align(1),
    ySubscriptXOffset: sfnt.FWORD align(1),
    ySubscriptYOffset: sfnt.FWORD align(1),
    ySuperscriptXSize: sfnt.FWORD align(1),
    ySuperscriptYSize: sfnt.FWORD align(1),
    ySuperscriptXOffset: sfnt.FWORD align(1),
    ySuperscriptYOffset: sfnt.FWORD align(1),
    yStrikeoutSize: sfnt.FWORD align(1),
    yStrikeoutPosition: sfnt.FWORD align(1),
    sFamilyClass: sfnt.int16 align(1),
    panose: [10]sfnt.uint8 align(1),
    ulUnicodeRange1: sfnt.uint32 align(1),
    ulUnicodeRange2: sfnt.uint32 align(1),
    ulUnicodeRange3: sfnt.uint32 align(1),
    ulUnicodeRange4: sfnt.uint32 align(1),
    achVendID: sfnt.Tag align(1),
    fsSelection: FSSelection align(1),
    usFirstCharIndex: sfnt.uint16 align(1),
    usLastCharIndex: sfnt.uint16 align(1),
    sTypoAscender: sfnt.FWORD align(1),
    sTypoDescender: sfnt.FWORD align(1),
    sTypoLineGap: sfnt.FWORD align(1),
    usWinAscent: sfnt.UFWORD align(1),
    usWinDescent: sfnt.UFWORD align(1),
};

/// Generic OS/2 table with optional fields
/// for those that don't exist in all versions.
///
/// References:
/// - https://learn.microsoft.com/en-us/typography/opentype/spec/os2
///
/// Field names are in camelCase to match names in spec.
pub const OS2 = struct {
    /// The version number for the OS/2 table: 0x0000 to 0x0005.
    ///
    /// https://learn.microsoft.com/en-us/typography/opentype/spec/os2#version
    version: u16,
    /// The Average Character Width field specifies the arithmetic average of the escapement (width) of all non-zero width glyphs in the font.
    ///
    /// https://learn.microsoft.com/en-us/typography/opentype/spec/os2/#xavgcharwidth
    xAvgCharWidth: i16,
    /// Indicates the visual weight (degree of blackness or thickness of strokes) of the characters in the font. Values from 1 to 1000 are valid.
    ///
    /// https://learn.microsoft.com/en-us/typography/opentype/spec/os2/#usweightclass
    usWeightClass: u16,
    /// Indicates a relative change from the normal aspect ratio (width to height ratio) as specified by a font designer for the glyphs in a font.
    ///
    /// https://learn.microsoft.com/en-us/typography/opentype/spec/os2/#uswidthclass
    usWidthClass: u16,
    /// Indicates font embedding licensing rights for the font.
    ///
    /// https://learn.microsoft.com/en-us/typography/opentype/spec/os2/#fstype
    fsType: u16,
    /// The recommended horizontal size in font design units for subscripts for this font.
    ///
    /// https://learn.microsoft.com/en-us/typography/opentype/spec/os2/#ysubscriptxsize
    ySubscriptXSize: i16,
    /// The recommended vertical size in font design units for subscripts for this font.
    ///
    /// https://learn.microsoft.com/en-us/typography/opentype/spec/os2/#ysubscriptysize
    ySubscriptYSize: i16,
    /// The recommended horizontal offset in font design units for subscripts for this font.
    ///
    /// https://learn.microsoft.com/en-us/typography/opentype/spec/os2/#ysubscriptxoffset
    ySubscriptXOffset: i16,
    /// The recommended vertical offset in font design units from the baseline for subscripts for this font.
    ///
    /// https://learn.microsoft.com/en-us/typography/opentype/spec/os2/#ysubscriptyoffset
    ySubscriptYOffset: i16,
    /// The recommended horizontal size in font design units for superscripts for this font.
    ///
    /// https://learn.microsoft.com/en-us/typography/opentype/spec/os2/#ysuperscriptxsize
    ySuperscriptXSize: i16,
    /// The recommended vertical size in font design units for superscripts for this font.
    ///
    /// https://learn.microsoft.com/en-us/typography/opentype/spec/os2/#ysuperscriptysize
    ySuperscriptYSize: i16,
    /// The recommended horizontal offset in font design units for superscripts for this font.
    ///
    /// https://learn.microsoft.com/en-us/typography/opentype/spec/os2/#ysuperscriptxoffset
    ySuperscriptXOffset: i16,
    /// The recommended vertical offset in font design units from the baseline for superscripts for this font.
    ///
    /// https://learn.microsoft.com/en-us/typography/opentype/spec/os2/#ysuperscriptyoffset
    ySuperscriptYOffset: i16,
    /// Thickness of the strikeout stroke in font design units. Should be > 0.
    ///
    /// https://learn.microsoft.com/en-us/typography/opentype/spec/os2/#ystrikeoutsize
    yStrikeoutSize: i16,
    /// The position of the top of the strikeout stroke relative to the baseline in font design units.
    ///
    /// https://learn.microsoft.com/en-us/typography/opentype/spec/os2/#ystrikeoutposition
    yStrikeoutPosition: i16,
    /// This field provides a classification of font-family design.
    ///
    /// https://learn.microsoft.com/en-us/typography/opentype/spec/os2/#sfamilyclass
    sFamilyClass: i16,
    /// This 10-byte array of numbers is used to describe the visual characteristics of a given typeface.
    ///
    /// https://learn.microsoft.com/en-us/typography/opentype/spec/os2/#panose
    panose: [10]u8,
    /// https://learn.microsoft.com/en-us/typography/opentype/spec/os2/#ulunicoderange
    ulUnicodeRange1: u32,
    /// https://learn.microsoft.com/en-us/typography/opentype/spec/os2/#ulunicoderange
    ulUnicodeRange2: u32,
    /// https://learn.microsoft.com/en-us/typography/opentype/spec/os2/#ulunicoderange
    ulUnicodeRange3: u32,
    /// https://learn.microsoft.com/en-us/typography/opentype/spec/os2/#ulunicoderange
    ulUnicodeRange4: u32,
    /// The four character identifier for the vendor of the given type face.
    ///
    /// https://learn.microsoft.com/en-us/typography/opentype/spec/os2/#achvendid
    achVendID: [4]u8,
    /// Contains information concerning the nature of the font patterns.
    ///
    /// https://learn.microsoft.com/en-us/typography/opentype/spec/os2/#fsselection
    fsSelection: FSSelection,
    /// The minimum Unicode index (character code) in this font, according to the 'cmap' subtable for platform ID 3 and platform-specific encoding ID 0 or 1.
    ///
    /// https://learn.microsoft.com/en-us/typography/opentype/spec/os2/#usfirstcharindex
    usFirstCharIndex: u16,
    /// The maximum Unicode index (character code) in this font, according to the 'cmap' subtable for platform ID 3 and encoding ID 0 or 1.
    ///
    /// https://learn.microsoft.com/en-us/typography/opentype/spec/os2/#uslastcharindex
    usLastCharIndex: u16,
    /// The typographic ascender for this font. This field should be combined with the sTypoDescender and sTypoLineGap values to determine default line spacing.
    ///
    /// https://learn.microsoft.com/en-us/typography/opentype/spec/os2/#stypoascender
    sTypoAscender: i16,
    /// The typographic descender for this font. This field should be combined with the sTypoAscender and sTypoLineGap values to determine default line spacing.
    ///
    /// https://learn.microsoft.com/en-us/typography/opentype/spec/os2/#stypodescender
    sTypoDescender: i16,
    /// The typographic line gap for this font. This field should be combined with the sTypoAscender and sTypoDescender values to determine default line spacing.
    ///
    /// https://learn.microsoft.com/en-us/typography/opentype/spec/os2/#stypolinegap
    sTypoLineGap: i16,
    /// The “Windows ascender” metric. This should be used to specify the height above the baseline for a clipping region.
    ///
    /// https://learn.microsoft.com/en-us/typography/opentype/spec/os2/#uswinascent
    usWinAscent: u16,
    /// The “Windows descender” metric. This should be used to specify the vertical extent below the baseline for a clipping region.
    ///
    /// https://learn.microsoft.com/en-us/typography/opentype/spec/os2/#uswindescent
    usWinDescent: u16,
    /// https://learn.microsoft.com/en-us/typography/opentype/spec/os2/#ulcodepagerange
    ulCodePageRange1: ?u32 = null,
    /// https://learn.microsoft.com/en-us/typography/opentype/spec/os2/#ulcodepagerange
    ulCodePageRange2: ?u32 = null,
    /// This metric specifies the distance between the baseline and the approximate height of non-ascending lowercase letters measured in font design units.
    ///
    /// https://learn.microsoft.com/en-us/typography/opentype/spec/os2/#sxheight
    sxHeight: ?i16 = null,
    /// This metric specifies the distance between the baseline and the approximate height of uppercase letters measured in font design units.
    ///
    /// https://learn.microsoft.com/en-us/typography/opentype/spec/os2/#scapheight
    sCapHeight: ?i16 = null,
    /// This is the Unicode code point, in UTF-16 encoding, of a character that can be used for a default glyph if a requested character is not supported in the font.
    ///
    /// https://learn.microsoft.com/en-us/typography/opentype/spec/os2/#usdefaultchar
    usDefaultChar: ?u16 = null,
    /// This is the Unicode code point, in UTF-16 encoding, of a character that can be used as a default break character.
    ///
    /// https://learn.microsoft.com/en-us/typography/opentype/spec/os2/#usbreakchar
    usBreakChar: ?u16 = null,
    /// The maximum length of a target glyph context for any feature in this font. For example, a font which has only a pair kerning feature should set this field to 2.
    ///
    /// https://learn.microsoft.com/en-us/typography/opentype/spec/os2/#usmaxcontext
    usMaxContext: ?u16 = null,
    /// This field is used for fonts with multiple optical styles.
    ///
    /// https://learn.microsoft.com/en-us/typography/opentype/spec/os2/#usloweropticalpointsize
    usLowerOpticalPointSize: ?u16 = null,
    /// This field is used for fonts with multiple optical styles.
    ///
    /// https://learn.microsoft.com/en-us/typography/opentype/spec/os2/#usupperopticalpointsize
    usUpperOpticalPointSize: ?u16 = null,

    /// Parse the table from raw data.
    pub fn init(data: []const u8) error{
        EndOfStream,
        OS2VersionNotSupported,
    }!OS2 {
        var fbs = std.io.fixedBufferStream(data);
        const reader = fbs.reader();

        const version = try reader.readInt(sfnt.uint16, .big);

        // Return to the start, cause the version is part of the struct.
        try fbs.seekTo(0);

        switch (version) {
            5 => {
                const table = try reader.readStructEndian(OS2v5, .big);
                return .{
                    .version = table.version,
                    .xAvgCharWidth = table.xAvgCharWidth,
                    .usWeightClass = table.usWeightClass,
                    .usWidthClass = table.usWidthClass,
                    .fsType = table.fsType,
                    .ySubscriptXSize = table.ySubscriptXSize,
                    .ySubscriptYSize = table.ySubscriptYSize,
                    .ySubscriptXOffset = table.ySubscriptXOffset,
                    .ySubscriptYOffset = table.ySubscriptYOffset,
                    .ySuperscriptXSize = table.ySuperscriptXSize,
                    .ySuperscriptYSize = table.ySuperscriptYSize,
                    .ySuperscriptXOffset = table.ySuperscriptXOffset,
                    .ySuperscriptYOffset = table.ySuperscriptYOffset,
                    .yStrikeoutSize = table.yStrikeoutSize,
                    .yStrikeoutPosition = table.yStrikeoutPosition,
                    .sFamilyClass = table.sFamilyClass,
                    .panose = table.panose,
                    .ulUnicodeRange1 = table.ulUnicodeRange1,
                    .ulUnicodeRange2 = table.ulUnicodeRange2,
                    .ulUnicodeRange3 = table.ulUnicodeRange3,
                    .ulUnicodeRange4 = table.ulUnicodeRange4,
                    .achVendID = table.achVendID,
                    .fsSelection = table.fsSelection,
                    .usFirstCharIndex = table.usFirstCharIndex,
                    .usLastCharIndex = table.usLastCharIndex,
                    .sTypoAscender = table.sTypoAscender,
                    .sTypoDescender = table.sTypoDescender,
                    .sTypoLineGap = table.sTypoLineGap,
                    .usWinAscent = table.usWinAscent,
                    .usWinDescent = table.usWinDescent,
                    .ulCodePageRange1 = table.ulCodePageRange1,
                    .ulCodePageRange2 = table.ulCodePageRange2,
                    .sxHeight = table.sxHeight,
                    .sCapHeight = table.sCapHeight,
                    .usDefaultChar = table.usDefaultChar,
                    .usBreakChar = table.usBreakChar,
                    .usMaxContext = table.usMaxContext,
                    .usLowerOpticalPointSize = table.usLowerOpticalPointSize,
                    .usUpperOpticalPointSize = table.usUpperOpticalPointSize,
                };
            },
            4, 3, 2 => {
                const table = try reader.readStructEndian(OS2v4_3_2, .big);
                return .{
                    .version = table.version,
                    .xAvgCharWidth = table.xAvgCharWidth,
                    .usWeightClass = table.usWeightClass,
                    .usWidthClass = table.usWidthClass,
                    .fsType = table.fsType,
                    .ySubscriptXSize = table.ySubscriptXSize,
                    .ySubscriptYSize = table.ySubscriptYSize,
                    .ySubscriptXOffset = table.ySubscriptXOffset,
                    .ySubscriptYOffset = table.ySubscriptYOffset,
                    .ySuperscriptXSize = table.ySuperscriptXSize,
                    .ySuperscriptYSize = table.ySuperscriptYSize,
                    .ySuperscriptXOffset = table.ySuperscriptXOffset,
                    .ySuperscriptYOffset = table.ySuperscriptYOffset,
                    .yStrikeoutSize = table.yStrikeoutSize,
                    .yStrikeoutPosition = table.yStrikeoutPosition,
                    .sFamilyClass = table.sFamilyClass,
                    .panose = table.panose,
                    .ulUnicodeRange1 = table.ulUnicodeRange1,
                    .ulUnicodeRange2 = table.ulUnicodeRange2,
                    .ulUnicodeRange3 = table.ulUnicodeRange3,
                    .ulUnicodeRange4 = table.ulUnicodeRange4,
                    .achVendID = table.achVendID,
                    .fsSelection = table.fsSelection,
                    .usFirstCharIndex = table.usFirstCharIndex,
                    .usLastCharIndex = table.usLastCharIndex,
                    .sTypoAscender = table.sTypoAscender,
                    .sTypoDescender = table.sTypoDescender,
                    .sTypoLineGap = table.sTypoLineGap,
                    .usWinAscent = table.usWinAscent,
                    .usWinDescent = table.usWinDescent,
                    .ulCodePageRange1 = table.ulCodePageRange1,
                    .ulCodePageRange2 = table.ulCodePageRange2,
                    .sxHeight = table.sxHeight,
                    .sCapHeight = table.sCapHeight,
                    .usDefaultChar = table.usDefaultChar,
                    .usBreakChar = table.usBreakChar,
                    .usMaxContext = table.usMaxContext,
                };
            },
            1 => {
                const table = try reader.readStructEndian(OS2v1, .big);
                return .{
                    .version = table.version,
                    .xAvgCharWidth = table.xAvgCharWidth,
                    .usWeightClass = table.usWeightClass,
                    .usWidthClass = table.usWidthClass,
                    .fsType = table.fsType,
                    .ySubscriptXSize = table.ySubscriptXSize,
                    .ySubscriptYSize = table.ySubscriptYSize,
                    .ySubscriptXOffset = table.ySubscriptXOffset,
                    .ySubscriptYOffset = table.ySubscriptYOffset,
                    .ySuperscriptXSize = table.ySuperscriptXSize,
                    .ySuperscriptYSize = table.ySuperscriptYSize,
                    .ySuperscriptXOffset = table.ySuperscriptXOffset,
                    .ySuperscriptYOffset = table.ySuperscriptYOffset,
                    .yStrikeoutSize = table.yStrikeoutSize,
                    .yStrikeoutPosition = table.yStrikeoutPosition,
                    .sFamilyClass = table.sFamilyClass,
                    .panose = table.panose,
                    .ulUnicodeRange1 = table.ulUnicodeRange1,
                    .ulUnicodeRange2 = table.ulUnicodeRange2,
                    .ulUnicodeRange3 = table.ulUnicodeRange3,
                    .ulUnicodeRange4 = table.ulUnicodeRange4,
                    .achVendID = table.achVendID,
                    .fsSelection = table.fsSelection,
                    .usFirstCharIndex = table.usFirstCharIndex,
                    .usLastCharIndex = table.usLastCharIndex,
                    .sTypoAscender = table.sTypoAscender,
                    .sTypoDescender = table.sTypoDescender,
                    .sTypoLineGap = table.sTypoLineGap,
                    .usWinAscent = table.usWinAscent,
                    .usWinDescent = table.usWinDescent,
                    .ulCodePageRange1 = table.ulCodePageRange1,
                    .ulCodePageRange2 = table.ulCodePageRange2,
                };
            },
            0 => {
                const table = try reader.readStructEndian(OS2v0, .big);
                return .{
                    .version = table.version,
                    .xAvgCharWidth = table.xAvgCharWidth,
                    .usWeightClass = table.usWeightClass,
                    .usWidthClass = table.usWidthClass,
                    .fsType = table.fsType,
                    .ySubscriptXSize = table.ySubscriptXSize,
                    .ySubscriptYSize = table.ySubscriptYSize,
                    .ySubscriptXOffset = table.ySubscriptXOffset,
                    .ySubscriptYOffset = table.ySubscriptYOffset,
                    .ySuperscriptXSize = table.ySuperscriptXSize,
                    .ySuperscriptYSize = table.ySuperscriptYSize,
                    .ySuperscriptXOffset = table.ySuperscriptXOffset,
                    .ySuperscriptYOffset = table.ySuperscriptYOffset,
                    .yStrikeoutSize = table.yStrikeoutSize,
                    .yStrikeoutPosition = table.yStrikeoutPosition,
                    .sFamilyClass = table.sFamilyClass,
                    .panose = table.panose,
                    .ulUnicodeRange1 = table.ulUnicodeRange1,
                    .ulUnicodeRange2 = table.ulUnicodeRange2,
                    .ulUnicodeRange3 = table.ulUnicodeRange3,
                    .ulUnicodeRange4 = table.ulUnicodeRange4,
                    .achVendID = table.achVendID,
                    .fsSelection = table.fsSelection,
                    .usFirstCharIndex = table.usFirstCharIndex,
                    .usLastCharIndex = table.usLastCharIndex,
                    .sTypoAscender = table.sTypoAscender,
                    .sTypoDescender = table.sTypoDescender,
                    .sTypoLineGap = table.sTypoLineGap,
                    .usWinAscent = table.usWinAscent,
                    .usWinDescent = table.usWinDescent,
                };
            },
            else => return error.OS2VersionNotSupported,
        }
    }
};

test "OS/2" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const test_font = @import("../embedded.zig").julia_mono;

    const font = try sfnt.SFNT.init(test_font, alloc);
    defer font.deinit(alloc);

    const table = font.getTable("OS/2").?;

    const os2 = try OS2.init(table);

    try testing.expectEqualDeep(OS2{
        .version = 4,
        .xAvgCharWidth = 1200,
        .usWeightClass = 400,
        .usWidthClass = 5,
        .fsType = 0,
        .ySubscriptXSize = 1300,
        .ySubscriptYSize = 1200,
        .ySubscriptXOffset = 0,
        .ySubscriptYOffset = 150,
        .ySuperscriptXSize = 1300,
        .ySuperscriptYSize = 1200,
        .ySuperscriptXOffset = 0,
        .ySuperscriptYOffset = 700,
        .yStrikeoutSize = 100,
        .yStrikeoutPosition = 550,
        .sFamilyClass = 0,
        .panose = .{ 2, 11, 6, 9, 6, 3, 0, 2, 0, 4 },
        .ulUnicodeRange1 = 3843162111,
        .ulUnicodeRange2 = 3603300351,
        .ulUnicodeRange3 = 117760229,
        .ulUnicodeRange4 = 96510060,
        .achVendID = "corm".*,
        .fsSelection = .{
            .regular = true,
            .use_typo_metrics = true,
        },
        .usFirstCharIndex = 13,
        .usLastCharIndex = 65535,
        .sTypoAscender = 1900,
        .sTypoDescender = -450,
        .sTypoLineGap = 0,
        .usWinAscent = 2400,
        .usWinDescent = 450,
        .ulCodePageRange1 = 1613234687,
        .ulCodePageRange2 = 0,
        .sxHeight = 1100,
        .sCapHeight = 1450,
        .usDefaultChar = 0,
        .usBreakChar = 32,
        .usMaxContext = 126,
        .usLowerOpticalPointSize = null,
        .usUpperOpticalPointSize = null,
    }, os2);
}
