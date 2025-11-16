const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const point = @import("../point.zig");
const PageList = @import("../PageList.zig");
const Pin = PageList.Pin;
const Screen = @import("../Screen.zig");
const Selection = @import("../Selection.zig");
const Terminal = @import("../Terminal.zig");
const ActiveSearch = @import("active.zig").ActiveSearch;
const PageListSearch = @import("pagelist.zig").PageListSearch;
const SlidingWindow = @import("sliding_window.zig").SlidingWindow;

/// Searches for a needle within a Screen, handling active area updates,
/// pages being pruned from the screen (e.g. scrollback limits), and more.
///
/// Unlike our lower-level searchers (like ActiveSearch and PageListSearch),
/// this will cache and store all search results so the caller can re-access
/// them as needed. This structure does this because it is intended to help
/// the caller handle the case where the Screen is changing while the user
/// is searching.
///
/// An inactive screen can continue to be searched in the background, and when
/// screen state changes, the renderer/caller can access the existing search
/// results without needing to re-search everything. This prevents a particularly
/// nasty UX where going to alt screen (e.g. neovim) and then back would
/// restart the full scrollback search.
pub const ScreenSearch = struct {
    /// The screen being searched.
    screen: *Screen,

    /// The active area search state
    active: ActiveSearch,

    /// The history (scrollback) search state. May be null if there is
    /// no history yet.
    history: ?HistorySearch,

    /// Current state of the search, a state machine.
    state: State,

    /// The results found so far. These are stored separately because history
    /// is mostly immutable once found, while active area results may
    /// change. This lets us easily reset the active area results for a
    /// re-search scenario.
    history_results: std.ArrayList(Selection),
    active_results: std.ArrayList(Selection),

    /// History search state.
    const HistorySearch = struct {
        /// The actual searcher state.
        searcher: PageListSearch,

        /// The pin for the first node that this searcher is searching from.
        /// We use this when the active area changes to find the diff between
        /// the top of the new active area and the previous start point
        /// to determine if we need to search more history.
        start_pin: *Pin,

        pub fn deinit(self: *HistorySearch, screen: *Screen) void {
            self.searcher.deinit();
            screen.pages.untrackPin(self.start_pin);
        }
    };

    /// Search state machine
    const State = enum {
        /// Currently searching the active area
        active,

        /// Currently searching the history area
        history,

        /// History search is waiting for more data to be fed before
        /// it can progress.
        history_feed,

        /// Search is complete given the current terminal state.
        complete,

        pub fn isComplete(self: State) bool {
            return switch (self) {
                .complete => true,
                else => false,
            };
        }

        pub fn needsFeed(self: State) bool {
            return switch (self) {
                .history_feed => true,
                else => false,
            };
        }
    };

    // Initialize a screen search for the given screen and needle.
    pub fn init(
        alloc: Allocator,
        screen: *Screen,
        needle_unowned: []const u8,
    ) Allocator.Error!ScreenSearch {
        var result: ScreenSearch = .{
            .screen = screen,
            .active = try .init(alloc, needle_unowned),
            .history = null,
            .state = .active,
            .active_results = .empty,
            .history_results = .empty,
        };
        errdefer result.deinit();

        // Update our initial active area state
        try result.reloadActive();

        return result;
    }

    pub fn deinit(self: *ScreenSearch) void {
        const alloc = self.allocator();
        self.active.deinit();
        if (self.history) |*h| h.deinit(self.screen);
        self.active_results.deinit(alloc);
        self.history_results.deinit(alloc);
    }

    fn allocator(self: *ScreenSearch) Allocator {
        return self.active.window.alloc;
    }

    /// The needle that this search is using.
    pub fn needle(self: *const ScreenSearch) []const u8 {
        assert(self.active.window.direction == .forward);
        return self.active.window.needle;
    }

    /// Returns the total number of matches found so far.
    pub fn matchesLen(self: *const ScreenSearch) usize {
        return self.active_results.items.len + self.history_results.items.len;
    }

    /// Returns all matches as an owned slice (caller must free).
    /// The matches are ordered from most recent to oldest (e.g. bottom
    /// of the screen to top of the screen).
    pub fn matches(
        self: *ScreenSearch,
        alloc: Allocator,
    ) Allocator.Error![]Selection {
        const active_results = self.active_results.items;
        const history_results = self.history_results.items;
        const results = try alloc.alloc(
            Selection,
            active_results.len + history_results.len,
        );
        errdefer alloc.free(results);

        // Active does a forward search, so we add the active results then
        // reverse them. There are usually not many active results so this
        // is fast enough compared to adding them in reverse order.
        assert(self.active.window.direction == .forward);
        @memcpy(
            results[0..active_results.len],
            active_results,
        );
        std.mem.reverse(Selection, results[0..active_results.len]);

        // History does a backward search, so we can just append them
        // after.
        @memcpy(
            results[active_results.len..],
            history_results,
        );

        return results;
    }

    /// Search the full screen state. This will block until the search
    /// is complete. For performance, it is recommended to use `tick` and
    /// `feed` to incrementally make progress on the search instead.
    pub fn searchAll(self: *ScreenSearch) Allocator.Error!void {
        while (true) {
            self.tick() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.FeedRequired => try self.feed(),
                error.SearchComplete => return,
            };
        }
    }

    pub const TickError = Allocator.Error || error{
        FeedRequired,
        SearchComplete,
    };

    /// Make incremental progress on the search without accessing any
    /// screen state (so no lock is required).
    ///
    /// This will return error.FeedRequired if the search cannot make progress
    /// without being fed more data. In this case, the caller should call
    /// the `feed` function to provide more data to the searcher.
    ///
    /// This will return error.SearchComplete if the search is fully complete.
    /// This is to signal to the caller that it can move to a more efficient
    /// sleep/wait state until there is more work to do (e.g. new data to feed).
    pub fn tick(self: *ScreenSearch) TickError!void {
        switch (self.state) {
            .active => try self.tickActive(),
            .history => try self.tickHistory(),
            .history_feed => return error.FeedRequired,
            .complete => return error.SearchComplete,
        }
    }

    /// Feed more data to the searcher so it can continue searching. This
    /// accesses the screen state, so the caller must hold the necessary locks.
    pub fn feed(self: *ScreenSearch) Allocator.Error!void {
        const history: *PageListSearch = if (self.history) |*h| &h.searcher else {
            // No history to feed, search is complete.
            self.state = .complete;
            return;
        };

        // Future: we may want to feed multiple pages at once here to
        // lower the frequency of lock acquisitions.
        if (!try history.feed()) {
            // No more data to feed, search is complete.
            self.state = .complete;
            return;
        }

        // Depending on our state handle where feed goes
        switch (self.state) {
            // If we're searching active or history, then feeding doesn't
            // change the state.
            .active, .history => {},

            // Feed goes back to searching history.
            .history_feed => self.state = .history,

            // If we're complete then the feed call above should always
            // return false and we can't reach this.
            .complete => unreachable,
        }
    }

    fn tickActive(self: *ScreenSearch) Allocator.Error!void {
        // For the active area, we consume the entire search in one go
        // because the active area is generally small.
        const alloc = self.allocator();
        while (self.active.next()) |sel| {
            // If this fails, then we miss a result since `active.next()`
            // moves forward and prunes data. In the future, we may want
            // to have some more robust error handling but the only
            // scenario this would fail is OOM and we're probably in
            // deeper trouble at that point anyways.
            try self.active_results.append(alloc, sel);
        }

        // We've consumed the entire active area, move to history.
        self.state = .history;
    }

    fn tickHistory(self: *ScreenSearch) Allocator.Error!void {
        const history: *HistorySearch = if (self.history) |*h| h else {
            // No history to search, we're done.
            self.state = .complete;
            return;
        };

        // Try to consume all the loaded matches in one go, because
        // the search is generally fast for loaded data.
        const alloc = self.allocator();
        while (history.searcher.next()) |sel| {
            // Ignore selections that are found within the starting
            // node since those are covered by the active area search.
            if (sel.start().node == history.start_pin.node) continue;

            // Same note as tickActive for error handling.
            try self.history_results.append(alloc, sel);
        }

        // We need to be fed more data.
        self.state = .history_feed;
    }

    /// Reload the active area because it has changed.
    ///
    /// Since it is very fast, this will also do the full active area
    /// search again, too. This avoids any complexity around the search
    /// state machine.
    ///
    /// The caller must hold the necessary locks to access the screen state.
    pub fn reloadActive(self: *ScreenSearch) Allocator.Error!void {
        const list: *PageList = &self.screen.pages;
        if (try self.active.update(list)) |history_node| history: {
            // We need to account for any active area growth that would
            // cause new pages to move into our history. If there are new
            // pages then we need to re-search the pages and add it to
            // our history results.

            const history_: ?*HistorySearch = if (self.history) |*h| state: {
                // If our start pin became garbage, it means we pruned all
                // the way up through it, so we have no history anymore.
                // Reset our history state.
                if (h.start_pin.garbage) {
                    h.deinit(self.screen);
                    self.history = null;
                    self.history_results.clearRetainingCapacity();
                    break :state null;
                }

                break :state h;
            } else null;

            const history = history_ orelse {
                // No history search yet, but we now have history. So let's
                // initialize.

                var search: PageListSearch = try .init(
                    self.allocator(),
                    self.needle(),
                    list,
                    history_node,
                );
                errdefer search.deinit();

                const pin = try list.trackPin(.{ .node = history_node });
                errdefer list.untrackPin(pin);

                self.history = .{
                    .searcher = search,
                    .start_pin = pin,
                };

                // We don't need to update any history since we had no history
                // before, so we can break out of the whole conditional.
                break :history;
            };

            if (history.start_pin.node == history_node) {
                // No change in the starting node, we're done.
                break :history;
            }

            // Do a forward search from our prior node to this one. We
            // collect all the results into a new list. We ASSUME that
            // reloadActive is being called frequently enough that there isn't
            // a massive amount of history to search here.
            const alloc = self.allocator();
            var window: SlidingWindow = try .init(
                alloc,
                .forward,
                self.needle(),
            );
            defer window.deinit();
            while (true) {
                _ = try window.append(history.start_pin.node);
                if (history.start_pin.node == history_node) break;
                const next = history.start_pin.node.next orelse break;
                history.start_pin.node = next;
            }
            assert(history.start_pin.node == history_node);

            var results: std.ArrayList(Selection) = try .initCapacity(
                alloc,
                self.history_results.items.len,
            );
            errdefer results.deinit(alloc);
            while (window.next()) |sel| {
                if (sel.start().node == history_node) continue;
                try results.append(
                    alloc,
                    sel,
                );
            }

            // If we have no matches then there is nothing to change
            // in our history (fast path)
            if (results.items.len == 0) break :history;

            // Matches! Reverse our list then append all the remaining
            // history items that didn't start on our original node.
            std.mem.reverse(Selection, results.items);
            try results.appendSlice(alloc, self.history_results.items);
            self.history_results.deinit(alloc);
            self.history_results = results;
        }

        // Reset our active search results and search again.
        self.active_results.clearRetainingCapacity();
        switch (self.state) {
            // If we're in the active state we run a normal tick so
            // we can move into a better state.
            .active => try self.tickActive(),

            // Otherwise, just tick it and move back to whatever state
            // we were in.
            else => {
                const old_state = self.state;
                defer self.state = old_state;
                try self.tickActive();
            },
        }
    }
};

test "simple search" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{ .cols = 10, .rows = 2 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice("Fizz\r\nBuzz\r\nFizz\r\nBang");

    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();
    try testing.expectEqual(2, search.active_results.items.len);
    // We don't test history results since there is overlap

    // Get all matches
    const matches = try search.matches(alloc);
    defer alloc.free(matches);
    try testing.expectEqual(2, matches.len);

    {
        const sel = matches[0];
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end()).?);
    }
    {
        const sel = matches[1];
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end()).?);
    }
}

test "simple search with history" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);
    const list: *PageList = &t.screens.active.pages;

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("Fizz\r\n");
    while (list.totalPages() < 3) try s.nextSlice("\r\n");
    for (0..list.rows) |_| try s.nextSlice("\r\n");
    try s.nextSlice("hello.");

    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();
    try testing.expectEqual(0, search.active_results.items.len);

    // Get all matches
    const matches = try search.matches(alloc);
    defer alloc.free(matches);
    try testing.expectEqual(1, matches.len);

    {
        const sel = matches[0];
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end()).?);
    }
}

test "reload active with history change" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);
    const list: *PageList = &t.screens.active.pages;

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice("Fizz\r\n");

    // Start up our search which will populate our initial active area.
    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();
    {
        const matches = try search.matches(alloc);
        defer alloc.free(matches);
        try testing.expectEqual(1, matches.len);
    }

    // Grow into two pages so our history pin will move.
    while (list.totalPages() < 2) try s.nextSlice("\r\n");
    for (0..list.rows) |_| try s.nextSlice("\r\n");
    try s.nextSlice("2Fizz");

    // Active area changed so reload
    try search.reloadActive();
    try search.searchAll();

    // Get all matches
    {
        const matches = try search.matches(alloc);
        defer alloc.free(matches);
        try testing.expectEqual(2, matches.len);
        {
            const sel = matches[1];
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 0,
                .y = 0,
            } }, t.screens.active.pages.pointFromPin(.screen, sel.start()).?);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 3,
                .y = 0,
            } }, t.screens.active.pages.pointFromPin(.screen, sel.end()).?);
        }
        {
            const sel = matches[0];
            try testing.expectEqual(point.Point{ .active = .{
                .x = 1,
                .y = 1,
            } }, t.screens.active.pages.pointFromPin(.active, sel.start()).?);
            try testing.expectEqual(point.Point{ .active = .{
                .x = 4,
                .y = 1,
            } }, t.screens.active.pages.pointFromPin(.active, sel.end()).?);
        }
    }

    // Reset the screen which will make our pin garbage.
    t.fullReset();
    try s.nextSlice("WeFizzing");
    try search.reloadActive();
    try search.searchAll();

    {
        const matches = try search.matches(alloc);
        defer alloc.free(matches);
        try testing.expectEqual(1, matches.len);
        {
            const sel = matches[0];
            try testing.expectEqual(point.Point{ .active = .{
                .x = 2,
                .y = 0,
            } }, t.screens.active.pages.pointFromPin(.active, sel.start()).?);
            try testing.expectEqual(point.Point{ .active = .{
                .x = 5,
                .y = 0,
            } }, t.screens.active.pages.pointFromPin(.active, sel.end()).?);
        }
    }
}

test "active change contents" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice("Fuzz\r\nBuzz\r\nFizz\r\nBang");

    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();
    try testing.expectEqual(1, search.active_results.items.len);

    // Erase the screen, move our cursor to the top, and change contents.
    try s.nextSlice("\x1b[2J\x1b[H"); // Clear screen and move home
    try s.nextSlice("Bang\r\nFizz\r\nHello!");

    try search.reloadActive();
    try search.searchAll();
    try testing.expectEqual(1, search.active_results.items.len);

    // Get all matches
    const matches = try search.matches(alloc);
    defer alloc.free(matches);
    try testing.expectEqual(1, matches.len);

    {
        const sel = matches[0];
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 1,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end()).?);
    }
}
