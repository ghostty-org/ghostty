//! Vocabulary types shared by every bidi backend.
//!
//! These are deliberately backend-agnostic: they describe the *result* of
//! running the Unicode Bidirectional Algorithm (UAX #9), not how it was
//! computed. Swapping the backend must never change these.

const std = @import("std");

/// A resolved direction. Levels are even for left-to-right and odd for
/// right-to-left (UAX #9, rules I1/I2).
pub const Direction = enum(u1) {
    ltr,
    rtl,
};

/// An embedding level. UAX #9 caps the maximum depth at 125 (BD2), so this
/// always fits in a u8 with room to spare.
pub const Level = u8;

/// The maximum explicit embedding depth (UAX #9, BD2).
pub const max_depth: Level = 125;

/// The direction implied by an embedding level: even is LTR, odd is RTL.
pub fn levelDirection(level: Level) Direction {
    return if (level & 1 == 0) .ltr else .rtl;
}

/// How to determine the paragraph embedding level.
pub const ParagraphDirection = enum {
    /// Derive it from the first strong character (UAX #9, rules P2/P3),
    /// defaulting to left-to-right if there is none.
    auto,

    /// Force a left-to-right paragraph, skipping P2/P3.
    ltr,

    /// Force a right-to-left paragraph, skipping P2/P3.
    rtl,
};

/// A maximal run of elements sharing one embedding level, in visual order.
///
/// Rule L2 reverses contiguous level runs, which means a run is contiguous
/// in both logical and visual order. That is what lets a shaper treat a run
/// as a plain logical substring plus a direction.
pub const LevelRun = struct {
    /// The first visual index covered by this run.
    visual_start: u16,

    /// The number of elements in the run.
    len: u16,

    /// The lowest logical index covered by this run. For a right-to-left
    /// run the logical indices descend as the visual indices ascend, so
    /// this is the logical index of the run's *last* visual element.
    logical_start: u16,

    /// The resolved embedding level of every element in the run.
    level: Level,

    pub fn direction(self: LevelRun) Direction {
        return levelDirection(self.level);
    }
};

/// Options for a single resolve call.
pub const Options = struct {
    /// How to determine the paragraph embedding level.
    direction: ParagraphDirection = .auto,
};

/// The result of resolving one paragraph.
///
/// The slices borrow the resolver's internal buffers and are only valid
/// until the next call to `resolve` on that resolver. Callers that need to
/// retain the mapping must copy it (the renderer's row cache does exactly
/// this in a later phase).
///
/// ## The identity fast path
///
/// When `identity` is true, visual order equals logical order and
/// `levels`, `v2l`, and `l2v` are left empty rather than being filled with
/// a trivial 0..n mapping. This is the whole point of the fast path: a row
/// of pure left-to-right text costs no allocation and no table writes. Use
/// the accessors below rather than indexing the slices directly so this
/// stays transparent.
pub const Result = struct {
    /// The resolved paragraph direction.
    direction: Direction,

    /// The number of elements this result describes.
    len: usize,

    /// True when visual order equals logical order. See above.
    identity: bool,

    /// Resolved embedding level per logical index. Empty when `identity`.
    levels: []const Level,

    /// Visual index to logical index. Empty when `identity`.
    v2l: []const u16,

    /// Logical index to visual index. Empty when `identity`.
    l2v: []const u16,

    /// Level runs in visual order. Always populated, including for the
    /// identity case, so run iteration needs no special casing.
    runs: []const LevelRun,

    /// The logical index displayed at the given visual index.
    pub inline fn logicalIndex(self: Result, visual: usize) usize {
        std.debug.assert(visual < self.len);
        return if (self.identity) visual else self.v2l[visual];
    }

    /// The visual index at which the given logical index is displayed.
    pub inline fn visualIndex(self: Result, logical: usize) usize {
        std.debug.assert(logical < self.len);
        return if (self.identity) logical else self.l2v[logical];
    }

    /// The resolved embedding level of the given logical index.
    pub inline fn level(self: Result, logical: usize) Level {
        std.debug.assert(logical < self.len);
        return if (self.identity) 0 else self.levels[logical];
    }

    /// An empty result, for zero-length input.
    pub const empty: Result = .{
        .direction = .ltr,
        .len = 0,
        .identity = true,
        .levels = &.{},
        .v2l = &.{},
        .l2v = &.{},
        .runs = &.{},
    };
};

test "levelDirection" {
    const testing = std.testing;
    try testing.expectEqual(Direction.ltr, levelDirection(0));
    try testing.expectEqual(Direction.rtl, levelDirection(1));
    try testing.expectEqual(Direction.ltr, levelDirection(2));
    try testing.expectEqual(Direction.rtl, levelDirection(125));
}

test "LevelRun direction" {
    const testing = std.testing;
    const ltr: LevelRun = .{
        .visual_start = 0,
        .len = 3,
        .logical_start = 0,
        .level = 0,
    };
    const rtl: LevelRun = .{
        .visual_start = 3,
        .len = 3,
        .logical_start = 3,
        .level = 1,
    };
    try testing.expectEqual(Direction.ltr, ltr.direction());
    try testing.expectEqual(Direction.rtl, rtl.direction());
}

test "Result: identity accessors need no tables" {
    const testing = std.testing;

    const r: Result = .{
        .direction = .ltr,
        .len = 4,
        .identity = true,
        .levels = &.{},
        .v2l = &.{},
        .l2v = &.{},
        .runs = &.{},
    };

    for (0..4) |i| {
        try testing.expectEqual(i, r.logicalIndex(i));
        try testing.expectEqual(i, r.visualIndex(i));
        try testing.expectEqual(@as(Level, 0), r.level(i));
    }
}

test "Result: non-identity accessors read the tables" {
    const testing = std.testing;

    // Logical "abcABC" where ABC is RTL: visual order is abcCBA.
    const levels = [_]Level{ 0, 0, 0, 1, 1, 1 };
    const v2l = [_]u16{ 0, 1, 2, 5, 4, 3 };
    const l2v = [_]u16{ 0, 1, 2, 5, 4, 3 };

    const r: Result = .{
        .direction = .ltr,
        .len = 6,
        .identity = false,
        .levels = &levels,
        .v2l = &v2l,
        .l2v = &l2v,
        .runs = &.{},
    };

    try testing.expectEqual(@as(usize, 5), r.logicalIndex(3));
    try testing.expectEqual(@as(usize, 3), r.visualIndex(5));
    try testing.expectEqual(@as(Level, 1), r.level(4));
    try testing.expectEqual(@as(Level, 0), r.level(0));

    // v2l and l2v must be inverse permutations of each other.
    for (0..6) |i| {
        try testing.expectEqual(i, r.logicalIndex(r.visualIndex(i)));
    }
}

test "Result.empty" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 0), Result.empty.len);
    try testing.expect(Result.empty.identity);
    try testing.expectEqual(@as(usize, 0), Result.empty.runs.len);
}
