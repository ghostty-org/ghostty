//! READY and FINISH snapshot checkpoint records.
//!
//! Each checkpoint payload is one BLAKE3-256 digest of every snapshot byte
//! before that checkpoint's record header. This binds record order and detects
//! omitted or duplicated records in ways that independent record CRCs cannot.
//!
//! READY covers the envelope, TERMINAL, and all SCREEN/PAGE sequences. FINISH
//! covers that same prefix plus the complete READY record and all HISTORY/PAGE
//! sequences. Neither digest includes its own record. FINISH terminates one
//! snapshot; bytes after it belong to the containing transport.
//!
//! The digest does not replace record framing. Its 32-byte payload is still
//! protected by the record's CRC32C.
//!
//! ## Binary Format
//!
//! READY and FINISH use the same fixed payload:
//!
//! ```text
//!  0 +----------------------------+
//!    | BLAKE3-256 prefix digest   |
//!    | 32 bytes                   |
//! 32 +----------------------------+
//! ```

const std = @import("std");
const test_fixture = @import("fixture.zig");
const record = @import("record.zig");

const Blake3 = std.crypto.hash.Blake3;

/// The prefix digest exchanged by checkpoint codecs and the snapshot driver.
pub const Digest = record.PrefixDigest;

comptime {
    std.debug.assert(@sizeOf(Digest) == 32);
}

/// Selects one of the two checkpoint positions in a snapshot.
pub const Kind = enum {
    ready,
    finish,

    fn tag(self: Kind) record.Tag {
        return switch (self) {
            .ready => .ready,
            .finish => .finish,
        };
    }
};

pub const EncodeError = std.Io.Writer.Error ||
    record.Writer.FinishError;

/// Append one checkpoint covering every byte already emitted by `stream`.
///
/// Finalizing does not consume the running hasher. READY is therefore included
/// as the stream continues toward FINISH.
pub fn encode(
    kind: Kind,
    stream: *record.Writer,
) EncodeError!void {
    const digest = stream.prefixDigest();

    const payload = stream.begin(kind.tag());
    errdefer stream.cancel();
    try payload.writeAll(&digest);
    try stream.finish();
}

pub const DecodeError = record.Reader.InitError ||
    record.Reader.FinishError ||
    error{
        /// The next record is valid but is not the expected checkpoint.
        UnexpectedRecordTag,

        /// The checkpoint does not describe the preceding snapshot bytes.
        InvalidDigest,
    };

/// Decode and validate one checkpoint against the running prefix digest.
///
/// READY is consumed through the hashing reader so FINISH covers it. FINISH is
/// consumed from the underlying source so neither checkpoint includes itself.
pub fn decode(
    kind: Kind,
    stream: *record.StreamReader,
) DecodeError!void {
    const expected = stream.prefixDigest();
    const source = if (kind == .finish)
        stream.source()
    else
        stream.reader();

    var record_reader: record.Reader = undefined;
    try record_reader.init(source);
    if (record_reader.header.tag != kind.tag()) {
        return error.UnexpectedRecordTag;
    }

    var actual: Digest = undefined;
    try record_reader.payloadReader().readSliceAll(&actual);
    try record_reader.finish();
    if (!std.mem.eql(u8, &expected, &actual)) return error.InvalidDigest;
}

const test_ready_fixture = test_fixture.parse(
    @embedFile("testdata/checkpoint-ready-v1.hex"),
);

test "READY golden encoding and BLAKE3-256 registry" {
    const prefix = "abc";

    var snapshot: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer snapshot.deinit();
    var stream: record.Writer = .init(
        std.testing.allocator,
        &snapshot.writer,
    );
    defer stream.deinit();
    try stream.writer().writeAll(prefix);
    try encode(.ready, &stream);

    try test_fixture.expectEqual(
        .bytes,
        "src/terminal/snapshot/testdata/checkpoint-ready-v1.hex",
        "snapshot_fixture-checkpoint-ready-v1.hex",
        &test_ready_fixture,
        snapshot.written(),
    );

    // The checked-in payload independently locks the BLAKE3-256 registry.
    var actual: Digest = undefined;
    Blake3.hash(prefix, &actual, .{});
    const payload_offset = prefix.len + record.Header.len;
    try std.testing.expectEqualSlices(
        u8,
        test_ready_fixture[payload_offset..][0..actual.len],
        &actual,
    );

    // Finalizing a streaming hasher neither consumes nor resets it.
    var hasher = Blake3.init(.{});
    hasher.update("a");
    var prefix_digest: Digest = undefined;
    Blake3.hash("a", &prefix_digest, .{});
    hasher.final(&actual);
    try std.testing.expectEqual(prefix_digest, actual);

    hasher.update("bc");
    hasher.final(&actual);
    try std.testing.expectEqualSlices(
        u8,
        test_ready_fixture[payload_offset..][0..actual.len],
        &actual,
    );

    // Decode the checked-in record rather than the generated candidate.
    var source: std.Io.Reader = .fixed(&test_ready_fixture);
    var source_stream: record.StreamReader = .init(&source);
    try source_stream.reader().discardAll(prefix.len);
    try decode(.ready, &source_stream);
}

test "READY and FINISH checkpoint coverage" {
    const testing = std.testing;

    var snapshot: std.Io.Writer.Allocating = .init(testing.allocator);
    defer snapshot.deinit();
    var stream: record.Writer = .init(
        testing.allocator,
        &snapshot.writer,
    );
    defer stream.deinit();
    try stream.writer().writeAll("prefix");

    // READY covers only the bytes that precede its own record.
    const ready_offset = snapshot.written().len;
    const ready_digest = stream.prefixDigest();
    try encode(.ready, &stream);

    // History follows READY and is included by FINISH.
    try stream.writer().writeAll("history");
    const finish_offset = snapshot.written().len;
    const finish_digest = stream.prefixDigest();
    try encode(.finish, &stream);

    // The running stream reaches both checkpoints without rehashing its prefix.
    var source: std.Io.Reader = .fixed(snapshot.written());
    var source_stream: record.StreamReader = .init(&source);
    try source_stream.reader().discardAll(ready_offset);
    try testing.expectEqual(ready_digest, source_stream.prefixDigest());
    try decode(.ready, &source_stream);
    try source_stream.reader().discardAll("history".len);
    try testing.expectEqual(finish_digest, source_stream.prefixDigest());
    try decode(.finish, &source_stream);

    try testing.expectEqual(
        snapshot.written().len - finish_offset,
        record.Header.len + @sizeOf(Digest),
    );
}

test "checkpoint rejects wrong tags and digests" {
    const testing = std.testing;

    var snapshot: std.Io.Writer.Allocating = .init(testing.allocator);
    defer snapshot.deinit();
    var stream: record.Writer = .init(
        testing.allocator,
        &snapshot.writer,
    );
    defer stream.deinit();
    try stream.writer().writeAll("prefix");
    const checkpoint_offset = snapshot.written().len;
    try encode(.ready, &stream);

    var wrong_tag_source: std.Io.Reader = .fixed(
        snapshot.written()[checkpoint_offset..],
    );
    var wrong_tag: record.StreamReader = .init(&wrong_tag_source);
    try testing.expectError(
        error.UnexpectedRecordTag,
        decode(.finish, &wrong_tag),
    );

    // Build a correctly framed checkpoint containing an unrelated digest.
    var invalid: std.Io.Writer.Allocating = .init(testing.allocator);
    defer invalid.deinit();
    var invalid_stream: record.Writer = .init(
        testing.allocator,
        &invalid.writer,
    );
    defer invalid_stream.deinit();
    try invalid_stream.writer().writeAll("prefix");
    var invalid_digest = invalid_stream.prefixDigest();
    invalid_digest[0] ^= 1;
    const invalid_payload = invalid_stream.begin(.ready);
    errdefer invalid_stream.cancel();
    try invalid_payload.writeAll(&invalid_digest);
    try invalid_stream.finish();

    var invalid_digest_source: std.Io.Reader = .fixed(invalid.written());
    var invalid_digest_stream: record.StreamReader = .init(
        &invalid_digest_source,
    );
    try invalid_digest_stream.reader().discardAll("prefix".len);
    try testing.expectError(
        error.InvalidDigest,
        decode(.ready, &invalid_digest_stream),
    );
}

test "FINISH leaves continuation bytes unread" {
    const testing = std.testing;

    var finished: std.Io.Writer.Allocating = .init(testing.allocator);
    defer finished.deinit();
    var finished_stream: record.Writer = .init(
        testing.allocator,
        &finished.writer,
    );
    defer finished_stream.deinit();
    try finished_stream.writer().writeAll("prefix");
    try encode(.finish, &finished_stream);
    try finished.writer.writeByte(0);

    var trailing_source: std.Io.Reader = .fixed(finished.written());
    var trailing_stream: record.StreamReader = .init(
        &trailing_source,
    );
    try trailing_stream.reader().discardAll("prefix".len);
    try decode(.finish, &trailing_stream);
    try testing.expectEqual(@as(u8, 0), try trailing_source.takeByte());
}
