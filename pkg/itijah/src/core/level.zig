const std = @import("std");

pub const BidiLevel = u7;

pub const max_explicit_level: BidiLevel = 125;
pub const max_depth: BidiLevel = 125;
pub const max_resolved_level: BidiLevel = 126;

pub const ltr_level: BidiLevel = 0;
pub const rtl_level: BidiLevel = 1;

pub inline fn isRtl(level: BidiLevel) bool {
    return level & 1 != 0;
}

pub inline fn isLtr(level: BidiLevel) bool {
    return level & 1 == 0;
}

pub inline fn isEven(level: BidiLevel) bool {
    return level & 1 == 0;
}

/// Next even level (for LTR embedding). Returns null if overflow.
pub inline fn nextEvenLevel(level: BidiLevel) ?BidiLevel {
    const next = (level + 2) & ~@as(BidiLevel, 1);
    return if (next <= max_explicit_level) next else null;
}

/// Next odd level (for RTL embedding). Returns null if overflow.
pub inline fn nextOddLevel(level: BidiLevel) ?BidiLevel {
    const next = (level + 1) | 1;
    return if (next <= max_explicit_level) next else null;
}

/// The direction type (L or R) implied by this embedding level.
pub inline fn levelToDir(level: BidiLevel) Direction {
    return if (isRtl(level)) .rtl else .ltr;
}

pub const Direction = enum {
    ltr,
    rtl,

    pub inline fn toLevel(self: Direction) BidiLevel {
        return switch (self) {
            .ltr => ltr_level,
            .rtl => rtl_level,
        };
    }
};

test "level helpers" {
    const testing = std.testing;

    try testing.expect(isRtl(1));
    try testing.expect(!isRtl(0));
    try testing.expect(isLtr(0));
    try testing.expect(isLtr(2));

    try testing.expectEqual(@as(?BidiLevel, 2), nextEvenLevel(0));
    try testing.expectEqual(@as(?BidiLevel, 2), nextEvenLevel(1));
    try testing.expectEqual(@as(?BidiLevel, 4), nextEvenLevel(2));

    try testing.expectEqual(@as(?BidiLevel, 1), nextOddLevel(0));
    try testing.expectEqual(@as(?BidiLevel, 3), nextOddLevel(1));
    try testing.expectEqual(@as(?BidiLevel, 3), nextOddLevel(2));

    try testing.expectEqual(@as(?BidiLevel, null), nextEvenLevel(125));
    try testing.expectEqual(@as(?BidiLevel, null), nextOddLevel(125));
    try testing.expectEqual(@as(?BidiLevel, null), nextEvenLevel(124));
    try testing.expectEqual(@as(?BidiLevel, 125), nextOddLevel(124));

    try testing.expectEqual(Direction.ltr, levelToDir(0));
    try testing.expectEqual(Direction.rtl, levelToDir(1));
    try testing.expectEqual(Direction.ltr, levelToDir(2));
}
