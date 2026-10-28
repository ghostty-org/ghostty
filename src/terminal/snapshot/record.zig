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
//! The tags this build understands are listed in `Tag`.
//!
//! ## Unknown Records
//!
//! A decoder skips any record whose tag it does not know, wherever that
//! record appears, and continues with the next record. Skipping still reads
//! the whole record and checks its CRC32C, so a damaged record fails
//! decoding even when its tag is unknown.
//!
//! For example, a decoder sees this sequence as two PAGE records in a row:
//!
//! ```text
//! PAGE | tag 0x4000 (unknown, skipped) | PAGE
//! ```
//!
//! Records with known tags are checked as carefully as ever. Their payloads
//! must be read exactly to the end, and the order and counts that other
//! records declare for them must match.
//!
//! This is how the format grows without changing its version. A newer
//! encoder can add new kinds of records, and older decoders skip them. That
//! only works if every new kind of record is optional, meaning the terminal
//! is still correct when a decoder skips it. Anything the terminal cannot be
//! correct without, and any change to the layout of an existing record,
//! needs a new snapshot version instead.
//!
//! You rarely need to think about this when writing a record decoder.
//! `nextHeader` does the skipping, and every header is read through it.
//!
//! ## Decoding Records
//!
//! Decoding a record is a two-step job. The caller reads the record's
//! header with `nextHeader`, then passes that header to the decoder for the
//! record, such as `screen.decode` or `checkpoint.decode`. The decoder reads
//! the payload that follows from the same source.
//!
//! ```zig
//! // Read the header, skipping any unknown records before it.
//! const header = try record.nextHeader(source);
//!
//! // Decode the record it belongs to.
//! try checkpoint.decode(.ready, source, header);
//! ```
//!
//! Splitting the work this way lets the caller look at the tag first. A
//! caller that accepts several kinds of records in one position reads the
//! header, switches on `header.tag`, and calls the matching decoder.
//!
//! A caller that expects exactly one kind of record can pass the header
//! along without checking it. Every decoder checks the tag itself and
//! returns `error.UnexpectedRecordTag` for a header of any other kind, so
//! that check lives in one place.
//!
//! Decoders that are followed by a sequence of records, such as a SCREEN
//! and its PAGE records, read the headers of the records in that sequence
//! themselves. Only the first header comes from the caller.

const std = @import("std");
const build_options = @import("terminal_options");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const test_fixture = @import("fixture.zig");
const io = @import("io.zig");

/// CRC32C as specified by the snapshot format. This is the parameter set
/// Zig's standard library names after its iSCSI use, backed by dedicated
/// CRC32C instructions where the target has them.
pub const Crc32c = @import("../../crc32c.zig").Crc32c;

/// Identifies the layout and meaning of a record payload.
///
/// A `Tag` can hold any 16-bit value, not just the ones named here, because
/// a snapshot may come from a newer encoder with tags this build has never
/// heard of. Use `known` to tell the two apart. Decoders skip records whose
/// tag is not known (see "Unknown Records" above).
///
/// Any tag added from now on must describe an optional record, one that a
/// decoder can skip without making the terminal incorrect.
pub const Tag = enum(u16) {
    /// Terminal-wide live state and configuration.
    terminal = 1,

    /// One live screen and its page sequence.
    screen = 2,

    /// One complete logical terminal page.
    page = 3,

    /// One screen's complete history manifest and page sequence.
    history = 4,

    /// Marker separating the renderable terminal state from history.
    ready = 5,

    /// Marker terminating the complete snapshot blob.
    finish = 6,

    /// Canonical unfinished standard TerminalStream input.
    continuation = 7,

    /// One screen's Kitty graphics images, placements and in-progress
    /// load. Optional. See `kitty.zig`.
    kitty_image_storage = 8,

    /// The pixels of one Kitty graphics image or animation frame.
    /// Optional. See `kitty.zig`.
    kitty_image_payload = 9,

    /// The Kitty graphics placements pinned to the history PAGE right
    /// before this record. Optional. See `kitty.zig`.
    kitty_image_page_placements = 10,

    _,

    /// Returns true if this build decodes records with this tag, and false
    /// for a tag it should skip.
    ///
    /// ```zig
    /// const page: Tag = .page;
    /// page.known(); // true
    ///
    /// const future: Tag = @fromBackingInt(0x4000);
    /// future.known(); // false
    /// ```
    pub fn known(self: Tag) bool {
        return switch (self) {
            .terminal,
            .screen,
            .page,
            .history,
            .ready,
            .finish,
            .continuation,
            => true,

            // A build without Kitty graphics skips these records and
            // restores the terminal without its images.
            .kitty_image_storage,
            .kitty_image_payload,
            .kitty_image_page_placements,
            => build_options.kitty_graphics,

            _ => false,
        };
    }
};

/// The fixed framing that precedes every record payload.
pub const Header = struct {
    /// Number of bytes written by `encode`, calculated using the encoder itself
    /// so this remains synchronized with the field-by-field wire format.
    pub const len = computeLen();

    comptime {
        // This size is part of the wire format. If it changes, the snapshot
        // version and golden fixtures must also change.
        assert(len == 10);
    }

    /// Determines how the payload is decoded.
    tag: Tag,

    /// Number of payload bytes immediately following this header.
    payload_len: u32,

    /// CRC32C over the encoded tag, payload length, and payload.
    crc32c: u32,

    /// Errors possible while decoding a record header.
    pub const DecodeError = std.Io.Reader.Error;

    /// Encode the fixed record header.
    pub fn encode(
        self: Header,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try encodeChecksumPrefix(self.tag, self.payload_len, writer);
        try io.writeInt(writer, u32, self.crc32c);
    }

    /// Decode one fixed record header, whatever its tag. The payload length
    /// and CRC are checked later, while the payload is read.
    ///
    /// Most callers want `nextHeader` instead, which skips records with
    /// unknown tags and returns the first header this build understands.
    pub fn decode(reader: *std.Io.Reader) DecodeError!Header {
        return .{
            .tag = @fromBackingInt(@intCast(try io.readInt(reader, u16))),
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

/// Errors possible from `nextHeader`. Besides read errors, a skipped
/// record can fail its checks: `error.InvalidChecksum` for a damaged
/// record, or `error.PayloadNotExhausted` if its payload cannot be read to
/// the declared length.
pub const NextHeaderError = Header.DecodeError || Reader.FinishError;

/// Read the next record header whose tag this build knows, skipping any
/// records with unknown tags on the way.
///
/// Each skipped record is read to its end and its CRC32C is checked, so a
/// damaged record fails here even though its contents are ignored. On
/// return, `source` is positioned at the start of the returned header's
/// payload. See "Unknown Records" above.
///
/// Most record decoders call `Reader.init`, which uses this. Call it
/// directly when you need to see the tag before choosing how to decode the
/// record, then hand the header to `Reader.initHeader`:
///
/// ```zig
/// const header = try record.nextHeader(source);
/// switch (header.tag) {
///     .page => {
///         var reader: record.Reader = undefined;
///         reader.initHeader(source, header);
///         // ... decode the PAGE payload, then reader.finish() ...
///     },
///     else => return error.UnexpectedRecordTag,
/// }
/// ```
pub fn nextHeader(source: *std.Io.Reader) NextHeaderError!Header {
    while (true) {
        const header = try Header.decode(source);
        if (header.tag.known()) return header;

        var skipped: Reader = undefined;
        skipped.initHeader(source, header);
        try skipped.payloadReader().discardAll(header.payload_len);
        try skipped.finish();
    }
}

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

/// Streams complete records while retaining only one payload at a time.
///
/// The scratch allocation is retained between records so a stream's peak
/// memory is the largest record payload rather than the complete snapshot.
pub const Writer = struct {
    destination: *std.Io.Writer,
    scratch: std.Io.Writer.Allocating,
    active_tag: ?Tag,

    pub fn init(
        alloc: Allocator,
        destination: *std.Io.Writer,
    ) Writer {
        return .{
            .destination = destination,
            .scratch = .init(alloc),
            .active_tag = null,
        };
    }

    pub fn deinit(self: *Writer) void {
        assert(self.active_tag == null);
        assert(self.scratch.writer.end == 0);
        self.scratch.deinit();
        self.* = undefined;
    }

    /// Return the destination writer for unframed snapshot bytes.
    pub fn writer(self: *Writer) *std.Io.Writer {
        assert(self.active_tag == null);
        return self.destination;
    }

    /// Begin one record and return its reusable payload writer.
    pub fn begin(self: *Writer, tag: Tag) *std.Io.Writer {
        assert(self.active_tag == null);
        assert(self.scratch.writer.end == 0);
        self.active_tag = tag;
        return &self.scratch.writer;
    }

    pub const FinishError = std.Io.Writer.Error || error{
        /// The payload cannot be represented by the record's `u32` length.
        PayloadTooLarge,
    };

    /// Finish and emit the active record's header followed by its payload.
    ///
    /// Payload validation failures occur before this function and emit no part
    /// of the record. A destination failure here may have emitted a prefix.
    pub fn finish(self: *Writer) FinishError!void {
        assert(self.active_tag != null);
        const tag = self.active_tag.?;
        defer self.cancel();

        const payload = self.scratch.written();
        const payload_len = std.math.cast(
            u32,
            payload.len,
        ) orelse return error.PayloadTooLarge;

        // The CRC prefix contains the payload length, so checksum the retained
        // payload only after its final length is known.
        var checksum: Checksum = .init(tag, payload_len);
        checksum.writer().writeAll(payload) catch unreachable;

        const header: Header = .{
            .tag = tag,
            .payload_len = payload_len,
            .crc32c = checksum.final(),
        };
        var header_bytes: [Header.len]u8 = undefined;
        var header_writer: std.Io.Writer = .fixed(&header_bytes);
        header.encode(&header_writer) catch unreachable;

        try self.destination.writeAll(&header_bytes);
        try self.destination.writeAll(payload);
    }

    /// Discard the active record without emitting any bytes.
    ///
    /// This is idempotent so an outer error cleanup may call it after `finish`
    /// has already cleared state following a destination failure.
    pub fn cancel(self: *Writer) void {
        self.scratch.shrinkRetainingCapacity(0);
        self.active_tag = null;
    }
};

/// Reads one complete record.
///
/// `init` decodes the header, `payloadReader` returns a reader limited to the
/// declared payload, and `finish` verifies exact exhaustion and the CRC32C.
pub const Reader = struct {
    header: Header,

    // The limited reader normally streams directly into the checksum reader's
    // buffer. One byte is enough for operations that require it to buffer,
    // such as peek and discard.
    limited_buffer: [1]u8,

    // Fixed-header decoding performs several small reads. 256 bytes batches
    // them while CRC32C is calculated without making Reader large on the
    // stack. Bulk payload reads bypass this buffer entirely.
    hashing_buffer: [256]u8,

    limited: std.Io.Reader.Limited,
    hashing: std.Io.Reader.Hashed(Crc32c),

    /// When the source already has the complete payload buffered, for
    /// example an in-memory snapshot, the payload is borrowed straight
    /// from the source buffer instead of streaming through the limited
    /// and hashing adapters. The checksum is then verified with one bulk
    /// update in `finish`, and the source is not advanced until `finish`.
    borrowed: ?Borrowed,

    const Borrowed = struct {
        source: *std.Io.Reader,
        payload: std.Io.Reader,
    };

    /// Errors possible from `init`, which reads the header with
    /// `nextHeader`.
    pub const InitError = NextHeaderError;

    /// Errors detected after a payload decoder returns.
    pub const FinishError = error{
        /// The payload bytes do not match the CRC in the record header.
        InvalidChecksum,

        /// The decoder did not consume exactly `payload_len` bytes.
        PayloadNotExhausted,
    };

    /// Read the next record header with a known tag and get ready to read
    /// its payload. Records with unknown tags before it are skipped, as
    /// described in `nextHeader`.
    ///
    /// `self` must remain at a stable address until `finish` returns. Decode
    /// the payload only through the reader returned by `payloadReader`.
    pub fn init(
        self: *Reader,
        source: *std.Io.Reader,
    ) InitError!void {
        self.initHeader(source, try nextHeader(source));
    }

    /// Get ready to read the payload of a header that was already read
    /// from `source`, usually with `nextHeader`. `source` must be
    /// positioned at the start of that payload.
    ///
    /// Use this when you need to look at the tag before deciding how to
    /// decode the record. Otherwise use `init`. The same rules apply
    /// afterward: read the payload through `payloadReader`, then call
    /// `finish`.
    pub fn initHeader(
        self: *Reader,
        source: *std.Io.Reader,
        header: Header,
    ) void {
        self.* = undefined;
        self.header = header;

        // The complete payload is already sitting in the source buffer:
        // borrow it in place. Payload decoders read from a fixed reader
        // over the borrowed bytes and `finish` checksums them in one pass.
        if (source.bufferedLen() >= self.header.payload_len) {
            self.borrowed = .{
                .source = source,
                .payload = .fixed(
                    source.buffered()[0..self.header.payload_len],
                ),
            };
            return;
        }

        self.borrowed = null;
        self.limited = .init(
            source,
            .limited(self.header.payload_len),
            &self.limited_buffer,
        );

        const checksum: Checksum = .init(
            self.header.tag,
            self.header.payload_len,
        );
        self.hashing = .init(
            &self.limited.interface,
            checksum.hashing.hasher,
            &self.hashing_buffer,
        );
    }

    /// Return the length-limited, checksum-updating payload reader.
    pub fn payloadReader(self: *Reader) *std.Io.Reader {
        if (self.borrowed) |*borrowed| return &borrowed.payload;
        return &self.hashing.reader;
    }

    /// Require exact payload exhaustion and validate its CRC32C.
    pub fn finish(self: *Reader) FinishError!void {
        if (self.borrowed) |*borrowed| {
            if (borrowed.payload.bufferedLen() != 0) {
                return error.PayloadNotExhausted;
            }

            var checksum: Checksum = .init(
                self.header.tag,
                self.header.payload_len,
            );
            checksum.writer().writeAll(
                borrowed.payload.buffer[0..borrowed.payload.end],
            ) catch unreachable;
            if (checksum.final() != self.header.crc32c) {
                return error.InvalidChecksum;
            }

            // The borrowed bytes validated, so consume them from the
            // source only now, leaving it positioned at the next record.
            borrowed.source.toss(self.header.payload_len);
            return;
        }

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
    try io.writeInt(writer, u16, @backingInt(tag));
    try io.writeInt(writer, u32, payload_len);
}

const test_page_header_fixture = test_fixture.parse(
    @embedFile("testdata/record-page-header-v1.hex"),
);

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

    try test_fixture.expectEqual(
        .bytes,
        "src/terminal/snapshot/testdata/record-page-header-v1.hex",
        "snapshot_fixture-record-page-header-v1.hex",
        &test_page_header_fixture,
        writer.buffered(),
    );

    var reader: std.Io.Reader = .fixed(&test_page_header_fixture);
    try std.testing.expectEqual(header, try Header.decode(&reader));
}

test "headers decode unknown tags" {
    for ([_]u16{ 0, 12, std.math.maxInt(u16) }) |tag| {
        var fixture: [Header.len]u8 = @splat(0);
        std.mem.writeInt(u16, fixture[0..2], tag, .little);
        var reader: std.Io.Reader = .fixed(&fixture);
        const header = try Header.decode(&reader);
        try std.testing.expectEqual(tag, @backingInt(header.tag));
        try std.testing.expect(!header.tag.known());
    }
}

/// Test helper that appends one complete record with any raw tag,
/// including tags that `Tag` does not name.
pub fn testWriteRaw(
    writer: *std.Io.Writer,
    tag: u16,
    payload: []const u8,
) !void {
    const len: u32 = @intCast(payload.len);
    var checksum: Checksum = .init(@fromBackingInt(@intCast(tag)), len);
    try checksum.writer().writeAll(payload);
    try (Header{
        .tag = @fromBackingInt(@intCast(tag)),
        .payload_len = len,
        .crc32c = checksum.final(),
    }).encode(writer);
    try writer.writeAll(payload);
}

test "record reader skips unknown records" {
    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    try testWriteRaw(&encoded.writer, 0, "");
    try testWriteRaw(&encoded.writer, 0x7fff, "unknown payload");
    try testWriteRaw(&encoded.writer, @backingInt(Tag.page), "page");

    // Skip both from a fully buffered source and through a one-byte buffer,
    // which forces the streaming payload path.
    for (0..2) |streaming| {
        var fixed: std.Io.Reader = .fixed(encoded.written());
        var buf: [1]u8 = undefined;
        var limited = fixed.limited(.unlimited, &buf);
        const source = if (streaming == 1) &limited.interface else &fixed;

        var record_reader: Reader = undefined;
        try record_reader.init(source);
        try std.testing.expectEqual(Tag.page, record_reader.header.tag);
        var payload: [4]u8 = undefined;
        try record_reader.payloadReader().readSliceAll(&payload);
        try record_reader.finish();
        try std.testing.expectEqualStrings("page", &payload);
    }
}

test "record reader rejects a corrupted unknown record" {
    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    try testWriteRaw(&encoded.writer, 0x7fff, "unknown payload");
    try testWriteRaw(&encoded.writer, @backingInt(Tag.page), "page");
    encoded.written()[Header.len] ^= 1;

    var source: std.Io.Reader = .fixed(encoded.written());
    var record_reader: Reader = undefined;
    try std.testing.expectError(
        error.InvalidChecksum,
        record_reader.init(&source),
    );
}

test "reject every header truncation" {
    for (0..Header.len) |len| {
        var reader: std.Io.Reader = .fixed(
            test_page_header_fixture[0..len],
        );
        try std.testing.expectError(error.EndOfStream, Header.decode(&reader));
    }
}

test "record reader verifies exhaustion and checksum" {
    const payload = "snapshot payload";
    var checksum: Checksum = .init(.page, payload.len);
    try checksum.writer().writeAll(payload);
    const header: Header = .{
        .tag = .page,
        .payload_len = payload.len,
        .crc32c = checksum.final(),
    };

    var encoded: [Header.len + payload.len + 4]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&encoded);
    try header.encode(&writer);
    try writer.writeAll(payload ++ "next");

    var source: std.Io.Reader = .fixed(writer.buffered());
    var record_reader: Reader = undefined;
    try record_reader.init(&source);
    var decoded: [payload.len]u8 = undefined;
    try record_reader.payloadReader().readSliceAll(&decoded);
    try record_reader.finish();
    try std.testing.expectEqualStrings(payload, &decoded);
    try std.testing.expectEqualStrings("next", try source.take(4));
}

test "record reader rejects remaining bytes and invalid checksum" {
    const payload = "payload";
    const header: Header = .{
        .tag = .page,
        .payload_len = payload.len,
        .crc32c = 0,
    };

    var encoded: [Header.len + payload.len]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&encoded);
    try header.encode(&writer);
    try writer.writeAll(payload);

    {
        var source: std.Io.Reader = .fixed(writer.buffered());
        var record_reader: Reader = undefined;
        try record_reader.init(&source);
        _ = try record_reader.payloadReader().takeByte();
        try std.testing.expectError(
            error.PayloadNotExhausted,
            record_reader.finish(),
        );
    }

    {
        var source: std.Io.Reader = .fixed(writer.buffered());
        var record_reader: Reader = undefined;
        try record_reader.init(&source);
        try record_reader.payloadReader().discardAll(payload.len);
        try std.testing.expectError(
            error.InvalidChecksum,
            record_reader.finish(),
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

    var encoded: [Header.len + payload.len + 4]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&encoded);
    try header.encode(&writer);
    try writer.writeAll(payload ++ "next");

    var source: std.Io.Reader = .fixed(writer.buffered());
    var record_reader: Reader = undefined;
    try record_reader.init(&source);
    var too_long: [3]u8 = undefined;
    try std.testing.expectError(
        error.EndOfStream,
        record_reader.payloadReader().readSliceAll(&too_long),
    );
    try record_reader.finish();
    try std.testing.expectEqualStrings("next", try source.take(4));
}

test "record writer buffers a payload and appends framing" {
    var destination: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer destination.deinit();
    try destination.writer.writeAll("prefix");
    var stream: Writer = .init(
        std.testing.allocator,
        &destination.writer,
    );
    defer stream.deinit();

    const payload = stream.begin(.page);
    errdefer stream.cancel();
    try payload.writeAll("payload");
    try stream.finish();

    const encoded = destination.written();
    try std.testing.expectEqualStrings("prefix", encoded[0..6]);

    var source: std.Io.Reader = .fixed(encoded[6..]);
    var record_reader: Reader = undefined;
    try record_reader.init(&source);
    try std.testing.expectEqual(Tag.page, record_reader.header.tag);
    try std.testing.expectEqual(
        @as(u32, 7),
        record_reader.header.payload_len,
    );
    try std.testing.expectEqualStrings(
        "payload",
        try record_reader.payloadReader().take(7),
    );
    try record_reader.finish();
}

test "record writer cancel preserves preceding bytes" {
    var destination: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer destination.deinit();
    try destination.writer.writeAll("prefix");
    var stream: Writer = .init(
        std.testing.allocator,
        &destination.writer,
    );
    defer stream.deinit();

    const partial = stream.begin(.page);
    errdefer stream.cancel();
    try partial.writeAll("partial");
    const scratch_capacity = stream.scratch.writer.buffer.len;
    stream.cancel();

    try std.testing.expectEqualStrings("prefix", destination.written());
    try std.testing.expectEqual(
        scratch_capacity,
        stream.scratch.writer.buffer.len,
    );

    // Cancel retains the allocation but leaves it ready for the next record.
    const next = stream.begin(.page);
    try next.writeAll("next");
    try stream.finish();

    var source: std.Io.Reader = .fixed(destination.written()[6..]);
    var record_reader: Reader = undefined;
    try record_reader.init(&source);
    try std.testing.expectEqualStrings(
        "next",
        try record_reader.payloadReader().take(4),
    );
    try record_reader.finish();
}

test "record writer clears active state after destination failure" {
    // The header fits but the payload does not, leaving a permitted partial
    // record in the destination while the reusable writer becomes idle again.
    var destination_bytes: [Header.len]u8 = undefined;
    var destination: std.Io.Writer = .fixed(&destination_bytes);
    var stream: Writer = .init(std.testing.allocator, &destination);
    defer stream.deinit();

    const payload = stream.begin(.page);
    try payload.writeByte(0);
    try std.testing.expectError(error.WriteFailed, stream.finish());
    try std.testing.expectEqual(@as(?Tag, null), stream.active_tag);
    try std.testing.expectEqual(@as(usize, 0), stream.scratch.writer.end);
}
