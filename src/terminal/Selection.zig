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

/// Returns true if this selection is equal to another selection.
pub fn eql(self: Selection, other: Selection) bool {
    return self.start().eql(other.start()) and
        self.end().eql(other.end()) and
        self.rectangle == other.rectangle;
}

/// The starting pin of the selection. This is NOT ordered.
pub fn startPtr(self: *Selection) *Pin {
    return switch (self.bounds) {
        .untracked => |*v| &v.start,
        .tracked => |v| v.start,
    };
}

/// The ending pin of the selection. This is NOT ordered.
pub fn endPtr(self: *Selection) *Pin {
    return switch (self.bounds) {
        .untracked => |*v| &v.end,
        .tracked => |v| v.end,
    };
}

pub fn start(self: Selection) Pin {
    return switch (self.bounds) {
        .untracked => |v| v.start,
        .tracked => |v| v.start.*,
    };
}

pub fn end(self: Selection) Pin {
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
/// an untracked selection. The tracked selection is returned.
pub fn track(self: *const Selection, s: *Screen) !Selection {
    assert(!self.tracked());

    // Track our pins
    const start_pin = self.bounds.untracked.start;
    const end_pin = self.bounds.untracked.end;
    const tracked_start = try s.pages.trackPin(start_pin);
    errdefer s.pages.untrackPin(tracked_start);
    const tracked_end = try s.pages.trackPin(end_pin);
    errdefer s.pages.untrackPin(tracked_end);

    return .{
        .bounds = .{ .tracked = .{
            .start = tracked_start,
            .end = tracked_end,
        } },
        .rectangle = self.rectangle,
    };
}

/// Returns the top left point of the selection.
pub fn topLeft(self: Selection, s: *const Screen) Pin {
    return switch (self.order(s)) {
        .forward => self.start(),
        .reverse => self.end(),
        .mirrored_forward => pin: {
            var p = self.start();
            p.x = self.end().x;
            break :pin p;
        },
        .mirrored_reverse => pin: {
            var p = self.end();
            p.x = self.start().x;
            break :pin p;
        },
    };
}

/// Returns the bottom right point of the selection.
pub fn bottomRight(self: Selection, s: *const Screen) Pin {
    return switch (self.order(s)) {
        .forward => self.end(),
        .reverse => self.start(),
        .mirrored_forward => pin: {
            var p = self.end();
            p.x = self.start().x;
            break :pin p;
        },
        .mirrored_reverse => pin: {
            var p = self.start();
            p.x = self.end().x;
            break :pin p;
        },
    };
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
    const start_pt = s.pages.pointFromPin(.screen, self.start()).?.screen;
    const end_pt = s.pages.pointFromPin(.screen, self.end()).?.screen;

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

/// Returns the selection in the given order.
///
/// The returned selection is always a new untracked selection.
///
/// Note that only forward and reverse are useful desired orders for this
/// function. All other orders act as if forward order was desired.
pub fn ordered(self: Selection, s: *const Screen, desired: Order) Selection {
    if (self.order(s) == desired) return .init(
        self.start(),
        self.end(),
        self.rectangle,
    );

    const tl = self.topLeft(s);
    const br = self.bottomRight(s);
    return switch (desired) {
        .forward => .init(tl, br, self.rectangle),
        .reverse => .init(br, tl, self.rectangle),
        else => .init(tl, br, self.rectangle),
    };
}

/// Returns true if the selection contains the given point.
///
/// This recalculates top left and bottom right each call. If you have
/// many points to check, it is cheaper to do the containment logic
/// yourself and cache the topleft/bottomright.
pub fn contains(self: Selection, s: *const Screen, pin: Pin) bool {
    const tl_pin = self.topLeft(s);
    const br_pin = self.bottomRight(s);

    // This is definitely not very efficient. Low-hanging fruit to
    // improve this.
    const tl = s.pages.pointFromPin(.screen, tl_pin).?.screen;
    const br = s.pages.pointFromPin(.screen, br_pin).?.screen;
    const p = s.pages.pointFromPin(.screen, pin).?.screen;

    // If we're in rectangle select, we can short-circuit with an easy check
    // here
    if (self.rectangle)
        return p.y >= tl.y and p.y <= br.y and p.x >= tl.x and p.x <= br.x;

    // If tl/br are same line
    if (tl.y == br.y) return p.y == tl.y and
        p.x >= tl.x and
        p.x <= br.x;

    // If on top line, just has to be left of X
    if (p.y == tl.y) return p.x >= tl.x;

    // If on bottom line, just has to be right of X
    if (p.y == br.y) return p.x <= br.x;

    // If between the top/bottom, always good.
    return p.y > tl.y and p.y < br.y;
}

/// Get a selection for a single row in the screen. This will return null
/// if the row is not included in the selection.
pub fn containedRow(self: Selection, s: *const Screen, pin: Pin) ?Selection {
    const tl_pin = self.topLeft(s);
    const br_pin = self.bottomRight(s);

    // This is definitely not very efficient. Low-hanging fruit to
    // improve this.
    const tl = s.pages.pointFromPin(.screen, tl_pin).?.screen;
    const br = s.pages.pointFromPin(.screen, br_pin).?.screen;
    const p = s.pages.pointFromPin(.screen, pin).?.screen;

    if (p.y < tl.y or p.y > br.y) return null;

    // Rectangle case: we can return early as the x range will always be the
    // same. We've already validated that the row is in the selection.
    if (self.rectangle) return init(
        s.pages.pin(.{ .screen = .{ .y = p.y, .x = tl.x } }).?,
        s.pages.pin(.{ .screen = .{ .y = p.y, .x = br.x } }).?,
        true,
    );

    if (p.y == tl.y) {
        // If the selection is JUST this line, return it as-is.
        if (p.y == br.y) {
            return init(tl_pin, br_pin, false);
        }

        // Selection top-left line matches only.
        return init(
            tl_pin,
            s.pages.pin(.{ .screen = .{ .y = p.y, .x = s.pages.cols - 1 } }).?,
            false,
        );
    }

    // Row is our bottom selection, so we return the selection from the
    // beginning of the line to the br. We know our selection is more than
    // one line (due to conditionals above)
    if (p.y == br.y) {
        assert(p.y != tl.y);
        return init(
            s.pages.pin(.{ .screen = .{ .y = p.y, .x = 0 } }).?,
            br_pin,
            false,
        );
    }

    // Row is somewhere between our selection lines so we return the full line.
    return init(
        s.pages.pin(.{ .screen = .{ .y = p.y, .x = 0 } }).?,
        s.pages.pin(.{ .screen = .{ .y = p.y, .x = s.pages.cols - 1 } }).?,
        false,
    );
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
    beginning_of_line,
    end_of_line,
};

/// Adjust the selection by some given adjustment. An adjustment allows
/// a selection to be expanded slightly left, right, up, down, etc.
pub fn adjust(
    self: *Selection,
    s: *const Screen,
    adjustment: Adjustment,
) void {
    // Note that we always adjust "end" because end always represents
    // the last point of the selection by mouse, not necessarily the
    // top/bottom visually. So this results in the correct behavior
    // whether the user drags up or down.
    const end_pin = self.endPtr();
    switch (adjustment) {
        .up => if (end_pin.up(1)) |new_end| {
            end_pin.* = new_end;
        } else {
            self.adjust(s, .beginning_of_line);
        },

        .down => {
            // Find the next non-blank row
            var current = end_pin.*;
            while (current.down(1)) |next| : (current = next) {
                const rac = next.rowAndCell();
                const cells = next.node.data.getCells(rac.row);
                if (page.Cell.hasTextAny(cells)) {
                    end_pin.* = next;
                    break;
                }
            } else {
                // If we're at the bottom, just go to the end of the line
                self.adjust(s, .end_of_line);
            }
        },

        .left => {
            var it = end_pin.cellIterator(.left_up, null);
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
            var it = end_pin.cellIterator(.right_down, null);
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
                const cells = next.node.data.getCells(rac.row);
                if (page.Cell.hasTextAny(cells)) {
                    end_pin.* = next;
                    end_pin.x = @intCast(cells.len - 1);
                    break;
                }
            }
        },

        .beginning_of_line => end_pin.x = 0,

        .end_of_line => end_pin.x = end_pin.node.data.size.cols - 1,
    }
}

test "Selection: adjust right" {
    const testing = std.testing;
    var s = try Screen.init(testing.allocator, 10, 10, 0);
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
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 3,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
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
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 3,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
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
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 3,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}

test "Selection: adjust left" {
    const testing = std.testing;
    var s = try Screen.init(testing.allocator, 10, 10, 0);
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
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 3,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
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
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 2,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}

test "Selection: adjust left skips blanks" {
    const testing = std.testing;
    var s = try Screen.init(testing.allocator, 10, 10, 0);
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
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 3,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
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
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 2,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}

test "Selection: adjust up" {
    const testing = std.testing;
    var s = try Screen.init(testing.allocator, 10, 10, 0);
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
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 2,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
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
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}

test "Selection: adjust down" {
    const testing = std.testing;
    var s = try Screen.init(testing.allocator, 10, 10, 0);
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
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 4,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
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
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 9,
            .y = 4,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}

test "Selection: adjust down with not full screen" {
    const testing = std.testing;
    var s = try Screen.init(testing.allocator, 10, 10, 0);
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
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 9,
            .y = 2,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}

test "Selection: adjust home" {
    const testing = std.testing;
    var s = try Screen.init(testing.allocator, 10, 10, 0);
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
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}

test "Selection: adjust end with not full screen" {
    const testing = std.testing;
    var s = try Screen.init(testing.allocator, 10, 10, 0);
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
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 9,
            .y = 2,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}

test "Selection: adjust beginning of line" {
    const testing = std.testing;
    var s = try Screen.init(testing.allocator, 8, 10, 0);
    defer s.deinit();
    try s.testWriteString("A12 B34\nC12 D34");

    // Not at beginning of the line
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .beginning_of_line);

        // Start line
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 5,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    // Already at beginning of the line
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 1 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .beginning_of_line);

        // Start line
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 5,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    // End pin moves to start pin
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .beginning_of_line);

        // Start line
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}

test "Selection: adjust end of line" {
    const testing = std.testing;
    var s = try Screen.init(testing.allocator, 8, 10, 0);
    defer s.deinit();
    try s.testWriteString("A12 B34\nC12 D34");

    // Not at end of the line
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 0 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 0 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .end_of_line);

        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    // Already at end of the line
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 0 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 7, .y = 0 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .end_of_line);

        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    // End pin moves to start pin
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 7, .y = 0 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 0 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .end_of_line);

        // Start line
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
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

test "topLeft" {
    const testing = std.testing;

    var s = try Screen.init(testing.allocator, 10, 10, 0);
    defer s.deinit();
    {
        // forward
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            true,
        );
        defer sel.deinit(&s);
        const tl = sel.topLeft(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, tl));
    }
    {
        // reverse
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            true,
        );
        defer sel.deinit(&s);
        const tl = sel.topLeft(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, tl));
    }
    {
        // mirrored_forward
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 3 } }).?,
            true,
        );
        defer sel.deinit(&s);
        const tl = sel.topLeft(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, tl));
    }
    {
        // mirrored_reverse
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 3 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            true,
        );
        defer sel.deinit(&s);
        const tl = sel.topLeft(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, tl));
    }
}

test "bottomRight" {
    const testing = std.testing;

    var s = try Screen.init(testing.allocator, 10, 10, 0);
    defer s.deinit();
    {
        // forward
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            false,
        );
        defer sel.deinit(&s);
        const br = sel.bottomRight(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, br));
    }
    {
        // reverse
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            false,
        );
        defer sel.deinit(&s);
        const br = sel.bottomRight(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, br));
    }
    {
        // mirrored_forward
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 3 } }).?,
            true,
        );
        defer sel.deinit(&s);
        const br = sel.bottomRight(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 3,
        } }, s.pages.pointFromPin(.screen, br));
    }
    {
        // mirrored_reverse
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 3 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            true,
        );
        defer sel.deinit(&s);
        const br = sel.bottomRight(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 3,
        } }, s.pages.pointFromPin(.screen, br));
    }
}

test "ordered" {
    const testing = std.testing;

    var s = try Screen.init(testing.allocator, 10, 10, 0);
    defer s.deinit();
    {
        // forward
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            false,
        );
        const sel_reverse = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            false,
        );
        try testing.expect(sel.ordered(&s, .forward).eql(sel));
        try testing.expect(sel.ordered(&s, .reverse).eql(sel_reverse));
        try testing.expect(sel.ordered(&s, .mirrored_forward).eql(sel));
    }
    {
        // reverse
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            false,
        );
        const sel_forward = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            false,
        );
        try testing.expect(sel.ordered(&s, .forward).eql(sel_forward));
        try testing.expect(sel.ordered(&s, .reverse).eql(sel));
        try testing.expect(sel.ordered(&s, .mirrored_forward).eql(sel_forward));
    }
    {
        // mirrored_forward
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 3 } }).?,
            true,
        );
        const sel_forward = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 3 } }).?,
            true,
        );
        const sel_reverse = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 3 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            true,
        );
        try testing.expect(sel.ordered(&s, .forward).eql(sel_forward));
        try testing.expect(sel.ordered(&s, .reverse).eql(sel_reverse));
        try testing.expect(sel.ordered(&s, .mirrored_reverse).eql(sel_forward));
    }
    {
        // mirrored_reverse
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 3 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            true,
        );
        const sel_forward = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 3 } }).?,
            true,
        );
        const sel_reverse = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 3 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            true,
        );
        try testing.expect(sel.ordered(&s, .forward).eql(sel_forward));
        try testing.expect(sel.ordered(&s, .reverse).eql(sel_reverse));
        try testing.expect(sel.ordered(&s, .mirrored_forward).eql(sel_forward));
    }
}

test "Selection: contains" {
    const testing = std.testing;

    var s = try Screen.init(testing.allocator, 10, 10, 0);
    defer s.deinit();
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 2 } }).?,
            false,
        );

        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 6, .y = 1 } }).?));
        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 1, .y = 2 } }).?));
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?));
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 5, .y = 2 } }).?));
    }

    // Reverse
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 2 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            false,
        );

        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 6, .y = 1 } }).?));
        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 1, .y = 2 } }).?));
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?));
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 5, .y = 2 } }).?));
    }

    // Single line
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 8, .y = 1 } }).?,
            false,
        );

        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 6, .y = 1 } }).?));
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?));
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 9, .y = 1 } }).?));
    }
}

test "Selection: contains, rectangle" {
    const testing = std.testing;

    var s = try Screen.init(testing.allocator, 15, 15, 0);
    defer s.deinit();
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 3 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 7, .y = 9 } }).?,
            true,
        );

        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 5, .y = 6 } }).?)); // Center
        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 3, .y = 6 } }).?)); // Left border
        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 7, .y = 6 } }).?)); // Right border
        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 5, .y = 3 } }).?)); // Top border
        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 5, .y = 9 } }).?)); // Bottom border

        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 5, .y = 2 } }).?)); // Above center
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 5, .y = 10 } }).?)); // Below center
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 2, .y = 6 } }).?)); // Left center
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 8, .y = 6 } }).?)); // Right center
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 8, .y = 3 } }).?)); // Just right of top right
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 2, .y = 9 } }).?)); // Just left of bottom left
    }

    // Reverse
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 7, .y = 9 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 3 } }).?,
            true,
        );

        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 5, .y = 6 } }).?)); // Center
        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 3, .y = 6 } }).?)); // Left border
        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 7, .y = 6 } }).?)); // Right border
        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 5, .y = 3 } }).?)); // Top border
        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 5, .y = 9 } }).?)); // Bottom border

        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 5, .y = 2 } }).?)); // Above center
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 5, .y = 10 } }).?)); // Below center
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 2, .y = 6 } }).?)); // Left center
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 8, .y = 6 } }).?)); // Right center
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 8, .y = 3 } }).?)); // Just right of top right
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 2, .y = 9 } }).?)); // Just left of bottom left
    }

    // Single line
    // NOTE: This is the same as normal selection but we just do it for brevity
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 10, .y = 1 } }).?,
            true,
        );

        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 6, .y = 1 } }).?));
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?));
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 12, .y = 1 } }).?));
    }
}

test "Selection: containedRow" {
    const testing = std.testing;
    var s = try Screen.init(testing.allocator, 10, 5, 0);
    defer s.deinit();

    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 3 } }).?,
            false,
        );

        // Not contained
        try testing.expect(sel.containedRow(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 4 } }).?,
        ) == null);

        // Start line
        try testing.expectEqual(Selection.init(
            sel.start(),
            s.pages.pin(.{ .screen = .{ .x = s.pages.cols - 1, .y = 1 } }).?,
            false,
        ), sel.containedRow(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
        ).?);

        // End line
        try testing.expectEqual(Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 3 } }).?,
            sel.end(),
            false,
        ), sel.containedRow(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 3 } }).?,
        ).?);

        // Middle line
        try testing.expectEqual(Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 2 } }).?,
            s.pages.pin(.{ .screen = .{ .x = s.pages.cols - 1, .y = 2 } }).?,
            false,
        ), sel.containedRow(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 2 } }).?,
        ).?);
    }

    // Rectangle
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 6, .y = 3 } }).?,
            true,
        );

        // Not contained
        try testing.expect(sel.containedRow(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 4 } }).?,
        ) == null);

        // Start line
        try testing.expectEqual(Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 6, .y = 1 } }).?,
            true,
        ), sel.containedRow(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
        ).?);

        // End line
        try testing.expectEqual(Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 3 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 6, .y = 3 } }).?,
            true,
        ), sel.containedRow(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 3 } }).?,
        ).?);

        // Middle line
        try testing.expectEqual(Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 2 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 6, .y = 2 } }).?,
            true,
        ), sel.containedRow(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 2 } }).?,
        ).?);
    }

    // Single-line selection
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 6, .y = 1 } }).?,
            false,
        );

        // Not contained
        try testing.expect(sel.containedRow(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 0 } }).?,
        ) == null);
        try testing.expect(sel.containedRow(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 2 } }).?,
        ) == null);

        // Contained
        try testing.expectEqual(sel, sel.containedRow(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
        ).?);
    }
}
