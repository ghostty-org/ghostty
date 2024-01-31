const std = @import("std");
const assert = std.debug.assert;
const isa = @import("isa.zig");
const aarch64 = @import("aarch64.zig");
const utf_tables = @import("utf_tables.zig");

// All of the work in this file is based heavily on the work of
// Daniel Lemire and John Keiser. Their original work can be found here:
// - https://arxiv.org/pdf/2010.03090.pdf
// - https://simdutf.github.io/simdutf/ (MIT License)

/// Decode UTF-8 codepoints to UTF-32. Returns the number of codepoints
/// decoded. The output buffer must be large enough to hold the decoded
/// codepoints (worst case is 4x the number of bytes).
///
/// This also assumes the UTF-8 is valid. If it may not be, you should
/// validate first.
pub const Decode = fn ([]u32, []const u8) []const u32;

/// Returns the function for the given ISA.
pub fn decodeFunc(v: isa.ISA) *const Decode {
    return isa.funcMap(Decode, v, .{
        .{ .scalar, Scalar.decode },
        .{ .neon, Neon.decode },
        .{ .avx2, Scalar.decode }, // todo
    });
}

pub const Scalar = struct {
    pub fn decode(out: []u32, in: []const u8) []const u32 {
        const view = std.unicode.Utf8View.initUnchecked(in);
        var it = view.iterator();
        var i: usize = 0;
        while (it.nextCodepoint()) |cp| {
            out[i] = cp;
            i += 1;
        }

        return out[0..i];
    }
};

/// Arm NEON implementation
pub const Neon = struct {
    pub fn decode(out: []u32, in: []const u8) []const u32 {
        var delta: Delta = .{ .in = 0, .out = 0 };
        while (delta.in + 16 <= in.len) {
            const next = process(out[delta.out..], in[delta.in..]);
            delta.in += next.in;
            delta.out += next.out;
        }

        if (delta.in < in.len) delta.out += Scalar.decode(
            out[delta.out..],
            in[delta.in..],
        ).len;

        return out[0..delta.out];
    }

    const Delta = struct {
        in: usize,
        out: usize,
    };

    pub fn process(out: []u32, in: []const u8) Delta {
        const v = aarch64.vld1q_u8(in);

        // Fast-path all ASCII.
        if (aarch64.vmaxvq_u8(v) <= 0b10000000) {
            processASCII(out, v);
            return .{ .in = 16, .out = 16 };
        }

        const continuation_mask: u64 = mask: {
            const bitmask: @Vector(16, u8) = .{
                0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80,
                0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80,
            };
            const mask = aarch64.vcltq_s8(@bitCast(v), aarch64.vdupq_n_s8(-65 + 1));
            const mask_and = aarch64.vandq_u8(mask, bitmask);
            const sum0 = aarch64.vpaddq_u8(mask_and, aarch64.vdupq_n_u8(0));
            const sum1 = aarch64.vpaddq_u8(aarch64.vdupq_n_u8(0), aarch64.vdupq_n_u8(0));
            const sum0_added = aarch64.vpaddq_u8(sum0, sum1);
            const sum0_added2 = aarch64.vpaddq_u8(sum0_added, sum0_added);
            const final = aarch64.vgetq_lane_u64(@bitCast(sum0_added2), 0);
            // std.log.warn("sum0={}", .{sum0});
            // std.log.warn("sum1={}", .{sum1});
            // std.log.warn("sum0_added={}", .{sum0_added});
            // std.log.warn("sum0_added2={}", .{sum0_added2});
            // std.log.warn("final={X}", .{final});
            //
            // const mask_sum = aarch64.vpaddq_u8(mask_and, mask_and);
            // const lane = aarch64.vgetq_lane_u16(@bitCast(mask_sum), 0);
            // std.log.warn("mask={}", .{mask});
            // std.log.warn("mask_and={}", .{mask_and});
            // std.log.warn("mask_sum={}", .{mask_sum});
            // std.log.warn("lane={X}", .{@as(u64, @intCast(lane))});

            break :mask final;
            //break :mask @intCast(lane);
            //break :mask aarch64.vgetq_lane_u64(@bitCast(mask_sum), 0);
        };
        const leading_mask = ~continuation_mask;
        var end_of_cp_mask = leading_mask >> 1;

        // std.log.warn("continuation_mask={X}", .{continuation_mask});
        // std.log.warn("leading_mask={X}", .{leading_mask});
        // std.log.warn("end_of_cp_mask={X}", .{end_of_cp_mask});

        var delta: Delta = .{ .in = 0, .out = 0 };
        const max_starting_point = 4;
        while (delta.in < max_starting_point) {
            const step_delta = convertMaskedUtf8ToUtf32(
                out[delta.out..],
                in[delta.in..],
                end_of_cp_mask,
            );

            delta.in += step_delta.in;
            delta.out += step_delta.out;
            end_of_cp_mask >>= @intCast(step_delta.in);
        }

        return delta;
    }

    fn convertMaskedUtf8ToUtf32(
        out: []u32,
        in: []const u8,
        end_of_cp_mask: u64,
    ) Delta {
        const v = aarch64.vld1q_u8(in);
        const input_end_of_cp_mask = end_of_cp_mask & 0xFFF;

        // Fast paths
        // if ((end_of_cp_mask & 0xFFFF) == 0xFFFF) {
        //     @panic("ASCII");
        // }
        // if (input_end_of_cp_mask == 0x924) {
        //     @panic("4 3-byte");
        // }
        // if (input_end_of_cp_mask == 0xAAA) {
        //     @panic("2 byte burst");
        // }
        // No fast path

        const idx = utf_tables.utf8bigindex[input_end_of_cp_mask][0];
        const consumed = utf_tables.utf8bigindex[input_end_of_cp_mask][1];
        // std.log.warn("idx={d}", .{idx});
        // std.log.warn("consumed={d}", .{consumed});
        if (idx < 64) {
            // SIX (6) input code-code units
            const composed_utf16 = convertUtf8ByteToUtf16(v, idx);
            aarch64.vst2q_u16(@ptrCast(out.ptr), .{ composed_utf16, aarch64.vmovq_n_u16(0) });
            return .{ .in = consumed, .out = 6 };
        } else if (idx < 145) {
            // FOUR (4) input code-code units
            // UTF-16 and UTF-32 use similar algorithms, but UTF-32 skips the narrowing.
            const sh = aarch64.vld1q_u8(&utf_tables.shufutf8[idx]);

            // Shuffle
            // 1 byte: 00000000 00000000 0ccccccc
            // 2 byte: 00000000 110bbbbb 10cccccc
            // 3 byte: 1110aaaa 10bbbbbb 10cccccc
            const perm: @Vector(4, u32) = @bitCast(aarch64.vqtbl1q_u8(v, sh));

            // Split
            // 00000000 00000000 0ccccccc
            const ascii = aarch64.vandq_u32(perm, aarch64.vmovq_n_u32(0x7F));

            // Note: unmasked
            // xxxxxxxx aaaaxxxx xxxxxxxx
            const high = aarch64.vshrq_n_u32(perm, 4);
            // Use 16 bit bic instead of and.
            // The top bits will be corrected later in the bsl
            // 00000000 10bbbbbb 00000000
            const middle: @Vector(4, u32) = @bitCast(aarch64.vbicq_u16(
                @bitCast(perm),
                aarch64.vmovq_n_u16(~@as(u16, 0xFF00)),
            ));
            // Combine low and middle with shift right accumulate
            // 00000000 00xxbbbb bbcccccc
            const lowmid = aarch64.vsraq_n_u32(ascii, middle, 2);

            // Insert top 4 bits from high byte with bitwise select
            // 00000000 aaaabbbb bbcccccc
            const composed = aarch64.vbslq_u32(
                aarch64.vmovq_n_u32(0x0000F000),
                high,
                lowmid,
            );

            aarch64.vst1q_u32(@ptrCast(out.ptr), composed);
            return .{ .in = consumed, .out = 4 };
        } else if (idx < 209) {
            // THREE (3) input code-code units
            if (input_end_of_cp_mask == 0x888) {
                @panic("TODO");
            }

            // Unlike UTF-16, doing a fast codepath doesn't have nearly as much benefit due to
            // surrogates no longer being involved.
            const sh = aarch64.vld1q_u8(&utf_tables.shufutf8[idx]);

            // 1 byte: 00000000 00000000 00000000 0ddddddd
            // 2 byte: 00000000 00000000 110ccccc 10dddddd
            // 3 byte: 00000000 1110bbbb 10cccccc 10dddddd
            // 4 byte: 11110aaa 10bbbbbb 10cccccc 10dddddd
            const perm: @Vector(4, u32) = @bitCast(aarch64.vqtbl1q_u8(v, sh));

            // Ascii
            const ascii = aarch64.vandq_u32(perm, aarch64.vmovq_n_u32(0x7F));
            const middle = aarch64.vandq_u32(perm, aarch64.vmovq_n_u32(0x3f00));

            // When converting the way we do, the 3 byte prefix will be interpreted as the
            // 18th bit being set, since the code would interpret the lead byte (0b1110bbbb)
            // as a continuation byte (0b10bbbbbb). To fix this, we can either xor or do an
            // 8 bit add of the 6th bit shifted right by 1. Since NEON has shift right accumulate,
            // we use that.
            //  4 byte   3 byte
            // 10bbbbbb 1110bbbb
            // 00000000 01000000 6th bit
            // 00000000 00100000 shift right
            // 10bbbbbb 0000bbbb add
            // 00bbbbbb 0000bbbb mask
            const correction = aarch64.vandq_u32(perm, aarch64.vmovq_n_u32(0x00400000));
            const corrected: @Vector(4, u32) = @bitCast(aarch64.vsraq_n_u8(
                @bitCast(perm),
                @bitCast(correction),
                1,
            ));

            // 00000000 00000000 0000cccc ccdddddd
            const cd = aarch64.vsraq_n_u32(ascii, middle, 2);

            // Insert twice
            // xxxxxxxx xxxaaabb bbbbxxxx xxxxxxxx
            const ab = aarch64.vbslq_u32(
                aarch64.vmovq_n_u32(0x01C0000),
                aarch64.vshrq_n_u32(corrected, 6),
                aarch64.vshrq_n_u32(corrected, 4),
            );
            // 00000000 000aaabb bbbbcccc ccdddddd
            const composed = aarch64.vbslq_u32(aarch64.vmovq_n_u32(0xFFE00FFF), cd, ab);

            aarch64.vst1q_u32(out.ptr, composed);
            return .{ .in = consumed, .out = 3 };
        }

        // Definitely a UTF-8 error but we don't handle errors
        @panic("invalid UTF-8");
    }

    /// Converts 6 1-2 byte UTF-8 characters to 6 UTF-16 characters.
    fn convertUtf8ByteToUtf16(v: @Vector(16, u8), idx: usize) @Vector(8, u16) {
        // This is a relatively easy scenario
        // we process SIX (6) input code-code units. The max length in bytes of six code
        // code units spanning between 1 and 2 bytes each is 12 bytes.
        const sh = aarch64.vld1q_u8(&utf_tables.shufutf8[idx]);

        // Shuffle
        // 1 byte: 00000000 0bbbbbbb
        // 2 byte: 110aaaaa 10bbbbbb
        const perm: @Vector(8, u16) = @bitCast(aarch64.vqtbl1q_u8(v, sh));

        // Mask
        // 1 byte: 00000000 0bbbbbbb
        // 2 byte: 00000000 00bbbbbb
        const ascii = aarch64.vandq_u16(perm, aarch64.vmovq_n_u16(0x7F));
        // 1 byte: 00000000 00000000
        // 2 byte: 000aaaaa 00000000
        const highbyte = aarch64.vandq_u16(perm, aarch64.vmovq_n_u16(0x1F00));

        // Combine with a shift right accumulate
        // 1 byte: 00000000 0bbbbbbb
        // 2 byte: 00000aaa aabbbbbb
        const composed = aarch64.vsraq_n_u16(ascii, highbyte, 2);

        // std.log.warn("sh={}", .{sh});
        // std.log.warn("perm={}", .{perm});
        // std.log.warn("ascii={}", .{ascii});
        // std.log.warn("highbyte={}", .{highbyte});
        // std.log.warn("composed={}", .{composed});
        return composed;
    }

    fn processASCII(out: []u32, v: @Vector(16, u8)) void {
        // Use table lookups to extract individual elements out of the
        // u8-packed vector so we can widen to u32. Each table below pulls
        // the next 4 elements out of the vector.
        const tb1: @Vector(16, u8) = .{ 0, 255, 255, 255, 1, 255, 255, 255, 2, 255, 255, 255, 3, 255, 255, 255 };
        const tb2: @Vector(16, u8) = .{ 4, 255, 255, 255, 5, 255, 255, 255, 6, 255, 255, 255, 7, 255, 255, 255 };
        const tb3: @Vector(16, u8) = .{ 8, 255, 255, 255, 9, 255, 255, 255, 10, 255, 255, 255, 11, 255, 255, 255 };
        const tb4: @Vector(16, u8) = .{ 12, 255, 255, 255, 13, 255, 255, 255, 14, 255, 255, 255, 15, 255, 255, 255 };

        const shuf1 = aarch64.vqtbl1q_u8(v, tb1);
        const shuf2 = aarch64.vqtbl1q_u8(v, tb2);
        aarch64.vst1q_u8(@ptrCast(out.ptr), shuf1);
        aarch64.vst1q_u8(@ptrCast(out.ptr + 4), shuf2);

        const shuf3 = aarch64.vqtbl1q_u8(v, tb3);
        const shuf4 = aarch64.vqtbl1q_u8(v, tb4);
        aarch64.vst1q_u8(@ptrCast(out.ptr + 8), shuf3);
        aarch64.vst1q_u8(@ptrCast(out.ptr + 12), shuf4);
    }
};

/// Generic test function so we can test against multiple implementations.
fn testDecode(func: *const Decode) !void {
    const testing = std.testing;
    const inputs: []const []const u8 = &.{
        "hello friends!!!",
        "hello friends!!!",
        "abc",
        "abc\xdf\xbf",
        "Ж",
        "ЖЖ",
        "брэд-ЛГТМ",
        "☺☻☹",
        "a\u{fffdb}",
        "\xf4\x8f\xbf\xbf",
    };

    inline for (inputs) |input_raw| {
        const input = if (input_raw.len >= 64) input_raw else input_raw ++ ("hello" ** 15);
        assert(input.len >= 64);

        var buf: [1024]u32 = undefined;
        var buf2: [1024]u32 = undefined;
        const scalar = Scalar.decode(&buf, input);
        const actual = func(&buf2, input);
        try testing.expectEqualSlices(u32, scalar, actual);
    }
}

test "count" {
    const v = isa.detect();
    var it = v.iterator();
    while (it.next()) |isa_v| try testDecode(decodeFunc(isa_v));
}
