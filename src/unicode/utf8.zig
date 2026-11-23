//! UTF-8 codepoint offset helpers. Except for `cpCount`, they never
//! fail: a stray continuation byte counts as one byte.

const std = @import("std");
const simd = @import("../simd/main.zig");

/// Byte length of a codepoint given its first byte, or 1 for a
/// continuation byte.
pub fn cpLen(b: u8) usize {
    return std.unicode.utf8ByteSequenceLength(b) catch 1;
}

/// Asserts that `s` is valid UTF-8; see `simd.countUtf8`.
pub fn cpCount(s: []const u8) usize {
    return simd.countUtf8(s);
}

/// Byte offset of the `cp_idx`-th codepoint in `s`. Clamps at `s.len`.
pub fn cpToByte(s: []const u8, cp_idx: usize) usize {
    var i: usize = 0;
    var c: usize = 0;
    while (i < s.len and c < cp_idx) : (c += 1) i += cpLen(s[i]);
    return i;
}

pub fn isContinuation(b: u8) bool {
    return b & 0xC0 == 0x80;
}

test "utf8: codepoint length, count and index" {
    const testing = std.testing;
    const euro = "€"; // three bytes: 0xE2 0x82 0xAC

    try testing.expectEqual(1, cpLen('a'));
    try testing.expectEqual(2, cpLen("é"[0]));
    try testing.expectEqual(3, cpLen(euro[0]));
    try testing.expectEqual(4, cpLen("😀"[0]));

    try testing.expectEqual(1, cpLen(0x80));
    try testing.expect(isContinuation(0x80));
    try testing.expect(!isContinuation('a'));
    try testing.expect(!isContinuation(euro[0]));
    try testing.expect(isContinuation(euro[1]));

    const s = "a" ++ euro ++ "b😀";
    try testing.expectEqual(4, cpCount(s));
    try testing.expectEqual(9, s.len);

    try testing.expectEqual(0, cpToByte(s, 0));
    try testing.expectEqual(1, cpToByte(s, 1));
    try testing.expectEqual(4, cpToByte(s, 2));
    try testing.expectEqual(5, cpToByte(s, 3));
    try testing.expectEqual(s.len, cpToByte(s, std.math.maxInt(usize)));
}
