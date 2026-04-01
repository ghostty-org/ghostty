//! Kitty clipboard protocol (OSC 5522) paste encoding helpers.
//! Spec: https://rockorager.dev/misc/bracketed-paste-mime/
//!
//! When mode 5522 is enabled, paste events send an unsolicited MIME
//! type listing with a single-use password. The application then
//! requests specific MIME data using the password.

const std = @import("std");
const Allocator = std.mem.Allocator;

const parsers = @import("../terminal/osc/parsers/kitty_clipboard_protocol.zig");
pub const Status = parsers.Status;

/// Maximum raw payload size per DATA packet (before base64 encoding).
/// The spec limits payload to 4096 bytes pre-encoding.
pub const chunk_raw_max = 4096;

/// Chunk size in base64 characters. We slice a pre-encoded base64 stream,
/// so middle chunks have no padding: N chars decode to N/4*3 raw bytes.
/// To stay at or under 4096 raw bytes: (4096/3)*4 = 5460 chars → 4095 bytes.
pub const chunk_b64_max = (chunk_raw_max / 3) * 4;

comptime {
    std.debug.assert(chunk_b64_max % 4 == 0);
    std.debug.assert(chunk_b64_max / 4 * 3 <= chunk_raw_max);
}

/// Maximum raw MIME type length. Must match apprt.ClipboardRequest.KittyMimeRead
/// so we never advertise a MIME type the reader can't accept back.
/// 256 covers all IANA-registered types including the OpenXML Office types
/// (65-73 bytes) with comfortable headroom.
pub const mime_max_len = 256;

/// Encode an unsolicited MIME type listing for a paste event.
/// This is sent by the terminal when the user pastes and mode 5522 is enabled.
///
/// The `mimes` argument is a newline-separated list of MIME types.
/// The `password` is raw bytes that will be base64-encoded.
pub fn encodeMimeList(
    alloc: Allocator,
    password: []const u8,
    mimes: []const u8,
) Allocator.Error![]u8 {
    const b64 = std.base64.standard.Encoder;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);

    var pw_buf: [64]u8 = undefined;
    const pw_size = b64.calcSize(password.len);
    std.debug.assert(pw_size <= pw_buf.len);
    const pw_b64 = b64.encode(pw_buf[0..pw_size], password);

    try buf.writer(alloc).print(
        "\x1b]5522;type=read:status=OK:password={s}\x1b\\",
        .{pw_b64},
    );

    var it = std.mem.tokenizeScalar(u8, mimes, '\n');
    while (it.next()) |mime| {
        const trimmed = std.mem.trim(u8, mime, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        if (trimmed.len > mime_max_len) continue;

        var mime_buf: [b64.calcSize(mime_max_len)]u8 = undefined;
        const mime_b64 = b64.encode(mime_buf[0..b64.calcSize(trimmed.len)], trimmed);

        try buf.writer(alloc).print(
            "\x1b]5522;type=read:status=DATA:mime={s}\x1b\\",
            .{mime_b64},
        );
    }

    try buf.appendSlice(alloc, "\x1b]5522;type=read:status=DONE\x1b\\");

    return buf.toOwnedSlice(alloc);
}

/// Encode a MIME data response. The `data` is already base64-encoded
/// (typically by the apprt). Data is chunked into DATA packets.
pub fn encodeMimeData(
    alloc: Allocator,
    mime: []const u8,
    data: []const u8,
) Allocator.Error![]u8 {
    const b64 = std.base64.standard.Encoder;

    std.debug.assert(mime.len <= mime_max_len);
    var mime_buf: [b64.calcSize(mime_max_len)]u8 = undefined;
    const mime_b64 = b64.encode(mime_buf[0..b64.calcSize(mime.len)], mime);

    // Per-chunk overhead is ~60 bytes of OSC framing plus the MIME echo.
    // Pre-size to avoid O(log n) reallocs when encoding multi-MB images.
    const chunks = (data.len + chunk_b64_max - 1) / chunk_b64_max;
    const per_chunk_overhead = 64 + mime_b64.len;
    const cap = data.len + chunks * per_chunk_overhead + 128;

    var buf: std.ArrayList(u8) = try .initCapacity(alloc, cap);
    errdefer buf.deinit(alloc);

    try buf.appendSlice(alloc, "\x1b]5522;type=read:status=OK\x1b\\");

    var offset: usize = 0;
    while (offset < data.len) {
        const end = @min(offset + chunk_b64_max, data.len);
        try buf.writer(alloc).print(
            "\x1b]5522;type=read:status=DATA:mime={s};{s}\x1b\\",
            .{ mime_b64, data[offset..end] },
        );
        offset = end;
    }

    try buf.appendSlice(alloc, "\x1b]5522;type=read:status=DONE\x1b\\");

    return buf.toOwnedSlice(alloc);
}

/// Encode an error response. Using the Status enum gives compile-time
/// drift detection against the OSC parser.
pub fn encodeError(comptime status: Status) []const u8 {
    return "\x1b]5522;type=read:status=" ++ @tagName(status) ++ "\x1b\\";
}

test "encodeMimeList: single text/plain" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = try encodeMimeList(alloc, "secret123456789a", "text/plain");
    defer alloc.free(result);

    try testing.expect(std.mem.startsWith(u8, result, "\x1b]5522;type=read:status=OK:password="));
    try testing.expect(std.mem.indexOf(u8, result, "status=DATA:mime=dGV4dC9wbGFpbg==") != null);
    try testing.expect(std.mem.endsWith(u8, result, "\x1b]5522;type=read:status=DONE\x1b\\"));
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, result, "\x1b\\"));
}

test "encodeMimeList: multiple MIME types" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = try encodeMimeList(
        alloc,
        "pw",
        "text/plain\nimage/png\ntext/html",
    );
    defer alloc.free(result);

    try testing.expectEqual(@as(usize, 5), std.mem.count(u8, result, "\x1b\\"));
    try testing.expect(std.mem.indexOf(u8, result, "dGV4dC9wbGFpbg==") != null);
    try testing.expect(std.mem.indexOf(u8, result, "aW1hZ2UvcG5n") != null);
    try testing.expect(std.mem.indexOf(u8, result, "dGV4dC9odG1s") != null);
}

test "encodeMimeList: empty MIME list" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = try encodeMimeList(alloc, "pw", "");
    defer alloc.free(result);

    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, result, "\x1b\\"));
    try testing.expect(std.mem.indexOf(u8, result, "status=DATA") == null);
}

test "encodeMimeList: whitespace-only MIME entries skipped" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = try encodeMimeList(alloc, "pw", "text/plain\n   \n\t\nimage/png");
    defer alloc.free(result);

    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, result, "\x1b\\"));
}

test "encodeMimeList: overlong MIME type skipped" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Exactly at the limit: included
    {
        const at_limit = "x" ** mime_max_len;
        const result = try encodeMimeList(alloc, "pw", at_limit);
        defer alloc.free(result);
        try testing.expectEqual(@as(usize, 3), std.mem.count(u8, result, "\x1b\\"));
    }

    // One byte over: skipped. Prevents advertising a MIME the reader
    // can't accept back through the fixed-size request struct.
    {
        const over = "x" ** (mime_max_len + 1);
        const result = try encodeMimeList(alloc, "pw", over);
        defer alloc.free(result);
        try testing.expectEqual(@as(usize, 2), std.mem.count(u8, result, "\x1b\\"));
    }
}

test "encodeMimeList: Office MIME types pass through" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // 65-73 bytes — well under mime_max_len. Someone might actually want
    // to paste an .xlsx into a TUI editor.
    const office_types =
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet\n" ++
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document\n" ++
        "application/vnd.openxmlformats-officedocument.presentationml.presentation\n" ++
        "text/plain";

    const result = try encodeMimeList(alloc, "pw", office_types);
    defer alloc.free(result);

    // All four MIME types advertised + OK + DONE = 6 packets
    try testing.expectEqual(@as(usize, 6), std.mem.count(u8, result, "\x1b\\"));
}

test "encodeMimeList: password base64 round-trip" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const pw = [_]u8{ 0x00, 0xFF, 0x42, 0x13, 0x37, 0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE, 0x12, 0x34, 0x56 };
    const result = try encodeMimeList(alloc, &pw, "text/plain");
    defer alloc.free(result);

    const prefix = "password=";
    const start = std.mem.indexOf(u8, result, prefix).? + prefix.len;
    const end = std.mem.indexOfScalarPos(u8, result, start, '\x1b').?;
    const pw_b64 = result[start..end];

    var decoded: [16]u8 = undefined;
    try std.base64.standard.Decoder.decode(&decoded, pw_b64);
    try testing.expectEqualSlices(u8, &pw, &decoded);
}

test "encodeMimeData: small payload single chunk" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = try encodeMimeData(alloc, "text/plain", "SGVsbG8=");
    defer alloc.free(result);

    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, result, "\x1b\\"));
    try testing.expect(std.mem.indexOf(u8, result, ";SGVsbG8=\x1b") != null);
}

test "encodeMimeData: empty payload" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = try encodeMimeData(alloc, "text/plain", "");
    defer alloc.free(result);

    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, result, "\x1b\\"));
}

test "encodeMimeData: large payload chunked" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const data = try alloc.alloc(u8, chunk_b64_max * 3 + 100);
    defer alloc.free(data);
    @memset(data, 'A');

    const result = try encodeMimeData(alloc, "image/png", data);
    defer alloc.free(result);

    try testing.expectEqual(@as(usize, 6), std.mem.count(u8, result, "\x1b\\"));
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, result, "status=DATA"));
}

test "chunk_b64_max decodes to <= 4096 raw bytes" {
    const testing = std.testing;
    const decoded = chunk_b64_max / 4 * 3;
    try testing.expect(decoded <= chunk_raw_max);
    try testing.expectEqual(@as(usize, 5460), chunk_b64_max);
    try testing.expectEqual(@as(usize, 4095), decoded);
}

test "encodeMimeData: chunk boundary exact multiple" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const data = try alloc.alloc(u8, chunk_b64_max * 2);
    defer alloc.free(data);
    @memset(data, 'B');

    const result = try encodeMimeData(alloc, "image/png", data);
    defer alloc.free(result);

    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, result, "status=DATA"));
}

test "encodeMimeData: chunks preserve data integrity" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const b64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const data = try alloc.alloc(u8, chunk_b64_max + 500);
    defer alloc.free(data);
    for (data, 0..) |*b, i| b.* = b64_alphabet[i % 64];

    const result = try encodeMimeData(alloc, "text/plain", data);
    defer alloc.free(result);

    var reassembled: std.ArrayList(u8) = .empty;
    defer reassembled.deinit(alloc);

    var it = std.mem.splitSequence(u8, result, "\x1b\\");
    while (it.next()) |seq| {
        if (std.mem.indexOf(u8, seq, "status=DATA") == null) continue;
        const sep = std.mem.lastIndexOfScalar(u8, seq, ';') orelse continue;
        try reassembled.appendSlice(alloc, seq[sep + 1 ..]);
    }

    try testing.expectEqualSlices(u8, data, reassembled.items);
}

test "encodeError: all error status codes" {
    const testing = std.testing;
    inline for (.{ .EINVAL, .EIO, .ENOSYS, .EPERM, .EBUSY }) |status| {
        const result = encodeError(status);
        try testing.expect(std.mem.startsWith(u8, result, "\x1b]5522;type=read:status="));
        try testing.expect(std.mem.endsWith(u8, result, "\x1b\\"));
        try testing.expect(std.mem.indexOf(u8, result, @tagName(status)) != null);
    }
}

// Roundtrip tests: verify our encoder output can be parsed back by the
// OSC parser. Catches encoder/parser drift.

const terminal = @import("../terminal/main.zig");

test "roundtrip: encodeMimeList output parses correctly" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const password = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10 };
    const encoded = try encodeMimeList(alloc, &password, "text/plain\nimage/png");
    defer alloc.free(encoded);

    var packets: std.ArrayList(struct {
        type: ?[]const u8,
        status: ?[]const u8,
        mime: ?[]const u8,
        password: ?[]const u8,
    }) = .empty;
    defer {
        for (packets.items) |p| {
            if (p.type) |v| alloc.free(v);
            if (p.status) |v| alloc.free(v);
            if (p.mime) |v| alloc.free(v);
            if (p.password) |v| alloc.free(v);
        }
        packets.deinit(alloc);
    }

    var offset: usize = 0;
    while (offset < encoded.len) {
        const osc_start = std.mem.indexOfPos(u8, encoded, offset, "\x1b]") orelse break;
        const st = std.mem.indexOfPos(u8, encoded, osc_start, "\x1b\\") orelse break;

        var p: terminal.osc.Parser = .init(alloc);
        defer p.deinit();
        for (encoded[osc_start + 2 .. st]) |ch| p.next(ch);
        const cmd = p.end('\x1b') orelse return error.ParseFailed;

        try testing.expect(cmd.* == .kitty_clipboard_protocol);
        const kcp = cmd.kitty_clipboard_protocol;

        try packets.append(alloc, .{
            .type = if (kcp.readOption(.type)) |v| try alloc.dupe(u8, @tagName(v)) else null,
            .status = if (kcp.readOption(.status)) |v| try alloc.dupe(u8, @tagName(v)) else null,
            .mime = if (kcp.readOption(.mime)) |v| try alloc.dupe(u8, v) else null,
            .password = if (kcp.readOption(.password)) |v| try alloc.dupe(u8, v) else null,
        });

        offset = st + 2;
    }

    // OK → DATA(text/plain) → DATA(image/png) → DONE
    try testing.expectEqual(@as(usize, 4), packets.items.len);

    try testing.expectEqualStrings("read", packets.items[0].type.?);
    try testing.expectEqualStrings("OK", packets.items[0].status.?);
    try testing.expect(packets.items[0].password != null);

    try testing.expectEqualStrings("DATA", packets.items[1].status.?);
    try testing.expectEqualStrings("dGV4dC9wbGFpbg==", packets.items[1].mime.?);

    try testing.expectEqualStrings("DATA", packets.items[2].status.?);
    try testing.expectEqualStrings("aW1hZ2UvcG5n", packets.items[2].mime.?);

    try testing.expectEqualStrings("DONE", packets.items[3].status.?);

    var pw_decoded: [16]u8 = undefined;
    try std.base64.standard.Decoder.decode(&pw_decoded, packets.items[0].password.?);
    try testing.expectEqualSlices(u8, &password, &pw_decoded);
}

test "roundtrip: encodeMimeData chunks parse correctly" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const raw_data = try alloc.alloc(u8, chunk_b64_max + 200);
    defer alloc.free(raw_data);
    @memset(raw_data, 'Q');

    const encoded = try encodeMimeData(alloc, "image/png", raw_data);
    defer alloc.free(encoded);

    var reassembled: std.ArrayList(u8) = .empty;
    defer reassembled.deinit(alloc);

    var packet_count: usize = 0;
    var offset: usize = 0;
    while (offset < encoded.len) {
        const osc_start = std.mem.indexOfPos(u8, encoded, offset, "\x1b]") orelse break;
        const st = std.mem.indexOfPos(u8, encoded, osc_start, "\x1b\\") orelse break;

        var p: terminal.osc.Parser = .init(alloc);
        defer p.deinit();
        for (encoded[osc_start + 2 .. st]) |ch| p.next(ch);
        const cmd = p.end('\x1b') orelse return error.ParseFailed;

        try testing.expect(cmd.* == .kitty_clipboard_protocol);
        const kcp = cmd.kitty_clipboard_protocol;
        packet_count += 1;

        if (kcp.readOption(.status) == .DATA) {
            try testing.expectEqualStrings("aW1hZ2UvcG5n", kcp.readOption(.mime).?);
            const payload = kcp.payload orelse return error.MissingPayload;
            try reassembled.appendSlice(alloc, payload);
        }

        offset = st + 2;
    }

    try testing.expectEqual(@as(usize, 4), packet_count);
    try testing.expectEqualSlices(u8, raw_data, reassembled.items);
}

test "roundtrip: encodeError parses correctly" {
    const testing = std.testing;
    const alloc = testing.allocator;

    inline for (.{ Status.EPERM, .EINVAL, .EIO, .ENOSYS }) |status| {
        const encoded = encodeError(status);

        var p: terminal.osc.Parser = .init(alloc);
        defer p.deinit();
        for (encoded[2 .. encoded.len - 2]) |ch| p.next(ch);
        const cmd = p.end('\x1b') orelse return error.ParseFailed;

        try testing.expect(cmd.* == .kitty_clipboard_protocol);
        const kcp = cmd.kitty_clipboard_protocol;
        try testing.expectEqual(parsers.Operation.read, kcp.readOption(.type).?);
        try testing.expectEqual(status, kcp.readOption(.status).?);
    }
}

// Allocation failure: every alloc point in the encoders is a leak vector if
// errdefer is wrong. This walks a failing allocator through every index.

test "encodeMimeList: no leaks under allocation failure" {
    const testing = std.testing;

    // checkAllAllocationFailures runs the function once per allocation site,
    // failing at index 0, then 1, then 2, etc. testing.allocator catches any
    // un-freed bytes when an error path returns. If errdefer buf.deinit() is
    // missing or fires on the wrong scope, this fails.
    const TestFn = struct {
        fn run(alloc: Allocator) !void {
            const result = try encodeMimeList(
                alloc,
                "0123456789abcdef",
                // Multiple MIME types means multiple writer.print() allocations
                "text/plain\ntext/html\nimage/png\napplication/json",
            );
            alloc.free(result);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, TestFn.run, .{});
}

test "encodeMimeData: no leaks under allocation failure with large multi-chunk payload" {
    const testing = std.testing;

    const TestFn = struct {
        fn run(alloc: Allocator) !void {
            // Three full chunks plus a remainder — exercises the loop body's
            // writer.print() allocation for each chunk separately.
            var data: [chunk_b64_max * 3 + 100]u8 = undefined;
            @memset(&data, 'X');
            const result = try encodeMimeData(alloc, "image/png", &data);
            alloc.free(result);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, TestFn.run, .{});
}

// Spec wire-format compliance: every byte we emit is read by an application
// expecting exact framing. A single off-by-one in delimiters breaks the peer.

test "encodeMimeData: every chunk respects the 4096-byte raw limit" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // 5 full chunks plus a partial. The spec says "no more than 4096 bytes
    // before encoding" — if a single chunk exceeds that, kitty (or anything
    // following the spec) is allowed to reject the whole transfer.
    const data = try alloc.alloc(u8, chunk_b64_max * 5 + 1000);
    defer alloc.free(data);
    @memset(data, 'A');

    const result = try encodeMimeData(alloc, "application/octet-stream", data);
    defer alloc.free(result);

    var it = std.mem.splitSequence(u8, result, "\x1b\\");
    while (it.next()) |seq| {
        if (std.mem.indexOf(u8, seq, "status=DATA") == null) continue;
        const sep = std.mem.lastIndexOfScalar(u8, seq, ';') orelse continue;
        const payload = seq[sep + 1 ..];

        // Middle chunks (no padding): N chars decode to N/4*3 bytes.
        // Final chunk may have padding which decodes to fewer bytes —
        // either way the upper bound is N/4*3.
        const decoded_max = payload.len / 4 * 3;
        try testing.expect(decoded_max <= chunk_raw_max);
    }
}

test "encodeMimeData: capacity estimate covers actual output (no realloc growth)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // The encoder pre-sizes the buffer to avoid O(log n) reallocs on big
    // images. If the estimate is too low, the buffer grows mid-encode —
    // that's a perf bug (silent ~2x memory churn on a 10MB image), and
    // it means the per_chunk_overhead constant is wrong.
    //
    // We can't directly observe reallocs from outside ArrayList, but we
    // can re-derive the estimate and assert the final size fits.
    const cases = [_]struct { mime: []const u8, data_len: usize }{
        .{ .mime = "text/plain", .data_len = 0 },
        .{ .mime = "text/plain", .data_len = 1 },
        .{ .mime = "text/plain", .data_len = chunk_b64_max },
        .{ .mime = "text/plain", .data_len = chunk_b64_max + 1 },
        .{ .mime = "image/png", .data_len = chunk_b64_max * 10 },
        // Longest MIME we accept — overhead estimate must account for it
        .{ .mime = "x" ** mime_max_len, .data_len = chunk_b64_max * 3 },
    };

    for (cases) |c| {
        const data = try alloc.alloc(u8, c.data_len);
        defer alloc.free(data);
        @memset(data, 'Z');

        const result = try encodeMimeData(alloc, c.mime, data);
        defer alloc.free(result);

        // Mirror the encoder's estimate
        const b64 = std.base64.standard.Encoder;
        const mime_b64_len = b64.calcSize(c.mime.len);
        const chunks = if (c.data_len == 0) 0 else (c.data_len + chunk_b64_max - 1) / chunk_b64_max;
        const per_chunk_overhead = 64 + mime_b64_len;
        const cap = c.data_len + chunks * per_chunk_overhead + 128;

        try testing.expect(result.len <= cap);
    }
}

test "encodeMimeData: payload bytes are reproduced exactly with no foreign bytes between chunks" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Unique byte at every position. If chunk N's last bytes leak into
    // chunk N+1's first bytes (or vice versa), or if the slicing skips/
    // duplicates bytes at boundaries, the reassembled stream won't match.
    // This is the data-bleed test: a single dropped, repeated, or foreign
    // byte fails byte-exact comparison.
    const b64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const sizes = [_]usize{
        chunk_b64_max - 1, // just under one chunk
        chunk_b64_max, // exactly one chunk
        chunk_b64_max + 1, // one byte into chunk 2
        chunk_b64_max * 2, // exactly two chunks
        chunk_b64_max * 7 + 333, // 8 chunks, last one weird size
    };

    for (sizes) |size| {
        const data = try alloc.alloc(u8, size);
        defer alloc.free(data);
        for (data, 0..) |*b, i| b.* = b64_alphabet[i % 64];

        const result = try encodeMimeData(alloc, "image/png", data);
        defer alloc.free(result);

        var reassembled: std.ArrayList(u8) = .empty;
        defer reassembled.deinit(alloc);

        var it = std.mem.splitSequence(u8, result, "\x1b\\");
        while (it.next()) |seq| {
            if (std.mem.indexOf(u8, seq, "status=DATA") == null) continue;
            const sep = std.mem.lastIndexOfScalar(u8, seq, ';') orelse continue;
            try reassembled.appendSlice(alloc, seq[sep + 1 ..]);
        }

        try testing.expectEqualSlices(u8, data, reassembled.items);
    }
}

test "encodeMimeData: MIME echo is identical in every DATA packet" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // The spec sends the MIME in every DATA packet for self-describing
    // chunks. If the encoder cached it once and accidentally reused a
    // stack buffer, packets after the first could carry garbage.
    const data = try alloc.alloc(u8, chunk_b64_max * 4);
    defer alloc.free(data);
    @memset(data, 'M');

    const result = try encodeMimeData(alloc, "text/html", data);
    defer alloc.free(result);

    const expected_mime = "dGV4dC9odG1s"; // base64("text/html")
    var data_packet_count: usize = 0;

    var it = std.mem.splitSequence(u8, result, "\x1b\\");
    while (it.next()) |seq| {
        if (std.mem.indexOf(u8, seq, "status=DATA") == null) continue;
        data_packet_count += 1;

        const mime_start = std.mem.indexOf(u8, seq, "mime=") orelse
            return error.MissingMime;
        const mime_field = seq[mime_start + 5 ..];
        const mime_end = std.mem.indexOfScalar(u8, mime_field, ';') orelse mime_field.len;

        try testing.expectEqualStrings(expected_mime, mime_field[0..mime_end]);
    }

    try testing.expectEqual(@as(usize, 4), data_packet_count);
}

test "encodeMimeList: packet ordering is OK first, DATA*, DONE last" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // The spec requires this exact ordering. An app reading our output
    // is a state machine: if DONE appears before DATA, or DATA before OK,
    // it's a protocol violation.
    const result = try encodeMimeList(
        alloc,
        "secretsecretsecr",
        "text/plain\nimage/png\ntext/html\napplication/json",
    );
    defer alloc.free(result);

    var seen_ok = false;
    var seen_done = false;
    var data_after_ok: usize = 0;

    var it = std.mem.splitSequence(u8, result, "\x1b\\");
    while (it.next()) |seq| {
        if (seq.len == 0) continue;

        if (std.mem.indexOf(u8, seq, "status=OK") != null) {
            try testing.expect(!seen_ok); // exactly one OK
            try testing.expect(!seen_done);
            seen_ok = true;
        } else if (std.mem.indexOf(u8, seq, "status=DATA") != null) {
            try testing.expect(seen_ok);
            try testing.expect(!seen_done);
            data_after_ok += 1;
        } else if (std.mem.indexOf(u8, seq, "status=DONE") != null) {
            try testing.expect(seen_ok);
            try testing.expect(!seen_done); // exactly one DONE
            seen_done = true;
        }
    }

    try testing.expect(seen_ok);
    try testing.expect(seen_done);
    try testing.expectEqual(@as(usize, 4), data_after_ok);
}

test "encodeMimeList: output contains no naked ESC outside ST" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // A stray 0x1b that isn't part of "\x1b]" (OSC) or "\x1b\\" (ST)
    // would corrupt any terminal parser. This checks we don't accidentally
    // emit one — e.g., if the password contains 0x1b.
    const password = [_]u8{ 0x1b, 0x5d, 0x5c, 0x07, 0x00, 0xff, 0x1b, 0x1b, 0x5c, 0x5c, 0x5c, 0x5c, 0x5c, 0x5c, 0x5c, 0x5c };
    const result = try encodeMimeList(alloc, &password, "text/plain");
    defer alloc.free(result);

    var i: usize = 0;
    while (i < result.len) : (i += 1) {
        if (result[i] != 0x1b) continue;
        // Every ESC must be followed by ']' (OSC start) or '\' (ST end)
        try testing.expect(i + 1 < result.len);
        const next = result[i + 1];
        try testing.expect(next == ']' or next == '\\');
    }
}

// Spec example reproduction: the spec gives byte-exact examples. Our encoder
// should produce them. If these tests fail, we're not interoperable.

test "spec example: text/plain paste with password 'secret123'" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // From https://rockorager.dev/misc/bracketed-paste-mime/ — the spec's
    // first example shows password "secret123" base64 → "c2VjcmV0MTIz".
    // Our encoder takes raw bytes, so the password input is the literal
    // string "secret123" (9 bytes, not 16 — the spec doesn't fix length,
    // we chose 16 for entropy).
    const result = try encodeMimeList(alloc, "secret123", "text/plain");
    defer alloc.free(result);

    // Spec's exact output:
    // T: \x1b]5522;type=read:status=OK:password=c2VjcmV0MTIz\x1b\\
    // T: \x1b]5522;type=read:status=DATA:mime=dGV4dC9wbGFpbg==\x1b\\
    // T: \x1b]5522;type=read:status=DONE\x1b\\
    const expected =
        "\x1b]5522;type=read:status=OK:password=c2VjcmV0MTIz\x1b\\" ++
        "\x1b]5522;type=read:status=DATA:mime=dGV4dC9wbGFpbg==\x1b\\" ++
        "\x1b]5522;type=read:status=DONE\x1b\\";

    try testing.expectEqualStrings(expected, result);
}

test "spec example: data response 'Hello, world!' as text/plain" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Spec shows: SGVsbG8sIHdvcmxkIQ== which is base64("Hello, world!")
    // Our encoder takes pre-encoded base64 (the apprt encodes), so we
    // pass the b64 string directly.
    const result = try encodeMimeData(alloc, "text/plain", "SGVsbG8sIHdvcmxkIQ==");
    defer alloc.free(result);

    const expected =
        "\x1b]5522;type=read:status=OK\x1b\\" ++
        "\x1b]5522;type=read:status=DATA:mime=dGV4dC9wbGFpbg==;SGVsbG8sIHdvcmxkIQ==\x1b\\" ++
        "\x1b]5522;type=read:status=DONE\x1b\\";

    try testing.expectEqualStrings(expected, result);
}

test "spec example: HTML data response '<b>Bold text</b>'" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Spec: PGI+Qm9sZCB0ZXh0PC9iPg== = base64("<b>Bold text</b>")
    const result = try encodeMimeData(alloc, "text/html", "PGI+Qm9sZCB0ZXh0PC9iPg==");
    defer alloc.free(result);

    const expected =
        "\x1b]5522;type=read:status=OK\x1b\\" ++
        "\x1b]5522;type=read:status=DATA:mime=dGV4dC9odG1s;PGI+Qm9sZCB0ZXh0PC9iPg==\x1b\\" ++
        "\x1b]5522;type=read:status=DONE\x1b\\";

    try testing.expectEqualStrings(expected, result);
}

// Adversarial inputs: an apprt could pass us anything. These should be
// handled gracefully, not crash or corrupt the output.

test "encodeMimeList: MIME containing colon doesn't break OSC option parsing" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // ":" is the OSC metadata separator. A MIME like "text/plain:v2"
    // (not standard but the apprt could send anything) gets base64'd,
    // so the colon is encoded away. Verify the output parses cleanly.
    const result = try encodeMimeList(alloc, "pw", "text/plain:v2");
    defer alloc.free(result);

    var p: terminal.osc.Parser = .init(alloc);
    defer p.deinit();

    // Find the DATA packet
    const data_start = std.mem.indexOf(u8, result, "status=DATA").?;
    const osc_start = std.mem.lastIndexOfScalar(u8, result[0..data_start], 0x1b).?;
    const st = std.mem.indexOfPos(u8, result, data_start, "\x1b\\").?;

    for (result[osc_start + 2 .. st]) |ch| p.next(ch);
    const cmd = p.end('\x1b').?;

    const mime_b64 = cmd.kitty_clipboard_protocol.readOption(.mime).?;
    var decoded: [32]u8 = undefined;
    const len = try std.base64.standard.Decoder.calcSizeForSlice(mime_b64);
    try std.base64.standard.Decoder.decode(decoded[0..len], mime_b64);

    try testing.expectEqualStrings("text/plain:v2", decoded[0..len]);
}

test "encodeMimeList: MIME with trailing newline doesn't produce empty DATA packet" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // tokenizeScalar correctly skips empty tokens, but a regression to
    // splitScalar would produce an empty entry. Belt and suspenders.
    const result = try encodeMimeList(alloc, "pw", "text/plain\n");
    defer alloc.free(result);

    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, result, "status=DATA"));
}

test "encodeMimeList: 100 MIME types — no quadratic behavior" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var mimes: std.ArrayList(u8) = .empty;
    defer mimes.deinit(alloc);
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try mimes.writer(alloc).print("application/x-type-{d}\n", .{i});
    }

    const result = try encodeMimeList(alloc, "pw", mimes.items);
    defer alloc.free(result);

    try testing.expectEqual(@as(usize, 100), std.mem.count(u8, result, "status=DATA"));
    // Each entry adds <100 bytes of output. Anything wildly above that
    // means the encoder is doing something quadratic (like re-encoding
    // the password per entry).
    try testing.expect(result.len < 100 * 100 + 200);
}

test "encodeMimeData: payload that LOOKS like an OSC sequence is preserved literally" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // The data is opaque base64 to us. If the apprt's base64 happens to
    // produce a substring like "5522;type=" (entirely possible — base64
    // uses [A-Za-z0-9+/=] but the surrounding context could line up),
    // the encoder must NOT interpret it. The chunk goes between ';' and
    // ST, so it's payload, not metadata.
    //
    // This particular string doesn't decode to anything meaningful but
    // it stress-tests the framing.
    const sneaky = "ABCD]5522;type=read:status=EVILpasswordEFGH";
    const result = try encodeMimeData(alloc, "text/plain", sneaky);
    defer alloc.free(result);

    // The sneaky string appears exactly once, in the payload position
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, result, sneaky));
    // And it's framed correctly — preceded by ';', followed by ST
    const idx = std.mem.indexOf(u8, result, sneaky).?;
    try testing.expectEqual(@as(u8, ';'), result[idx - 1]);
    try testing.expectEqual(@as(u8, 0x1b), result[idx + sneaky.len]);
    try testing.expectEqual(@as(u8, '\\'), result[idx + sneaky.len + 1]);
}
