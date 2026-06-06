//! Pure helpers for reporting the on-screen bounds of the selected search
//! match to the apprt. These are factored out of the renderer so they can be
//! unit tested without a GraphicsAPI/GPU.

const std = @import("std");
const Allocator = std.mem.Allocator;
const terminal = @import("../terminal/main.zig");
const renderer = @import("../renderer.zig");

const RenderState = terminal.RenderState;
pub const Highlight = RenderState.Highlight;
const Size = renderer.Size;
const Bounds = renderer.Bounds;

/// Append one rect per viewport row holding a `selected_tag` highlight, so a
/// wrapped match is represented exactly rather than as one covering rect.
pub fn appendRegions(
    list: *std.ArrayListUnmanaged(Bounds),
    alloc: Allocator,
    row_highlights: []const std.ArrayList(Highlight),
    sz: Size,
    selected_tag: u8,
) Allocator.Error!void {
    for (0.., row_highlights) |y, highlights| {
        for (highlights.items) |hl| {
            if (hl.tag != selected_tag) continue;
            try list.append(alloc, Bounds.fromCellRange(sz, .{
                .y = @intCast(y),
                .x0 = hl.range[0],
                .x1 = hl.range[1],
            }));
        }
    }
}

pub fn eql(a: []const Bounds, b: []const Bounds) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!x.eql(y)) return false;
    }
    return true;
}

pub const Decision = enum {
    skip,
    push,
    /// No rects now but some were reported before (match scrolled off-screen):
    /// drop the overlay, keep the index.
    clear,
};

/// Decide how the freshly-computed selection (`idx`, `new_regions`) relates to
/// the last one reported (`last_*`, valid only when `has_last`).
pub fn decide(
    has_last: bool,
    last_idx: usize,
    last_regions: []const Bounds,
    idx: usize,
    new_regions: []const Bounds,
) Decision {
    if (has_last and last_idx == idx and eql(last_regions, new_regions))
        return .skip;

    // No rects: clear a stale overlay if one was reported, else nothing to do
    // (transient post-resize / freshly-selected state; a report follows soon).
    if (new_regions.len == 0)
        return if (has_last) .clear else .skip;

    return .push;
}

fn testSize() Size {
    return .{
        .screen = .{ .width = 1000, .height = 1000 },
        .cell = .{ .width = 10, .height = 20 },
        .padding = .{},
    };
}

test "appendRegions: empty input yields nothing" {
    const alloc = std.testing.allocator;
    var list: std.ArrayListUnmanaged(Bounds) = .empty;
    defer list.deinit(alloc);
    const rows = [_]std.ArrayList(Highlight){};
    try appendRegions(&list, alloc, &rows, testSize(), 7);
    try std.testing.expectEqual(@as(usize, 0), list.items.len);
}

test "appendRegions: single selected row produces one rect" {
    const alloc = std.testing.allocator;

    var r0: std.ArrayList(Highlight) = .empty;
    defer r0.deinit(alloc);
    var r1: std.ArrayList(Highlight) = .empty;
    defer r1.deinit(alloc);
    try r1.append(alloc, .{ .tag = 7, .range = .{ 2, 4 } });

    const rows = [_]std.ArrayList(Highlight){ r0, r1 };
    var list: std.ArrayListUnmanaged(Bounds) = .empty;
    defer list.deinit(alloc);

    try appendRegions(&list, alloc, &rows, testSize(), 7);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    // y=1 -> 20px, x0=2 -> 20px, cols=3 -> width 30, height 20
    try std.testing.expectEqual(
        Bounds{ .x = 20, .y = 20, .width = 30, .height = 20 },
        list.items[0],
    );
}

test "appendRegions: ignores highlights with a different tag" {
    const alloc = std.testing.allocator;

    var r0: std.ArrayList(Highlight) = .empty;
    defer r0.deinit(alloc);
    try r0.append(alloc, .{ .tag = 3, .range = .{ 0, 0 } });

    const rows = [_]std.ArrayList(Highlight){r0};
    var list: std.ArrayListUnmanaged(Bounds) = .empty;
    defer list.deinit(alloc);

    try appendRegions(&list, alloc, &rows, testSize(), 7);
    try std.testing.expectEqual(@as(usize, 0), list.items.len);
}

test "appendRegions: one rect per row for a multi-row match" {
    const alloc = std.testing.allocator;

    var r0: std.ArrayList(Highlight) = .empty;
    defer r0.deinit(alloc);
    var r1: std.ArrayList(Highlight) = .empty;
    defer r1.deinit(alloc);
    try r0.append(alloc, .{ .tag = 7, .range = .{ 0, 1 } });
    try r1.append(alloc, .{ .tag = 7, .range = .{ 0, 1 } });

    const rows = [_]std.ArrayList(Highlight){ r0, r1 };
    var list: std.ArrayListUnmanaged(Bounds) = .empty;
    defer list.deinit(alloc);

    try appendRegions(&list, alloc, &rows, testSize(), 7);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqual(@as(f64, 0), list.items[0].y);
    try std.testing.expectEqual(@as(f64, 20), list.items[1].y);
}

test "eql" {
    const a = [_]Bounds{.{ .x = 1, .y = 2, .width = 3, .height = 4 }};
    const b = [_]Bounds{.{ .x = 1, .y = 2, .width = 3, .height = 4 }};
    const c = [_]Bounds{.{ .x = 9, .y = 2, .width = 3, .height = 4 }};
    try std.testing.expect(eql(&a, &b));
    try std.testing.expect(!eql(&a, &c));
    try std.testing.expect(!eql(&a, &.{}));
}

test "decide: unchanged -> skip" {
    const regions = [_]Bounds{.{ .x = 1, .y = 2, .width = 3, .height = 4 }};
    try std.testing.expectEqual(
        Decision.skip,
        decide(true, 5, &regions, 5, &regions),
    );
}

test "decide: changed index -> push" {
    const regions = [_]Bounds{.{ .x = 1, .y = 2, .width = 3, .height = 4 }};
    try std.testing.expectEqual(
        Decision.push,
        decide(true, 5, &regions, 6, &regions),
    );
}

test "decide: changed regions -> push" {
    const a = [_]Bounds{.{ .x = 1, .y = 2, .width = 3, .height = 4 }};
    const b = [_]Bounds{.{ .x = 9, .y = 2, .width = 3, .height = 4 }};
    try std.testing.expectEqual(
        Decision.push,
        decide(true, 5, &a, 5, &b),
    );
}

test "decide: new selection with no prior -> push" {
    const regions = [_]Bounds{.{ .x = 1, .y = 2, .width = 3, .height = 4 }};
    try std.testing.expectEqual(
        Decision.push,
        decide(false, 0, &.{}, 5, &regions),
    );
}

test "decide: went empty with a prior report -> clear" {
    const prior = [_]Bounds{.{ .x = 1, .y = 2, .width = 3, .height = 4 }};
    try std.testing.expectEqual(
        Decision.clear,
        decide(true, 5, &prior, 5, &.{}),
    );
}

test "decide: empty with no prior -> skip" {
    try std.testing.expectEqual(
        Decision.skip,
        decide(false, 0, &.{}, 5, &.{}),
    );
}
