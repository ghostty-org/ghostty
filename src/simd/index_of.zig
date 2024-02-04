const std = @import("std");
const builtin = @import("builtin");
const isa = @import("isa.zig");
const aarch64 = @import("aarch64.zig");

// Note this is a reimplementation of std.mem.indexOfScalar. The Zig stdlib
// version is already SIMD-optimized but not using runtime ISA detection. This
// expands the stdlib version to use runtime ISA detection. This also, at the
// time of writing this comment, reimplements it using manual assembly. This is
// so I can compare to Zig's @Vector lowering.

pub const IndexOf = fn ([]const u8, u8) ?usize;

/// Returns the indexOf function for the given ISA.
pub fn indexOfFunc(v: isa.ISA) *const IndexOf {
    return isa.funcMap(IndexOf, v, .{
        .{ .avx2, Scalar.indexOf }, // todo
        .{ .neon, Neon.indexOf },
        .{ .scalar, Scalar.indexOf },
    });
}

pub const Scalar = struct {
    pub fn indexOf(input: []const u8, needle: u8) ?usize {
        return std.mem.indexOfScalar(u8, input, needle);
    }
};

pub const Neon = struct {
    /// indexOf implementation using ARM NEON instructions.
    pub fn indexOf(input: []const u8, needle: u8) ?usize {
        // This function is going to be commented in a lot of detail. SIMD is
        // complicated and nonintuitive, so I want to make sure I understand what's
        // going on. More importantly, I want to make sure when I look back on this
        // code in the future, I understand what's going on.

        // Load our needle into a vector register. This duplicates the needle 16
        // times, once for each byte in the 128-bit vector register.
        const needle_vec = aarch64.vdupq_n_u8(needle);

        // note(mitchellh): benchmark to see if we should align to 16 bytes here

        // Iterate 16 bytes at a time, which is the max size of a vector register.
        var i: usize = 0;
        while (i + 16 <= input.len) : (i += 16) {
            const input_vec = aarch64.vld1q_u8(input[i..]);
            if (indexOfVec(input_vec, needle_vec)) |index| {
                return i + index;
            }
        }

        // Handle the remaining bytes
        if (i < input.len) {
            while (i < input.len) : (i += 1) {
                if (input[i] == needle) return i;
            }
        }

        return null;
    }

    pub fn indexOfVec(input_vec: @Vector(16, u8), needle_vec: @Vector(16, u8)) ?usize {
        // Compare the input vector to the needle vector. This will set
        // all bits to "1" in the output vector for each matching byte.
        const match_vec = aarch64.vceqq_u8(input_vec, needle_vec);

        // This is a neat trick in order to efficiently find the index of
        // the first matching byte. Details for this can be found here:
        // https://community.arm.com/arm-community-blogs/b/infrastructure-solutions-blog/posts/porting-x86-vector-bitmask-optimizations-to-arm-neon
        const shift_vec = aarch64.vshrn_n_u16(@bitCast(match_vec), 4);
        const shift_u64 = aarch64.vget_lane_u64(@bitCast(shift_vec));
        if (shift_u64 == 0) {
            // This means no matches were found.
            return null;
        }

        // A match was found! Reverse the bits and divide by 4 to get the
        // index of the first matching byte. The reversal is due to the
        // bits being reversed in the shift operation, the division by 4
        // is due to all data being repeated 4 times by vceqq.
        const reversed = aarch64.rbit(u64, shift_u64);
        const index = aarch64.clz(u64, reversed) >> 2;
        return index;
    }
};

/// Generic test function so we can test against multiple implementations.
fn testIndexOf(func: *const IndexOf) !void {
    const testing = std.testing;
    try testing.expect(func("hello", ' ') == null);
    try testing.expectEqual(@as(usize, 2), func("hi lo", ' ').?);
    try testing.expectEqual(@as(usize, 5), func(
        \\XXXXX XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
        \\XXXXXXXXXXXX XXXXXXXXXXX XXXXXXXXXXXXXXX
    , ' ').?);
    try testing.expectEqual(@as(usize, 53), func(
        \\XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
        \\XXXXXXXXXXXX XXXXXXXXXXX XXXXXXXXXXXXXXX
    , ' ').?);
}

pub const Hwy = struct {
    extern "c" fn ghostty_simd_index_of(
        needle: u8,
        input: [*]const u8,
        count: usize,
    ) usize;

    pub fn indexOf(input: []const u8, needle: u8) ?usize {
        const result = ghostty_simd_index_of(needle, input.ptr, input.len);
        return if (result == input.len) null else result;
    }
};

test "indexOf" {
    const v = isa.detect();
    var it = v.iterator();
    while (it.next()) |isa_v| try testIndexOf(indexOfFunc(isa_v));
    try testIndexOf(&Hwy.indexOf);
}
