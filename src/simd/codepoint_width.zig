const std = @import("std");

// vt.cpp
extern "c" fn ghostty_simd_codepoint_width(u32) i8;

pub fn codepointWidth(cp: u32) i8 {
    // try testing.expectEqual(@as(i8, 1), @import("DisplayWidth").codePointWidth(@intCast(cp)));
    return ghostty_simd_codepoint_width(cp);
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
    // try testing.expectEqual(@as(i8, 1), @import("DisplayWidth").codePointWidth(0x100));
}

// This is not very fast in debug modes, so its commented by default.
// IMPORTANT: UNCOMMENT THIS WHENEVER MAKING CODEPOINTWIDTH CHANGES.
//test "codepointWidth matches zg" {
//    const testing = std.testing;
//    const DisplayWidth = @import("DisplayWidth");
//    var success: bool = true;
//
//    const min = 0xFF + 1; // start outside ascii
//    for (min..0x110000) |cp| {
//        const simd = codepointWidth(@intCast(cp));
//        const zg_width = DisplayWidth.codePointWidth(@intCast(cp));
//        if (simd != zg_width) mismatch: {
//            if (cp == 0x2E3B) {
//                try testing.expectEqual(@as(i8, 2), simd);
//                std.log.warn("mismatch for 0x2e3b cp=U+{x} simd={} zg={}", .{ cp, simd, zg_width });
//                break :mismatch;
//            }
//
//            if (cp == 0x890) {
//                try testing.expectEqual(@as(i8, 0), simd);
//                try testing.expectEqual(@as(i8, 1), zg_width);
//                break :mismatch;
//            }
//
//            std.log.warn("mismatch cp=U+{x} simd={} zg={}", .{ cp, simd, zg_width });
//            success = false;
//        }
//    }
//
//    try testing.expect(success);
//}
