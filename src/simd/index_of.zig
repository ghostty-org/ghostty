const std = @import("std");
const builtin = @import("builtin");

extern "c" fn ghostty_simd_index_of(
    needle: u8,
    input: [*]const u8,
    count: usize,
) usize;

pub fn indexOf(input: []const u8, needle: u8) ?usize {
    const result = ghostty_simd_index_of(needle, input.ptr, input.len);
    return if (result == input.len) null else result;
}

test "indexOf" {
    const testing = std.testing;
    try testing.expect(indexOf("hello", ' ') == null);
    try testing.expectEqual(@as(usize, 2), indexOf("hi lo", ' ').?);
    try testing.expectEqual(@as(usize, 5), indexOf(
        \\XXXXX XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
        \\XXXXXXXXXXXX XXXXXXXXXXX XXXXXXXXXXXXXXX
    , ' ').?);
    try testing.expectEqual(@as(usize, 53), indexOf(
        \\XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
        \\XXXXXXXXXXXX XXXXXXXXXXX XXXXXXXXXXXXXXX
    , ' ').?);
}
