//! READY and FINISH snapshot marker records.
//!
//! READY separates the renderable terminal state from the history sequences.
//! FINISH terminates one snapshot; bytes after it belong to the containing
//! transport. Both markers have empty payloads, independently framed and
//! protected by the same CRC32C as every other record.
//!
//! ## Binary Format
//!
//! READY and FINISH contain only their record headers. Their declared payload
//! length must be zero.

const std = @import("std");
const test_fixture = @import("fixture.zig");
const record = @import("record.zig");

/// Selects one of the two marker positions in a snapshot.
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

pub const EncodeError = record.Writer.FinishError;

/// Append one empty marker record.
pub fn encode(kind: Kind, stream: *record.Writer) EncodeError!void {
    _ = stream.begin(kind.tag());
    errdefer stream.cancel();
    try stream.finish();
}

pub const DecodeError = record.Reader.InitError ||
    record.Reader.FinishError ||
    error{
        /// The next record is valid but is not the expected marker.
        UnexpectedRecordTag,
    };

/// Decode one marker and require its payload to be empty.
pub fn decode(
    kind: Kind,
    source: *std.Io.Reader,
) DecodeError!void {
    var record_reader: record.Reader = undefined;
    try record_reader.init(source);
    if (record_reader.header.tag != kind.tag()) {
        return error.UnexpectedRecordTag;
    }
    try record_reader.finish();
}

const test_ready_fixture = test_fixture.parse(
    @embedFile("testdata/checkpoint-ready-v1.hex"),
);

test "READY golden encoding" {
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

    // Decode the checked-in record rather than the generated candidate.
    var source: std.Io.Reader = .fixed(&test_ready_fixture);
    try source.discardAll(prefix.len);
    try decode(.ready, &source);
}

test "READY and FINISH are empty marker records" {
    const testing = std.testing;

    var snapshot: std.Io.Writer.Allocating = .init(testing.allocator);
    defer snapshot.deinit();
    var stream: record.Writer = .init(
        testing.allocator,
        &snapshot.writer,
    );
    defer stream.deinit();
    try stream.writer().writeAll("prefix");

    const ready_offset = snapshot.written().len;
    try encode(.ready, &stream);
    try stream.writer().writeAll("history");
    const finish_offset = snapshot.written().len;
    try encode(.finish, &stream);

    try testing.expectEqual(
        record.Header.len,
        finish_offset - ready_offset - "history".len,
    );
    try testing.expectEqual(
        record.Header.len,
        snapshot.written().len - finish_offset,
    );

    var source: std.Io.Reader = .fixed(snapshot.written());
    try source.discardAll(ready_offset);
    try decode(.ready, &source);
    try source.discardAll("history".len);
    try decode(.finish, &source);
}

test "checkpoint rejects wrong tags and nonempty payloads" {
    const testing = std.testing;

    var snapshot: std.Io.Writer.Allocating = .init(testing.allocator);
    defer snapshot.deinit();
    var stream: record.Writer = .init(
        testing.allocator,
        &snapshot.writer,
    );
    defer stream.deinit();
    try encode(.ready, &stream);

    var wrong_tag_source: std.Io.Reader = .fixed(snapshot.written());
    try testing.expectError(
        error.UnexpectedRecordTag,
        decode(.finish, &wrong_tag_source),
    );

    var invalid: std.Io.Writer.Allocating = .init(testing.allocator);
    defer invalid.deinit();
    var invalid_stream: record.Writer = .init(
        testing.allocator,
        &invalid.writer,
    );
    defer invalid_stream.deinit();
    const invalid_payload = invalid_stream.begin(.ready);
    errdefer invalid_stream.cancel();
    try invalid_payload.writeByte(0);
    try invalid_stream.finish();

    var invalid_source: std.Io.Reader = .fixed(invalid.written());
    try testing.expectError(
        error.PayloadNotExhausted,
        decode(.ready, &invalid_source),
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
    try encode(.finish, &finished_stream);
    try finished.writer.writeByte(0);

    var source: std.Io.Reader = .fixed(finished.written());
    try decode(.finish, &source);
    try testing.expectEqual(@as(u8, 0), try source.takeByte());
}
