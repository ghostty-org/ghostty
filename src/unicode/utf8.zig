//! UTF-8 codepoint offset helpers.
//!
//! These are total functions (rather than error unions like e.g.
//! `std.unicode.utf8CountCodepoints`): a stray continuation byte
//! advances one byte instead of erroring, so a scan over malformed
//! input can't stall. That suits call sites with no useful error path,
//! such as accessibility callbacks reading buffers that are built
//! codepoint by codepoint and always well-formed.

const std = @import("std");
const simd = @import("../simd/main.zig");

/// Byte length of a UTF-8 codepoint given its leading byte. A total
/// wrapper over `std.unicode.utf8ByteSequenceLength`: stray continuation
/// bytes advance 1 so a scan over malformed input can't stall.
pub fn cpLen(b: u8) usize {
    return std.unicode.utf8ByteSequenceLength(b) catch 1;
}

/// Count UTF-8 codepoints in `s`, via simdutf when the build has SIMD
/// enabled.
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

/// Whether `b` is a UTF-8 continuation byte, i.e. a byte that cannot
/// begin a codepoint.
pub fn isContinuation(b: u8) bool {
    return b & 0xC0 == 0x80;
}

test "utf8: codepoint length, count and index" {
    const testing = std.testing;
    const box_v = "│"; // three bytes: 0xE2 0x94 0x82

    try testing.expectEqual(@as(usize, 1), cpLen('a'));
    try testing.expectEqual(@as(usize, 2), cpLen("é"[0]));
    try testing.expectEqual(@as(usize, 3), cpLen(box_v[0]));
    try testing.expectEqual(@as(usize, 4), cpLen("😀"[0]));

    // Continuation bytes advance by one so a malformed scan terminates.
    try testing.expectEqual(@as(usize, 1), cpLen(0x80));
    try testing.expect(isContinuation(0x80));
    try testing.expect(!isContinuation('a'));
    try testing.expect(!isContinuation(box_v[0]));
    try testing.expect(isContinuation(box_v[1]));

    const s = "a" ++ box_v ++ "b😀";
    try testing.expectEqual(@as(usize, 4), cpCount(s));
    try testing.expectEqual(@as(usize, 9), s.len);

    try testing.expectEqual(@as(usize, 0), cpToByte(s, 0));
    try testing.expectEqual(@as(usize, 1), cpToByte(s, 1));
    try testing.expectEqual(@as(usize, 4), cpToByte(s, 2));
    try testing.expectEqual(@as(usize, 5), cpToByte(s, 3));
    // Past the end clamps rather than overruns.
    try testing.expectEqual(s.len, cpToByte(s, 99));
}
