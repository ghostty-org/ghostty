/// Represents a single selection within the terminal
/// (i.e. a highlight region).
const Selection = @This();

const std = @import("std");
const assert = std.debug.assert;
const point = @import("point.zig");
const Screen = @import("Screen.zig");
const ScreenPoint = point.ScreenPoint;

/// Start and end of the selection. There is no guarantee that
/// start is before end or vice versa. If a user selects backwards,
/// start will be after end, and vice versa. Use the struct functions
/// to not have to worry about this.
start: ScreenPoint,
end: ScreenPoint,

/// Whether or not this selection refers to a rectangle, rather than whole
/// lines of a buffer. In this mode, start and end refer to the top left and
/// bottom right of the rectangle, or vice versa if the selection is backwards.
rectangle: bool = false,

/// Converts a selection screen points to viewport points (still typed
/// as ScreenPoints) if the selection is present within the viewport
/// of the screen.
pub fn toViewport(self: Selection, screen: *const Screen) ?Selection {
    const top = (point.Viewport{ .x = 0, .y = 0 }).toScreen(screen);
    const bot = (point.Viewport{ .x = screen.cols - 1, .y = screen.rows - 1 }).toScreen(screen);

    // If our selection isn't within the viewport, do nothing.
    if (!self.within(top, bot)) return null;

    // Convert
    const start = self.start.toViewport(screen);
    const end = self.end.toViewport(screen);
    return Selection{
        .start = .{ .x = if (self.rectangle) self.start.x else start.x, .y = start.y },
        .end = .{ .x = if (self.rectangle) self.end.x else end.x, .y = end.y },
        .rectangle = self.rectangle,
    };
}

/// Returns true if the selection is empty.
pub fn empty(self: Selection) bool {
    return self.start.x == self.end.x and self.start.y == self.end.y;
}

/// Returns true if the selection contains the given point.
///
/// This recalculates top left and bottom right each call. If you have
/// many points to check, it is cheaper to do the containment logic
/// yourself and cache the topleft/bottomright.
pub fn contains(self: Selection, p: ScreenPoint) bool {
    const tl = self.topLeft();
    const br = self.bottomRight();

    // Honestly there is probably way more efficient boolean logic here.
    // Look back at this in the future...

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

/// Returns true if the selection contains any of the points between
/// (and including) the start and end. The x values are ignored this is
/// just a section match
pub fn within(self: Selection, start: ScreenPoint, end: ScreenPoint) bool {
    const tl = self.topLeft();
    const br = self.bottomRight();

    // Bottom right is before start, no way we are in it.
    if (br.y < start.y) return false;
    // Bottom right is the first line, only if our x is in it.
    if (br.y == start.y) return br.x >= start.x;

    // If top left is beyond the end, we're not in it.
    if (tl.y > end.y) return false;
    // If top left is on the end, only if our x is in it.
    if (tl.y == end.y) return tl.x <= end.x;

    return true;
}

/// Returns true if the selection contains the row of the given point,
/// regardless of the x value.
pub fn containsRow(self: Selection, p: ScreenPoint) bool {
    const tl = self.topLeft();
    const br = self.bottomRight();
    return p.y >= tl.y and p.y <= br.y;
}

/// Get a selection for a single row in the screen. This will return null
/// if the row is not included in the selection.
pub fn containedRow(self: Selection, screen: *const Screen, p: ScreenPoint) ?Selection {
    const tl = self.topLeft();
    const br = self.bottomRight();
    if (p.y < tl.y or p.y > br.y) return null;

    // Rectangle case: we can return early as the x range will always be the
    // same. We've already validated that the row is in the selection.
    if (self.rectangle) return .{
        .start = .{ .y = p.y, .x = tl.x },
        .end = .{ .y = p.y, .x = br.x },
        .rectangle = true,
    };

    if (p.y == tl.y) {
        // If the selection is JUST this line, return it as-is.
        if (p.y == br.y) {
            return self;
        }

        // Selection top-left line matches only.
        return .{
            .start = tl,
            .end = .{ .y = tl.y, .x = screen.cols - 1 },
        };
    }

    // Row is our bottom selection, so we return the selection from the
    // beginning of the line to the br. We know our selection is more than
    // one line (due to conditionals above)
    if (p.y == br.y) {
        assert(p.y != tl.y);
        return .{
            .start = .{ .y = br.y, .x = 0 },
            .end = br,
        };
    }

    // Row is somewhere between our selection lines so we return the full line.
    return .{
        .start = .{ .y = p.y, .x = 0 },
        .end = .{ .y = p.y, .x = screen.cols - 1 },
    };
}

/// Returns the top left point of the selection.
pub fn topLeft(self: Selection) ScreenPoint {
    return switch (self.order()) {
        .forward => self.start,
        .reverse => self.end,
        .mirrored_forward => .{ .x = self.end.x, .y = self.start.y },
        .mirrored_reverse => .{ .x = self.start.x, .y = self.end.y },
    };
}

/// Returns the bottom right point of the selection.
pub fn bottomRight(self: Selection) ScreenPoint {
    return switch (self.order()) {
        .forward => self.end,
        .reverse => self.start,
        .mirrored_forward => .{ .x = self.start.x, .y = self.end.y },
        .mirrored_reverse => .{ .x = self.end.x, .y = self.start.y },
    };
}

/// Returns the selection in the given order.
///
/// Note that only forward and reverse are useful desired orders for this
/// function. All other orders act as if forward order was desired.
pub fn ordered(self: Selection, desired: Order) Selection {
    if (self.order() == desired) return self;
    const tl = self.topLeft();
    const br = self.bottomRight();
    return switch (desired) {
        .forward => .{ .start = tl, .end = br, .rectangle = self.rectangle },
        .reverse => .{ .start = br, .end = tl, .rectangle = self.rectangle },
        else => .{ .start = tl, .end = br, .rectangle = self.rectangle },
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

pub fn order(self: Selection) Order {
    if (self.rectangle) {
        // Reverse (also handles single-column)
        if (self.start.y > self.end.y and self.start.x >= self.end.x) return .reverse;
        if (self.start.y >= self.end.y and self.start.x > self.end.x) return .reverse;

        // Mirror, bottom-left to top-right
        if (self.start.y > self.end.y and self.start.x < self.end.x) return .mirrored_reverse;

        // Mirror, top-right to bottom-left
        if (self.start.y < self.end.y and self.start.x > self.end.x) return .mirrored_forward;

        // Forward
        return .forward;
    }

    if (self.start.y < self.end.y) return .forward;
    if (self.start.y > self.end.y) return .reverse;
    if (self.start.x <= self.end.x) return .forward;
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
pub fn adjust(self: Selection, screen: *Screen, adjustment: Adjustment) Selection {
    const screen_end = Screen.RowIndexTag.screen.maxLen(screen) - 1;

    // Make an editable one because its so much easier to use modification
    // logic below than it is to reconstruct the selection every time.
    var result = self;

    // Note that we always adjusts "end" because end always represents
    // the last point of the selection by mouse, not necessarilly the
    // top/bottom visually. So this results in the right behavior
    // whether the user drags up or down.
    switch (adjustment) {
        .up => if (result.end.y == 0) {
            result.end.x = 0;
        } else {
            result.end.y -= 1;
        },

        .down => if (result.end.y >= screen_end) {
            result.end.y = screen_end;
            result.end.x = screen.cols - 1;
        } else {
            result.end.y += 1;
        },

        .left => {
            // Step left, wrapping to the next row up at the start of each new line,
            // until we find a non-empty cell.
            //
            // This iterator emits the start point first, throw it out.
            var iterator = result.end.iterator(screen, .left_up);
            _ = iterator.next();
            while (iterator.next()) |next| {
                if (screen.getCell(
                    .screen,
                    next.y,
                    next.x,
                ).char != 0) {
                    result.end = next;
                    break;
                }
            }
        },

        .right => {
            // Step right, wrapping to the next row down at the start of each new line,
            // until we find a non-empty cell.
            var iterator = result.end.iterator(screen, .right_down);
            _ = iterator.next();
            while (iterator.next()) |next| {
                if (next.y > screen_end) break;
                if (screen.getCell(
                    .screen,
                    next.y,
                    next.x,
                ).char != 0) {
                    if (next.y > screen_end) {
                        result.end.y = screen_end;
                    } else {
                        result.end = next;
                    }
                    break;
                }
            }
        },

        .page_up => if (screen.rows > result.end.y) {
            result.end.y = 0;
            result.end.x = 0;
        } else {
            result.end.y -= screen.rows;
        },

        .page_down => if (screen.rows > screen_end - result.end.y) {
            result.end.y = screen_end;
            result.end.x = screen.cols - 1;
        } else {
            result.end.y += screen.rows;
        },

        .home => {
            result.end.y = 0;
            result.end.x = 0;
        },

        .end => {
            result.end.y = screen_end;
            result.end.x = screen.cols - 1;
        },
    }

    return result;
}

// X
test "Selection: adjust right" {
    const testing = std.testing;
    var screen = try Screen.init(testing.allocator, 5, 10, 0);
    defer screen.deinit();
    try screen.testWriteString("A1234\nB5678\nC1234\nD5678");

    // Simple movement right
    {
        const sel = (Selection{
            .start = .{ .x = 5, .y = 1 },
            .end = .{ .x = 3, .y = 3 },
        }).adjust(&screen, .right);

        try testing.expectEqual(Selection{
            .start = .{ .x = 5, .y = 1 },
            .end = .{ .x = 4, .y = 3 },
        }, sel);
    }

    // Already at end of the line.
    {
        const sel = (Selection{
            .start = .{ .x = 5, .y = 1 },
            .end = .{ .x = 4, .y = 2 },
        }).adjust(&screen, .right);

        try testing.expectEqual(Selection{
            .start = .{ .x = 5, .y = 1 },
            .end = .{ .x = 0, .y = 3 },
        }, sel);
    }

    // Already at end of the screen
    {
        const sel = (Selection{
            .start = .{ .x = 5, .y = 1 },
            .end = .{ .x = 4, .y = 3 },
        }).adjust(&screen, .right);

        try testing.expectEqual(Selection{
            .start = .{ .x = 5, .y = 1 },
            .end = .{ .x = 4, .y = 3 },
        }, sel);
    }
}

// X
test "Selection: adjust left" {
    const testing = std.testing;
    var screen = try Screen.init(testing.allocator, 5, 10, 0);
    defer screen.deinit();
    try screen.testWriteString("A1234\nB5678\nC1234\nD5678");

    // Simple movement left
    {
        const sel = (Selection{
            .start = .{ .x = 5, .y = 1 },
            .end = .{ .x = 3, .y = 3 },
        }).adjust(&screen, .left);

        // Start line
        try testing.expectEqual(Selection{
            .start = .{ .x = 5, .y = 1 },
            .end = .{ .x = 2, .y = 3 },
        }, sel);
    }

    // Already at beginning of the line.
    {
        const sel = (Selection{
            .start = .{ .x = 5, .y = 1 },
            .end = .{ .x = 0, .y = 3 },
        }).adjust(&screen, .left);

        // Start line
        try testing.expectEqual(Selection{
            .start = .{ .x = 5, .y = 1 },
            .end = .{ .x = 4, .y = 2 },
        }, sel);
    }
}

// X
test "Selection: adjust left skips blanks" {
    const testing = std.testing;
    var screen = try Screen.init(testing.allocator, 5, 10, 0);
    defer screen.deinit();
    try screen.testWriteString("A1234\nB5678\nC12\nD56");

    // Same line
    {
        const sel = (Selection{
            .start = .{ .x = 5, .y = 1 },
            .end = .{ .x = 4, .y = 3 },
        }).adjust(&screen, .left);

        // Start line
        try testing.expectEqual(Selection{
            .start = .{ .x = 5, .y = 1 },
            .end = .{ .x = 2, .y = 3 },
        }, sel);
    }

    // Edge
    {
        const sel = (Selection{
            .start = .{ .x = 5, .y = 1 },
            .end = .{ .x = 0, .y = 3 },
        }).adjust(&screen, .left);

        // Start line
        try testing.expectEqual(Selection{
            .start = .{ .x = 5, .y = 1 },
            .end = .{ .x = 2, .y = 2 },
        }, sel);
    }
}

// X
test "Selection: adjust up" {
    const testing = std.testing;
    var screen = try Screen.init(testing.allocator, 5, 10, 0);
    defer screen.deinit();
    try screen.testWriteString("A\nB\nC\nD\nE");

    // Not on the first line
    {
        const sel = (Selection{
            .start = .{ .x = 5, .y = 1 },
            .end = .{ .x = 3, .y = 3 },
        }).adjust(&screen, .up);

        // Start line
        try testing.expectEqual(Selection{
            .start = .{ .x = 5, .y = 1 },
            .end = .{ .x = 3, .y = 2 },
        }, sel);
    }

    // On the first line
    {
        const sel = (Selection{
            .start = .{ .x = 5, .y = 1 },
            .end = .{ .x = 3, .y = 0 },
        }).adjust(&screen, .up);

        // Start line
        try testing.expectEqual(Selection{
            .start = .{ .x = 5, .y = 1 },
            .end = .{ .x = 0, .y = 0 },
        }, sel);
    }
}

// X
test "Selection: adjust down" {
    const testing = std.testing;
    var screen = try Screen.init(testing.allocator, 5, 10, 0);
    defer screen.deinit();
    try screen.testWriteString("A\nB\nC\nD\nE");

    // Not on the first line
    {
        const sel = (Selection{
            .start = .{ .x = 5, .y = 1 },
            .end = .{ .x = 3, .y = 3 },
        }).adjust(&screen, .down);

        // Start line
        try testing.expectEqual(Selection{
            .start = .{ .x = 5, .y = 1 },
            .end = .{ .x = 3, .y = 4 },
        }, sel);
    }

    // On the last line
    {
        const sel = (Selection{
            .start = .{ .x = 5, .y = 1 },
            .end = .{ .x = 3, .y = 4 },
        }).adjust(&screen, .down);

        // Start line
        try testing.expectEqual(Selection{
            .start = .{ .x = 5, .y = 1 },
            .end = .{ .x = 9, .y = 4 },
        }, sel);
    }
}

// X
test "Selection: adjust down with not full screen" {
    const testing = std.testing;
    var screen = try Screen.init(testing.allocator, 5, 10, 0);
    defer screen.deinit();
    try screen.testWriteString("A\nB\nC");

    // On the last line
    {
        const sel = (Selection{
            .start = .{ .x = 5, .y = 1 },
            .end = .{ .x = 3, .y = 2 },
        }).adjust(&screen, .down);

        // Start line
        try testing.expectEqual(Selection{
            .start = .{ .x = 5, .y = 1 },
            .end = .{ .x = 9, .y = 2 },
        }, sel);
    }
}

test "Selection: contains" {
    const testing = std.testing;
    {
        const sel: Selection = .{
            .start = .{ .x = 5, .y = 1 },
            .end = .{ .x = 3, .y = 2 },
        };

        try testing.expect(sel.contains(.{ .x = 6, .y = 1 }));
        try testing.expect(sel.contains(.{ .x = 1, .y = 2 }));
        try testing.expect(!sel.contains(.{ .x = 1, .y = 1 }));
        try testing.expect(!sel.contains(.{ .x = 5, .y = 2 }));
        try testing.expect(!sel.containsRow(.{ .x = 1, .y = 3 }));
        try testing.expect(sel.containsRow(.{ .x = 1, .y = 1 }));
        try testing.expect(sel.containsRow(.{ .x = 5, .y = 2 }));
    }

    // Reverse
    {
        const sel: Selection = .{
            .start = .{ .x = 3, .y = 2 },
            .end = .{ .x = 5, .y = 1 },
        };

        try testing.expect(sel.contains(.{ .x = 6, .y = 1 }));
        try testing.expect(sel.contains(.{ .x = 1, .y = 2 }));
        try testing.expect(!sel.contains(.{ .x = 1, .y = 1 }));
        try testing.expect(!sel.contains(.{ .x = 5, .y = 2 }));
    }

    // Single line
    {
        const sel: Selection = .{
            .start = .{ .x = 5, .y = 1 },
            .end = .{ .x = 10, .y = 1 },
        };

        try testing.expect(sel.contains(.{ .x = 6, .y = 1 }));
        try testing.expect(!sel.contains(.{ .x = 2, .y = 1 }));
        try testing.expect(!sel.contains(.{ .x = 12, .y = 1 }));
    }
}

test "Selection: contains, rectangle" {
    const testing = std.testing;
    {
        const sel: Selection = .{
            .start = .{ .x = 3, .y = 3 },
            .end = .{ .x = 7, .y = 9 },
            .rectangle = true,
        };

        try testing.expect(sel.contains(.{ .x = 5, .y = 6 })); // Center
        try testing.expect(sel.contains(.{ .x = 3, .y = 6 })); // Left border
        try testing.expect(sel.contains(.{ .x = 7, .y = 6 })); // Right border
        try testing.expect(sel.contains(.{ .x = 5, .y = 3 })); // Top border
        try testing.expect(sel.contains(.{ .x = 5, .y = 9 })); // Bottom border

        try testing.expect(!sel.contains(.{ .x = 5, .y = 2 })); // Above center
        try testing.expect(!sel.contains(.{ .x = 5, .y = 10 })); // Below center
        try testing.expect(!sel.contains(.{ .x = 2, .y = 6 })); // Left center
        try testing.expect(!sel.contains(.{ .x = 8, .y = 6 })); // Right center
        try testing.expect(!sel.contains(.{ .x = 8, .y = 3 })); // Just right of top right
        try testing.expect(!sel.contains(.{ .x = 2, .y = 9 })); // Just left of bottom left

        try testing.expect(!sel.containsRow(.{ .x = 1, .y = 1 }));
        try testing.expect(sel.containsRow(.{ .x = 1, .y = 3 })); // x does not matter
        try testing.expect(sel.containsRow(.{ .x = 1, .y = 6 }));
        try testing.expect(sel.containsRow(.{ .x = 5, .y = 9 }));
        try testing.expect(!sel.containsRow(.{ .x = 5, .y = 10 }));
    }

    // Reverse
    {
        const sel: Selection = .{
            .start = .{ .x = 7, .y = 9 },
            .end = .{ .x = 3, .y = 3 },
            .rectangle = true,
        };

        try testing.expect(sel.contains(.{ .x = 5, .y = 6 })); // Center
        try testing.expect(sel.contains(.{ .x = 3, .y = 6 })); // Left border
        try testing.expect(sel.contains(.{ .x = 7, .y = 6 })); // Right border
        try testing.expect(sel.contains(.{ .x = 5, .y = 3 })); // Top border
        try testing.expect(sel.contains(.{ .x = 5, .y = 9 })); // Bottom border

        try testing.expect(!sel.contains(.{ .x = 5, .y = 2 })); // Above center
        try testing.expect(!sel.contains(.{ .x = 5, .y = 10 })); // Below center
        try testing.expect(!sel.contains(.{ .x = 2, .y = 6 })); // Left center
        try testing.expect(!sel.contains(.{ .x = 8, .y = 6 })); // Right center
        try testing.expect(!sel.contains(.{ .x = 8, .y = 3 })); // Just right of top right
        try testing.expect(!sel.contains(.{ .x = 2, .y = 9 })); // Just left of bottom left

        try testing.expect(!sel.containsRow(.{ .x = 1, .y = 1 }));
        try testing.expect(sel.containsRow(.{ .x = 1, .y = 3 })); // x does not matter
        try testing.expect(sel.containsRow(.{ .x = 1, .y = 6 }));
        try testing.expect(sel.containsRow(.{ .x = 5, .y = 9 }));
        try testing.expect(!sel.containsRow(.{ .x = 5, .y = 10 }));
    }

    // Single line
    // NOTE: This is the same as normal selection but we just do it for brevity
    {
        const sel: Selection = .{
            .start = .{ .x = 5, .y = 1 },
            .end = .{ .x = 10, .y = 1 },
            .rectangle = true,
        };

        try testing.expect(sel.contains(.{ .x = 6, .y = 1 }));
        try testing.expect(!sel.contains(.{ .x = 2, .y = 1 }));
        try testing.expect(!sel.contains(.{ .x = 12, .y = 1 }));
    }
}

test "Selection: containedRow" {
    const testing = std.testing;
    var screen = try Screen.init(testing.allocator, 5, 10, 0);
    defer screen.deinit();

    {
        const sel: Selection = .{
            .start = .{ .x = 5, .y = 1 },
            .end = .{ .x = 3, .y = 3 },
        };

        // Not contained
        try testing.expect(sel.containedRow(&screen, .{ .x = 1, .y = 4 }) == null);

        // Start line
        try testing.expectEqual(Selection{
            .start = sel.start,
            .end = .{ .x = screen.cols - 1, .y = 1 },
        }, sel.containedRow(&screen, .{ .x = 1, .y = 1 }).?);

        // End line
        try testing.expectEqual(Selection{
            .start = .{ .x = 0, .y = 3 },
            .end = sel.end,
        }, sel.containedRow(&screen, .{ .x = 2, .y = 3 }).?);

        // Middle line
        try testing.expectEqual(Selection{
            .start = .{ .x = 0, .y = 2 },
            .end = .{ .x = screen.cols - 1, .y = 2 },
        }, sel.containedRow(&screen, .{ .x = 2, .y = 2 }).?);
    }

    // Rectangle
    {
        const sel: Selection = .{
            .start = .{ .x = 3, .y = 1 },
            .end = .{ .x = 6, .y = 3 },
            .rectangle = true,
        };

        // Not contained
        try testing.expect(sel.containedRow(&screen, .{ .x = 1, .y = 4 }) == null);

        // Start line
        try testing.expectEqual(Selection{
            .start = .{ .x = 3, .y = 1 },
            .end = .{ .x = 6, .y = 1 },
            .rectangle = true,
        }, sel.containedRow(&screen, .{ .x = 1, .y = 1 }).?);

        // End line
        try testing.expectEqual(Selection{
            .start = .{ .x = 3, .y = 3 },
            .end = .{ .x = 6, .y = 3 },
            .rectangle = true,
        }, sel.containedRow(&screen, .{ .x = 2, .y = 3 }).?);

        // Middle line
        try testing.expectEqual(Selection{
            .start = .{ .x = 3, .y = 2 },
            .end = .{ .x = 6, .y = 2 },
            .rectangle = true,
        }, sel.containedRow(&screen, .{ .x = 2, .y = 2 }).?);
    }

    // Single-line selection
    {
        const sel: Selection = .{
            .start = .{ .x = 2, .y = 1 },
            .end = .{ .x = 6, .y = 1 },
        };

        // Not contained
        try testing.expect(sel.containedRow(&screen, .{ .x = 1, .y = 0 }) == null);
        try testing.expect(sel.containedRow(&screen, .{ .x = 1, .y = 2 }) == null);

        // Contained
        try testing.expectEqual(Selection{
            .start = sel.start,
            .end = sel.end,
        }, sel.containedRow(&screen, .{ .x = 1, .y = 1 }).?);
    }
}

test "Selection: within" {
    const testing = std.testing;
    {
        const sel: Selection = .{
            .start = .{ .x = 5, .y = 1 },
            .end = .{ .x = 3, .y = 2 },
        };

        // Fully within
        try testing.expect(sel.within(.{ .x = 6, .y = 0 }, .{ .x = 6, .y = 3 }));
        try testing.expect(sel.within(.{ .x = 3, .y = 1 }, .{ .x = 6, .y = 3 }));
        try testing.expect(sel.within(.{ .x = 3, .y = 0 }, .{ .x = 6, .y = 2 }));

        // Partially within
        try testing.expect(sel.within(.{ .x = 1, .y = 2 }, .{ .x = 6, .y = 3 }));
        try testing.expect(sel.within(.{ .x = 1, .y = 0 }, .{ .x = 6, .y = 1 }));

        // Not within at all
        try testing.expect(!sel.within(.{ .x = 0, .y = 0 }, .{ .x = 4, .y = 1 }));
    }
}

// X
test "Selection: order, standard" {
    const testing = std.testing;
    {
        // forward, multi-line
        const sel: Selection = .{
            .start = .{ .x = 2, .y = 1 },
            .end = .{ .x = 2, .y = 2 },
        };

        try testing.expect(sel.order() == .forward);
    }
    {
        // reverse, multi-line
        const sel: Selection = .{
            .start = .{ .x = 2, .y = 2 },
            .end = .{ .x = 2, .y = 1 },
        };

        try testing.expect(sel.order() == .reverse);
    }
    {
        // forward, same-line
        const sel: Selection = .{
            .start = .{ .x = 2, .y = 1 },
            .end = .{ .x = 3, .y = 1 },
        };

        try testing.expect(sel.order() == .forward);
    }
    {
        // forward, single char
        const sel: Selection = .{
            .start = .{ .x = 2, .y = 1 },
            .end = .{ .x = 2, .y = 1 },
        };

        try testing.expect(sel.order() == .forward);
    }
    {
        // reverse, single line
        const sel: Selection = .{
            .start = .{ .x = 2, .y = 1 },
            .end = .{ .x = 1, .y = 1 },
        };

        try testing.expect(sel.order() == .reverse);
    }
}

// X
test "Selection: order, rectangle" {
    const testing = std.testing;
    // Conventions:
    // TL - top left
    // BL - bottom left
    // TR - top right
    // BR - bottom right
    {
        // forward (TL -> BR)
        const sel: Selection = .{
            .start = .{ .x = 1, .y = 1 },
            .end = .{ .x = 2, .y = 2 },
            .rectangle = true,
        };

        try testing.expect(sel.order() == .forward);
    }
    {
        // reverse (BR -> TL)
        const sel: Selection = .{
            .start = .{ .x = 2, .y = 2 },
            .end = .{ .x = 1, .y = 1 },
            .rectangle = true,
        };

        try testing.expect(sel.order() == .reverse);
    }
    {
        // mirrored_forward (TR -> BL)
        const sel: Selection = .{
            .start = .{ .x = 3, .y = 1 },
            .end = .{ .x = 1, .y = 3 },
            .rectangle = true,
        };

        try testing.expect(sel.order() == .mirrored_forward);
    }
    {
        // mirrored_reverse (BL -> TR)
        const sel: Selection = .{
            .start = .{ .x = 1, .y = 3 },
            .end = .{ .x = 3, .y = 1 },
            .rectangle = true,
        };

        try testing.expect(sel.order() == .mirrored_reverse);
    }
    {
        // forward, single line (left -> right )
        const sel: Selection = .{
            .start = .{ .x = 1, .y = 1 },
            .end = .{ .x = 3, .y = 1 },
            .rectangle = true,
        };

        try testing.expect(sel.order() == .forward);
    }
    {
        // reverse, single line (right -> left)
        const sel: Selection = .{
            .start = .{ .x = 3, .y = 1 },
            .end = .{ .x = 1, .y = 1 },
            .rectangle = true,
        };

        try testing.expect(sel.order() == .reverse);
    }
    {
        // forward, single column (top -> bottom)
        const sel: Selection = .{
            .start = .{ .x = 2, .y = 1 },
            .end = .{ .x = 2, .y = 3 },
            .rectangle = true,
        };

        try testing.expect(sel.order() == .forward);
    }
    {
        // reverse, single column (bottom -> top)
        const sel: Selection = .{
            .start = .{ .x = 2, .y = 3 },
            .end = .{ .x = 2, .y = 1 },
            .rectangle = true,
        };

        try testing.expect(sel.order() == .reverse);
    }
    {
        // forward, single cell
        const sel: Selection = .{
            .start = .{ .x = 1, .y = 1 },
            .end = .{ .x = 1, .y = 1 },
            .rectangle = true,
        };

        try testing.expect(sel.order() == .forward);
    }
}

test "topLeft" {
    const testing = std.testing;
    {
        // forward
        const sel: Selection = .{
            .start = .{ .x = 1, .y = 1 },
            .end = .{ .x = 3, .y = 1 },
        };
        const expected: ScreenPoint = .{ .x = 1, .y = 1 };
        try testing.expectEqual(sel.topLeft(), expected);
    }
    {
        // reverse
        const sel: Selection = .{
            .start = .{ .x = 3, .y = 1 },
            .end = .{ .x = 1, .y = 1 },
        };
        const expected: ScreenPoint = .{ .x = 1, .y = 1 };
        try testing.expectEqual(sel.topLeft(), expected);
    }
    {
        // mirrored_forward
        const sel: Selection = .{
            .start = .{ .x = 3, .y = 1 },
            .end = .{ .x = 1, .y = 3 },
            .rectangle = true,
        };
        const expected: ScreenPoint = .{ .x = 1, .y = 1 };
        try testing.expectEqual(sel.topLeft(), expected);
    }
    {
        // mirrored_reverse
        const sel: Selection = .{
            .start = .{ .x = 1, .y = 3 },
            .end = .{ .x = 3, .y = 1 },
            .rectangle = true,
        };
        const expected: ScreenPoint = .{ .x = 1, .y = 1 };
        try testing.expectEqual(sel.topLeft(), expected);
    }
}

test "bottomRight" {
    const testing = std.testing;
    {
        // forward
        const sel: Selection = .{
            .start = .{ .x = 1, .y = 1 },
            .end = .{ .x = 3, .y = 1 },
        };
        const expected: ScreenPoint = .{ .x = 3, .y = 1 };
        try testing.expectEqual(sel.bottomRight(), expected);
    }
    {
        // reverse
        const sel: Selection = .{
            .start = .{ .x = 3, .y = 1 },
            .end = .{ .x = 1, .y = 1 },
        };
        const expected: ScreenPoint = .{ .x = 3, .y = 1 };
        try testing.expectEqual(sel.bottomRight(), expected);
    }
    {
        // mirrored_forward
        const sel: Selection = .{
            .start = .{ .x = 3, .y = 1 },
            .end = .{ .x = 1, .y = 3 },
            .rectangle = true,
        };
        const expected: ScreenPoint = .{ .x = 3, .y = 3 };
        try testing.expectEqual(sel.bottomRight(), expected);
    }
    {
        // mirrored_reverse
        const sel: Selection = .{
            .start = .{ .x = 1, .y = 3 },
            .end = .{ .x = 3, .y = 1 },
            .rectangle = true,
        };
        const expected: ScreenPoint = .{ .x = 3, .y = 3 };
        try testing.expectEqual(sel.bottomRight(), expected);
    }
}

test "ordered" {
    const testing = std.testing;
    {
        // forward
        const sel: Selection = .{
            .start = .{ .x = 1, .y = 1 },
            .end = .{ .x = 3, .y = 1 },
        };
        const sel_reverse: Selection = .{
            .start = .{ .x = 3, .y = 1 },
            .end = .{ .x = 1, .y = 1 },
        };
        try testing.expectEqual(sel.ordered(.forward), sel);
        try testing.expectEqual(sel.ordered(.reverse), sel_reverse);
        try testing.expectEqual(sel.ordered(.mirrored_reverse), sel);
    }
    {
        // reverse
        const sel: Selection = .{
            .start = .{ .x = 3, .y = 1 },
            .end = .{ .x = 1, .y = 1 },
        };
        const sel_forward: Selection = .{
            .start = .{ .x = 1, .y = 1 },
            .end = .{ .x = 3, .y = 1 },
        };
        try testing.expectEqual(sel.ordered(.forward), sel_forward);
        try testing.expectEqual(sel.ordered(.reverse), sel);
        try testing.expectEqual(sel.ordered(.mirrored_forward), sel_forward);
    }
    {
        // mirrored_forward
        const sel: Selection = .{
            .start = .{ .x = 3, .y = 1 },
            .end = .{ .x = 1, .y = 3 },
            .rectangle = true,
        };
        const sel_forward: Selection = .{
            .start = .{ .x = 1, .y = 1 },
            .end = .{ .x = 3, .y = 3 },
            .rectangle = true,
        };
        const sel_reverse: Selection = .{
            .start = .{ .x = 3, .y = 3 },
            .end = .{ .x = 1, .y = 1 },
            .rectangle = true,
        };
        try testing.expectEqual(sel.ordered(.forward), sel_forward);
        try testing.expectEqual(sel.ordered(.reverse), sel_reverse);
        try testing.expectEqual(sel.ordered(.mirrored_reverse), sel_forward);
    }
    {
        // mirrored_reverse
        const sel: Selection = .{
            .start = .{ .x = 1, .y = 3 },
            .end = .{ .x = 3, .y = 1 },
            .rectangle = true,
        };
        const sel_forward: Selection = .{
            .start = .{ .x = 1, .y = 1 },
            .end = .{ .x = 3, .y = 3 },
            .rectangle = true,
        };
        const sel_reverse: Selection = .{
            .start = .{ .x = 3, .y = 3 },
            .end = .{ .x = 1, .y = 1 },
            .rectangle = true,
        };
        try testing.expectEqual(sel.ordered(.forward), sel_forward);
        try testing.expectEqual(sel.ordered(.reverse), sel_reverse);
        try testing.expectEqual(sel.ordered(.mirrored_forward), sel_forward);
    }
}

test "toViewport" {
    const testing = std.testing;
    var screen = try Screen.init(testing.allocator, 24, 80, 0);
    defer screen.deinit();
    screen.viewport = 11; // Scroll us down a bit
    {
        // Not in viewport (null)
        const sel: Selection = .{
            .start = .{ .x = 10, .y = 1 },
            .end = .{ .x = 3, .y = 3 },
            .rectangle = false,
        };
        try testing.expectEqual(null, sel.toViewport(&screen));
    }
    {
        // In viewport
        const sel: Selection = .{
            .start = .{ .x = 10, .y = 11 },
            .end = .{ .x = 3, .y = 13 },
            .rectangle = false,
        };
        const want: Selection = .{
            .start = .{ .x = 10, .y = 0 },
            .end = .{ .x = 3, .y = 2 },
            .rectangle = false,
        };
        try testing.expectEqual(want, sel.toViewport(&screen));
    }
    {
        // Top off viewport
        const sel: Selection = .{
            .start = .{ .x = 10, .y = 1 },
            .end = .{ .x = 3, .y = 13 },
            .rectangle = false,
        };
        const want: Selection = .{
            .start = .{ .x = 0, .y = 0 },
            .end = .{ .x = 3, .y = 2 },
            .rectangle = false,
        };
        try testing.expectEqual(want, sel.toViewport(&screen));
    }
    {
        // Bottom off viewport
        const sel: Selection = .{
            .start = .{ .x = 10, .y = 11 },
            .end = .{ .x = 3, .y = 40 },
            .rectangle = false,
        };
        const want: Selection = .{
            .start = .{ .x = 10, .y = 0 },
            .end = .{ .x = 79, .y = 23 },
            .rectangle = false,
        };
        try testing.expectEqual(want, sel.toViewport(&screen));
    }
    {
        // Both off viewport
        const sel: Selection = .{
            .start = .{ .x = 10, .y = 1 },
            .end = .{ .x = 3, .y = 40 },
            .rectangle = false,
        };
        const want: Selection = .{
            .start = .{ .x = 0, .y = 0 },
            .end = .{ .x = 79, .y = 23 },
            .rectangle = false,
        };
        try testing.expectEqual(want, sel.toViewport(&screen));
    }
    {
        // Both off viewport (rectangle)
        const sel: Selection = .{
            .start = .{ .x = 10, .y = 1 },
            .end = .{ .x = 3, .y = 40 },
            .rectangle = true,
        };
        const want: Selection = .{
            .start = .{ .x = 10, .y = 0 },
            .end = .{ .x = 3, .y = 23 },
            .rectangle = true,
        };
        try testing.expectEqual(want, sel.toViewport(&screen));
    }
}
