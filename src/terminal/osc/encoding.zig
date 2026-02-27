//! Specialized encodings used in some OSC protocols.
const std = @import("std");

/// Kitty defines "Escape code safe UTF-8" as valid UTF-8 with the
/// additional requirement of not containing any C0 escape codes
/// (0x00-0x1f), DEL (0x7f) and C1 escape codes (0x80-0x9f).
///
/// Used by OSC 66 (text sizing) and OSC 99 (Kitty notifications).
///
/// See: https://sw.kovidgoyal.net/kitty/desktop-notifications/#safe-utf8
pub fn isSafeUtf8(s: []const u8) bool {
    const utf8 = std.unicode.Utf8View.init(s) catch {
        @branchHint(.cold);
        return false;
    };

    var it = utf8.iterator();
    while (it.nextCodepoint()) |cp| switch (cp) {
        0x00...0x1f, 0x7f, 0x80...0x9f => {
            @branchHint(.cold);
            return false;
        },
        else => {},
    };

    return true;
}

test isSafeUtf8 {
    const testing = std.testing;

    try testing.expect(isSafeUtf8("Hello world!"));
    try testing.expect(isSafeUtf8("安全的ユニコード☀️"));
    try testing.expect(!isSafeUtf8("No linebreaks\nallowed"));
    try testing.expect(!isSafeUtf8("\x07no bells"));
    try testing.expect(!isSafeUtf8("\x1b]9;no OSCs\x1b\\\x1b[m"));
    try testing.expect(!isSafeUtf8("\x9f8-bit escapes are clever, but no"));
}
