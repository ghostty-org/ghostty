const std = @import("std");
const Allocator = std.mem.Allocator;
const lib = @import("lib.zig");
const size = @import("size.zig");

/// The possible reference locations for a point. When someone says "(42, 80)"
/// in the context of a terminal, that could mean multiple things: it is in the
/// current visible viewport? the current active area of the screen where the
/// cursor is? the entire scrollback history? etc.
///
/// This tag is used to differentiate those cases.
pub const Tag = lib.Enum(lib.target, &.{
    // Top-left is part of the active area where a running program can
    // jump the cursor and make changes. The active area is the "editable"
    // part of the screen.
    //
    // The bottom-right of the active tag differs from all other tags
    // because it includes the full height (rows) of the screen, including
    // rows that may not be written yet. This is required because the active
    // area is fully "addressable" by the running program (see below) whereas
    // the other tags are used primarily for reading/modifying past-written
    // data so they can't address unwritten rows.
    //
    // Note for those less familiar with terminal functionality: there
    // are escape sequences to move the cursor to any position on
    // the screen, but it is limited to the size of the viewport and
    // the bottommost part of the screen. Terminal programs can't --
    // with sequences at the time of writing this comment -- modify
    // anything in the scrollback, visible viewport (if it differs
    // from the active area), etc.
    "active",

    // Top-left is the visible viewport. This means that if the user
    // has scrolled in any direction, top-left changes. The bottom-right
    // is the last written row from the top-left.
    "viewport",

    // Top-left is the furthest back in the scrollback history
    // supported by the screen and the bottom-right is the bottom-right
    // of the last written row. Note this last point is important: the
    // bottom right is NOT necessarily the same as "active" because
    // "active" always allows referencing the full rows tall of the
    // screen whereas "screen" only contains written rows.
    "screen",

    // The top-left is the same as "screen" but the bottom-right is
    // the line just before the top of "active". This contains only
    // the scrollback history.
    "history",
});

/// An x/y point in the terminal for some definition of location (tag).
pub const Point = union(Tag) {
    active: Coordinate,
    viewport: Coordinate,
    screen: Coordinate,
    history: Coordinate,

    pub inline fn coord(self: Point) Coordinate {
        return switch (self) {
            .active,
            .viewport,
            .screen,
            .history,
            => |v| v,
        };
    }

    const c_union = lib.TaggedUnion(
        lib.target,
        @This(),
        // Padding: largest variant is Coordinate (u16 + u32 = 6 bytes).
        // Use [2]u64 (16 bytes) for future expansion.
        [2]u64,
    );
    pub const C = c_union.C;
    pub const CValue = c_union.CValue;
    pub const cval = c_union.cval;

    /// Convert a C ABI point into the native Zig tagged union.
    pub fn fromC(pt: C) Point {
        return switch (pt.tag) {
            .active => .{ .active = pt.value.active },
            .viewport => .{ .viewport = pt.value.viewport },
            .screen => .{ .screen = pt.value.screen },
            .history => .{ .history = pt.value.history },
        };
    }
};

/// The coordinate space a column is expressed in.
///
/// A terminal grid has exactly two of these once bidirectional text is
/// supported, and confusing them is the defect class that dominates bidi
/// implementations. See `Col` below.
pub const ColSpace = enum {
    /// The order characters are stored, transmitted, and typed. This is what
    /// the PTY delivers, what escape sequences address, and what must go on
    /// the clipboard. Logical order is authoritative: it is the only order in
    /// which the terminal's contract with the running program is defined.
    logical,

    /// The left-to-right order glyphs appear on the physical screen. It is
    /// derived from logical order and exists only for display and for
    /// interpreting pointer input. It is never written back to the screen.
    visual,
};

/// A column index in a specific coordinate space.
///
/// Today every column in Ghostty is logical, because no reordering exists
/// yet. That makes this the cheapest possible moment to introduce the
/// distinction: the conversion is mechanical while there is exactly one
/// space in play, and it becomes a compile error to mix them the moment a
/// second space appears.
///
/// This is a non-exhaustive enum rather than a struct so that it is a truly
/// distinct type with a defined backing integer: it cannot be implicitly
/// converted to or from `size.CellCountInt`, and `LogicalCol` cannot be
/// passed where `VisualCol` is expected. It compiles to the same `u16` as
/// the bare integer it replaces, so there is no runtime or memory cost.
///
/// Conversions to and from the backing integer go through `from` and `int`.
/// Callers must never reach for `@enumFromInt`/`@intFromEnum` directly, and
/// must never use `@intCast`/`@bitCast` to move between the two spaces: the
/// whole point of the type is that such a move is a deliberate, greppable
/// act. See `assumeIdentity` for the one sanctioned escape hatch.
fn Col(comptime col_space: ColSpace) type {
    return enum(size.CellCountInt) {
        _,

        const Self = @This();

        /// The coordinate space this column lives in. Reflecting the
        /// comptime parameter into a decl both documents the space and
        /// keeps the two instantiations distinct types.
        pub const space: ColSpace = col_space;

        /// The first column.
        pub const zero: Self = @enumFromInt(0);

        /// Build a column from a raw index.
        pub inline fn from(v: size.CellCountInt) Self {
            return @enumFromInt(v);
        }

        /// The raw index. Use this only at the boundary where a plain
        /// integer is genuinely required (indexing a slice, an escape
        /// sequence parameter, the C ABI).
        pub inline fn int(self: Self) size.CellCountInt {
            return @intFromEnum(self);
        }

        pub inline fn eql(self: Self, other: Self) bool {
            return self.int() == other.int();
        }

        pub inline fn order(self: Self, other: Self) std.math.Order {
            return std.math.order(self.int(), other.int());
        }

        pub inline fn lessThan(self: Self, other: Self) bool {
            return self.int() < other.int();
        }

        pub inline fn min(self: Self, other: Self) Self {
            return .from(@min(self.int(), other.int()));
        }

        pub inline fn max(self: Self, other: Self) Self {
            return .from(@max(self.int(), other.int()));
        }

        /// Offset by a count of cells. These have the same overflow
        /// semantics as the raw integer arithmetic they replace, so
        /// behavior is unchanged from before the type existed.
        pub inline fn add(self: Self, v: size.CellCountInt) Self {
            return .from(self.int() + v);
        }

        pub inline fn sub(self: Self, v: size.CellCountInt) Self {
            return .from(self.int() - v);
        }

        /// The identity mapping between spaces.
        ///
        /// While bidi is disabled (and on any row with no right-to-left
        /// content, which is the overwhelming majority) logical and visual
        /// order coincide, so this conversion is correct. It is spelled
        /// "assume" so that every site relying on that coincidence is
        /// greppable: when reordering lands, each one must be revisited and
        /// either justified or routed through the row's bidi map.
        pub inline fn assumeIdentity(
            self: Self,
            comptime to: ColSpace,
        ) Col(to) {
            return .from(self.int());
        }
    };
}

/// A column in logical (storage) order. See `Col`.
pub const LogicalCol = Col(.logical);

/// A column in visual (display) order. See `Col`.
pub const VisualCol = Col(.visual);

pub const Coordinate = extern struct {
    /// x can use size.CellCountInt because the number of columns
    /// can't ever be more than a valid number of columns in a Page.
    ///
    /// This is deliberately NOT a `LogicalCol`. A `Coordinate` is
    /// space-agnostic: a `viewport` coordinate built from a mouse position
    /// is a visual column, while one used for cursor addressing is logical.
    /// Committing this field to one space would make the other one wrong.
    /// Callers state which space they mean at the point of use via
    /// `logicalX`/`visualX`.
    x: size.CellCountInt = 0,

    /// y does not use size.CellCountInt because certain coordinate
    /// usage such as screen/history can have more rows than are possible
    /// in a single page.
    y: u32 = 0,

    pub fn eql(self: Coordinate, other: Coordinate) bool {
        return self.x == other.x and self.y == other.y;
    }

    /// Interpret this coordinate's column as logical (storage) order.
    /// Use this when the coordinate came from the screen, the cursor, or
    /// an escape sequence.
    pub inline fn logicalX(self: Coordinate) LogicalCol {
        return .from(self.x);
    }

    /// Interpret this coordinate's column as visual (display) order.
    /// Use this when the coordinate came from a pointer position or any
    /// other on-screen measurement.
    pub inline fn visualX(self: Coordinate) VisualCol {
        return .from(self.x);
    }
};

test "Col: distinct types with a zero-cost representation" {
    const testing = std.testing;

    // The two spaces are genuinely different types. Passing one where the
    // other is expected is a compile error, which is the entire point.
    try testing.expect(LogicalCol != VisualCol);
    try testing.expectEqual(ColSpace.logical, LogicalCol.space);
    try testing.expectEqual(ColSpace.visual, VisualCol.space);

    // Zero-cost: identical size and alignment to the bare integer it
    // replaces, so adopting it cannot change a struct layout or an ABI.
    inline for (.{ LogicalCol, VisualCol }) |T| {
        try testing.expectEqual(@sizeOf(size.CellCountInt), @sizeOf(T));
        try testing.expectEqual(@alignOf(size.CellCountInt), @alignOf(T));
        try testing.expectEqual(@bitSizeOf(size.CellCountInt), @bitSizeOf(T));
    }
}

test "Col: conversion round trip" {
    const testing = std.testing;

    for ([_]size.CellCountInt{ 0, 1, 42, 79, 80, 1000, std.math.maxInt(size.CellCountInt) }) |v| {
        try testing.expectEqual(v, LogicalCol.from(v).int());
        try testing.expectEqual(v, VisualCol.from(v).int());
    }

    try testing.expectEqual(@as(size.CellCountInt, 0), LogicalCol.zero.int());
    try testing.expectEqual(@as(size.CellCountInt, 0), VisualCol.zero.int());
}

test "Col: comparison and ordering" {
    const testing = std.testing;

    const a: LogicalCol = .from(3);
    const b: LogicalCol = .from(7);
    const c: LogicalCol = .from(3);

    try testing.expect(a.eql(c));
    try testing.expect(!a.eql(b));
    try testing.expect(a.lessThan(b));
    try testing.expect(!b.lessThan(a));

    try testing.expectEqual(std.math.Order.lt, a.order(b));
    try testing.expectEqual(std.math.Order.gt, b.order(a));
    try testing.expectEqual(std.math.Order.eq, a.order(c));

    try testing.expectEqual(a, a.min(b));
    try testing.expectEqual(b, a.max(b));
}

test "Col: arithmetic matches the raw integer it replaces" {
    const testing = std.testing;

    const a: VisualCol = .from(10);
    try testing.expectEqual(@as(size.CellCountInt, 13), a.add(3).int());
    try testing.expectEqual(@as(size.CellCountInt, 7), a.sub(3).int());
    try testing.expectEqual(@as(size.CellCountInt, 10), a.add(5).sub(5).int());
}

test "Col: identity mapping between spaces" {
    const testing = std.testing;

    // Correct only while logical and visual order coincide, which is the
    // case for every row without RTL content. Spelled "assume" so the
    // reliance is greppable when reordering lands.
    const l: LogicalCol = .from(12);
    const v: VisualCol = l.assumeIdentity(.visual);
    try testing.expectEqual(@as(size.CellCountInt, 12), v.int());
    try testing.expect(VisualCol == @TypeOf(v));

    const back: LogicalCol = v.assumeIdentity(.logical);
    try testing.expectEqual(l, back);
    try testing.expect(LogicalCol == @TypeOf(back));
}

test "Coordinate: space is stated at the point of use" {
    const testing = std.testing;

    const coord: Coordinate = .{ .x = 5, .y = 2 };
    try testing.expectEqual(@as(size.CellCountInt, 5), coord.logicalX().int());
    try testing.expectEqual(@as(size.CellCountInt, 5), coord.visualX().int());
    try testing.expect(LogicalCol == @TypeOf(coord.logicalX()));
    try testing.expect(VisualCol == @TypeOf(coord.visualX()));
}
