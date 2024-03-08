const std = @import("std");
const terminal = @import("main.zig");
const Screen = terminal.Screen;

// This file contains various types to represent x/y coordinates. We
// use different types so that we can lean on type-safety to get the
// exact expected type of point.

/// Active is a point within the active part of the screen.
pub const Active = struct {
    x: usize = 0,
    y: usize = 0,

    pub fn toScreen(self: Active, screen: *const Screen) ScreenPoint {
        return .{
            .x = self.x,
            .y = screen.history + self.y,
        };
    }

    test "toScreen with scrollback" {
        const testing = std.testing;
        const alloc = testing.allocator;

        var s = try Screen.init(alloc, 3, 5, 3);
        defer s.deinit();
        const str = "1\n2\n3\n4\n5\n6\n7\n8";
        try s.testWriteString(str);

        try testing.expectEqual(ScreenPoint{
            .x = 1,
            .y = 5,
        }, (Active{ .x = 1, .y = 2 }).toScreen(&s));
    }
};

/// Viewport is a point within the viewport of the screen.
pub const Viewport = struct {
    x: usize = 0,
    y: usize = 0,

    pub fn toScreen(self: Viewport, screen: *const Screen) ScreenPoint {
        // x is unchanged, y we have to add the visible offset to
        // get the full offset from the top.
        return .{
            .x = self.x,
            .y = screen.viewport + self.y,
        };
    }

    pub fn eql(self: Viewport, other: Viewport) bool {
        return self.x == other.x and self.y == other.y;
    }

    test "toScreen with no scrollback" {
        const testing = std.testing;
        const alloc = testing.allocator;

        var s = try Screen.init(alloc, 3, 5, 0);
        defer s.deinit();

        try testing.expectEqual(ScreenPoint{
            .x = 1,
            .y = 1,
        }, (Viewport{ .x = 1, .y = 1 }).toScreen(&s));
    }

    test "toScreen with scrollback" {
        const testing = std.testing;
        const alloc = testing.allocator;

        var s = try Screen.init(alloc, 3, 5, 3);
        defer s.deinit();

        // At the bottom
        try s.scroll(.{ .screen = 6 });
        try testing.expectEqual(ScreenPoint{
            .x = 0,
            .y = 3,
        }, (Viewport{ .x = 0, .y = 0 }).toScreen(&s));

        // Move the viewport a bit up
        try s.scroll(.{ .screen = -1 });
        try testing.expectEqual(ScreenPoint{
            .x = 0,
            .y = 2,
        }, (Viewport{ .x = 0, .y = 0 }).toScreen(&s));

        // Move the viewport to top
        try s.scroll(.{ .top = {} });
        try testing.expectEqual(ScreenPoint{
            .x = 0,
            .y = 0,
        }, (Viewport{ .x = 0, .y = 0 }).toScreen(&s));
    }
};

/// A screen point. This is offset from the top of the scrollback
/// buffer. If the screen is scrolled or resized, this will have to
/// be recomputed.
pub const ScreenPoint = struct {
    x: usize = 0,
    y: usize = 0,

    /// Returns if this point is before another point.
    pub fn before(self: ScreenPoint, other: ScreenPoint) bool {
        return self.y < other.y or
            (self.y == other.y and self.x < other.x);
    }

    /// Returns if two points are equal.
    pub fn eql(self: ScreenPoint, other: ScreenPoint) bool {
        return self.x == other.x and self.y == other.y;
    }

    /// Returns true if this screen point is currently in the active viewport.
    pub fn inViewport(self: ScreenPoint, screen: *const Screen) bool {
        return self.y >= screen.viewport and
            self.y < screen.viewport + screen.rows;
    }

    /// Converts this to a viewport point. If the point is above the
    /// viewport this will move the point to (0, 0) and if it is below
    /// the viewport it'll move it to (cols - 1, rows - 1).
    pub fn toViewport(self: ScreenPoint, screen: *const Screen) Viewport {
        // TODO: test

        // Before viewport
        if (self.y < screen.viewport) return .{ .x = 0, .y = 0 };

        // After viewport
        if (self.y > screen.viewport + screen.rows) return .{
            .x = screen.cols - 1,
            .y = screen.rows - 1,
        };

        return .{ .x = self.x, .y = self.y - screen.viewport };
    }

    /// Returns a screen point iterator. This will iterate over all of
    /// of the points in a screen in a given direction one by one.
    ///
    /// The iterator is only valid as long as the screen is not resized.
    pub fn iterator(
        self: ScreenPoint,
        screen: *const Screen,
        dir: Direction,
    ) Iterator {
        return .{ .screen = screen, .current = self, .direction = dir };
    }

    pub const Iterator = struct {
        screen: *const Screen,
        current: ?ScreenPoint,
        direction: Direction,

        pub fn next(self: *Iterator) ?ScreenPoint {
            const current = self.current orelse return null;
            self.current = switch (self.direction) {
                .left_up => left_up: {
                    if (current.x == 0) {
                        if (current.y == 0) break :left_up null;
                        break :left_up .{
                            .x = self.screen.cols - 1,
                            .y = current.y - 1,
                        };
                    }

                    break :left_up .{
                        .x = current.x - 1,
                        .y = current.y,
                    };
                },

                .right_down => right_down: {
                    if (current.x == self.screen.cols - 1) {
                        const max = self.screen.rows + self.screen.max_scrollback;
                        if (current.y == max - 1) break :right_down null;
                        break :right_down .{
                            .x = 0,
                            .y = current.y + 1,
                        };
                    }

                    break :right_down .{
                        .x = current.x + 1,
                        .y = current.y,
                    };
                },
            };

            return current;
        }
    };

    test "before" {
        const testing = std.testing;

        const p: ScreenPoint = .{ .x = 5, .y = 2 };
        try testing.expect(p.before(.{ .x = 6, .y = 2 }));
        try testing.expect(p.before(.{ .x = 3, .y = 3 }));
    }

    test "iterator" {
        const testing = std.testing;
        const alloc = testing.allocator;

        var s = try Screen.init(alloc, 5, 5, 0);
        defer s.deinit();

        // Back from the first line
        {
            var pt: ScreenPoint = .{ .x = 1, .y = 0 };
            var it = pt.iterator(&s, .left_up);
            try testing.expectEqual(ScreenPoint{ .x = 1, .y = 0 }, it.next().?);
            try testing.expectEqual(ScreenPoint{ .x = 0, .y = 0 }, it.next().?);
            try testing.expect(it.next() == null);
        }

        // Back from second line
        {
            var pt: ScreenPoint = .{ .x = 1, .y = 1 };
            var it = pt.iterator(&s, .left_up);
            try testing.expectEqual(ScreenPoint{ .x = 1, .y = 1 }, it.next().?);
            try testing.expectEqual(ScreenPoint{ .x = 0, .y = 1 }, it.next().?);
            try testing.expectEqual(ScreenPoint{ .x = 4, .y = 0 }, it.next().?);
        }

        // Forward last line
        {
            var pt: ScreenPoint = .{ .x = 3, .y = 4 };
            var it = pt.iterator(&s, .right_down);
            try testing.expectEqual(ScreenPoint{ .x = 3, .y = 4 }, it.next().?);
            try testing.expectEqual(ScreenPoint{ .x = 4, .y = 4 }, it.next().?);
            try testing.expect(it.next() == null);
        }

        // Forward not last line
        {
            var pt: ScreenPoint = .{ .x = 3, .y = 3 };
            var it = pt.iterator(&s, .right_down);
            try testing.expectEqual(ScreenPoint{ .x = 3, .y = 3 }, it.next().?);
            try testing.expectEqual(ScreenPoint{ .x = 4, .y = 3 }, it.next().?);
            try testing.expectEqual(ScreenPoint{ .x = 0, .y = 4 }, it.next().?);
        }
    }
};

/// Direction that points can go.
pub const Direction = enum { left_up, right_down };

test {
    std.testing.refAllDecls(@This());
}
