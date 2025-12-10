const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const terminal = @import("../main.zig");
const point = terminal.point;
const FlattenedHighlight = @import("../highlight.zig").Flattened;
const Page = terminal.Page;
const PageList = terminal.PageList;
const Pin = PageList.Pin;
const Selection = terminal.Selection;
const Screen = terminal.Screen;
const Terminal = @import("../Terminal.zig");
const SlidingWindow = @import("sliding_window.zig").SlidingWindow;

/// Searches for a term in a PageList structure.
///
/// This searches in reverse order starting from the given node.
///
/// This assumes that nodes do not change contents. For nodes that change
/// contents, look at ActiveSearch, which is designed to re-search the active
/// area since it assumed to change. When integrating ActiveSearch with
/// PageListSearch, the caller should start the PageListSearch from the
/// returned node from ActiveSearch.update().
///
/// Concurrent access to a PageList or nodes in a PageList are not allowed,
/// so the caller should ensure that necessary locks are held. Each function
/// documents whether it accesses the PageList or not. For example, you can
/// safely call `next()` without holding a lock, but you must hold a lock
/// while calling `feed()`.
pub const PageListSearch = struct {
    /// The list we're searching.
    list: *PageList,

    /// The sliding window of page contents and nodes to search.
    window: SlidingWindow,

    /// The tracked pin for our current position in the pagelist. This
    /// will always point to the CURRENT node we're searching from so that
    /// we can track if we move.
    pin: *Pin,

    /// Initialize the page list search. The needle is copied so it can
    /// be freed immediately.
    ///
    /// Accesses the PageList/Node so the caller must ensure it is safe
    /// to do so if there is any concurrent access.
    pub fn init(
        alloc: Allocator,
        needle: []const u8,
        list: *PageList,
        start: *PageList.List.Node,
    ) Allocator.Error!PageListSearch {
        // We put a tracked pin into the node that we're starting from.
        // By using a tracked pin, we can keep our pagelist references safe
        // because if the pagelist prunes pages, the tracked pin will
        // be moved somewhere safe.
        const pin = try list.trackPin(.{
            .node = start,
            .y = start.data.size.rows - 1,
            .x = start.data.size.cols - 1,
        });
        errdefer list.untrackPin(pin);

        // Create our sliding window we'll use for searching.
        var window: SlidingWindow = try .init(alloc, .reverse, needle);
        errdefer window.deinit();

        // We always feed our initial page data into the window, because
        // we have the lock anyways and this lets our `pin` point to our
        // current node and feed to work properly.
        _ = try window.append(start);

        return .{
            .list = list,
            .window = window,
            .pin = pin,
        };
    }

    /// Modifies the PageList (to untrack a pin) so the caller must ensure
    /// that it is safe to do so.
    pub fn deinit(self: *PageListSearch) void {
        self.window.deinit();
        self.list.untrackPin(self.pin);
    }

    /// Return the next match in the loaded page nodes. If this returns
    /// null then the PageList search needs to be fed the next node(s).
    /// Call, `feed` to do this.
    ///
    /// Beware that the selection returned may point to a node that
    /// is freed if the caller does not hold necessary locks on the
    /// PageList while searching. The pins should be validated prior to
    /// final use.
    ///
    /// This does NOT access the PageList, so it can be called without
    /// a lock held.
    pub fn next(self: *PageListSearch) ?FlattenedHighlight {
        return self.window.next();
    }

    /// Feed more data to the sliding window from the pagelist. This will
    /// feed enough data to cover at least one match (needle length) if it
    /// exists; this doesn't perform the search, it only feeds data.
    ///
    /// This accesses nodes in the PageList, so the caller must ensure
    /// it is safe to do so (i.e. hold necessary locks).
    ///
    /// This returns false if there is no more data to feed. This essentially
    /// means we've searched the entire pagelist.
    pub fn feed(self: *PageListSearch) Allocator.Error!bool {
        // If our pin becomes garbage it means wherever we were next
        // was reused and we can't make sense of our progress anymore.
        // It is effectively equivalent to reaching the end of the PageList.
        if (self.pin.garbage) return false;

        // Add at least enough data to find a single match.
        var rem = self.window.needle.len;

        // Start at our previous node and then continue adding until we
        // get our desired amount of data.
        var node_: ?*PageList.List.Node = self.pin.node.prev;
        while (node_) |node| : (node_ = node.prev) {
            rem -|= try self.window.append(node);

            // Move our tracked pin to the new node.
            self.pin.node = node;

            if (rem == 0) break;
        }

        // True if we fed any data.
        return rem < self.window.needle.len;
    }
};

test "simple search" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice("Fizz\r\nBuzz\r\nFizz\r\nBang");

    var search: PageListSearch = try .init(
        alloc,
        "Fizz",
        &t.screens.active.pages,
        t.screens.active.pages.pages.last.?,
    );
    defer search.deinit();

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
    try testing.expect(search.next() == null);

    // We should not be able to feed since we have one page
    try testing.expect(!try search.feed());
}

test "feed multiple pages with matches" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    // Fill up first page
    const first_page_rows = t.screens.active.pages.pages.first.?.data.capacity.rows;
    for (0..first_page_rows - 1) |_| try s.nextSlice("\r\n");
    try s.nextSlice("Fizz");
    try testing.expect(t.screens.active.pages.pages.first == t.screens.active.pages.pages.last);

    // Create second page
    try s.nextSlice("\r\n");
    try testing.expect(t.screens.active.pages.pages.first != t.screens.active.pages.pages.last);
    try s.nextSlice("Buzz\r\nFizz");

    var search: PageListSearch = try .init(
        alloc,
        "Fizz",
        &t.screens.active.pages,
        t.screens.active.pages.pages.last.?,
    );
    defer search.deinit();

    // First match on the last page
    const sel1 = search.next();
    try testing.expect(sel1 != null);
    try testing.expect(search.next() == null);

    // Feed should succeed and load the first page
    try testing.expect(try search.feed());

    // Now we should find the match on the first page
    const sel2 = search.next();
    try testing.expect(sel2 != null);
    try testing.expect(search.next() == null);

    // No more pages to feed
    try testing.expect(!try search.feed());
}

test "feed multiple pages no matches" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    // Fill up first page
    const first_page_rows = t.screens.active.pages.pages.first.?.data.capacity.rows;
    for (0..first_page_rows - 1) |_| try s.nextSlice("\r\n");
    try s.nextSlice("Hello");

    // Create second page
    try s.nextSlice("\r\n");
    try testing.expect(t.screens.active.pages.pages.first != t.screens.active.pages.pages.last);
    try s.nextSlice("World");

    var search: PageListSearch = try .init(
        alloc,
        "Nope",
        &t.screens.active.pages,
        t.screens.active.pages.pages.last.?,
    );
    defer search.deinit();

    // No matches on last page
    try testing.expect(search.next() == null);

    // Feed first page
    try testing.expect(try search.feed());

    // Still no matches
    try testing.expect(search.next() == null);

    // No more pages
    try testing.expect(!try search.feed());
}

test "feed iteratively through multiple matches" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{ .cols = 80, .rows = 24 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    const first_page_rows = t.screens.active.pages.pages.first.?.data.capacity.rows;

    // Fill first page with a match at the end
    for (0..first_page_rows - 1) |_| try s.nextSlice("\r\n");
    try s.nextSlice("Page1Test");
    try testing.expect(t.screens.active.pages.pages.first == t.screens.active.pages.pages.last);

    // Create second page with a match
    try s.nextSlice("\r\n");
    try testing.expect(t.screens.active.pages.pages.first != t.screens.active.pages.pages.last);
    try s.nextSlice("Page2Test");

    var search: PageListSearch = try .init(
        alloc,
        "Test",
        &t.screens.active.pages,
        t.screens.active.pages.pages.last.?,
    );
    defer search.deinit();

    // Match on page 2
    try testing.expect(search.next() != null);
    try testing.expect(search.next() == null);

    // Feed page 1
    try testing.expect(try search.feed());
    try testing.expect(search.next() != null);
    try testing.expect(search.next() == null);

    // No more pages
    try testing.expect(!try search.feed());
}

test "feed with match spanning page boundary" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{ .cols = 80, .rows = 24 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    const first_page_rows = t.screens.active.pages.pages.first.?.data.capacity.rows;

    // Fill first page ending with "Te"
    for (0..first_page_rows - 1) |_| try s.nextSlice("\r\n");
    for (0..t.screens.active.pages.cols - 2) |_| try s.nextSlice("x");
    try s.nextSlice("Te");
    try testing.expect(t.screens.active.pages.pages.first == t.screens.active.pages.pages.last);

    // Second page starts with "st"
    try s.nextSlice("st");
    try testing.expect(t.screens.active.pages.pages.first != t.screens.active.pages.pages.last);

    var search: PageListSearch = try .init(
        alloc,
        "Test",
        &t.screens.active.pages,
        t.screens.active.pages.pages.last.?,
    );
    defer search.deinit();

    // No complete match on last page alone (only has "st")
    try testing.expect(search.next() == null);

    // Feed first page - this should give us enough data to find "Test"
    try testing.expect(try search.feed());

    // Should find the spanning match
    const h = search.next().?;
    const sel = h.untracked();
    try testing.expect(sel.start.node != sel.end.node);
    {
        const str = try t.screens.active.selectionString(
            alloc,
            .{ .sel = .init(sel.start, sel.end, false) },
        );
        defer alloc.free(str);
        try testing.expectEqualStrings(str, "Test");
    }

    // No more matches
    try testing.expect(search.next() == null);

    // No more pages
    try testing.expect(!try search.feed());
}

test "feed with match spanning page boundary with newline" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{ .cols = 80, .rows = 24 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    const first_page_rows = t.screens.active.pages.pages.first.?.data.capacity.rows;

    // Fill first page ending with "Te"
    for (0..first_page_rows - 1) |_| try s.nextSlice("\r\n");
    for (0..t.screens.active.pages.cols - 2) |_| try s.nextSlice("x");
    try s.nextSlice("Te");
    try testing.expect(t.screens.active.pages.pages.first == t.screens.active.pages.pages.last);

    // Second page starts with "st"
    try s.nextSlice("\r\n");
    try testing.expect(t.screens.active.pages.pages.first != t.screens.active.pages.pages.last);
    try s.nextSlice("st");

    var search: PageListSearch = try .init(
        alloc,
        "Test",
        &t.screens.active.pages,
        t.screens.active.pages.pages.last.?,
    );
    defer search.deinit();

    // Should not find any matches since we broke with an explicit newline.
    try testing.expect(search.next() == null);
    try testing.expect(try search.feed());
    try testing.expect(search.next() == null);
    try testing.expect(!try search.feed());
}

test "feed with pruned page" {
    const alloc = testing.allocator;

    // Zero here forces minimum max size to effectively two pages.
    var p: PageList = try .init(alloc, 80, 24, 0);
    defer p.deinit();

    // Grow to capacity
    const page1_node = p.pages.last.?;
    const page1 = page1_node.data;
    for (0..page1.capacity.rows - page1.size.rows) |_| {
        try testing.expect(try p.grow() == null);
    }

    // Grow and allocate one more page. Then fill that page up.
    const page2_node = (try p.grow()).?;
    const page2 = page2_node.data;
    for (0..page2.capacity.rows - page2.size.rows) |_| {
        try testing.expect(try p.grow() == null);
    }

    // Setup search and feed until we can't
    var search: PageListSearch = try .init(
        alloc,
        "Test",
        &p,
        p.pages.last.?,
    );
    defer search.deinit();
    try testing.expect(try search.feed());
    try testing.expect(!try search.feed());

    // Next should create a new page, but it should reuse our first
    // page since we're at max size.
    const new = (try p.grow()).?;
    try testing.expect(p.pages.last.? == new);

    // Our first should now be page2 and our last should be page1
    try testing.expectEqual(page2_node, p.pages.first.?);
    try testing.expectEqual(page1_node, p.pages.last.?);

    // Feed should still do nothing
    try testing.expect(!try search.feed());
}
