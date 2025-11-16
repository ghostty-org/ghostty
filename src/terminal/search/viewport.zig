const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const point = @import("../point.zig");
const size = @import("../size.zig");
const PageList = @import("../PageList.zig");
const Selection = @import("../Selection.zig");
const SlidingWindow = @import("sliding_window.zig").SlidingWindow;
const Terminal = @import("../Terminal.zig");

/// Searches for a substring within the viewport of a PageList.
///
/// This contains logic to efficiently detect when the viewport changes
/// and only re-search when necessary.
///
/// The specialization for "viewport" is because the viewport is the
/// only part of the search where the user can actively see the results,
/// usually. In that case, it is more efficient to re-search only the
/// viewport rather than store all the results for the entire screen.
///
/// Note that this searches all the pages that viewport covers, so
/// this can include extra matches outside the viewport if the data
/// lives in the same page.
pub const ViewportSearch = struct {
    window: SlidingWindow,
    fingerprint: ?Fingerprint,

    pub fn init(
        alloc: Allocator,
        needle_unowned: []const u8,
    ) Allocator.Error!ViewportSearch {
        // We just do a forward search since the viewport is usually
        // pretty small so search results are instant anyways. This avoids
        // a small amount of work to reverse things.
        var window: SlidingWindow = try .init(alloc, .forward, needle_unowned);
        errdefer window.deinit();
        return .{ .window = window, .fingerprint = null };
    }

    pub fn deinit(self: *ViewportSearch) void {
        if (self.fingerprint) |*fp| fp.deinit(self.window.alloc);
        self.window.deinit();
    }

    /// Reset our fingerprint and results so that the next update will
    /// always re-search.
    pub fn reset(self: *ViewportSearch) void {
        if (self.fingerprint) |*fp| fp.deinit(self.window.alloc);
        self.fingerprint = null;
        self.window.clearAndRetainCapacity();
    }

    /// The needle that this search is using.
    pub fn needle(self: *const ViewportSearch) []const u8 {
        assert(self.window.direction == .forward);
        return self.window.needle;
    }

    /// Update the sliding window to reflect the current viewport. This
    /// will do nothing if the viewport hasn't changed since the last
    /// search.
    ///
    /// The PageList must be safe to read throughout the lifetime of this
    /// function.
    ///
    /// Returns true if the viewport changed and a re-search is needed.
    /// Returns false if the viewport is unchanged.
    pub fn update(
        self: *ViewportSearch,
        list: *PageList,
    ) Allocator.Error!bool {
        // See if our viewport changed
        var fingerprint: Fingerprint = try .init(self.window.alloc, list);
        if (self.fingerprint) |*old| {
            if (old.eql(fingerprint)) match: {
                // If our fingerprint contains the active area, then we always
                // re-search since the active area is mutable.
                const active_tl = list.getTopLeft(.active);
                const active_br = list.getBottomRight(.active).?;

                // If our viewport contains the start or end of the active area,
                // we are in the active area. We purposely do this first
                // because our viewport is always larger than the active area.
                for (old.nodes) |node| {
                    if (node == active_tl.node) break :match;
                    if (node == active_br.node) break :match;
                }

                // No change
                fingerprint.deinit(self.window.alloc);
                return false;
            }

            old.deinit(self.window.alloc);
            self.fingerprint = null;
        }
        assert(self.fingerprint == null);
        self.fingerprint = fingerprint;
        errdefer {
            fingerprint.deinit(self.window.alloc);
            self.fingerprint = null;
        }

        // Clear our previous sliding window
        self.window.clearAndRetainCapacity();

        // Add enough overlap to cover needle.len - 1 bytes (if it
        // exists) so we can cover the overlap. We only do this for the
        // soft-wrapped prior pages.
        var node_ = fingerprint.nodes[0].prev;
        var added: usize = 0;
        while (node_) |node| : (node_ = node.prev) {
            // If the last row of this node isn't wrapped we can't overlap.
            const row = node.data.getRow(node.data.size.rows - 1);
            if (!row.wrap) break;

            // We could be more accurate here and count bytes since the
            // last wrap but its complicated and unlikely multiple pages
            // wrap so this should be fine.
            added += try self.window.append(node);
            if (added >= self.window.needle.len - 1) break;
        }

        // We can use our fingerprint nodes to initialize our sliding
        // window, since we already traversed the viewport once.
        for (fingerprint.nodes) |node| {
            _ = try self.window.append(node);
        }

        // Add any trailing overlap as well.
        trailing: {
            const end: *PageList.List.Node = fingerprint.nodes[fingerprint.nodes.len - 1];
            if (!end.data.getRow(end.data.size.rows - 1).wrap) break :trailing;

            node_ = end.next;
            added = 0;
            while (node_) |node| : (node_ = node.next) {
                added += try self.window.append(node);
                if (added >= self.window.needle.len - 1) break;

                // If this row doesn't wrap, then we can quit
                const row = node.data.getRow(node.data.size.rows - 1);
                if (!row.wrap) break;
            }
        }

        return true;
    }

    /// Find the next match for the needle in the active area. This returns
    /// null when there are no more matches.
    pub fn next(self: *ViewportSearch) ?Selection {
        return self.window.next();
    }

    /// Viewport fingerprint so we can detect when the viewport moves.
    const Fingerprint = struct {
        /// The nodes that make up the viewport. We need to flatten this
        /// to a single list because we can't safely traverse the cached values
        /// because the page nodes may be invalid. All that is safe is comparing
        /// the actual pointer values.
        nodes: []const *PageList.List.Node,

        pub fn init(alloc: Allocator, pages: *PageList) Allocator.Error!Fingerprint {
            var list: std.ArrayList(*PageList.List.Node) = .empty;
            defer list.deinit(alloc);

            // Get our viewport area. Bottom right of a viewport can never
            // fail.
            const tl = pages.getTopLeft(.viewport);
            const br = pages.getBottomRight(.viewport).?;

            var it = tl.pageIterator(.right_down, br);
            while (it.next()) |chunk| try list.append(alloc, chunk.node);
            return .{ .nodes = try list.toOwnedSlice(alloc) };
        }

        pub fn deinit(self: *Fingerprint, alloc: Allocator) void {
            alloc.free(self.nodes);
        }

        pub fn eql(self: Fingerprint, other: Fingerprint) bool {
            if (self.nodes.len != other.nodes.len) return false;
            for (self.nodes, other.nodes) |a, b| {
                if (a != b) return false;
            }
            return true;
        }
    };
};

test "simple search" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice("Fizz\r\nBuzz\r\nFizz\r\nBang");

    var search: ViewportSearch = try .init(alloc, "Fizz");
    defer search.deinit();
    try testing.expect(try search.update(&t.screens.active.pages));

    // Viewport contains active so update should always re-search.
    try testing.expect(try search.update(&t.screens.active.pages));

    {
        const sel = search.next().?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 3,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.active, sel.end()).?);
    }
    {
        const sel = search.next().?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 3,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.active, sel.end()).?);
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

    var search: ViewportSearch = try .init(alloc, "Fizz");
    defer search.deinit();
    try testing.expect(try search.update(&t.screens.active.pages));

    try s.nextSlice("\x1b[2J"); // Clear screen
    try s.nextSlice("\x1b[H"); // Move cursor home
    try s.nextSlice("Buzz\r\nFizz\r\nBuzz");
    try testing.expect(try search.update(&t.screens.active.pages));

    {
        const sel = search.next().?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 1,
        } }, t.screens.active.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 3,
            .y = 1,
        } }, t.screens.active.pages.pointFromPin(.active, sel.end()).?);
    }
    try testing.expect(search.next() == null);
}

test "history search, no active area" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{ .cols = 10, .rows = 2 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    // Fill up first page
    const first_page_rows = t.screens.active.pages.pages.first.?.data.capacity.rows;
    try s.nextSlice("Fizz\r\n");
    for (1..first_page_rows - 1) |_| try s.nextSlice("\r\n");
    try testing.expect(t.screens.active.pages.pages.first == t.screens.active.pages.pages.last);

    // Create second page
    try s.nextSlice("\r\n");
    try testing.expect(t.screens.active.pages.pages.first != t.screens.active.pages.pages.last);
    try s.nextSlice("Buzz\r\nFizz");

    try t.scrollViewport(.top);

    var search: ViewportSearch = try .init(alloc, "Fizz");
    defer search.deinit();
    try testing.expect(try search.update(&t.screens.active.pages));

    {
        const sel = search.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end()).?);
    }
    try testing.expect(search.next() == null);

    // Viewport doesn't contain active
    try testing.expect(!try search.update(&t.screens.active.pages));
    try testing.expect(search.next() == null);
}
