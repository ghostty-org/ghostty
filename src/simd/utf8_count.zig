const std = @import("std");
const isa = @import("isa.zig");
const aarch64 = @import("aarch64.zig");

/// Count the number of UTF-8 codepoints in the given string. The string
/// is assumed to be valid UTF-8. Invalid UTF-8 will result in undefined
/// (and probably incorrect) behaviour.
pub const Count = fn ([]const u8) usize;

/// Returns the count function for the given ISA.
pub fn countFunc(v: isa.ISA) *const Count {
    return isa.funcMap(Count, v, .{
        .{ .avx2, Scalar.count }, // todo
        .{ .neon, Neon.count },
        .{ .scalar, Scalar.count },
    });
}

pub const Scalar = struct {
    pub fn count(input: []const u8) usize {
        return std.unicode.utf8CountCodepoints(input) catch unreachable;
    }
};

/// Arm NEON implementation of the count function.
pub const Neon = struct {
    pub fn count(input: []const u8) usize {
        var result: usize = 0;
        var i: usize = 0;
        while (i + 16 <= input.len) : (i += 16) {
            const input_vec = aarch64.vld1q_u8(input[i..]);
            result += @intCast(process(input_vec));
        }

        if (i < input.len) result += Scalar.count(input[i..]);
        return result;
    }

    pub fn process(v: @Vector(16, u8)) u8 {
        // Find all the bits greater than -65 in binary (0b10000001) which
        // are a leading byte of a UTF-8 codepoint. This will set the resulting
        // vector to 0xFF for all leading bytes and 0x00 for all non-leading.
        const mask = aarch64.vcgtq_s8(@bitCast(v), aarch64.vdupq_n_s8(-65));

        // Shift to turn 0xFF to 0x01.
        const mask_shift = aarch64.vshrq_n_u8(mask, 7);

        // Sum across the vector
        const sum = aarch64.vaddvq_u8(mask_shift);

        // std.log.warn("mask={}", .{mask});
        // std.log.warn("mask_shift={}", .{mask_shift});
        // std.log.warn("sum={}", .{sum});
        return sum;
    }
};

/// Generic test function so we can test against multiple implementations.
/// This is initially copied from the Zig stdlib but may be expanded.
fn testCount(func: *const Count) !void {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 16), func("hello friends!!!"));
    try testing.expectEqual(@as(usize, 10), func("abcdefghij"));
    try testing.expectEqual(@as(usize, 10), func("äåéëþüúíóö"));
    try testing.expectEqual(@as(usize, 5), func("こんにちは"));
}

test "count" {
    const v = isa.detect();
    var it = v.iterator();
    while (it.next()) |isa_v| try testCount(countFunc(isa_v));
}
