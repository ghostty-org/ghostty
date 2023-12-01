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
        .start = .{ .x = start.x, .y = start.y },
        .end = .{ .x = end.x, .y = end.y },
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
    };
}

/// Returns the bottom right point of the selection.
pub fn bottomRight(self: Selection) ScreenPoint {
    return switch (self.order()) {
        .forward => self.end,
        .reverse => self.start,
    };
}

/// Returns the selection in the given order.
pub fn ordered(self: Selection, desired: Order) Selection {
    if (self.order() == desired) return self;
    const tl = self.topLeft();
    const br = self.bottomRight();
    return switch (desired) {
        .forward => .{ .start = tl, .end = br, .rectangle = self.rectangle },
        .reverse => .{ .start = br, .end = tl, .rectangle = self.rectangle },
    };
}

/// The order of the selection (whether it is selecting forward or back).
pub const Order = enum { forward, reverse };

fn order(self: Selection) Order {
    if (self.start.y < self.end.y) return .forward;
    if (self.start.y > self.end.y) return .reverse;
    if (self.start.x <= self.end.x) return .forward;
    return .reverse;
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
