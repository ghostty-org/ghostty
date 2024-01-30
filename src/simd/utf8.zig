const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const isa = @import("isa.zig");
const aarch64 = @import("aarch64.zig");

const Validate = @TypeOf(utf8Validate);

// All of the work in this file is based heavily on the work of
// Daniel Lemire and John Keiser. Their original work can be found here:
// - https://arxiv.org/pdf/2010.03090.pdf
// - https://simdutf.github.io/simdutf/ (MIT License)

pub fn utf8Validate(input: []const u8) bool {
    return utf8ValidateNeon(input);
}

pub fn utf8ValidateNeon(input: []const u8) bool {
    var neon = Neon.init();
    neon.validate(input);
    return !neon.hasErrors();
}

pub const Neon = struct {
    /// The previous input in a vector. This is required because to check
    /// the validity of a UTF-8 byte, we need to sometimes know previous
    /// state if it the first byte is a continuation byte.
    prev_input: @Vector(16, u8),

    /// The current error status. Once an error is set, it is never unset.
    prev_error: @Vector(16, u8),

    /// The current incomplete status. This is non-zero if the last chunk
    /// requires more bytes to be valid UTF-8.
    prev_incomplete: @Vector(16, u8),

    pub fn init() Neon {
        return .{
            .prev_input = aarch64.vdupq_n_u8(0),
            .prev_error = aarch64.vdupq_n_u8(0),
            .prev_incomplete = aarch64.vdupq_n_u8(0),
        };
    }

    /// Validate a chunk of UTF-8 data. This function is designed to be
    /// called multiple times with successive chunks of data. When the
    /// data is complete, you must call `finalize` to check for any
    /// remaining errors.
    pub fn validate(self: *Neon, input: []const u8) void {
        // Break up our input into 16 byte chunks, and process each chunk
        // separately. The size of a Neon register is 16 bytes.
        var i: usize = 0;
        while (i + 16 <= input.len) : (i += 16) {
            const input_vec = aarch64.vld1q_u8(input[i..]);
            self.next(input_vec);
        }

        // If we have any data remaining, we pad it with zeroes since that
        // is valid UTF-8, and then treat it like a normal block.
        if (i < input.len) {
            const remaining = input.len - i;
            assert(remaining < 16);

            var buf: [16]u8 = undefined;
            @memcpy(buf[0..remaining], input[i..]);
            @memset(buf[remaining..], 0);

            const input_vec = aarch64.vld1q_u8(&buf);
            self.next(input_vec);
        }
    }

    /// Call to finalize the validation (EOF is reached).
    pub fn finalize(self: *Neon) void {
        // Its possible for our last chunk to end expecting more
        // continuation bytes.
        self.prev_error = aarch64.vorrq_u8(self.prev_error, self.prev_incomplete);
    }

    /// Returns true if there are any errors.
    pub fn hasErrors(self: *Neon) bool {
        return aarch64.vmaxvq_u8(self.prev_error) != 0;
    }

    /// Process a single vector of input.
    ///
    /// This function generally isn't called directly, but it is very useful
    /// if you want to compose this validation with other SIMD operations
    /// and already have your data in a SIMD register.
    pub fn process(self: *Neon, input_vec: @Vector(16, u8)) void {
        // If all we have is ASCII, then we can skip the rest.
        if (aarch64.vmaxvq_u8(input_vec) <= 0b10000000) {
            self.prev_error = aarch64.vorrq_u8(self.prev_error, self.prev_incomplete);
            return;
        }

        const prev1 = aarch64.vextq_u8(self.prev_input, input_vec, 15);
        const prev1_shr4 = aarch64.vshrq_n_u8(prev1, 4);
        const prev1_lownibs = aarch64.vandq_u8(prev1, aarch64.vdupq_n_u8(0x0F));
        const input_highnibs = aarch64.vshrq_n_u8(input_vec, 4);
        const byte_1_high = aarch64.vqtbl1q_u8(byte1HighTable(), prev1_shr4);
        const byte_2_low = aarch64.vqtbl1q_u8(byte2LowTable(), prev1_lownibs);
        const byte_2_high = aarch64.vqtbl1q_u8(byte2HighTable(), input_highnibs);
        const special_cases = aarch64.vandq_u8(
            byte_1_high,
            aarch64.vandq_u8(byte_2_low, byte_2_high),
        );

        const prev2 = aarch64.vextq_u8(self.prev_input, input_vec, 14);
        const prev3 = aarch64.vextq_u8(self.prev_input, input_vec, 13);
        const is_third_byte = aarch64.vcgeq_u8(prev2, aarch64.vdupq_n_u8(0xE0));
        const is_fourth_byte = aarch64.vcgeq_u8(prev3, aarch64.vdupq_n_u8(0xF0));
        const must23 = aarch64.veorq_u8(is_third_byte, is_fourth_byte);
        const must23_80 = aarch64.vandq_u8(must23, aarch64.vdupq_n_u8(0x80));
        const multibyte_len = aarch64.veorq_u8(must23_80, special_cases);

        self.prev_error = aarch64.vorrq_u8(self.prev_error, multibyte_len);
        self.prev_input = input_vec;
        self.prev_incomplete = aarch64.vcgtq_u8(input_vec, incomplete: {
            var bytes: [16]u8 = .{255} ** 16;
            bytes[15] = 0b11000000 - 1;
            bytes[14] = 0b11100000 - 1;
            bytes[13] = 0b11110000 - 1;
            break :incomplete aarch64.vld1q_u8(&bytes);
        });

        // Debug all the vector registers:
        // std.log.warn("input={}", .{input_vec});
        // std.log.warn("prev_input={}", .{self.prev_input});
        // std.log.warn("prev1={}", .{prev1});
        // std.log.warn("prev1_shr4={}", .{prev1_shr4});
        // std.log.warn("prev1_lownibs={}", .{prev1_lownibs});
        // std.log.warn("input_highnibs={}", .{input_highnibs});
        // std.log.warn("byte_1_high={}", .{byte_1_high});
        // std.log.warn("byte_2_low={}", .{byte_2_low});
        // std.log.warn("byte_2_high={}", .{byte_2_high});
        // std.log.warn("special_cases={}", .{special_cases});
        // std.log.warn("prev2={}", .{prev2});
        // std.log.warn("prev3={}", .{prev3});
        // std.log.warn("is_third_byte={}", .{is_third_byte});
        // std.log.warn("is_fourth_byte={}", .{is_fourth_byte});
        // std.log.warn("must23={}", .{must23});
        // std.log.warn("must23_80={}", .{must23_80});
        // std.log.warn("multibyte_len={}", .{multibyte_len});
        // std.log.warn("error={}", .{self.prev_error});
        // std.log.warn("incomplete={}", .{self.prev_incomplete});
    }

    inline fn byte1HighTable() @Vector(16, u8) {
        // zig fmt: off
        return aarch64.vld1q_u8(&.{
            // 0_______ ________ <ASCII in byte 1>
            TOO_LONG, TOO_LONG, TOO_LONG, TOO_LONG,
            TOO_LONG, TOO_LONG, TOO_LONG, TOO_LONG,
            // 10______ ________ <continuation in byte 1>
            TWO_CONTS, TWO_CONTS, TWO_CONTS, TWO_CONTS,
            // 1100____ ________ <two byte lead in byte 1>
            TOO_SHORT | OVERLONG_2,
            // 1101____ ________ <two byte lead in byte 1>
            TOO_SHORT,
            // 1110____ ________ <three byte lead in byte 1>
            TOO_SHORT | OVERLONG_3 | SURROGATE,
            // 1111____ ________ <four+ byte lead in byte 1>
            TOO_SHORT | TOO_LARGE | TOO_LARGE_1000 | OVERLONG_4
        });
        // zig fmt: on
    }

    inline fn byte2LowTable() @Vector(16, u8) {
        // zig fmt: off
        return aarch64.vld1q_u8(&.{
            // ____0000 ________
            CARRY | OVERLONG_3 | OVERLONG_2 | OVERLONG_4,
            // ____0001 ________
            CARRY | OVERLONG_2,
            // ____001_ ________
            CARRY,
            CARRY,

            // ____0100 ________
            CARRY | TOO_LARGE,
            // ____0101 ________
            CARRY | TOO_LARGE | TOO_LARGE_1000,
            // ____011_ ________
            CARRY | TOO_LARGE | TOO_LARGE_1000,
            CARRY | TOO_LARGE | TOO_LARGE_1000,

            // ____1___ ________
            CARRY | TOO_LARGE | TOO_LARGE_1000,
            CARRY | TOO_LARGE | TOO_LARGE_1000,
            CARRY | TOO_LARGE | TOO_LARGE_1000,
            CARRY | TOO_LARGE | TOO_LARGE_1000,
            CARRY | TOO_LARGE | TOO_LARGE_1000,
            // ____1101 ________
            CARRY | TOO_LARGE | TOO_LARGE_1000 | SURROGATE,
            CARRY | TOO_LARGE | TOO_LARGE_1000,
            CARRY | TOO_LARGE | TOO_LARGE_1000
        });
        // zig fmt: on
    }

    inline fn byte2HighTable() @Vector(16, u8) {
        // zig fmt: off
        return aarch64.vld1q_u8(&.{
            // ________ 0_______ <ASCII in byte 2>
            TOO_SHORT, TOO_SHORT, TOO_SHORT, TOO_SHORT,
            TOO_SHORT, TOO_SHORT, TOO_SHORT, TOO_SHORT,

            // ________ 1000____
            TOO_LONG | OVERLONG_2 | TWO_CONTS | OVERLONG_3 | TOO_LARGE_1000 | OVERLONG_4,
            // ________ 1001____
            TOO_LONG | OVERLONG_2 | TWO_CONTS | OVERLONG_3 | TOO_LARGE,
            // ________ 101_____
            TOO_LONG | OVERLONG_2 | TWO_CONTS | SURROGATE  | TOO_LARGE,
            TOO_LONG | OVERLONG_2 | TWO_CONTS | SURROGATE  | TOO_LARGE,

            // ________ 11______
            TOO_SHORT, TOO_SHORT, TOO_SHORT, TOO_SHORT
        });
        // zig fmt: on
    }
};

// Bit 0 = Too Short (lead byte/ASCII followed by lead byte/ASCII)
// Bit 1 = Too Long (ASCII followed by continuation)
// Bit 2 = Overlong 3-byte
// Bit 4 = Surrogate
// Bit 5 = Overlong 2-byte
// Bit 7 = Two Continuations
const TOO_SHORT: u8 = 1 << 0; // 11______ 0_______
// 11______ 11______
// 0_______ 10______
const TOO_LONG: u8 = 1 << 1;
const OVERLONG_3: u8 = 1 << 2; // 11100000 100_____
const SURROGATE: u8 = 1 << 4; // 11101101 101_____
const OVERLONG_2: u8 = 1 << 5; // 1100000_ 10______
const TWO_CONTS: u8 = 1 << 7; // 10______ 10______
const TOO_LARGE: u8 = 1 << 3; // 11110100 1001____
// 11110100 101_____
// 11110101 1001____
// 11110101 101_____
// 1111011_ 1001____
// 1111011_ 101_____
// 11111___ 1001____
// 11111___ 101_____
const TOO_LARGE_1000: u8 = 1 << 6;
// 11110101 1000____
// 1111011_ 1000____
// 11111___ 1000____
// 11110000 1000____
const OVERLONG_4: u8 = 1 << 6;
const CARRY: u8 = TOO_SHORT | TOO_LONG | TWO_CONTS; // These all have ____ in byte 1 .

/// Generic test function so we can test against multiple implementations.
/// This is initially copied from the Zig stdlib but may be expanded.
fn testValidate(func: *const Validate) !void {
    const testing = std.testing;
    try testing.expect(func("hello friends!!!"));
    try testing.expect(func("abc"));
    try testing.expect(func("abc\xdf\xbf"));
    try testing.expect(func(""));
    try testing.expect(func("a"));
    try testing.expect(func("abc"));
    try testing.expect(func("Ж"));
    try testing.expect(func("ЖЖ"));
    try testing.expect(func("брэд-ЛГТМ"));
    try testing.expect(func("☺☻☹"));
    try testing.expect(func("a\u{fffdb}"));
    try testing.expect(func("\xf4\x8f\xbf\xbf"));
    try testing.expect(func("abc\xdf\xbf"));

    try testing.expect(!func("abc\xc0"));
    try testing.expect(!func("abc\xc0abc"));
    try testing.expect(!func("aa\xe2"));
    try testing.expect(!func("\x42\xfa"));
    try testing.expect(!func("\x42\xfa\x43"));
    try testing.expect(!func("abc\xc0"));
    try testing.expect(!func("abc\xc0abc"));
    try testing.expect(!func("\xf4\x90\x80\x80"));
    try testing.expect(!func("\xf7\xbf\xbf\xbf"));
    try testing.expect(!func("\xfb\xbf\xbf\xbf\xbf"));
    try testing.expect(!func("\xc0\x80"));
    try testing.expect(!func("\xed\xa0\x80"));
    try testing.expect(!func("\xed\xbf\xbf"));
}

test "utf8Validate neon" {
    if (comptime !isa.possible(.neon)) return error.SkipZigTest;
    const set = isa.detect();
    if (set.contains(.neon)) try testValidate(&utf8ValidateNeon);
}
