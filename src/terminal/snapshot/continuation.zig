//! Continuation record type.
//!
//! Continuation uses the standard record header. All trailing bytes
//! are payload bytes for the continuation state.
//!
//! A continuation's payload must be the minimal bytes to go from
//! a ground state to a non-ground state in a VT emulator. Any extra
//! bytes are treated as a validation error.

const std = @import("std");
const Allocator = std.mem.Allocator;
const record = @import("record.zig");
const stream_continuation = @import("../stream_continuation.zig");
const test_fixture = @import("fixture.zig");

/// A borrowed continuation value supplied to encode, or an allocator-owned
/// value stored in a decoded complete snapshot.
pub const Value = union(enum) {
    /// Neither the VT parser nor UTF-8 decoder has unfinished state.
    ground,

    /// Canonical replay-safe PTY bytes. Empty is equivalent to `ground`.
    bytes: []const u8,
};

pub const ValidateError = stream_continuation.ValidateError || error{
    /// The common record's u32 payload length cannot represent these bytes.
    Overflow,
};

/// Validate a continuation before any snapshot bytes are emitted.
pub fn validate(value: Value) ValidateError!void {
    switch (value) {
        .ground => {},
        .bytes => |bytes| {
            if (std.math.cast(u32, bytes.len) == null) {
                return error.Overflow;
            }
            try stream_continuation.validate(bytes);
        },
    }
}

pub const EncodeError = ValidateError || record.Writer.FinishError;

/// Encode one complete CONTINUATION record.
pub fn encode(
    value: Value,
    stream: *record.Writer,
) EncodeError!void {
    try validate(value);

    const payload = stream.begin(.continuation);
    errdefer stream.cancel();
    switch (value) {
        .ground => {},
        .bytes => |bytes| try payload.writeAll(bytes),
    }
    try stream.finish();
}

pub const DecodeError = Allocator.Error ||
    stream_continuation.ValidateError ||
    record.Reader.InitError ||
    record.Reader.FinishError ||
    std.Io.Reader.Error ||
    error{
        /// The next record is valid but is not CONTINUATION.
        UnexpectedRecordTag,

        /// The declared payload exceeds caller policy.
        ContinuationLimitExceeded,
    };

/// Decode and validate one CONTINUATION record.
///
/// A zero-length payload returns `ground` without allocating. A nonempty
/// payload returns allocator-owned bytes; although `Value.bytes` is a const
/// slice, the caller must eventually free it with the same allocator.
pub fn decode(
    alloc: Allocator,
    source: *std.Io.Reader,
    max_bytes: usize,
) DecodeError!Value {
    var record_reader: record.Reader = undefined;
    try record_reader.init(source);
    if (record_reader.header.tag != .continuation) {
        return error.UnexpectedRecordTag;
    }

    // Validate the header payload vs our max size since the header
    // enforces it.
    const len: usize = record_reader.header.payload_len;
    if (len > max_bytes) return error.ContinuationLimitExceeded;

    if (len == 0) {
        // Empty is the ground representation, but finish is still required:
        // its CRC covers the tag and zero length even though there is no body.
        try record_reader.finish();
        return .ground;
    }

    // Consume the bytes
    const bytes = try alloc.alloc(u8, len);
    errdefer alloc.free(bytes);
    try record_reader.payloadReader().readSliceAll(bytes);
    try record_reader.finish();

    // Framing is valid, so it is now safe to classify the bytes as replay
    // state. Validation requires a minimal, unfinished, side-effect-free tail.
    try stream_continuation.validate(bytes);

    // Ownership transfers to the returned Value only after all validation.
    return .{ .bytes = bytes };
}

const test_ground_fixture = test_fixture.parse(@embedFile("testdata/continuation-ground-v1.hex"));
const test_utf8_fixture = test_fixture.parse(@embedFile("testdata/continuation-utf8-v1.hex"));
const test_esc_fixture = test_fixture.parse(@embedFile("testdata/continuation-esc-v1.hex"));
const test_csi_fixture = test_fixture.parse(@embedFile("testdata/continuation-csi-v1.hex"));
const test_osc_fixture = test_fixture.parse(@embedFile("testdata/continuation-osc-v1.hex"));
const test_dcs_fixture = test_fixture.parse(@embedFile("testdata/continuation-dcs-v1.hex"));
const test_apc_fixture = test_fixture.parse(@embedFile("testdata/continuation-apc-v1.hex"));

test "continuation golden records" {
    const Golden = struct {
        path: []const u8,
        candidate: []const u8,
        value: Value,
        expected: []const u8,
    };
    const values = [_]Golden{
        .{
            .path = "src/terminal/snapshot/testdata/continuation-ground-v1.hex",
            .candidate = "snapshot_fixture-continuation-ground-v1.hex",
            .value = .ground,
            .expected = &test_ground_fixture,
        },
        .{
            .path = "src/terminal/snapshot/testdata/continuation-utf8-v1.hex",
            .candidate = "snapshot_fixture-continuation-utf8-v1.hex",
            .value = .{ .bytes = "\xF0\x9F\x98" },
            .expected = &test_utf8_fixture,
        },
        .{
            .path = "src/terminal/snapshot/testdata/continuation-esc-v1.hex",
            .candidate = "snapshot_fixture-continuation-esc-v1.hex",
            .value = .{ .bytes = "\x1b" },
            .expected = &test_esc_fixture,
        },
        .{
            .path = "src/terminal/snapshot/testdata/continuation-csi-v1.hex",
            .candidate = "snapshot_fixture-continuation-csi-v1.hex",
            .value = .{ .bytes = "\x1b[31" },
            .expected = &test_csi_fixture,
        },
        .{
            .path = "src/terminal/snapshot/testdata/continuation-osc-v1.hex",
            .candidate = "snapshot_fixture-continuation-osc-v1.hex",
            .value = .{ .bytes = "\x1b]2;title" },
            .expected = &test_osc_fixture,
        },
        .{
            .path = "src/terminal/snapshot/testdata/continuation-dcs-v1.hex",
            .candidate = "snapshot_fixture-continuation-dcs-v1.hex",
            .value = .{ .bytes = "\x1bPqdata" },
            .expected = &test_dcs_fixture,
        },
        .{
            .path = "src/terminal/snapshot/testdata/continuation-apc-v1.hex",
            .candidate = "snapshot_fixture-continuation-apc-v1.hex",
            .value = .{ .bytes = "\x1b_Gdata" },
            .expected = &test_apc_fixture,
        },
    };

    for (values) |golden| {
        var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer encoded.deinit();
        var stream: record.Writer = .init(
            std.testing.allocator,
            &encoded.writer,
        );
        defer stream.deinit();
        try encode(golden.value, &stream);
        try test_fixture.expectEqual(
            .bytes,
            golden.path,
            golden.candidate,
            golden.expected,
            encoded.written(),
        );
    }
}

test "continuation validates supported unfinished states" {
    const values = [_][]const u8{
        "\x1b",
        "\x1b[31",
        "\x1b]2;title",
        "\x1bPqdata",
        "\x1b_Gdata",
        "\xF0\x9F\x98",
    };
    for (values) |bytes| try validate(.{ .bytes = bytes });
}

test "empty continuation bytes encode and decode as ground" {
    const testing = std.testing;
    try validate(.{ .bytes = "" });

    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    var stream: record.Writer = .init(testing.allocator, &encoded.writer);
    defer stream.deinit();
    try encode(.{ .bytes = "" }, &stream);
    try testing.expectEqualStrings(&test_ground_fixture, encoded.written());

    var source: std.Io.Reader = .fixed(encoded.written());
    const decoded = try decode(testing.allocator, &source, 0);
    try testing.expect(decoded == .ground);
}

test "continuation rejects invalid semantic shapes" {
    const testing = std.testing;
    try testing.expectError(
        error.NoPendingState,
        validate(.{ .bytes = "\x1b[31m" }),
    );
    try testing.expectError(
        error.ReplayWouldCommit,
        validate(.{ .bytes = "\x1b[31\x07" }),
    );
    try testing.expectError(
        error.NonCanonicalContinuation,
        validate(.{ .bytes = "prefix\x1b[31" }),
    );
    try testing.expectError(
        error.NonCanonicalContinuation,
        validate(.{ .bytes = "\x1b[31\x1b[4" }),
    );
}

test "continuation record round trip and cap" {
    const testing = std.testing;
    const values = [_]Value{
        .ground,
        .{ .bytes = "\x1b[31" },
        .{ .bytes = "\xF0\x9F" },
    };

    for (values) |value| {
        var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
        defer encoded.deinit();
        var stream: record.Writer = .init(testing.allocator, &encoded.writer);
        defer stream.deinit();
        try encode(value, &stream);

        var source: std.Io.Reader = .fixed(encoded.written());
        const decoded = try decode(testing.allocator, &source, 1024);
        defer switch (decoded) {
            .ground => {},
            .bytes => |bytes| testing.allocator.free(bytes),
        };
        switch (value) {
            .ground => try testing.expect(decoded == .ground),
            .bytes => |expected| try testing.expectEqualStrings(
                expected,
                decoded.bytes,
            ),
        }
    }

    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    var stream: record.Writer = .init(testing.allocator, &encoded.writer);
    defer stream.deinit();
    try encode(.{ .bytes = "\x1b[31" }, &stream);

    var capped_source: std.Io.Reader = .fixed(encoded.written());
    var failing = testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = 0,
    });
    try testing.expectError(
        error.ContinuationLimitExceeded,
        decode(failing.allocator(), &capped_source, 3),
    );
    try testing.expectEqual(
        @as(usize, record.Header.len),
        capped_source.seek,
    );
}

test "continuation record rejects truncation, checksum, and tag" {
    const testing = std.testing;

    for (0..test_csi_fixture.len) |len| {
        var source: std.Io.Reader = .fixed(test_csi_fixture[0..len]);
        try testing.expectError(
            error.EndOfStream,
            decode(testing.allocator, &source, 1024),
        );
    }

    var invalid_checksum = test_csi_fixture;
    invalid_checksum[6] ^= 1;
    var checksum_source: std.Io.Reader = .fixed(&invalid_checksum);
    try testing.expectError(
        error.InvalidChecksum,
        decode(testing.allocator, &checksum_source, 1024),
    );

    var wrong_tag = test_ground_fixture;
    std.mem.writeInt(u16, wrong_tag[0..2], @intFromEnum(record.Tag.ready), .little);
    var tag_source: std.Io.Reader = .fixed(&wrong_tag);
    try testing.expectError(
        error.UnexpectedRecordTag,
        decode(testing.allocator, &tag_source, 1024),
    );
}
