//! Represents a single selection within the terminal (i.e. a highlight region).
const Selection = @This();

const std = @import("std");
const assert = std.debug.assert;
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

/// Start and end of the selection. There is no guarantee that
/// start is before end or vice versa. If a user selects backwards,
/// start will be after end, and vice versa. Use the struct functions
/// to not have to worry about this.
///
/// These are always tracked pins so that they automatically update as
/// the screen they're attached to gets scrolled, erased, etc.
start: *Pin,
end: *Pin,

/// Whether or not this selection refers to a rectangle, rather than whole
/// lines of a buffer. In this mode, start and end refer to the top left and
/// bottom right of the rectangle, or vice versa if the selection is backwards.
rectangle: bool = false,

/// Initialize a new selection with the given start and end pins on
/// the screen. The screen will be used for pin tracking.
pub fn init(
    s: *Screen,
    start: Pin,
    end: Pin,
    rect: bool,
) !Selection {
    // Track our pins
    const tracked_start = try s.pages.trackPin(start);
    errdefer s.pages.untrackPin(tracked_start);
    const tracked_end = try s.pages.trackPin(end);
    errdefer s.pages.untrackPin(tracked_end);

    return .{
        .start = tracked_start,
        .end = tracked_end,
        .rectangle = rect,
    };
}

pub fn deinit(
    self: Selection,
    s: *Screen,
) void {
    s.pages.untrackPin(self.start);
    s.pages.untrackPin(self.end);
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
    const start_pt = s.pages.pointFromPin(.screen, self.start.*).?.screen;
    const end_pt = s.pages.pointFromPin(.screen, self.end.*).?.screen;

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
    _ = self;
    _ = s;

    //const screen_end = Screen.RowIndexTag.screen.maxLen(screen) - 1;

    // Note that we always adjusts "end" because end always represents
    // the last point of the selection by mouse, not necessarilly the
    // top/bottom visually. So this results in the right behavior
    // whether the user drags up or down.
    switch (adjustment) {
        // .up => if (result.end.y == 0) {
        //     result.end.x = 0;
        // } else {
        //     result.end.y -= 1;
        // },
        //
        // .down => if (result.end.y >= screen_end) {
        //     result.end.y = screen_end;
        //     result.end.x = screen.cols - 1;
        // } else {
        //     result.end.y += 1;
        // },
        //
        // .left => {
        //     // Step left, wrapping to the next row up at the start of each new line,
        //     // until we find a non-empty cell.
        //     //
        //     // This iterator emits the start point first, throw it out.
        //     var iterator = result.end.iterator(screen, .left_up);
        //     _ = iterator.next();
        //     while (iterator.next()) |next| {
        //         if (screen.getCell(
        //             .screen,
        //             next.y,
        //             next.x,
        //         ).char != 0) {
        //             result.end = next;
        //             break;
        //         }
        //     }
        // },

        // .right => {
        //     // Step right, wrapping to the next row down at the start of each new line,
        //     // until we find a non-empty cell.
        //     var iterator = result.end.iterator(screen, .right_down);
        //     _ = iterator.next();
        //     while (iterator.next()) |next| {
        //         if (next.y > screen_end) break;
        //         if (screen.getCell(
        //             .screen,
        //             next.y,
        //             next.x,
        //         ).char != 0) {
        //             if (next.y > screen_end) {
        //                 result.end.y = screen_end;
        //             } else {
        //                 result.end = next;
        //             }
        //             break;
        //         }
        //     }
        // },
        //
        // .page_up => if (screen.rows > result.end.y) {
        //     result.end.y = 0;
        //     result.end.x = 0;
        // } else {
        //     result.end.y -= screen.rows;
        // },
        //
        // .page_down => if (screen.rows > screen_end - result.end.y) {
        //     result.end.y = screen_end;
        //     result.end.x = screen.cols - 1;
        // } else {
        //     result.end.y += screen.rows;
        // },
        //
        // .home => {
        //     result.end.y = 0;
        //     result.end.x = 0;
        // },
        //
        // .end => {
        //     result.end.y = screen_end;
        //     result.end.x = screen.cols - 1;
        //},

        else => @panic("TODO"),
    }
}

test "Selection: adjust right" {
    const testing = std.testing;
    var s = try Screen.init(testing.allocator, 5, 10, 0);
    defer s.deinit();
    try s.testWriteString("A1234\nB5678\nC1234\nD5678");

    // // Simple movement right
    // {
    //     var sel = try Selection.init(
    //         &s,
    //         s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
    //         s.pages.pin(.{ .screen = .{ .x = 3, .y = 3 } }).?,
    //         false,
    //     );
    //     defer sel.deinit(&s);
    //     sel.adjust(&s, .right);
    //
    //     try testing.expectEqual(point.Point{ .screen = .{
    //         .x = 5,
    //         .y = 1,
    //     } }, s.pages.pointFromPin(.screen, sel.start.*).?);
    //     try testing.expectEqual(point.Point{ .screen = .{
    //         .x = 4,
    //         .y = 3,
    //     } }, s.pages.pointFromPin(.screen, sel.end.*).?);
    // }

    // // Already at end of the line.
    // {
    //     const sel = (Selection{
    //         .start = .{ .x = 5, .y = 1 },
    //         .end = .{ .x = 4, .y = 2 },
    //     }).adjust(&screen, .right);
    //
    //     try testing.expectEqual(Selection{
    //         .start = .{ .x = 5, .y = 1 },
    //         .end = .{ .x = 0, .y = 3 },
    //     }, sel);
    // }
    //
    // // Already at end of the screen
    // {
    //     const sel = (Selection{
    //         .start = .{ .x = 5, .y = 1 },
    //         .end = .{ .x = 4, .y = 3 },
    //     }).adjust(&screen, .right);
    //
    //     try testing.expectEqual(Selection{
    //         .start = .{ .x = 5, .y = 1 },
    //         .end = .{ .x = 4, .y = 3 },
    //     }, sel);
    // }
}

test "Selection: order, standard" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, 100, 100, 1);
    defer s.deinit();

    {
        // forward, multi-line
        const sel = try Selection.init(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 2 } }).?,
            false,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .forward);
    }
    {
        // reverse, multi-line
        const sel = try Selection.init(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 2 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
            false,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .reverse);
    }
    {
        // forward, same-line
        const sel = try Selection.init(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            false,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .forward);
    }
    {
        // forward, single char
        const sel = try Selection.init(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
            false,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .forward);
    }
    {
        // reverse, single line
        const sel = try Selection.init(
            &s,
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
        const sel = try Selection.init(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 2 } }).?,
            true,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .forward);
    }
    {
        // reverse (BR -> TL)
        const sel = try Selection.init(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 2 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            true,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .reverse);
    }
    {
        // mirrored_forward (TR -> BL)
        const sel = try Selection.init(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 3 } }).?,
            true,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .mirrored_forward);
    }
    {
        // mirrored_reverse (BL -> TR)
        const sel = try Selection.init(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 3 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            true,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .mirrored_reverse);
    }
    {
        // forward, single line (left -> right )
        const sel = try Selection.init(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            true,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .forward);
    }
    {
        // reverse, single line (right -> left)
        const sel = try Selection.init(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            true,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .reverse);
    }
    {
        // forward, single column (top -> bottom)
        const sel = try Selection.init(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 3 } }).?,
            true,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .forward);
    }
    {
        // reverse, single column (bottom -> top)
        const sel = try Selection.init(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 3 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
            true,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .reverse);
    }
    {
        // forward, single cell
        const sel = try Selection.init(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            true,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .forward);
    }
}
