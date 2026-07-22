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
//! Underline values 6 and 7 are invalid in snapshot version 0.

const std = @import("std");
const io = @import("io.zig");
const sgr = @import("../sgr.zig");
const terminal_style = @import("../style.zig");

/// Number of bytes written by `encode`, calculated using the encoder itself
/// so this remains synchronized with the field-by-field wire format.
pub const len = computeLen();

comptime {
    // This size is part of the wire format. If it changes, the snapshot
    // version and golden fixtures must also change.
    std.debug.assert(len == 16);
}

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

/// Errors possible while decoding one style entry.
pub const DecodeError = std.Io.Reader.Error || error{
    /// A color kind is not defined by snapshot version 0.
    InvalidColorKind,

    /// The encoded underline kind is not defined by snapshot version 0.
    InvalidUnderline,

    /// One or more reserved style flag bits are set.
    InvalidFlags,

    /// The trailing reserved field is not zero.
    InvalidReserved,
};

/// Encode one terminal style as a fixed-size snapshot style entry.
pub fn encode(
    value: terminal_style.Style,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    try encodeColor(value.fg_color, writer);
    try encodeColor(value.bg_color, writer);
    try encodeColor(value.underline_color, writer);

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
    try io.writeInt(writer, u16, @bitCast(flags));
    try io.writeInt(writer, u16, 0);
}

/// Decode and validate one fixed-size snapshot style entry.
pub fn decode(reader: *std.Io.Reader) DecodeError!terminal_style.Style {
    const fg_color = try decodeColor(reader);
    const bg_color = try decodeColor(reader);
    const underline_color = try decodeColor(reader);

    const flags: Flags = @bitCast(try io.readInt(reader, u16));
    if (flags.reserved != 0) return error.InvalidFlags;

    const underline = std.enums.fromInt(
        sgr.Attribute.Underline,
        flags.underline,
    ) orelse return error.InvalidUnderline;

    const reserved = try io.readInt(reader, u16);
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

fn encodeColor(
    value: terminal_style.Style.Color,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    var encoded: [4]u8 = @splat(0);
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
    try writer.writeAll(&encoded);
}

fn decodeColor(
    reader: *std.Io.Reader,
) DecodeError!terminal_style.Style.Color {
    // Colors are always 4 bytes
    var encoded: [4]u8 = undefined;
    try reader.readSliceAll(&encoded);

    // Kind must be something we know about.
    const kind = std.enums.fromInt(ColorKind, encoded[0]) orelse {
        return error.InvalidColorKind;
    };

    return switch (kind) {
        .none => .none,
        .palette => .{ .palette = encoded[1] },
        .rgb => .{ .rgb = .{
            .r = encoded[1],
            .g = encoded[2],
            .b = encoded[3],
        } },
    };
}

fn computeLen() usize {
    comptime {
        var buf: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        encode(.{}, &writer) catch unreachable;
        return writer.end;
    }
}

test "golden encoding" {
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

    try std.testing.expectEqualStrings(
        "\x00\x00\x00\x00" ++
            "\x01\x7f\x00\x00" ++
            "\x02\x12\x34\x56" ++
            "\xff\x03\x00\x00",
        writer.buffered(),
    );
}

test "flag bit layout" {
    const cases = .{
        .{ Flags{ .bold = true }, @as(u16, 1 << 0) },
        .{ Flags{ .italic = true }, @as(u16, 1 << 1) },
        .{ Flags{ .faint = true }, @as(u16, 1 << 2) },
        .{ Flags{ .blink = true }, @as(u16, 1 << 3) },
        .{ Flags{ .inverse = true }, @as(u16, 1 << 4) },
        .{ Flags{ .invisible = true }, @as(u16, 1 << 5) },
        .{ Flags{ .strikethrough = true }, @as(u16, 1 << 6) },
        .{ Flags{ .overline = true }, @as(u16, 1 << 7) },
        .{
            Flags{ .underline = @intFromEnum(sgr.Attribute.Underline.single) },
            @as(u16, 1 << 8),
        },
        .{
            Flags{ .underline = @intFromEnum(sgr.Attribute.Underline.double) },
            @as(u16, 2 << 8),
        },
        .{
            Flags{ .underline = @intFromEnum(sgr.Attribute.Underline.curly) },
            @as(u16, 3 << 8),
        },
        .{
            Flags{ .underline = @intFromEnum(sgr.Attribute.Underline.dotted) },
            @as(u16, 4 << 8),
        },
        .{
            Flags{ .underline = @intFromEnum(sgr.Attribute.Underline.dashed) },
            @as(u16, 5 << 8),
        },
        .{ Flags{ .reserved = 1 }, @as(u16, 1 << 11) },
    };

    inline for (cases) |case| {
        try std.testing.expectEqual(case[1], @as(u16, @bitCast(case[0])));
    }
}

test "decode with a one-byte reader buffer" {
    const fixture =
        "\x00\x00\x00\x00" ++
        "\x01\x7f\x00\x00" ++
        "\x02\x12\x34\x56" ++
        "\xff\x03\x00\x00";
    var source: std.Io.Reader = .fixed(fixture);
    var buf: [1]u8 = undefined;
    var limited = source.limited(.unlimited, &buf);

    const expected: terminal_style.Style = .{
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
    const actual = try decode(&limited.interface);
    try std.testing.expect(expected.eql(actual));
}

test "reject invalid color kinds" {
    inline for (.{ 0, 4, 8 }) |offset| {
        var invalid_kind: [len]u8 = @splat(0);
        invalid_kind[offset] = 3;
        var reader: std.Io.Reader = .fixed(&invalid_kind);
        try std.testing.expectError(error.InvalidColorKind, decode(&reader));
    }
}

test "reject invalid flags and reserved field" {
    inline for (.{ 6, 7 }) |underline| {
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

test "reject every truncation" {
    const fixture = [_]u8{0} ** len;
    for (0..len) |fixture_len| {
        var reader: std.Io.Reader = .fixed(fixture[0..fixture_len]);
        try std.testing.expectError(error.EndOfStream, decode(&reader));
    }
}
