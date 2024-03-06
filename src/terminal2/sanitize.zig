const std = @import("std");

/// Returns true if the data looks safe to paste.
pub fn isSafePaste(data: []const u8) bool {
    return std.mem.indexOf(u8, data, "\n") == null;
}

test isSafePaste {
    const testing = std.testing;
    try testing.expect(isSafePaste("hello"));
    try testing.expect(!isSafePaste("hello\n"));
    try testing.expect(!isSafePaste("hello\nworld"));
}
