//! Snapshot record framing.
//!
//! Records begin immediately after the single snapshot envelope and continue
//! back-to-back until FINISH. Each record has one fixed-size header followed
//! by exactly `payload_len` bytes. The payload length limits the record reader
//! so malformed payloads cannot consume bytes from the following record.
//!
//! The CRC covers the first six header bytes (tag and payload length)
//! followed by the payload. The CRC field itself is not included for obvious
//! reasons. All integers are unsigned and little-endian.
//!
//! | Offset | Size          | Field                  |
//! | -----: | ------------: | :--------------------- |
//! |      0 |             2 | Tag (`u16`)            |
//! |      2 |             4 | Payload length (`u32`) |
//! |      6 |             4 | CRC32C (`u32`)         |
//! |     10 | `payload_len` | Payload                |
//!
//! Supported tags are in `Tag`.

const std = @import("std");
const io = @import("io.zig");

/// CRC32C as specified by the snapshot format. Zig names this standard
/// parameter set after its iSCSI use.
pub const Crc32c = std.hash.crc.Crc32Iscsi;

/// Identifies the layout and meaning of a record payload.
/// The current snapshot version rejects every value not listed here.
pub const Tag = enum(u16) {
    /// Terminal-wide live state and configuration.
    terminal = 1,

    /// One live screen and its page sequence.
    screen = 2,

    /// One complete logical terminal page.
    page = 3,

    /// Unfinished UTF-8 and terminal parser input.
    continuation = 4,

    /// Digest marking the validated terminal-state prefix.
    ready = 5,

    /// Digest validating the complete snapshot blob.
    finish = 6,
};

/// The fixed framing that precedes every record payload.
pub const Header = struct {
    /// Number of bytes written by `encode`, calculated using the encoder itself
    /// so this remains synchronized with the field-by-field wire format.
    pub const len = computeLen();

    comptime {
        // This size is part of the wire format. If it changes, the snapshot
        // version and golden fixtures must also change.
        std.debug.assert(len == 10);
    }

    /// Determines how the payload is decoded.
    tag: Tag,

    /// Number of payload bytes immediately following this header.
    payload_len: u32,

    /// CRC32C over the encoded tag, payload length, and payload.
    crc32c: u32,

    /// Errors possible while decoding a record header.
    pub const DecodeError = std.Io.Reader.Error || error{InvalidTag};

    /// Encode the fixed record header.
    pub fn encode(
        self: Header,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try encodeChecksumPrefix(self.tag, self.payload_len, writer);
        try io.writeInt(writer, u32, self.crc32c);
    }

    /// Decode a fixed record header and reject unknown tags.
    /// Payload length and CRC validation occur while decoding the payload.
    pub fn decode(reader: *std.Io.Reader) DecodeError!Header {
        const tag_raw = try io.readInt(reader, u16);
        const tag = std.enums.fromInt(Tag, tag_raw) orelse {
            return error.InvalidTag;
        };

        return .{
            .tag = tag,
            .payload_len = try io.readInt(reader, u32),
            .crc32c = try io.readInt(reader, u32),
        };
    }

    /// Computes the required header length at comptime.
    fn computeLen() usize {
        comptime {
            var buf: [128]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buf);
            const header: Header = .{
                .tag = .terminal,
                .payload_len = 0,
                .crc32c = 0,
            };
            header.encode(&writer) catch unreachable;
            return writer.end;
        }
    }
};

/// A writer that calculates a record checksum without retaining payload bytes.
/// The checksum is initialized with the encoded tag and payload length.
pub const Checksum = struct {
    hashing: std.Io.Writer.Hashing(Crc32c),

    /// Begin a checksum with the encoded tag and payload length already added.
    pub fn init(tag: Tag, payload_len: u32) Checksum {
        var result: Checksum = .{
            .hashing = .initHasher(.init(), &.{}),
        };
        encodeChecksumPrefix(
            tag,
            payload_len,
            &result.hashing.writer,
        ) catch unreachable;
        return result;
    }

    /// Return the writer through which the complete payload must be encoded.
    pub fn writer(self: *Checksum) *std.Io.Writer {
        return &self.hashing.writer;
    }

    /// Finish and return the checksum stored in the record header.
    pub fn final(self: *Checksum) u32 {
        self.hashing.writer.flush() catch unreachable;
        return self.hashing.hasher.final();
    }
};

/// A checksum-verifying reader limited to one record payload.
///
/// Initialize this only after decoding a `Header`, decode the payload through
/// `reader`, and then call `finish`. The caller owns both buffers and chooses
/// their sizes. They only need to remain valid until `finish` returns.
pub const PayloadReader = struct {
    header: Header,
    limited: std.Io.Reader.Limited,
    hashing: std.Io.Reader.Hashed(Crc32c),

    /// Caller-owned storage for the reader wrappers.
    pub const Buffers = struct {
        /// Buffer used to enforce the payload-length boundary.
        limited: []u8,

        /// Buffer used while updating CRC32C over consumed payload bytes.
        hashing: []u8,
    };

    /// Errors detected after a payload decoder returns.
    pub const FinishError = error{
        /// The payload bytes do not match the CRC in the record header.
        InvalidChecksum,

        /// The decoder did not consume exactly `payload_len` bytes.
        PayloadNotExhausted,
    };

    /// Initialize a reader for the payload described by `header`.
    ///
    /// `self` and both buffers must remain at stable addresses until `finish`
    /// returns. Decode only through the reader returned by `reader`.
    pub fn init(
        self: *PayloadReader,
        source: *std.Io.Reader,
        header: Header,
        buffers: Buffers,
    ) void {
        self.* = undefined;
        self.header = header;
        self.limited = .init(
            source,
            .limited(header.payload_len),
            buffers.limited,
        );

        const checksum: Checksum = .init(header.tag, header.payload_len);
        self.hashing = .init(
            &self.limited.interface,
            checksum.hashing.hasher,
            buffers.hashing,
        );
    }

    /// Return the length-limited, checksum-updating payload reader.
    pub fn reader(self: *PayloadReader) *std.Io.Reader {
        return &self.hashing.reader;
    }

    /// Require exact payload exhaustion and validate its CRC32C.
    pub fn finish(self: *PayloadReader) FinishError!void {
        if (self.hashing.reader.bufferedLen() != 0 or
            self.limited.remaining != .nothing)
        {
            return error.PayloadNotExhausted;
        }

        if (self.hashing.hasher.final() != self.header.crc32c) {
            return error.InvalidChecksum;
        }
    }
};

/// Encode the portion of a record header covered by CRC32C.
fn encodeChecksumPrefix(
    tag: Tag,
    payload_len: u32,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    try io.writeInt(writer, u16, @intFromEnum(tag));
    try io.writeInt(writer, u32, payload_len);
}

test "golden PAGE record header and checksum" {
    const page_header =
        "\x50\x00\x18\x00\x00\x00\x00\x00" ++
        "\x00\x00\x00\x00\x00\x00\x00\x00" ++
        "\x00\x00\x00\x00\x00\x00\x00\x00";

    var checksum: Checksum = .init(.page, page_header.len);
    try checksum.writer().writeAll(page_header);
    try std.testing.expectEqual(@as(u32, 0x7178441b), checksum.final());

    const header: Header = .{
        .tag = .page,
        .payload_len = page_header.len,
        .crc32c = 0x7178441b,
    };
    var buf: [Header.len]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try header.encode(&writer);

    try std.testing.expectEqualStrings(
        "\x03\x00\x18\x00\x00\x00\x1b\x44\x78\x71",
        writer.buffered(),
    );
}

test "decode header with a one-byte reader buffer" {
    const fixture = "\x03\x00\x18\x00\x00\x00\x1b\x44\x78\x71";
    var source: std.Io.Reader = .fixed(fixture);
    var buf: [1]u8 = undefined;
    var limited = source.limited(.unlimited, &buf);

    try std.testing.expectEqual(
        Header{
            .tag = .page,
            .payload_len = 24,
            .crc32c = 0x7178441b,
        },
        try Header.decode(&limited.interface),
    );
}

test "reject invalid tags" {
    inline for (.{ 0, 7, std.math.maxInt(u16) }) |tag| {
        var fixture = [_]u8{0} ** Header.len;
        std.mem.writeInt(u16, fixture[0..2], tag, .little);
        var reader: std.Io.Reader = .fixed(&fixture);
        try std.testing.expectError(error.InvalidTag, Header.decode(&reader));
    }
}

test "reject every header truncation" {
    const fixture = "\x03\x00\x18\x00\x00\x00\x1b\x44\x78\x71";
    for (0..Header.len) |len| {
        var reader: std.Io.Reader = .fixed(fixture[0..len]);
        try std.testing.expectError(error.EndOfStream, Header.decode(&reader));
    }
}

test "payload reader verifies exhaustion and checksum" {
    const payload = "snapshot payload";
    var checksum: Checksum = .init(.page, payload.len);
    try checksum.writer().writeAll(payload);
    const header: Header = .{
        .tag = .page,
        .payload_len = payload.len,
        .crc32c = checksum.final(),
    };

    var source: std.Io.Reader = .fixed(payload ++ "next");
    var payload_reader: PayloadReader = undefined;
    var limited_buf: [1]u8 = undefined;
    var hashing_buf: [1]u8 = undefined;
    payload_reader.init(&source, header, .{
        .limited = &limited_buf,
        .hashing = &hashing_buf,
    });

    var decoded: [payload.len]u8 = undefined;
    try payload_reader.reader().readSliceAll(&decoded);
    try payload_reader.finish();
    try std.testing.expectEqualStrings(payload, &decoded);
    try std.testing.expectEqualStrings("next", try source.take(4));
}

test "payload reader rejects remaining bytes and invalid checksum" {
    const payload = "payload";
    const header: Header = .{
        .tag = .page,
        .payload_len = payload.len,
        .crc32c = 0,
    };

    {
        var source: std.Io.Reader = .fixed(payload);
        var payload_reader: PayloadReader = undefined;
        var limited_buf: [1]u8 = undefined;
        var hashing_buf: [1]u8 = undefined;
        payload_reader.init(&source, header, .{
            .limited = &limited_buf,
            .hashing = &hashing_buf,
        });
        _ = try payload_reader.reader().takeByte();
        try std.testing.expectError(
            error.PayloadNotExhausted,
            payload_reader.finish(),
        );
    }

    {
        var source: std.Io.Reader = .fixed(payload);
        var payload_reader: PayloadReader = undefined;
        var limited_buf: [1]u8 = undefined;
        var hashing_buf: [1]u8 = undefined;
        payload_reader.init(&source, header, .{
            .limited = &limited_buf,
            .hashing = &hashing_buf,
        });
        try payload_reader.reader().discardAll(payload.len);
        try std.testing.expectError(
            error.InvalidChecksum,
            payload_reader.finish(),
        );
    }
}

test "payload limit does not consume the next record" {
    const payload = "ab";
    var checksum: Checksum = .init(.page, payload.len);
    try checksum.writer().writeAll(payload);
    const header: Header = .{
        .tag = .page,
        .payload_len = payload.len,
        .crc32c = checksum.final(),
    };

    var source: std.Io.Reader = .fixed(payload ++ "next");
    var payload_reader: PayloadReader = undefined;
    var limited_buf: [1]u8 = undefined;
    var hashing_buf: [1]u8 = undefined;
    payload_reader.init(&source, header, .{
        .limited = &limited_buf,
        .hashing = &hashing_buf,
    });

    var too_long: [3]u8 = undefined;
    try std.testing.expectError(
        error.EndOfStream,
        payload_reader.reader().readSliceAll(&too_long),
    );
    try payload_reader.finish();
    try std.testing.expectEqualStrings("next", try source.take(4));
}
