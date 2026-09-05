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

        // ASCII fast path. Use vectorization if it is available. This
        // path is only run when simd=false, but that only controls our C++
        // simd builds. We can still rely on Zig intrinsics for platforms
        // like wasm32+simd128.
        if (b0 < 0x80) {
            if (comptime std.simd.suggestVectorLength(u8)) |vl| {
                const V = @Vector(vl, u8);
                while (decode_offset + vl <= decode.len) {
                    const v: V = decode[decode_offset..][0..vl].*;
                    if (@reduce(.Or, v >= @as(V, @splat(0x80)))) break;
                    const w: @Vector(vl, u32) = @intCast(v);
                    output[decode_count..][0..vl].* = w;
                    decode_count += vl;
                    decode_offset += vl;
                }
            }
            while (decode_offset < decode.len) {
                const b = decode[decode_offset];
                if (b >= 0x80) break;
                output[decode_count] = b;
                decode_count += 1;
                decode_offset += 1;
            }
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

        // Multi-byte sequence. Only the first continuation byte has a
        // lead-dependent valid range per Unicode Table 3-7; later
        // continuation bytes are always 80-BF. Range validity per
        // Table 3-7 excludes overlong, surrogate, and out-of-range
        // encodings, so a fully valid sequence can be decoded by
        // direct bit assembly with no further checks.
        const seq_len: usize = if (b0 < 0xE0) 2 else if (b0 < 0xF0) 3 else 4;
        const cb1_lo: u8, const cb1_hi: u8 = switch (b0) {
            0xE0 => .{ 0xA0, 0xBF },
            0xED => .{ 0x80, 0x9F },
            0xF0 => .{ 0x90, 0xBF },
            0xF4 => .{ 0x80, 0x8F },
            else => .{ 0x80, 0xBF },
        };

        // Check how many continuation bytes form a valid prefix (the
        // maximal subpart), accumulating codepoint bits as we go. The
        // lead byte contributes its low 7-len bits.
        var cp: u32 = b0 & (@as(u32, 0x7F) >> @intCast(seq_len));
        var valid: usize = 1; // lead byte is valid
        while (valid < seq_len) {
            if (decode_offset + valid >= decode.len) {
                // The sequence is cut off by the end of the decode
                // region. If the region ends at the true end of the
                // input then it may be completed by future input, so
                // stop without consuming these bytes. If the region
                // was bounded by an ESC then the sequence can never
                // be completed; the valid-so-far prefix is a maximal
                // subpart which maps to a single U+FFFD below.
                if (decode.len == input.len) return .{
                    .consumed = decode_offset,
                    .decoded = decode_count,
                };
                break;
            }
            const cb = decode[decode_offset + valid];
            const lo: u8 = if (valid == 1) cb1_lo else 0x80;
            const hi: u8 = if (valid == 1) cb1_hi else 0xBF;
            if (cb < lo or cb > hi) break;
            cp = (cp << 6) | (cb & 0x3F);
            valid += 1;
        }

        if (valid == seq_len) {
            output[decode_count] = cp;
            decode_count += 1;
            decode_offset += seq_len;
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

// Differential test: the SIMD implementation must agree with the
// scalar implementation on any input. Exercises random mixtures of
// ASCII, escapes, controls, valid and invalid UTF-8, at various
// lengths (including chunk-boundary straddling cases).
test "decode simd matches scalar" {
    if (comptime !options.simd) return error.SkipZigTest;

    const testing = std.testing;
    var prng = std.Random.DefaultPrng.init(0xf00dface);
    const rand = prng.random();

    var input: [257]u8 = undefined;
    var out_simd: [input.len]u32 = undefined;
    var out_scalar: [input.len]u32 = undefined;

    for (0..10_000) |_| {
        const len = rand.intRangeAtMost(usize, 0, input.len);
        const style = rand.intRangeAtMost(u8, 0, 2);
        for (input[0..len]) |*b| {
            b.* = switch (style) {
                // Mostly ASCII with occasional specials.
                0 => switch (rand.intRangeAtMost(u8, 0, 20)) {
                    0 => 0x1B,
                    1 => rand.intRangeAtMost(u8, 0, 0x1F),
                    2 => rand.int(u8),
                    else => rand.intRangeAtMost(u8, 0x20, 0x7E),
                },
                // Heavy multi-byte/invalid UTF-8.
                1 => switch (rand.intRangeAtMost(u8, 0, 3)) {
                    0 => rand.intRangeAtMost(u8, 0x80, 0xBF),
                    1 => rand.intRangeAtMost(u8, 0xC0, 0xFF),
                    2 => 0x1B,
                    else => rand.intRangeAtMost(u8, 0x20, 0x7E),
                },
                // Fully random bytes.
                else => rand.int(u8),
            };
        }

        const res_simd = utf8DecodeUntilControlSeq(input[0..len], &out_simd);
        const res_scalar = utf8DecodeUntilControlSeqScalar(input[0..len], &out_scalar);
        errdefer std.debug.print("input={x}\n", .{input[0..len]});
        try testing.expectEqual(res_scalar.consumed, res_simd.consumed);
        try testing.expectEqual(res_scalar.decoded, res_simd.decoded);
        try testing.expectEqualSlices(
            u32,
            out_scalar[0..res_scalar.decoded],
            out_simd[0..res_simd.decoded],
        );
    }
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

test "decode partial UTF-8 before escape" {
    const testing = std.testing;

    // A valid-so-far but incomplete sequence cut off by an ESC can
    // never be completed, so it is consumed and replaced by a single
    // U+FFFD (maximal subpart) rather than left pending. Only
    // sequences cut off by the true end of input are left pending.
    var output: [64]u32 = undefined;

    // 2-byte lead cut off by ESC.
    {
        const str = "hi\xc2\x1b[0m";
        const result = utf8DecodeUntilControlSeq(str, &output);
        try testing.expectEqual(@as(usize, 3), result.consumed);
        try testing.expectEqual(@as(usize, 3), result.decoded);
        try testing.expectEqual(@as(u32, 0xFFFD), output[2]);
    }

    // 3-byte lead plus one valid continuation cut off by ESC:
    // the whole prefix is one maximal subpart, one U+FFFD.
    {
        const str = "\xe0\xa0\x1bX";
        const result = utf8DecodeUntilControlSeq(str, &output);
        try testing.expectEqual(@as(usize, 2), result.consumed);
        try testing.expectEqual(@as(usize, 1), result.decoded);
        try testing.expectEqual(@as(u32, 0xFFFD), output[0]);
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
