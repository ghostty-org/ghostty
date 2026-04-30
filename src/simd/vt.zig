const std = @import("std");
const options = @import("build_options");
const assert = @import("../quirks.zig").inlineAssert;
const indexOf = @import("index_of.zig").indexOf;

// vt.cpp
extern "c" fn ghostty_simd_decode_utf8_until_control_seq(
    input: [*]const u8,
    count: usize,
    output: [*]u32,
    output_count: *usize,
) usize;

const DecodeResult = struct {
    consumed: usize,
    decoded: usize,
};

pub fn utf8DecodeUntilControlSeq(
    input: []const u8,
    output: []u32,
) DecodeResult {
    assert(output.len >= input.len);

    if (comptime options.simd) {
        var decoded: usize = 0;
        const consumed = ghostty_simd_decode_utf8_until_control_seq(
            input.ptr,
            input.len,
            output.ptr,
            &decoded,
        );

        return .{ .consumed = consumed, .decoded = decoded };
    }

    return utf8DecodeUntilControlSeqScalar(input, output);
}

fn utf8DecodeUntilControlSeqScalar(
    input: []const u8,
    output: []u32,
) DecodeResult {
    // Find our escape
    const idx = indexOf(input, 0x1B) orelse input.len;
    const decode = input[0..idx];

    // Go through and decode one item at a time, following the W3C/Unicode
    // "U+FFFD Substitution of Maximal Subparts" algorithm for ill-formed
    // subsequences.
    var decode_offset: usize = 0;
    var decode_count: usize = 0;
    while (decode_offset < decode.len) {
        const b0 = decode[decode_offset];

        // ASCII fast path
        if (b0 < 0x80) {
            output[decode_count] = b0;
            decode_count += 1;
            decode_offset += 1;
            continue;
        }

        // Continuation byte (80-BF) or invalid byte (C0-C1, F5-FF)
        // as lead: each is its own maximal subpart → one FFFD per byte.
        if (b0 < 0xC2 or b0 > 0xF4) {
            output[decode_count] = 0xFFFD;
            decode_count += 1;
            decode_offset += 1;
            continue;
        }

        // Multi-byte sequence. Determine expected length and the valid
        // range for each continuation byte per Unicode Table 3-7.
        const seq = utf8SeqInfo(b0);

        // Check how many continuation bytes form a valid prefix (the
        // maximal subpart). We check each byte against its specific
        // valid range.
        var valid: usize = 1; // lead byte is valid
        for (0..seq.len - 1) |ci| {
            if (decode_offset + valid >= decode.len) {
                // Truncated at end of buffer: treat as incomplete
                // input that may be completed later. Stop decoding
                // without consuming these bytes.
                return .{
                    .consumed = decode_offset,
                    .decoded = decode_count,
                };
            }
            const cb = decode[decode_offset + valid];
            if (cb < seq.ranges[ci][0] or cb > seq.ranges[ci][1]) {
                // Byte doesn't match expected range. The maximal
                // subpart ends here.
                break;
            }
            valid += 1;
        }

        if (valid == seq.len) {
            // Full sequence present and structurally valid. Decode it.
            // (Structural validity per Table 3-7 guarantees decode success.)
            const cp_bytes = decode[decode_offset..][0..seq.len];
            if (std.unicode.utf8Decode(cp_bytes)) |cp| {
                output[decode_count] = @intCast(cp);
                decode_count += 1;
                decode_offset += seq.len;
            } else |_| {
                // Should not happen given Table 3-7 validation, but
                // be safe: emit FFFD for the lead byte.
                output[decode_count] = 0xFFFD;
                decode_count += 1;
                decode_offset += 1;
            }
        } else {
            // Incomplete/ill-formed: the maximal subpart (valid bytes)
            // maps to a single FFFD.
            output[decode_count] = 0xFFFD;
            decode_count += 1;
            decode_offset += valid;
        }
    }

    return .{
        .consumed = decode_offset,
        .decoded = decode_count,
    };
}

const Utf8SeqInfo = struct {
    len: u3,
    ranges: [3][2]u8,
};

/// Returns the expected byte count and valid continuation byte ranges
/// for a UTF-8 sequence based on its lead byte, per Unicode Table 3-7.
fn utf8SeqInfo(lead: u8) Utf8SeqInfo {
    return switch (lead) {
        0xC2...0xDF => .{ .len = 2, .ranges = .{ .{ 0x80, 0xBF }, .{ 0, 0 }, .{ 0, 0 } } },
        0xE0 => .{ .len = 3, .ranges = .{ .{ 0xA0, 0xBF }, .{ 0x80, 0xBF }, .{ 0, 0 } } },
        0xE1...0xEC => .{ .len = 3, .ranges = .{ .{ 0x80, 0xBF }, .{ 0x80, 0xBF }, .{ 0, 0 } } },
        0xED => .{ .len = 3, .ranges = .{ .{ 0x80, 0x9F }, .{ 0x80, 0xBF }, .{ 0, 0 } } },
        0xEE...0xEF => .{ .len = 3, .ranges = .{ .{ 0x80, 0xBF }, .{ 0x80, 0xBF }, .{ 0, 0 } } },
        0xF0 => .{ .len = 4, .ranges = .{ .{ 0x90, 0xBF }, .{ 0x80, 0xBF }, .{ 0x80, 0xBF } } },
        0xF1...0xF3 => .{ .len = 4, .ranges = .{ .{ 0x80, 0xBF }, .{ 0x80, 0xBF }, .{ 0x80, 0xBF } } },
        0xF4 => .{ .len = 4, .ranges = .{ .{ 0x80, 0x8F }, .{ 0x80, 0xBF }, .{ 0x80, 0xBF } } },
        else => unreachable,
    };
}

test "decode no escape" {
    const testing = std.testing;

    var output: [1024]u32 = undefined;

    // TODO: many more test cases
    {
        const str = "hello" ** 128;
        try testing.expectEqual(DecodeResult{
            .consumed = str.len,
            .decoded = str.len,
        }, utf8DecodeUntilControlSeq(str, &output));
    }
}

test "decode ASCII to escape" {
    const testing = std.testing;

    var output: [1024]u32 = undefined;

    // TODO: many more test cases
    {
        const prefix = "hello" ** 64;
        const str = prefix ++ "\x1b" ++ ("world" ** 64);
        try testing.expectEqual(DecodeResult{
            .consumed = prefix.len,
            .decoded = prefix.len,
        }, utf8DecodeUntilControlSeq(str, &output));
    }
}

test "decode immediate esc sequence" {
    const testing = std.testing;

    var output: [64]u32 = undefined;
    const str = "\x1b[?5s";
    try testing.expectEqual(DecodeResult{
        .consumed = 0,
        .decoded = 0,
    }, utf8DecodeUntilControlSeq(str, &output));
}

test "decode incomplete UTF-8" {
    const testing = std.testing;

    var output: [64]u32 = undefined;

    // 2-byte truncated at end of buffer
    {
        const str = "hello\xc2";
        try testing.expectEqual(DecodeResult{
            .consumed = 5,
            .decoded = 5,
        }, utf8DecodeUntilControlSeq(str, &output));
    }

    // 3-byte: \xe0 expects A0-BF next, but \x00 is not in range.
    // \xe0 is a maximal subpart of length 1 → FFFD, then \x00 is ASCII NUL.
    {
        const str = "hello\xe0\x00";
        const result = utf8DecodeUntilControlSeq(str, &output);
        try testing.expectEqual(@as(usize, 7), result.consumed);
        try testing.expectEqual(@as(usize, 7), result.decoded);
        try testing.expectEqual(@as(u32, 0xFFFD), output[5]);
        try testing.expectEqual(@as(u32, 0x00), output[6]);
    }

    // 4-byte truncated at end of buffer (F0 90 is valid so far)
    {
        const str = "hello\xf0\x90";
        try testing.expectEqual(DecodeResult{
            .consumed = 5,
            .decoded = 5,
        }, utf8DecodeUntilControlSeq(str, &output));
    }
}

test "decode invalid UTF-8" {
    const testing = std.testing;

    var output: [64]u32 = undefined;

    // Invalid leading 2-byte sequence
    {
        const str = "hello\xc2\x01";
        try testing.expectEqual(DecodeResult{
            .consumed = 7,
            .decoded = 7,
        }, utf8DecodeUntilControlSeq(str, &output));
    }

    // Replacement will only replace the invalid leading byte.
    try testing.expectEqual(@as(u32, 0xFFFD), output[5]);
    try testing.expectEqual(@as(u32, 0x01), output[6]);
}

// Per the maximal subpart spec, bytes F5-FF are each replaced with FFFD.
test "decode invalid leading byte is replaced" {
    const testing = std.testing;

    var output: [64]u32 = undefined;

    {
        const str = "hello\xFF";
        const result = utf8DecodeUntilControlSeq(str, &output);
        try testing.expectEqual(@as(usize, 6), result.consumed);
        try testing.expectEqual(@as(usize, 6), result.decoded);
        try testing.expectEqual(@as(u32, 0xFFFD), output[5]);
    }
}

test "decode invalid continuation in 3-byte sequence" {
    const testing = std.testing;

    var output: [64]u32 = undefined;

    // \xe2 expects two continuation bytes, \x28 is not one
    {
        const str = "hello\xe2\x28world";
        const result = utf8DecodeUntilControlSeq(str, &output);
        // "hello" + replacement + "(" + "world" = 12 codepoints
        try testing.expectEqual(@as(usize, 12), result.decoded);
        try testing.expectEqual(@as(u32, 0xFFFD), output[5]);
        try testing.expectEqual(@as(u32, '('), output[6]);
        try testing.expectEqual(@as(u32, 'w'), output[7]);
    }
}

test "decode invalid continuation in 4-byte sequence" {
    const testing = std.testing;

    var output: [64]u32 = undefined;

    // \xf0\x90 is a valid prefix of a 4-byte sequence, but \x28 breaks it.
    // Maximal subpart is F0 90 (length 2) → single FFFD, then '(' proceeds.
    {
        const str = "hello\xf0\x90\x28world";
        const result = utf8DecodeUntilControlSeq(str, &output);
        // "hello" + FFFD + "(" + "world" = 12 codepoints
        try testing.expectEqual(@as(usize, 12), result.decoded);
        try testing.expectEqual(@as(u32, 0xFFFD), output[5]);
        try testing.expectEqual(@as(u32, '('), output[6]);
        try testing.expectEqual(@as(u32, 'w'), output[7]);
    }
}

test "decode multiple consecutive invalid bytes" {
    const testing = std.testing;

    var output: [64]u32 = undefined;

    // Each lone continuation byte is its own maximal subpart → one FFFD each.
    {
        const str = "a\x80\x80b";
        const result = utf8DecodeUntilControlSeq(str, &output);
        // "a" + FFFD + FFFD + "b" = 4 codepoints
        try testing.expectEqual(@as(usize, 4), result.decoded);
        try testing.expectEqual(@as(u32, 'a'), output[0]);
        try testing.expectEqual(@as(u32, 0xFFFD), output[1]);
        try testing.expectEqual(@as(u32, 0xFFFD), output[2]);
        try testing.expectEqual(@as(u32, 'b'), output[3]);
    }

    // C0 is an invalid lead byte (< C2), each byte gets its own FFFD.
    {
        const str = "a\xc0\xc0b";
        const result = utf8DecodeUntilControlSeq(str, &output);
        // "a" + FFFD + FFFD + "b" = 4 codepoints
        try testing.expectEqual(@as(usize, 4), result.decoded);
        try testing.expectEqual(@as(u32, 'a'), output[0]);
        try testing.expectEqual(@as(u32, 0xFFFD), output[1]);
        try testing.expectEqual(@as(u32, 0xFFFD), output[2]);
        try testing.expectEqual(@as(u32, 'b'), output[3]);
    }
}

test "decode unexpected continuation byte as lead" {
    const testing = std.testing;

    var output: [64]u32 = undefined;

    // 0x80 is a continuation byte appearing as a lead byte
    {
        const str = "a\x80b";
        const result = utf8DecodeUntilControlSeq(str, &output);
        // "a" + replacement + "b" = 3 codepoints
        try testing.expectEqual(@as(usize, 3), result.decoded);
        try testing.expectEqual(@as(u32, 'a'), output[0]);
        try testing.expectEqual(@as(u32, 0xFFFD), output[1]);
        try testing.expectEqual(@as(u32, 'b'), output[2]);
    }
}

test "decode overlong 2-byte encoding" {
    const testing = std.testing;

    var output: [64]u32 = undefined;

    // \xc0\xaf: C0 is invalid lead (< C2) → FFFD, AF is lone continuation → FFFD
    // Per Table 3-8: C0 AF → FFFD FFFD
    {
        const str = "a\xc0\xafb";
        const result = utf8DecodeUntilControlSeq(str, &output);
        // "a" + FFFD + FFFD + "b" = 4 codepoints
        try testing.expectEqual(@as(usize, 4), result.decoded);
        try testing.expectEqual(@as(u32, 'a'), output[0]);
        try testing.expectEqual(@as(u32, 0xFFFD), output[1]);
        try testing.expectEqual(@as(u32, 0xFFFD), output[2]);
        try testing.expectEqual(@as(u32, 'b'), output[3]);
    }
}

test "decode surrogate half" {
    const testing = std.testing;

    var output: [64]u32 = undefined;

    // \xed\xa0\x80 encodes U+D800 (a surrogate). Per Table 3-7, after ED
    // the next byte must be 80-9F. A0 is out of range, so ED is a maximal
    // subpart of length 1 → FFFD. Then A0 and 80 are lone continuations
    // → FFFD each. Per Table 3-9: ED A0 80 → FFFD FFFD FFFD
    {
        const str = "a\xed\xa0\x80b";
        const result = utf8DecodeUntilControlSeq(str, &output);
        // "a" + FFFD + FFFD + FFFD + "b" = 5 codepoints
        try testing.expectEqual(@as(usize, 5), result.decoded);
        try testing.expectEqual(@as(u32, 'a'), output[0]);
        try testing.expectEqual(@as(u32, 0xFFFD), output[1]);
        try testing.expectEqual(@as(u32, 0xFFFD), output[2]);
        try testing.expectEqual(@as(u32, 0xFFFD), output[3]);
        try testing.expectEqual(@as(u32, 'b'), output[4]);
    }
}

test "decode valid multibyte surrounded by invalid" {
    const testing = std.testing;

    var output: [64]u32 = undefined;

    // \xc3\xa9 = é (U+00E9), surrounded by invalid continuation bytes
    {
        const str = "\x80\xc3\xa9\x80";
        const result = utf8DecodeUntilControlSeq(str, &output);
        // replacement + é + replacement = 3 codepoints
        try testing.expectEqual(@as(usize, 3), result.decoded);
        try testing.expectEqual(@as(u32, 0xFFFD), output[0]);
        try testing.expectEqual(@as(u32, 0x00E9), output[1]);
        try testing.expectEqual(@as(u32, 0xFFFD), output[2]);
    }
}

test "decode invalid byte before escape" {
    const testing = std.testing;

    var output: [64]u32 = undefined;

    // Invalid byte followed by ESC - should replace then stop
    {
        const str = "hi\x80\x1b[0m";
        const result = utf8DecodeUntilControlSeq(str, &output);
        try testing.expectEqual(@as(usize, 3), result.consumed);
        try testing.expectEqual(@as(usize, 3), result.decoded);
        try testing.expectEqual(@as(u32, 'h'), output[0]);
        try testing.expectEqual(@as(u32, 'i'), output[1]);
        try testing.expectEqual(@as(u32, 0xFFFD), output[2]);
    }
}

// Unicode Table 3-8: U+FFFD for Non-Shortest Form Sequences
// Bytes:  C0  AF  E0  80  BF  F0  81  82  41
// Output: FFFD FFFD FFFD FFFD FFFD FFFD FFFD FFFD 0041
test "Table 3-8: non-shortest form sequences" {
    const testing = std.testing;
    var output: [64]u32 = undefined;

    const str = "\xC0\xAF\xE0\x80\xBF\xF0\x81\x82\x41";
    const result = utf8DecodeUntilControlSeq(str, &output);
    try testing.expectEqual(@as(usize, 9), result.consumed);
    try testing.expectEqual(@as(usize, 9), result.decoded);
    for (0..8) |i| {
        try testing.expectEqual(@as(u32, 0xFFFD), output[i]);
    }
    try testing.expectEqual(@as(u32, 0x41), output[8]);
}

// Unicode Table 3-9: U+FFFD for Ill-Formed Sequences for Surrogates
// Bytes:  ED  A0  80  ED  BF  BF  ED  AF  41
// Output: FFFD FFFD FFFD FFFD FFFD FFFD FFFD FFFD 0041
test "Table 3-9: surrogate sequences" {
    const testing = std.testing;
    var output: [64]u32 = undefined;

    const str = "\xED\xA0\x80\xED\xBF\xBF\xED\xAF\x41";
    const result = utf8DecodeUntilControlSeq(str, &output);
    try testing.expectEqual(@as(usize, 9), result.consumed);
    try testing.expectEqual(@as(usize, 9), result.decoded);
    for (0..8) |i| {
        try testing.expectEqual(@as(u32, 0xFFFD), output[i]);
    }
    try testing.expectEqual(@as(u32, 0x41), output[8]);
}

// Unicode Table 3-10: U+FFFD for Other Ill-Formed Sequences
// Bytes:  F4  91  92  93  FF  41  80  BF  42
// Output: FFFD FFFD FFFD FFFD FFFD 0041 FFFD FFFD 0042
test "Table 3-10: other ill-formed sequences" {
    const testing = std.testing;
    var output: [64]u32 = undefined;

    const str = "\xF4\x91\x92\x93\xFF\x41\x80\xBF\x42";
    const result = utf8DecodeUntilControlSeq(str, &output);
    try testing.expectEqual(@as(usize, 9), result.consumed);
    try testing.expectEqual(@as(usize, 9), result.decoded);
    try testing.expectEqual(@as(u32, 0xFFFD), output[0]); // F4
    try testing.expectEqual(@as(u32, 0xFFFD), output[1]); // 91
    try testing.expectEqual(@as(u32, 0xFFFD), output[2]); // 92
    try testing.expectEqual(@as(u32, 0xFFFD), output[3]); // 93
    try testing.expectEqual(@as(u32, 0xFFFD), output[4]); // FF
    try testing.expectEqual(@as(u32, 0x0041), output[5]); // 41
    try testing.expectEqual(@as(u32, 0xFFFD), output[6]); // 80
    try testing.expectEqual(@as(u32, 0xFFFD), output[7]); // BF
    try testing.expectEqual(@as(u32, 0x0042), output[8]); // 42
}

// Unicode Table 3-11: U+FFFD for Truncated Sequences
// Bytes:  E1  80  E2  F0  91  92  F1  BF  41
// Output: FFFD     FFFD    FFFD         FFFD     0041
test "Table 3-11: truncated sequences" {
    const testing = std.testing;
    var output: [64]u32 = undefined;

    const str = "\xE1\x80\xE2\xF0\x91\x92\xF1\xBF\x41";
    const result = utf8DecodeUntilControlSeq(str, &output);
    try testing.expectEqual(@as(usize, 9), result.consumed);
    try testing.expectEqual(@as(usize, 5), result.decoded);
    try testing.expectEqual(@as(u32, 0xFFFD), output[0]); // E1 80 (truncated 3-byte)
    try testing.expectEqual(@as(u32, 0xFFFD), output[1]); // E2 (truncated 3-byte, next byte F0 not continuation)
    try testing.expectEqual(@as(u32, 0xFFFD), output[2]); // F0 91 92 (truncated 4-byte)
    try testing.expectEqual(@as(u32, 0xFFFD), output[3]); // F1 BF (truncated 4-byte, next byte 41 not continuation)
    try testing.expectEqual(@as(u32, 0x0041), output[4]); // 41
}
