//! Snapshot envelope.
//!
//! Every snapshot binary blob begins with exactly one envelope at byte zero.
//! It is followed by a set of records. Each record provides their own
//! tag, payload length, CRC, etc.
//!
//! The envelope identifies the bytes as a terminal snapshot and selects the
//! single version governing the entire blob. A decoder validates both fields
//! before reading any records.
//!
//! The envelope is exactly ten bytes. All integers are unsigned and
//! little-endian.
//!
//! | Offset | Size | Field                |
//! | -----: | ---: | :------------------- |
//! |      0 |    8 | Magic (`BOOSNAP\0`)  |
//! |      8 |    2 | Version (`u16`)      |

const std = @import("std");
const io = @import("io.zig");

/// Identifies a Ghostty terminal snapshot and rejects unrelated input before
/// any record decoding begins. The trailing NUL is part of the wire value.
pub const magic = "BOOSNAP\x00";

/// The complete compatibility boundary for snapshot layout and behavior.
/// Version 0 readers require this value to match exactly.
pub const version: u16 = 0;

/// Number of bytes in the fixed envelope: magic followed by version.
pub const encoded_len = magic.len + @sizeOf(@TypeOf(version));

comptime {
    // We expect this so if it changes we should think carefully.
    std.debug.assert(encoded_len == 10);
}

pub const DecodeError = std.Io.Reader.Error || error{
    InvalidMagic,
    UnsupportedVersion,
};

/// Encode the envelope.
pub fn encode(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll(magic);
    try io.writeInt(writer, u16, version);
}

/// Decode and validate the envelope.
pub fn decode(reader: *std.Io.Reader) DecodeError!void {
    var actual_magic: [magic.len]u8 = undefined;
    try reader.readSliceAll(&actual_magic);
    if (!std.mem.eql(u8, magic, &actual_magic)) return error.InvalidMagic;

    const actual_version = try io.readInt(reader, u16);
    if (actual_version != version) return error.UnsupportedVersion;
}

test "golden encoding" {
    var buf: [encoded_len]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encode(&writer);

    try std.testing.expectEqualStrings(
        "BOOSNAP\x00\x00\x00",
        writer.buffered(),
    );
}

test "reject invalid magic and version" {
    var invalid_magic: std.Io.Reader = .fixed("BOOSNAX\x00\x00\x00");
    try std.testing.expectError(error.InvalidMagic, decode(&invalid_magic));

    var invalid_version: std.Io.Reader = .fixed("BOOSNAP\x00\x01\x00");
    try std.testing.expectError(
        error.UnsupportedVersion,
        decode(&invalid_version),
    );
}

test "reject every truncation" {
    const fixture = "BOOSNAP\x00\x00\x00";
    for (0..encoded_len) |len| {
        var reader: std.Io.Reader = .fixed(fixture[0..len]);
        try std.testing.expectError(error.EndOfStream, decode(&reader));
    }
}
