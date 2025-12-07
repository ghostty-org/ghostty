//! Encodings used by various Kitty protocol extensions.
const std = @import("std");

/// Kitty defines "URL-safe UTF-8" as valid UTF-8 with the additional
/// requirement of not containing any C0 escape codes (0x00-0x1f)
pub fn isUrlSafeUtf8(s: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(s)) {
        @branchHint(.cold);
        return false;
    }

    for (s) |c| switch (c) {
        0x00...0x1f => {
            @branchHint(.cold);
            return false;
        },
        else => {},
    };

    return true;
}
