const std = @import("std");
const lib = @import("../lib.zig");
const unicode_pkg = @import("../../unicode/main.zig");

pub fn codepoint_width(cp: u32) callconv(lib.calling_conv) u8 {
    if (cp > 0x10FFFF) return 1;
    return unicode_pkg.codepointWidth(@intCast(cp));
}

pub fn grapheme_width(
    cps: ?[*]const u32,
    len: usize,
    width: ?*u8,
) callconv(lib.calling_conv) usize {
    if (len == 0) {
        if (width) |ptr| ptr.* = 0;
        return 0;
    }

    const ptr = cps orelse {
        if (width) |out| out.* = 0;
        return 0;
    };
    const result = unicode_pkg.graphemeWidth(u32, ptr[0..len]);
    if (width) |out| out.* = result.width;
    return result.len;
}

test "codepoint_width narrow" {
    const testing = std.testing;
    try testing.expectEqual(1, codepoint_width('a'));
}

test "codepoint_width wide" {
    const testing = std.testing;
    try testing.expectEqual(2, codepoint_width(0x4E00));
}

test "codepoint_width zero" {
    const testing = std.testing;
    try testing.expectEqual(0, codepoint_width(0x0301));
}

test "codepoint_width out of range" {
    const testing = std.testing;
    try testing.expectEqual(1, codepoint_width(0x110000));
    try testing.expectEqual(1, codepoint_width(std.math.maxInt(u32)));
}

test "grapheme_width empty" {
    const testing = std.testing;

    var width: u8 = 42;
    try testing.expectEqual(@as(usize, 0), grapheme_width(null, 0, &width));
    try testing.expectEqual(@as(u8, 0), width);
}

test "grapheme_width null width" {
    const testing = std.testing;

    const cps = [_]u32{ 0x2764, 0xFE0F };
    try testing.expectEqual(@as(usize, 2), grapheme_width(cps[0..].ptr, cps.len, null));
}

test "grapheme_width out of range" {
    const testing = std.testing;

    var width: u8 = 0;
    const invalid_first = [_]u32{ 0x110000, 0x0301 };
    try testing.expectEqual(@as(usize, 1), grapheme_width(invalid_first[0..].ptr, invalid_first.len, &width));
    try testing.expectEqual(@as(u8, 1), width);

    const invalid_second = [_]u32{ 'a', 0x110000 };
    try testing.expectEqual(@as(usize, 1), grapheme_width(invalid_second[0..].ptr, invalid_second.len, &width));
    try testing.expectEqual(@as(u8, 1), width);
}

test "grapheme_width emoji sequence" {
    const testing = std.testing;

    var width: u8 = 0;
    const cps = [_]u32{ 0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467 };
    try testing.expectEqual(@as(usize, cps.len), grapheme_width(cps[0..].ptr, cps.len, &width));
    try testing.expectEqual(@as(u8, 2), width);
}
