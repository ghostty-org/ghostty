const std = @import("std");

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
    var decoded: usize = 0;
    const consumed = ghostty_simd_decode_utf8_until_control_seq(
        input.ptr,
        input.len,
        output.ptr,
        &decoded,
    );

    return .{ .consumed = consumed, .decoded = decoded };
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

    // 2-byte
    {
        const str = "hello\xc2";
        try testing.expectEqual(DecodeResult{
            .consumed = 5,
            .decoded = 5,
        }, utf8DecodeUntilControlSeq(str, &output));
    }

    // 3-byte
    {
        const str = "hello\xe0\x00";
        try testing.expectEqual(DecodeResult{
            .consumed = 5,
            .decoded = 5,
        }, utf8DecodeUntilControlSeq(str, &output));
    }

    // 4-byte
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

    // Invalid leading 1s
    {
        const str = "hello\xc2\x00";
        try testing.expectEqual(DecodeResult{
            .consumed = 7,
            .decoded = 7,
        }, utf8DecodeUntilControlSeq(str, &output));
    }

    try testing.expectEqual(@as(u32, 0xFFFD), output[5]);
}
