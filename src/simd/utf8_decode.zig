const std = @import("std");
const assert = std.debug.assert;
const isa = @import("isa.zig");
const aarch64 = @import("aarch64.zig");
const utf_tables = @import("utf_tables.zig");

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
        .{ .scalar, Simdutf.decode },
        .{ .neon, Simdutf.decode },
        .{ .avx2, Simdutf.decode }, // todo
    });
}

pub const Stdlib = struct {
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

/// Uses the simdutf project
pub const Simdutf = struct {
    pub fn decode(out: []u32, in: []const u8) []const u32 {
        const len = simdutf_convert_utf8_to_utf32(
            in.ptr,
            in.len,
            out.ptr,
        );

        return out[0..len];
    }

    extern "c" fn simdutf_convert_utf8_to_utf32(
        [*]const u8,
        usize,
        [*]u32,
    ) usize;
};

/// Generic test function so we can test against multiple implementations.
fn testDecode(func: *const Decode) !void {
    const testing = std.testing;

    // This is pitifully small, but it's enough to test the basic logic.
    // simdutf is extremely well tested, so we don't need to test the
    // edge cases so much.
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
        const scalar = Stdlib.decode(&buf, input);
        const actual = func(&buf2, input);
        try testing.expectEqualSlices(u32, scalar, actual);
    }
}

test "count" {
    const v = isa.detect();
    var it = v.iterator();
    while (it.next()) |isa_v| try testDecode(decodeFunc(isa_v));
}
