//! Snapshot style entry encoding.
//!
//! Each entry describes one terminal style. A record can use these entries to
//! build a style table and assign indexes according to that record's format.
//! Indexing, ordering, etc. are properties of the containing record.
//!
//! Styles are encoded field by field from the terminal's native `Style` type.
//! The native packed representation is deliberately not part of the snapshot
//! format. This gives flexibility for changing one side or the other.
//!
//! All integers are unsigned and little-endian.
//!
//! | Offset | Size | Field                     |
//! | -----: | ---: | :------------------------ |
//! |      0 |    4 | Foreground color          |
//! |      4 |    4 | Background color          |
//! |      8 |    4 | Underline color           |
//! |     12 |    2 | Style flags (`u16`)       |
//! |     14 |    2 | Reserved, must be zero    |
//!
//! The trailing reserved field is explicit wire padding that rounds each
//! style entry from 14 bytes to 16 bytes. This makes entry offsets and byte
//! counts straightforward.
//!
//! Each color begins with a one-byte kind followed by three data bytes:
//!
//! | Kind | Meaning | Data bytes                         |
//! | ---: | :------ | :--------------------------------- |
//! |    0 | None    | All zero                           |
//! |    1 | Palette | Palette index, then two zero bytes |
//! |    2 | RGB     | Red, green, blue                   |
//!
//! Style flag bits 0 through 7 are bold, italic, faint, blink, inverse,
//! invisible, strikethrough, and overline. Bits 8 through 10 contain the
//! underline kind. Bits 11 through 15 must be zero.
//!
//! | Underline | Meaning |
//! | --------: | :------ |
//! |         0 | None    |
//! |         1 | Single  |
//! |         2 | Double  |
//! |         3 | Curly   |
//! |         4 | Dotted  |
//! |         5 | Dashed  |
//!
//! Underline values 6 and 7 are invalid in snapshot version 1.

const std = @import("std");
const test_fixture = @import("fixture.zig");
const sgr = @import("../sgr.zig");
const terminal_style = @import("../style.zig");

/// Number of bytes in one encoded style entry. This size is part of the
/// wire format: the codec reads and writes fixed offsets within an entry
/// of exactly this size, so if the layout changes, the snapshot version
/// and golden fixtures must also change.
pub const len = 16;

const Flags = packed struct(u16) {
    bold: bool = false,
    italic: bool = false,
    faint: bool = false,
    blink: bool = false,
    inverse: bool = false,
    invisible: bool = false,
    strikethrough: bool = false,
    overline: bool = false,
    underline: u3 = 0,
    reserved: u5 = 0,
};

const ColorKind = enum(u8) {
    none = 0,
    palette = 1,
    rgb = 2,
};

/// Semantic validation errors for one complete style entry buffer.
const ParseError = error{
    /// A color kind is not defined by snapshot version 1.
    InvalidColorKind,

    /// Bytes unused by the selected color kind are not zero.
    InvalidColor,

    /// The encoded underline kind is not defined by snapshot version 1.
    InvalidUnderline,

    /// One or more reserved style flag bits are set.
    InvalidFlags,

    /// The trailing reserved field is not zero.
    InvalidReserved,
};

/// Errors possible while decoding one style entry.
pub const DecodeError = std.Io.Reader.Error || ParseError;

/// Encode one terminal style as a fixed-size snapshot style entry.
///
/// The entry is assembled in a fixed buffer and written once, so hot
/// encoders perform a single writer call per style.
pub fn encode(
    value: terminal_style.Style,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    var encoded: [len]u8 = @splat(0);
    encodeColorBuf(encoded[0..4], value.fg_color);
    encodeColorBuf(encoded[4..8], value.bg_color);
    encodeColorBuf(encoded[8..12], value.underline_color);

    const flags: Flags = .{
        .bold = value.flags.bold,
        .italic = value.flags.italic,
        .faint = value.flags.faint,
        .blink = value.flags.blink,
        .inverse = value.flags.inverse,
        .invisible = value.flags.invisible,
        .strikethrough = value.flags.strikethrough,
        .overline = value.flags.overline,
        .underline = @intFromEnum(value.flags.underline),
    };
    std.mem.writeInt(u16, encoded[12..14], @bitCast(flags), .little);
    try writer.writeAll(&encoded);
}

/// Decode and validate one fixed-size snapshot style entry.
pub fn decode(reader: *std.Io.Reader) DecodeError!terminal_style.Style {
    var encoded: [len]u8 = undefined;
    try reader.readSliceAll(&encoded);
    return parse(&encoded);
}

/// Decode and validate one complete fixed-size style entry buffer.
fn parse(encoded: *const [len]u8) ParseError!terminal_style.Style {
    const fg_color = try parseColor(encoded[0..4]);
    const bg_color = try parseColor(encoded[4..8]);
    const underline_color = try parseColor(encoded[8..12]);

    const flags: Flags = @bitCast(
        std.mem.readInt(u16, encoded[12..14], .little),
    );
    if (flags.reserved != 0) return error.InvalidFlags;

    const underline = std.enums.fromInt(
        sgr.Attribute.Underline,
        flags.underline,
    ) orelse return error.InvalidUnderline;

    const reserved = std.mem.readInt(u16, encoded[14..16], .little);
    if (reserved != 0) return error.InvalidReserved;

    return .{
        .fg_color = fg_color,
        .bg_color = bg_color,
        .underline_color = underline_color,
        .flags = .{
            .bold = flags.bold,
            .italic = flags.italic,
            .faint = flags.faint,
            .blink = flags.blink,
            .inverse = flags.inverse,
            .invisible = flags.invisible,
            .strikethrough = flags.strikethrough,
            .overline = flags.overline,
            .underline = underline,
        },
    };
}

/// Decode strictly after consuming one complete fixed-size style entry.
///
/// Unlike `decode`, a semantic error leaves `reader` at the next entry. This
/// lets an enclosing codec catch the error and choose its own fallback without
/// losing the surrounding payload boundary.
pub fn decodeOrDiscard(
    reader: *std.Io.Reader,
) DecodeError!terminal_style.Style {
    var encoded: [len]u8 = undefined;
    try reader.readSliceAll(&encoded);
    return parse(&encoded);
}

/// Decode one complete entry, returning null for invalid semantic contents.
///
/// Reader errors remain structural and are always propagated. This is the
/// lenient entry point for enclosing codecs which can safely replace an
/// invalid fixed-size style without treating truncation as invalid styling.
pub fn decodeOrNull(
    reader: *std.Io.Reader,
) std.Io.Reader.Error!?terminal_style.Style {
    return decodeOrDiscard(reader) catch |err| switch (err) {
        error.ReadFailed => return error.ReadFailed,
        error.EndOfStream => return error.EndOfStream,

        error.InvalidColorKind,
        error.InvalidColor,
        error.InvalidUnderline,
        error.InvalidFlags,
        error.InvalidReserved,
        => null,
    };
}

/// `decodeOrNull` over one already-buffered entry, for enclosing codecs
/// that parse many entries from a flat payload without reader calls.
pub fn parseOrNull(encoded: *const [len]u8) ?terminal_style.Style {
    return parse(encoded) catch null;
}

fn encodeColorBuf(
    encoded: *[4]u8,
    value: terminal_style.Style.Color,
) void {
    switch (value) {
        .none => encoded[0] = @intFromEnum(ColorKind.none),
        .palette => |index| {
            encoded[0] = @intFromEnum(ColorKind.palette);
            encoded[1] = index;
        },
        .rgb => |rgb| {
            encoded[0] = @intFromEnum(ColorKind.rgb);
            encoded[1] = rgb.r;
            encoded[2] = rgb.g;
            encoded[3] = rgb.b;
        },
    }
}

fn parseColor(
    encoded: *const [4]u8,
) ParseError!terminal_style.Style.Color {
    // Kind must be something we know about.
    const kind = std.enums.fromInt(ColorKind, encoded[0]) orelse {
        return error.InvalidColorKind;
    };

    return switch (kind) {
        .none => if (encoded[1] == 0 and encoded[2] == 0 and encoded[3] == 0)
            .none
        else
            error.InvalidColor,
        .palette => if (encoded[2] == 0 and encoded[3] == 0)
            .{ .palette = encoded[1] }
        else
            error.InvalidColor,
        .rgb => .{ .rgb = .{
            .r = encoded[1],
            .g = encoded[2],
            .b = encoded[3],
        } },
    };
}

const test_golden_fixture = test_fixture.parse(@embedFile("testdata/style-v1.hex"));

test "golden encoding and decoding" {
    const value: terminal_style.Style = .{
        .fg_color = .none,
        .bg_color = .{ .palette = 0x7f },
        .underline_color = .{ .rgb = .{
            .r = 0x12,
            .g = 0x34,
            .b = 0x56,
        } },
        .flags = .{
            .bold = true,
            .italic = true,
            .faint = true,
            .blink = true,
            .inverse = true,
            .invisible = true,
            .strikethrough = true,
            .overline = true,
            .underline = .curly,
        },
    };
    var buf: [len]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encode(value, &writer);
    try test_fixture.expectEqual(
        .bytes,
        "src/terminal/snapshot/testdata/style-v1.hex",
        "snapshot_fixture-style-v1.hex",
        &test_golden_fixture,
        writer.buffered(),
    );

    var source: std.Io.Reader = .fixed(&test_golden_fixture);
    var read_buf: [1]u8 = undefined;
    var limited = source.limited(.unlimited, &read_buf);
    try std.testing.expect(value.eql(try decode(&limited.interface)));
}

test "flag bit layout" {
    const Case = struct {
        value: Flags,
        expected: u16,
    };
    const cases = [_]Case{
        .{ .value = .{ .bold = true }, .expected = 1 << 0 },
        .{ .value = .{ .italic = true }, .expected = 1 << 1 },
        .{ .value = .{ .faint = true }, .expected = 1 << 2 },
        .{ .value = .{ .blink = true }, .expected = 1 << 3 },
        .{ .value = .{ .inverse = true }, .expected = 1 << 4 },
        .{ .value = .{ .invisible = true }, .expected = 1 << 5 },
        .{ .value = .{ .strikethrough = true }, .expected = 1 << 6 },
        .{ .value = .{ .overline = true }, .expected = 1 << 7 },
        .{
            .value = .{
                .underline = @intFromEnum(sgr.Attribute.Underline.single),
            },
            .expected = 1 << 8,
        },
        .{
            .value = .{
                .underline = @intFromEnum(sgr.Attribute.Underline.double),
            },
            .expected = 2 << 8,
        },
        .{
            .value = .{
                .underline = @intFromEnum(sgr.Attribute.Underline.curly),
            },
            .expected = 3 << 8,
        },
        .{
            .value = .{
                .underline = @intFromEnum(sgr.Attribute.Underline.dotted),
            },
            .expected = 4 << 8,
        },
        .{
            .value = .{
                .underline = @intFromEnum(sgr.Attribute.Underline.dashed),
            },
            .expected = 5 << 8,
        },
        .{ .value = .{ .reserved = 1 }, .expected = 1 << 11 },
    };

    for (cases) |case| {
        try std.testing.expectEqual(
            case.expected,
            @as(u16, @bitCast(case.value)),
        );
    }
}

test "reject invalid colors" {
    for ([_]usize{ 0, 4, 8 }) |offset| {
        var invalid_kind: [len]u8 = @splat(0);
        invalid_kind[offset] = 3;
        var reader: std.Io.Reader = .fixed(&invalid_kind);
        try std.testing.expectError(error.InvalidColorKind, decode(&reader));
    }

    var invalid_none: [len]u8 = @splat(0);
    invalid_none[1] = 1;
    var none_reader: std.Io.Reader = .fixed(&invalid_none);
    try std.testing.expectError(error.InvalidColor, decode(&none_reader));

    var invalid_palette: [len]u8 = @splat(0);
    invalid_palette[0] = @intFromEnum(ColorKind.palette);
    invalid_palette[2] = 1;
    var palette_reader: std.Io.Reader = .fixed(&invalid_palette);
    try std.testing.expectError(error.InvalidColor, decode(&palette_reader));
}

test "reject invalid flags and reserved field" {
    for ([_]u16{ 6, 7 }) |underline| {
        var invalid_underline: [len]u8 = @splat(0);
        std.mem.writeInt(
            u16,
            invalid_underline[12..14],
            underline << 8,
            .little,
        );
        var reader: std.Io.Reader = .fixed(&invalid_underline);
        try std.testing.expectError(error.InvalidUnderline, decode(&reader));
    }

    var invalid_flags: [len]u8 = @splat(0);
    std.mem.writeInt(u16, invalid_flags[12..14], 1 << 11, .little);
    var flags_reader: std.Io.Reader = .fixed(&invalid_flags);
    try std.testing.expectError(error.InvalidFlags, decode(&flags_reader));

    var invalid_reserved: [len]u8 = @splat(0);
    std.mem.writeInt(u16, invalid_reserved[14..16], 1, .little);
    var reserved_reader: std.Io.Reader = .fixed(&invalid_reserved);
    try std.testing.expectError(
        error.InvalidReserved,
        decode(&reserved_reader),
    );
}

test "decodeOrDiscard preserves the next entry boundary" {
    var fixture: [len + 1]u8 = @splat(0);
    fixture[0] = 3;
    fixture[len] = 0xFF;

    var reader: std.Io.Reader = .fixed(&fixture);
    try std.testing.expectError(error.InvalidColorKind, decodeOrDiscard(&reader));
    try std.testing.expectEqual(@as(u8, 0xFF), try reader.takeByte());
}

test "decodeOrNull distinguishes semantic errors from truncation" {
    var invalid: [len]u8 = @splat(0);
    invalid[0] = 3;
    var invalid_reader: std.Io.Reader = .fixed(&invalid);
    try std.testing.expectEqual(null, try decodeOrNull(&invalid_reader));

    var truncated: std.Io.Reader = .fixed(invalid[0 .. len - 1]);
    try std.testing.expectError(error.EndOfStream, decodeOrNull(&truncated));
}

test "reject every truncation" {
    const fixture = [_]u8{0} ** len;
    for (0..len) |fixture_len| {
        var reader: std.Io.Reader = .fixed(fixture[0..fixture_len]);
        try std.testing.expectError(error.EndOfStream, decode(&reader));
    }
}
