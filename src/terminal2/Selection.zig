//! Represents a single selection within the terminal (i.e. a highlight region).
const Selection = @This();

const std = @import("std");
const assert = std.debug.assert;
const page = @import("page.zig");
const point = @import("point.zig");
const PageList = @import("PageList.zig");
const Screen = @import("Screen.zig");
const Pin = PageList.Pin;

// NOTE(mitchellh): I'm not very happy with how this is implemented, because
// the ordering operations which are used frequently require using
// pointFromPin which -- at the time of writing this -- is slow. The overall
// style of this struct is due to porting it from the previous implementation
// which had an efficient ordering operation.
//
// While reimplementing this, there were too many callers that already
// depended on this behavior so I kept it despite the inefficiency. In the
// future, we should take a look at this again!

/// The bounds of the selection.
bounds: Bounds,

/// Whether or not this selection refers to a rectangle, rather than whole
/// lines of a buffer. In this mode, start and end refer to the top left and
/// bottom right of the rectangle, or vice versa if the selection is backwards.
rectangle: bool = false,

/// The bounds of the selection. A selection bounds can be either tracked
/// or untracked. Untracked bounds are unsafe beyond the point the terminal
/// screen may be modified, since they may point to invalid memory. Tracked
/// bounds are always valid and will be updated as the screen changes, but
/// are more expensive to exist.
///
/// In all cases, start and end can be in any order. There is no guarantee that
/// start is before end or vice versa. If a user selects backwards,
/// start will be after end, and vice versa. Use the struct functions
/// to not have to worry about this.
pub const Bounds = union(enum) {
    untracked: struct {
        start: Pin,
        end: Pin,
    },

    tracked: struct {
        start: *Pin,
        end: *Pin,
    },
};

/// Initialize a new selection with the given start and end pins on
/// the screen. The screen will be used for pin tracking.
pub fn init(
    start_pin: Pin,
    end_pin: Pin,
    rect: bool,
) Selection {
    return .{
        .bounds = .{ .untracked = .{
            .start = start_pin,
            .end = end_pin,
        } },
        .rectangle = rect,
    };
}

pub fn deinit(
    self: Selection,
    s: *Screen,
) void {
    switch (self.bounds) {
        .tracked => |v| {
            s.pages.untrackPin(v.start);
            s.pages.untrackPin(v.end);
        },

        .untracked => {},
    }
}

/// The starting pin of the selection. This is NOT ordered.
pub fn start(self: *Selection) *Pin {
    return switch (self.bounds) {
        .untracked => |*v| &v.start,
        .tracked => |v| v.start,
    };
}

/// The ending pin of the selection. This is NOT ordered.
pub fn end(self: *Selection) *Pin {
    return switch (self.bounds) {
        .untracked => |*v| &v.end,
        .tracked => |v| v.end,
    };
}

fn startConst(self: Selection) Pin {
    return switch (self.bounds) {
        .untracked => |v| v.start,
        .tracked => |v| v.start.*,
    };
}

fn endConst(self: Selection) Pin {
    return switch (self.bounds) {
        .untracked => |v| v.end,
        .tracked => |v| v.end.*,
    };
}

/// Returns true if this is a tracked selection.
pub fn tracked(self: *const Selection) bool {
    return switch (self.bounds) {
        .untracked => false,
        .tracked => true,
    };
}

/// Convert this selection a tracked selection. It is asserted this is
/// an untracked selection.
pub fn track(self: *Selection, s: *Screen) !void {
    assert(!self.tracked());

    // Track our pins
    const start_pin = self.bounds.untracked.start;
    const end_pin = self.bounds.untracked.end;
    const tracked_start = try s.pages.trackPin(start_pin);
    errdefer s.pages.untrackPin(tracked_start);
    const tracked_end = try s.pages.trackPin(end_pin);
    errdefer s.pages.untrackPin(tracked_end);

    self.bounds = .{ .tracked = .{
        .start = tracked_start,
        .end = tracked_end,
    } };
}

/// The order of the selection:
///
///  * forward: start(x, y) is before end(x, y) (top-left to bottom-right).
///  * reverse: end(x, y) is before start(x, y) (bottom-right to top-left).
///  * mirrored_[forward|reverse]: special, rectangle selections only (see below).
///
///  For regular selections, the above also holds for top-right to bottom-left
///  (forward) and bottom-left to top-right (reverse). However, for rectangle
///  selections, both of these selections are *mirrored* as orientation
///  operations only flip the x or y axis, not both. Depending on the y axis
///  direction, this is either mirrored_forward or mirrored_reverse.
///
pub const Order = enum { forward, reverse, mirrored_forward, mirrored_reverse };

pub fn order(self: Selection, s: *const Screen) Order {
    const start_pt = s.pages.pointFromPin(.screen, self.startConst()).?.screen;
    const end_pt = s.pages.pointFromPin(.screen, self.endConst()).?.screen;

    if (self.rectangle) {
        // Reverse (also handles single-column)
        if (start_pt.y > end_pt.y and start_pt.x >= end_pt.x) return .reverse;
        if (start_pt.y >= end_pt.y and start_pt.x > end_pt.x) return .reverse;

        // Mirror, bottom-left to top-right
        if (start_pt.y > end_pt.y and start_pt.x < end_pt.x) return .mirrored_reverse;

        // Mirror, top-right to bottom-left
        if (start_pt.y < end_pt.y and start_pt.x > end_pt.x) return .mirrored_forward;

        // Forward
        return .forward;
    }

    if (start_pt.y < end_pt.y) return .forward;
    if (start_pt.y > end_pt.y) return .reverse;
    if (start_pt.x <= end_pt.x) return .forward;
    return .reverse;
}

/// Possible adjustments to the selection.
pub const Adjustment = enum {
    left,
    right,
    up,
    down,
    home,
    end,
    page_up,
    page_down,
};

/// Adjust the selection by some given adjustment. An adjustment allows
/// a selection to be expanded slightly left, right, up, down, etc.
pub fn adjust(
    self: *Selection,
    s: *const Screen,
    adjustment: Adjustment,
) void {
    // Note that we always adjusts "end" because end always represents
    // the last point of the selection by mouse, not necessarilly the
    // top/bottom visually. So this results in the right behavior
    // whether the user drags up or down.
    const end_pin = self.end();
    switch (adjustment) {
        .up => if (end_pin.up(1)) |new_end| {
            end_pin.* = new_end;
        } else {
            end_pin.x = 0;
        },

        .down => {
            // Find the next non-blank row
            var current = end_pin.*;
            while (current.down(1)) |next| : (current = next) {
                const rac = next.rowAndCell();
                const cells = next.page.data.getCells(rac.row);
                if (page.Cell.hasTextAny(cells)) {
                    end_pin.* = next;
                    break;
                }
            } else {
                // If we're at the bottom, just go to the end of the line
                end_pin.x = end_pin.page.data.size.cols - 1;
            }
        },

        .left => {
            var it = s.pages.cellIterator(
                .left_up,
                .{ .screen = .{} },
                s.pages.pointFromPin(.screen, end_pin.*).?,
            );
            _ = it.next();
            while (it.next()) |next| {
                const rac = next.rowAndCell();
                if (rac.cell.hasText()) {
                    end_pin.* = next;
                    break;
                }
            }
        },

        .right => {
            // Step right, wrapping to the next row down at the start of each new line,
            // until we find a non-empty cell.
            var it = s.pages.cellIterator(
                .right_down,
                s.pages.pointFromPin(.screen, end_pin.*).?,
                null,
            );
            _ = it.next();
            while (it.next()) |next| {
                const rac = next.rowAndCell();
                if (rac.cell.hasText()) {
                    end_pin.* = next;
                    break;
                }
            }
        },

        .page_up => if (end_pin.up(s.pages.rows)) |new_end| {
            end_pin.* = new_end;
        } else {
            self.adjust(s, .home);
        },

        // TODO(paged-terminal): this doesn't take into account blanks
        .page_down => if (end_pin.down(s.pages.rows)) |new_end| {
            end_pin.* = new_end;
        } else {
            self.adjust(s, .end);
        },

        .home => end_pin.* = s.pages.pin(.{ .screen = .{
            .x = 0,
            .y = 0,
        } }).?,

        .end => {
            var it = s.pages.rowIterator(
                .left_up,
                .{ .screen = .{} },
                null,
            );
            while (it.next()) |next| {
                const rac = next.rowAndCell();
                const cells = next.page.data.getCells(rac.row);
                if (page.Cell.hasTextAny(cells)) {
                    end_pin.* = next;
                    end_pin.x = cells.len - 1;
                    break;
                }
            }
        },
    }
}

test "Selection: adjust right" {
    const testing = std.testing;
    var s = try Screen.init(testing.allocator, 5, 10, 0);
    defer s.deinit();
    try s.testWriteString("A1234\nB5678\nC1234\nD5678");

    // Simple movement right
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 3 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .right);

        try testing.expectEqual(point.Point{ .screen = .{
            .x = 5,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 3,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }

    // Already at end of the line.
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 4, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 4, .y = 2 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .right);

        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 3,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }

    // Already at end of the screen
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 4, .y = 3 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .right);

        try testing.expectEqual(point.Point{ .screen = .{
            .x = 5,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 3,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }
}

test "Selection: adjust left" {
    const testing = std.testing;
    var s = try Screen.init(testing.allocator, 5, 10, 0);
    defer s.deinit();
    try s.testWriteString("A1234\nB5678\nC1234\nD5678");

    // Simple movement left
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 3 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .left);

        // Start line
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 5,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 3,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }

    // Already at beginning of the line.
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 3 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .left);

        // Start line
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 5,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 2,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }
}

test "Selection: adjust left skips blanks" {
    const testing = std.testing;
    var s = try Screen.init(testing.allocator, 5, 10, 0);
    defer s.deinit();
    try s.testWriteString("A1234\nB5678\nC12\nD56");

    // Same line
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 4, .y = 3 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .left);

        // Start line
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 5,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 3,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }

    // Edge
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 3 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .left);

        // Start line
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 5,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 2,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }
}

test "Selection: adjust up" {
    const testing = std.testing;
    var s = try Screen.init(testing.allocator, 5, 10, 0);
    defer s.deinit();
    try s.testWriteString("A\nB\nC\nD\nE");

    // Not on the first line
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 3 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .up);

        try testing.expectEqual(point.Point{ .screen = .{
            .x = 5,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 2,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }

    // On the first line
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 0 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .up);

        try testing.expectEqual(point.Point{ .screen = .{
            .x = 5,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }
}

test "Selection: adjust down" {
    const testing = std.testing;
    var s = try Screen.init(testing.allocator, 5, 10, 0);
    defer s.deinit();
    try s.testWriteString("A\nB\nC\nD\nE");

    // Not on the first line
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 3 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .down);

        try testing.expectEqual(point.Point{ .screen = .{
            .x = 5,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 4,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }

    // On the last line
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 4, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 4 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .down);

        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 4,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }
}

test "Selection: adjust down with not full screen" {
    const testing = std.testing;
    var s = try Screen.init(testing.allocator, 5, 10, 0);
    defer s.deinit();
    try s.testWriteString("A\nB\nC");

    // On the last line
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 4, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 2 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .down);

        // Start line
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 2,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }
}

test "Selection: adjust home" {
    const testing = std.testing;
    var s = try Screen.init(testing.allocator, 5, 10, 0);
    defer s.deinit();
    try s.testWriteString("A\nB\nC");

    // On the last line
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 4, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 2 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .home);

        // Start line
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }
}

test "Selection: adjust end with not full screen" {
    const testing = std.testing;
    var s = try Screen.init(testing.allocator, 5, 10, 0);
    defer s.deinit();
    try s.testWriteString("A\nB\nC");

    // On the last line
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 4, .y = 0 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .end);

        // Start line
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 2,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }
}

test "Selection: order, standard" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, 100, 100, 1);
    defer s.deinit();

    {
        // forward, multi-line
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 2 } }).?,
            false,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .forward);
    }
    {
        // reverse, multi-line
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 2 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
            false,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .reverse);
    }
    {
        // forward, same-line
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            false,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .forward);
    }
    {
        // forward, single char
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
            false,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .forward);
    }
    {
        // reverse, single line
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            false,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .reverse);
    }
}

test "Selection: order, rectangle" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, 100, 100, 1);
    defer s.deinit();

    // Conventions:
    // TL - top left
    // BL - bottom left
    // TR - top right
    // BR - bottom right
    {
        // forward (TL -> BR)
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 2 } }).?,
            true,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .forward);
    }
    {
        // reverse (BR -> TL)
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 2 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            true,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .reverse);
    }
    {
        // mirrored_forward (TR -> BL)
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 3 } }).?,
            true,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .mirrored_forward);
    }
    {
        // mirrored_reverse (BL -> TR)
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 3 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            true,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .mirrored_reverse);
    }
    {
        // forward, single line (left -> right )
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            true,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .forward);
    }
    {
        // reverse, single line (right -> left)
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            true,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .reverse);
    }
    {
        // forward, single column (top -> bottom)
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 3 } }).?,
            true,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .forward);
    }
    {
        // reverse, single column (bottom -> top)
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 3 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
            true,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .reverse);
    }
    {
        // forward, single cell
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            true,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .forward);
    }
}
