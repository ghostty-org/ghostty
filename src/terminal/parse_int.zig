//! Integer parsing for terminal protocols, without Zig digit separators.
const std = @import("std");

/// Parse ASCII digits in the given base. Signed types allow a leading sign;
/// unsigned types accept digits only.
pub fn parse(
    comptime T: type,
    value: []const u8,
    comptime base: u8,
) std.fmt.ParseIntError!T {
    comptime std.debug.assert(base >= 2 and base <= 36);
    const digits = if (@typeInfo(T).int.signedness == .signed and
        value.len > 0 and (value[0] == '+' or value[0] == '-'))
        value[1..]
    else
        value;
    if (digits.len == 0) return error.InvalidCharacter;
    for (digits) |c| {
        _ = try std.fmt.charToDigit(c, base);
    }
    return std.fmt.parseInt(T, value, base);
}

test "protocol integer parsing" {
    const testing = std.testing;
    try testing.expectEqual(42, try parse(u8, "042", 10));
    try testing.expectEqual(255, try parse(u8, "fF", 16));
    try testing.expectEqual(42, try parse(i32, "+42", 10));
    try testing.expectEqual(-2147483648, try parse(i32, "-2147483648", 10));
    try testing.expectEqual(2147483647, try parse(i32, "2147483647", 10));
    try testing.expectError(error.Overflow, parse(u8, "256", 10));
    try testing.expectError(error.Overflow, parse(i32, "2147483648", 10));
    try testing.expectError(error.Overflow, parse(i32, "-2147483649", 10));
    for ([_][]const u8{
        "", "4_2", "4__2", "_42", "42_", " 42", "42 ", "0x2a", "4.2", "4e2", "\xff",
    }) |value| {
        try testing.expectError(error.InvalidCharacter, parse(u8, value, 10));
        try testing.expectError(error.InvalidCharacter, parse(i32, value, 10));
    }
    for ([_][]const u8{ "+42", "-0", "-42" }) |value| {
        try testing.expectError(error.InvalidCharacter, parse(u8, value, 10));
    }
    for ([_][]const u8{ "+", "-", "-4_2", "+4__2" }) |value| {
        try testing.expectError(error.InvalidCharacter, parse(i32, value, 10));
    }
    try testing.expectError(error.InvalidCharacter, parse(u16, "f_f", 16));
    try testing.expectError(error.InvalidCharacter, parse(u16, "0xff", 16));
}
