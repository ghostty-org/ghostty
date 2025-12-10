const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const point = @import("../point.zig");
const size = @import("../size.zig");
const FlattenedHighlight = @import("../highlight.zig").Flattened;
const PageList = @import("../PageList.zig");
const SlidingWindow = @import("sliding_window.zig").SlidingWindow;
const Terminal = @import("../Terminal.zig");

/// Searches for a substring within the active area of a PageList.
///
/// The distinction for "active area" is important because it is the
/// only part of a PageList that is mutable. Therefore, its the only part
/// of the terminal that needs to be repeatedly searched as the contents
/// change.
///
/// This struct specializes in searching only within that active area,
/// and handling the active area moving as new lines are added to the bottom.
pub const ActiveSearch = struct {
    window: SlidingWindow,

    pub fn init(
        alloc: Allocator,
        needle: []const u8,
    ) Allocator.Error!ActiveSearch {
        // We just do a forward search since the active area is usually
        // pretty small so search results are instant anyways. This avoids
        // a small amount of work to reverse things.
        var window: SlidingWindow = try .init(alloc, .forward, needle);
        errdefer window.deinit();
        return .{ .window = window };
    }

    pub fn deinit(self: *ActiveSearch) void {
        self.window.deinit();
    }

    /// Update the active area to reflect the current state of the PageList.
    ///
    /// This doesn't do the search, it only copies the necessary data
    /// to perform the search later. This lets the caller hold the lock
    /// on the PageList for a minimal amount of time.
    ///
    /// This returns the first page (in reverse order) covered by this
    /// search. This allows the history search to overlap and search history.
    /// There CAN BE duplicates, and this page CAN BE mutable, so the history
    /// search results should prune anything that's in the active area.
    ///
    /// If the return value is null it means the active area covers the entire
    /// PageList, currently.
    pub fn update(
        self: *ActiveSearch,
        list: *const PageList,
    ) Allocator.Error!?*PageList.List.Node {
        // Clear our previous sliding window
        self.window.clearAndRetainCapacity();

        // First up, add enough pages to cover the active area.
        var rem: usize = list.rows;
        var node_ = list.pages.last;
        var last_node: ?*PageList.List.Node = null;
        while (node_) |node| : (node_ = node.prev) {
            _ = try self.window.append(node);
            last_node = node;

            // If we reached our target amount, then this is the last
            // page that contains the active area. We go to the previous
            // page once more since its the first page of our required
            // overlap.
            if (rem <= node.data.size.rows) {
                node_ = node.prev;
                break;
            }

            rem -= node.data.size.rows;
        }

        // Next, add enough overlap to cover needle.len - 1 bytes (if it
        // exists) so we can cover the overlap.
        while (node_) |node| : (node_ = node.prev) {
            // If the last row of this node isn't wrapped we can't overlap.
            const row = node.data.getRow(node.data.size.rows - 1);
            if (!row.wrap) break;

            // We could be more accurate here and count bytes since the
            // last wrap but its complicated and unlikely multiple pages
            // wrap so this should be fine.
            const added = try self.window.append(node);
            if (added >= self.window.needle.len - 1) break;
        }

        // Return the last node we added to our window.
        return last_node;
    }

    /// Find the next match for the needle in the active area. This returns
    /// null when there are no more matches.
    pub fn next(self: *ActiveSearch) ?FlattenedHighlight {
        return self.window.next();
    }
};

test "simple search" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice("Fizz\r\nBuzz\r\nFizz\r\nBang");

    var search: ActiveSearch = try .init(alloc, "Fizz");
    defer search.deinit();
    _ = try search.update(&t.screens.active.pages);

    {
        const h = search.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 3,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.active, sel.end).?);
    }
    {
        const h = search.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 3,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect(search.next() == null);
}

test "clear screen and search" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice("Fizz\r\nBuzz\r\nFizz\r\nBang");

    var search: ActiveSearch = try .init(alloc, "Fizz");
    defer search.deinit();
    _ = try search.update(&t.screens.active.pages);

    try s.nextSlice("\x1b[2J"); // Clear screen
    try s.nextSlice("\x1b[H"); // Move cursor home
    try s.nextSlice("Buzz\r\nFizz\r\nBuzz");
    _ = try search.update(&t.screens.active.pages);

    {
        const h = search.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 1,
        } }, t.screens.active.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 3,
            .y = 1,
        } }, t.screens.active.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect(search.next() == null);
}
