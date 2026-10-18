const std = @import("std");
const options = @import("build_options");

// utf8_count.cpp
extern "c" fn ghostty_simd_count_utf8([*]const u8, usize) usize;

/// Count UTF-8 codepoints in `s`. Asserts that `s` is valid UTF-8:
/// malformed input is undefined behavior, so callers must validate
/// anything they did not encode themselves.
pub fn countUtf8(s: []const u8) usize {
    if (comptime std.debug.runtime_safety) {
        std.debug.assert(std.unicode.utf8ValidateSlice(s));
    }

    if (comptime options.simd) return ghostty_simd_count_utf8(s.ptr, s.len);
    return countUtf8Scalar(s);
}

fn countUtf8Scalar(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch unreachable;
}

test "countUtf8 simd and scalar agree" {
    const testing = std.testing;
    const euros: [200 * 3]u8 = comptime std.simd.repeat(200 * 3, "€".*);
    const emoji: [50 * 4]u8 = comptime std.simd.repeat(50 * 4, "😀".*);
    const cases = [_][]const u8{
        "",
        "hello world",
        "a€b日😀 é plain mix",
        &euros,
        &emoji,
    };
    for (cases) |s| {
        try testing.expectEqual(countUtf8Scalar(s), countUtf8(s));
    }
}
