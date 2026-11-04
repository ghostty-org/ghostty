//! Integer parsing for terminal protocols, without Zig digit separators.
//!
//! Adapted from Zig's `std.fmt.parseInt` (MIT license). See
//! src/lib/compat/README.md for license and details.
const std = @import("std");
const math = std.math;

/// Parse ASCII digits in the given base. Signed types allow a leading sign;
/// unsigned types accept digits only.
///
/// This exists because `std.fmt.parseInt` implements Zig integer literal
/// syntax rather than what terminal protocols specify: it ignores `_` digit
/// separators (so `4_2` parses as 42) and accepts a leading `+` or `-` even
/// for unsigned types. Accepting that input makes us diverge from other
/// terminals, so don't replace this with `std.fmt.parseInt`.
pub fn parseInt(
    comptime T: type,
    value: []const u8,
    comptime base: u8,
) std.fmt.ParseIntError!T {
    comptime std.debug.assert(base >= 2 and base <= 36);
    if (value.len == 0) return error.InvalidCharacter;
    if (@typeInfo(T).int.signedness == .signed) {
        if (value[0] == '+') return parseWithSign(T, value[1..], base, .pos);
        if (value[0] == '-') return parseWithSign(T, value[1..], base, .neg);
    }
    return parseWithSign(T, value, base, .pos);
}

fn parseWithSign(
    comptime T: type,
    value: []const u8,
    comptime base: u8,
    comptime sign: enum { pos, neg },
) std.fmt.ParseIntError!T {
    if (value.len == 0) return error.InvalidCharacter;

    const add = switch (sign) {
        .pos => math.add,
        .neg => math.sub,
    };

    const info = @typeInfo(T).int;
    const Accumulate = @Int(info.signedness, @max(8, info.bits));
    var accumulate: Accumulate = 0;
    for (value) |c| {
        const digit = try std.fmt.charToDigit(c, base);
        accumulate = try math.mul(Accumulate, accumulate, base);
        accumulate = try add(Accumulate, accumulate, @intCast(digit));
    }

    return math.cast(T, accumulate) orelse return error.Overflow;
}

test "protocol integer parsing" {
    const testing = std.testing;
    try testing.expectEqual(42, try parseInt(u8, "042", 10));
    try testing.expectEqual(255, try parseInt(u8, "fF", 16));
    try testing.expectEqual(42, try parseInt(i32, "+42", 10));
    try testing.expectEqual(-2147483648, try parseInt(i32, "-2147483648", 10));
    try testing.expectEqual(2147483647, try parseInt(i32, "2147483647", 10));
    try testing.expectEqual(-4, try parseInt(i3, "-4", 10));
    try testing.expectError(error.Overflow, parseInt(i3, "4", 10));
    try testing.expectError(error.Overflow, parseInt(u8, "256", 10));
    try testing.expectError(error.Overflow, parseInt(i32, "2147483648", 10));
    try testing.expectError(error.Overflow, parseInt(i32, "-2147483649", 10));
    for ([_][]const u8{
        "", "4_2", "4__2", "_42", "42_", " 42", "42 ", "0x2a", "4.2", "4e2", "\xff",
    }) |value| {
        try testing.expectError(error.InvalidCharacter, parseInt(u8, value, 10));
        try testing.expectError(error.InvalidCharacter, parseInt(i32, value, 10));
    }
    for ([_][]const u8{ "+42", "-0", "-42" }) |value| {
        try testing.expectError(error.InvalidCharacter, parseInt(u8, value, 10));
    }
    for ([_][]const u8{ "+", "-", "-4_2", "+4__2" }) |value| {
        try testing.expectError(error.InvalidCharacter, parseInt(i32, value, 10));
    }
    try testing.expectError(error.InvalidCharacter, parseInt(u16, "f_f", 16));
    try testing.expectError(error.InvalidCharacter, parseInt(u16, "0xff", 16));
}
