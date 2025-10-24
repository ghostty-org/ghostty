const std = @import("std");
const options = @import("build_options");

// vt.cpp
extern "c" fn ghostty_simd_codepoint_width(u32) i8;

pub fn codepointWidth(cp: u32) i8 {
    if (comptime options.simd) return ghostty_simd_codepoint_width(cp);
    const uucode = @import("uucode");
    if (cp > uucode.config.max_code_point) return 1;
    return @import("uucode").get(.width, @intCast(cp));
}

test "codepointWidth basic" {
    const testing = std.testing;
    try testing.expectEqual(@as(i8, 1), codepointWidth('a'));
    try testing.expectEqual(@as(i8, 1), codepointWidth(0x100)); // Ā
    try testing.expectEqual(@as(i8, 2), codepointWidth(0x3400)); // 㐀
    try testing.expectEqual(@as(i8, 2), codepointWidth(0x2E3A)); // ⸺
    try testing.expectEqual(@as(i8, 2), codepointWidth(0x1F1E6)); // 🇦
    try testing.expectEqual(@as(i8, 2), codepointWidth(0x4E00)); // 一
    try testing.expectEqual(@as(i8, 2), codepointWidth(0xF900)); // 豈
    try testing.expectEqual(@as(i8, 2), codepointWidth(0x20000)); // 𠀀
    try testing.expectEqual(@as(i8, 2), codepointWidth(0x30000)); // 𠀀
    // try testing.expectEqual(@as(i8, 1), @import("uucode").get(.width, 0x100));
}

// This is not very fast in debug modes, so its commented by default.
// IMPORTANT: UNCOMMENT THIS WHENEVER MAKING CODEPOINTWIDTH CHANGES.
// test "codepointWidth matches uucode" {
//     const testing = std.testing;
//     const uucode = @import("uucode");
//
//     const min = 0xFF + 1; // start outside ascii
//     const max = std.math.maxInt(u21) + 1;
//     for (min..max) |cp| {
//         const simd = codepointWidth(@intCast(cp));
//         const uu = if (cp > uucode.config.max_code_point)
//             1
//         else
//             uucode.get(.width, @intCast(cp));
//         if (simd != uu) mismatch: {
//             if (cp == 0x2E3B) {
//                 try testing.expectEqual(@as(i8, 2), simd);
//                 break :mismatch;
//             }
//
//             std.log.warn("mismatch cp=U+{x} simd={} uucode={}", .{ cp, simd, uu });
//             try testing.expect(false);
//         }
//     }
// }
