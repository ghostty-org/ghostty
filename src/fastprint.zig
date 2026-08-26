//! Fastprint has fast printing routines that are significantly
//! faster than going through std.fmt.

const std = @import("std");

/// Print a decimal type T. The buffer is expected to be large enough so if
/// necessary use comptime with a buffer-too-large to determine your
/// max size needed. Returns the length written.
pub fn printDecimal(comptime T: type, buf: []u8, v: T) usize {
    // Note this only supports types as we need them.
    switch (T) {
        u8 => {
            if (v >= 100) {
                buf[0] = '0' + v / 100;
                buf[1..3].* = std.fmt.digits2(v % 100);
                return 3;
            }
            if (v >= 10) {
                buf[0..2].* = std.fmt.digits2(v);
                return 2;
            }
            buf[0] = '0' + v;
            return 1;
        },

        // This can probably be generalized...
        u21 => {
            // Maximum u21 is 2097151: at most 7 digits.
            var tmp: [7]u8 = undefined;
            var val: u32 = v;
            var i: usize = tmp.len;
            while (true) {
                i -= 1;
                tmp[i] = '0' + @as(u8, @intCast(val % 10));
                val /= 10;
                if (val == 0) break;
            }
            const n = tmp.len - i;
            @memcpy(buf[0..n], tmp[i..]);
            return n;
        },

        else => comptime unreachable,
    }
}

test printDecimal {
    const testing = std.testing;
    var buf: [16]u8 = undefined;

    // u8: exercise 1, 2, and 3 digit values including boundaries.
    const u8_cases = [_]u8{ 0, 1, 9, 10, 99, 100, 255 };
    for (u8_cases) |v| {
        var expected_buf: [3]u8 = undefined;
        const expected = std.fmt.bufPrint(&expected_buf, "{d}", .{v}) catch unreachable;
        const len = printDecimal(u8, &buf, v);
        try testing.expectEqualStrings(expected, buf[0..len]);
    }

    // u21: exercise digit count boundaries up to the maximum.
    const u21_cases = [_]u21{ 0, 9, 10, 128, 65535, 1114111, std.math.maxInt(u21) };
    for (u21_cases) |v| {
        var expected_buf: [8]u8 = undefined;
        const expected = std.fmt.bufPrint(&expected_buf, "{d}", .{v}) catch unreachable;
        const len = printDecimal(u21, &buf, v);
        try testing.expectEqualStrings(expected, buf[0..len]);
    }
}
