const std = @import("std");
const options = @import("build_options");
const assert = std.debug.assert;
const scalar_decoder = @import("base64_scalar.zig").scalar_decoder;

const log = std.log.scoped(.simd_base64);

pub fn maxLen(input: []const u8) usize {
    if (comptime options.simd) return ghostty_simd_base64_max_length(
        input.ptr,
        input.len,
    );

    return maxLenScalar(input);
}

fn maxLenScalar(input: []const u8) usize {
    return scalar_decoder.calcSizeForSlice(scalarInput(input)) catch |err| {
        log.warn("failed to calculate base64 size for payload: {}", .{err});
        return 0;
    };
}

pub fn decode(input: []const u8, output: []u8) error{Base64Invalid}![]const u8 {
    if (comptime options.simd) {
        const res = ghostty_simd_base64_decode(
            input.ptr,
            input.len,
            output.ptr,
        );
        if (res < 0) return error.Base64Invalid;
        return output[0..@intCast(res)];
    }

    return decodeScalar(input, output);
}

fn decodeScalar(
    input_raw: []const u8,
    output: []u8,
) error{Base64Invalid}![]const u8 {
    const input = scalarInput(input_raw);
    const size = maxLenScalar(input);
    if (size == 0) return "";
    assert(output.len >= size);
    scalar_decoder.decode(
        output,
        scalarInput(input),
    ) catch return error.Base64Invalid;
    return output[0..size];
}

/// For non-SIMD enabled builds, we trim the padding from the end of the
/// base64 input in order to get identical output with the SIMD version.
fn scalarInput(input: []const u8) []const u8 {
    var i: usize = 0;
    while (input[input.len - i - 1] == '=') i += 1;
    return input[0 .. input.len - i];
}

// base64.cpp
extern "c" fn ghostty_simd_base64_max_length(
    input: [*]const u8,
    len: usize,
) usize;
extern "c" fn ghostty_simd_base64_decode(
    input: [*]const u8,
    len: usize,
    output: [*]u8,
) isize;

test "base64 maxLen" {
    const testing = std.testing;
    const len = maxLen("aGVsbG8gd29ybGQ=");
    try testing.expectEqual(11, len);
}

test "base64 decode" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const input = "aGVsbG8gd29ybGQ=";
    const len = maxLen(input);
    const output = try alloc.alloc(u8, len);
    defer alloc.free(output);
    const str = try decode(input, output);
    try testing.expectEqualStrings("hello world", str);
}
