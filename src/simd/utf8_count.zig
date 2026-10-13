const std = @import("std");
const options = @import("build_options");

// utf8_count.cpp
extern "c" fn ghostty_simd_count_utf8([*]const u8, usize) usize;

/// Count UTF-8 codepoints in `s`, which must be valid UTF-8. On
/// malformed input both paths still terminate, but their counts can
/// differ, so validate first when the source is untrusted.
pub fn countUtf8(s: []const u8) usize {
    if (comptime options.simd) return ghostty_simd_count_utf8(s.ptr, s.len);
    return countUtf8Scalar(s);
}

fn countUtf8Scalar(s: []const u8) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len) : (n += 1) i += std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
    return n;
}

test "countUtf8 simd and scalar agree" {
    const testing = std.testing;
    const cases = [_][]const u8{
        "",
        "hello world",
        "a│b├😀 é plain mix",
        "─" ** 200,
        "😀" ** 50,
    };
    for (cases) |s| {
        try testing.expectEqual(countUtf8Scalar(s), countUtf8(s));
        try testing.expectEqual(std.unicode.utf8CountCodepoints(s) catch unreachable, countUtf8(s));
    }
}
