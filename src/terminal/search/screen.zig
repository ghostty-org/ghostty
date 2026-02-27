const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const testing = std.testing;
const tripwire = @import("../../tripwire.zig");
const Allocator = std.mem.Allocator;
const point = @import("../point.zig");
const highlight = @import("../highlight.zig");
const size = @import("../size.zig");
const FlattenedHighlight = highlight.Flattened;
const TrackedHighlight = highlight.Tracked;
const PageList = @import("../PageList.zig");
const Pin = PageList.Pin;
const Screen = @import("../Screen.zig");
const Terminal = @import("../Terminal.zig");
const ActiveSearch = @import("active.zig").ActiveSearch;
const PageListSearch = @import("pagelist.zig").PageListSearch;
const SlidingWindow = @import("sliding_window.zig").SlidingWindow;

const log = std.log.scoped(.search_screen);

const reloadActive_tw = tripwire.module(enum {
    history_append_new,
    history_append_existing,
}, ScreenSearch.reloadActive);

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

    /// The currently selected match, if any. As the screen contents
    /// change or get pruned, the screen search will do its best to keep
    /// this accurate.
    selected: ?SelectedMatch = null,

    /// The results found so far. These are stored separately because history
    /// is mostly immutable once found, while active area results may
    /// change. This lets us easily reset the active area results for a
    /// re-search scenario.
    history_results: std.ArrayList(FlattenedHighlight),
    active_results: std.ArrayList(FlattenedHighlight),

    /// The dimensions of the screen. When this changes we need to
    /// restart the whole search, currently.
    rows: size.CellCountInt,
    cols: size.CellCountInt,

    pub const SelectedMatch = struct {
        /// Index from the end of the match list (0 = most recent match)
        idx: usize,

        /// Tracked highlight so we can detect movement.
        highlight: TrackedHighlight,

        pub fn deinit(self: *SelectedMatch, screen: *Screen) void {
            self.highlight.deinit(screen);
        }
    };

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

                // Not obvious but complete search states will prune
                // stale history results on feed.
                .complete => true,

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
            .rows = screen.pages.rows,
            .cols = screen.pages.cols,
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
        if (self.selected) |*m| m.deinit(self.screen);
        for (self.active_results.items) |*hl| hl.deinit(alloc);
        self.active_results.deinit(alloc);
        for (self.history_results.items) |*hl| hl.deinit(alloc);
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
    ) Allocator.Error![]FlattenedHighlight {
        const active_results = self.active_results.items;
        const history_results = self.history_results.items;
        const results = try alloc.alloc(
            FlattenedHighlight,
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
        std.mem.reverse(FlattenedHighlight, results[0..active_results.len]);

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
    ///
    /// Feed on a complete screen search will perform some cleanup of
    /// potentially stale history results (pruned) and reclaim some memory.
    pub fn feed(self: *ScreenSearch) Allocator.Error!void {
        // If the screen resizes, we have to reset our entire search. That
        // isn't ideal but we don't have a better way right now to handle
        // reflowing the search results beyond putting a tracked pin for
        // every single result.
        if (self.screen.pages.rows != self.rows or
            self.screen.pages.cols != self.cols)
        {
            // Reinit
            const new: ScreenSearch = try .init(
                self.allocator(),
                self.screen,
                self.needle(),
            );

            // Deinit/reinit
            self.deinit();
            self.* = new;

            // New result should have matching dimensions
            assert(self.screen.pages.rows == self.rows);
            assert(self.screen.pages.cols == self.cols);
        }

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

            // We use this opportunity to also clean up older history
            // results that may be gone due to scrollback pruning, though.
            self.pruneHistory();

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

    fn pruneHistory(self: *ScreenSearch) void {
        // Go through our history results in order (newest to oldest) to find
        // any result that contains an invalid serial. Prune up to that
        // point.
        for (0..self.history_results.items.len) |i| {
            const hl = &self.history_results.items[i];
            const serials = hl.chunks.items(.serial);
            const lowest = serials[0];
            if (lowest < self.screen.pages.page_serial_min) {
                // Everything from here forward we assume is invalid because
                // our history results only get older.
                const alloc = self.allocator();
                for (self.history_results.items[i..]) |*prune_hl| prune_hl.deinit(alloc);
                self.history_results.shrinkAndFree(alloc, i);
                return;
            }
        }
    }

    fn tickActive(self: *ScreenSearch) Allocator.Error!void {
        // For the active area, we consume the entire search in one go
        // because the active area is generally small.
        const alloc = self.allocator();
        while (self.active.next()) |hl| {
            // If this fails, then we miss a result since `active.next()`
            // moves forward and prunes data. In the future, we may want
            // to have some more robust error handling but the only
            // scenario this would fail is OOM and we're probably in
            // deeper trouble at that point anyways.
            var hl_cloned = try hl.clone(alloc);
            errdefer hl_cloned.deinit(alloc);
            try self.active_results.append(alloc, hl_cloned);
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
        while (history.searcher.next()) |hl| {
            // Ignore selections that are found within the starting
            // node since those are covered by the active area search.
            if (hl.chunks.items(.node)[0] == history.start_pin.node) continue;

            // Same note as tickActive for error handling.
            var hl_cloned = try hl.clone(alloc);
            errdefer hl_cloned.deinit(alloc);
            try self.history_results.append(alloc, hl_cloned);

            // Since history only appends to our results in reverse order,
            // we don't need to update any selected match state. The index
            // and prior results are unaffected.
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
        const tw = reloadActive_tw;

        // If our selection pin became garbage it means we scrolled off
        // the end. Clear our selection and on exit of this function,
        // try to select the last match.
        const select_prev: bool = select_prev: {
            const m = if (self.selected) |*m| m else break :select_prev false;
            if (!m.highlight.start.garbage and
                !m.highlight.end.garbage) break :select_prev false;

            m.deinit(self.screen);
            self.selected = null;
            break :select_prev true;
        };
        defer if (select_prev) {
            _ = self.select(.prev) catch |err| {
                log.info("reload failed to reset search selection err={}", .{err});
            };
        };

        const alloc = self.allocator();
        const list: *PageList = &self.screen.pages;
        if (try self.active.update(list)) |history_node| history: {
            // We need to account for any active area growth that would
            // cause new pages to move into our history. If there are new
            // pages then we need to re-search the pages and add it to
            // our history results.

            // If our screen has no scrollback then we have no history.
            if (self.screen.no_scrollback) {
                assert(self.history == null);
                break :history;
            }

            const history_: ?*HistorySearch = if (self.history) |*h| state: {
                // If our start pin became garbage, it means we pruned all
                // the way up through it, so we have no history anymore.
                // Reset our history state.
                if (h.start_pin.garbage) {
                    h.deinit(self.screen);
                    self.history = null;
                    for (self.history_results.items) |*hl| hl.deinit(alloc);
                    self.history_results.clearRetainingCapacity();
                    break :state null;
                }

                break :state h;
            } else null;

            const history = history_ orelse {
                // No history search yet, but we now have history. So let's
                // initialize.

                var search: PageListSearch = try .init(
                    alloc,
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

            var results: std.ArrayList(FlattenedHighlight) = try .initCapacity(
                alloc,
                self.history_results.items.len,
            );
            errdefer {
                for (results.items) |*hl| hl.deinit(alloc);
                results.deinit(alloc);
            }
            while (window.next()) |hl| {
                if (hl.chunks.items(.node)[0] == history_node) continue;

                var hl_cloned = try hl.clone(alloc);
                errdefer hl_cloned.deinit(alloc);
                try tw.check(.history_append_new);
                try results.append(alloc, hl_cloned);
            }

            // If we have no matches then there is nothing to change
            // in our history (fast path)
            if (results.items.len == 0) break :history;

            // The number added to our history. Needed for updating
            // our selection if we have one.
            const added_len = results.items.len;

            // Matches! Reverse our list then append all the remaining
            // history items that didn't start on our original node.
            std.mem.reverse(FlattenedHighlight, results.items);
            try tw.check(.history_append_existing);
            try results.appendSlice(alloc, self.history_results.items);
            self.history_results.deinit(alloc);
            self.history_results = results;

            // If our prior selection was in the history area, update
            // the offset.
            if (self.selected) |*m| selected: {
                const active_len = self.active_results.items.len;
                if (m.idx < active_len) break :selected;
                m.idx += added_len;

                // Moving the idx should not change our targeted result
                // since the history is immutable.
                if (comptime std.debug.runtime_safety) {
                    const hl = self.history_results.items[m.idx - active_len];
                    assert(m.highlight.start.eql(hl.startPin()));
                }
            }
        } else {
            // No history node means we have no history
            if (self.history) |*h| {
                h.deinit(self.screen);
                self.history = null;
                for (self.history_results.items) |*hl| hl.deinit(alloc);
                self.history_results.clearRetainingCapacity();
            }

            // If we have a selection in the history area, we need to
            // move it to the end of the active area.
            if (self.selected) |*m| selected: {
                const active_len = self.active_results.items.len;
                if (m.idx < active_len) break :selected;
                m.deinit(self.screen);
                self.selected = null;
                _ = self.select(.prev) catch |err| {
                    log.info("reload failed to reset search selection err={}", .{err});
                };
            }
        }

        // Figure out if we need to fixup our selection later because
        // it was in the active area.
        const old_active_len = self.active_results.items.len;
        const old_selection_idx: ?usize = if (self.selected) |m| m.idx else null;
        errdefer if (old_selection_idx != null and
            old_selection_idx.? < old_active_len)
        {
            // This is the error scenario. If something fails below,
            // our active area is probably gone, so we just go back
            // to the first result because our selection can't be trusted.
            if (self.selected) |*m| {
                m.deinit(self.screen);
                self.selected = null;
                _ = self.select(.next) catch |err| {
                    log.info("reload failed to reset search selection err={}", .{err});
                };
            }
        };

        // Reset our active search results and search again.
        for (self.active_results.items) |*hl| hl.deinit(alloc);
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

        // If we have no scrollback, we need to prune any active results
        // that aren't in the actual active area. We only do this for the
        // no scrollback scenario because with scrollback we actually
        // rely on our active search searching by page to find history
        // items as well. This is all related to the fact that PageList
        // scrollback limits are discrete by page size except we special
        // case zero.
        if (self.screen.no_scrollback and
            self.active_results.items.len > 0)
        active_prune: {
            const items = self.active_results.items;
            const tl = self.screen.pages.getTopLeft(.active);
            for (0.., items) |i, *hl| {
                if (!tl.before(hl.endPin())) {
                    // Deinit because its going to be pruned no matter
                    // what at some point for not being in the active area.
                    hl.deinit(alloc);
                    continue;
                }

                // In the active area! Since our results are sorted
                // that means everything after this is also in the active
                // area, so we prune up to this i.
                if (i > 0) self.active_results.replaceRangeAssumeCapacity(
                    0,
                    i,
                    &.{},
                );

                break :active_prune;
            }

            // None are in the active area...
            self.active_results.clearRetainingCapacity();
        }

        // Now we have to fixup our selection if we had one.
        fixup: {
            const old_idx = old_selection_idx orelse break :fixup;
            const m = if (self.selected) |*m| m else break :fixup;

            // If our old selection wasn't in the active area, then we
            // need to fix up our offsets.
            if (old_idx >= old_active_len) {
                m.idx -= old_active_len;
                m.idx += self.active_results.items.len;
                break :fixup;
            }

            // We search for the matching highlight in the new active results.
            for (0.., self.active_results.items) |i, hl| {
                const untracked = hl.untracked();
                if (m.highlight.start.eql(untracked.start) and
                    m.highlight.end.eql(untracked.end))
                {
                    // Found it! Update our index.
                    m.idx = self.active_results.items.len - 1 - i;
                    break :fixup;
                }
            }

            // No match, just go back to the first match.
            m.deinit(self.screen);
            self.selected = null;
            _ = self.select(.next) catch |err| {
                log.info("reload failed to reset search selection err={}", .{err});
            };
        }
    }

    /// Return the selected match.
    ///
    /// This does not require read/write access to the underlying screen.
    pub fn selectedMatch(self: *const ScreenSearch) ?FlattenedHighlight {
        const sel = self.selected orelse return null;
        const active_len = self.active_results.items.len;
        if (sel.idx < active_len) {
            return self.active_results.items[active_len - 1 - sel.idx];
        }

        const history_len = self.history_results.items.len;
        if (sel.idx < active_len + history_len) {
            return self.history_results.items[sel.idx - active_len];
        }

        return null;
    }

    pub const Select = enum {
        /// Next selection, in reverse order (newest to oldest),
        /// non-wrapping.
        next,

        /// Prev selection, in forward order (oldest to newest),
        /// non-wrapping.
        prev,
    };

    /// Select the next or previous search result. This requires read/write
    /// access to the underlying screen, since we utilize tracked pins to
    /// ensure our selection sticks with contents changing.
    pub fn select(self: *ScreenSearch, to: Select) Allocator.Error!bool {
        // All selection requires valid pins so we prune history and
        // reload our active area immediately. This ensures all search
        // results point to valid nodes.
        try self.reloadActive();
        self.pruneHistory();

        return switch (to) {
            .next => try self.selectNext(),
            .prev => try self.selectPrev(),
        };
    }

    fn selectNext(self: *ScreenSearch) Allocator.Error!bool {
        // Get our previous match so we can change it. If we have no
        // prior match, we have the easy task of getting the first.
        var prev = if (self.selected) |*m| m else {
            // Get our highlight
            const hl: FlattenedHighlight = hl: {
                if (self.active_results.items.len > 0) {
                    // Active is in forward order
                    const len = self.active_results.items.len;
                    break :hl self.active_results.items[len - 1];
                } else if (self.history_results.items.len > 0) {
                    // History is in reverse order
                    break :hl self.history_results.items[0];
                } else {
                    // No matches at all. Can't select anything.
                    return false;
                }
            };

            // Pin it so we can track any movement
            const tracked = try hl.untracked().track(self.screen);
            errdefer tracked.deinit(self.screen);

            // Our selection is index zero since we just started and
            // we store our selection.
            self.selected = .{
                .idx = 0,
                .highlight = tracked,
            };
            return true;
        };

        const next_idx = prev.idx + 1;
        const active_len = self.active_results.items.len;
        const history_len = self.history_results.items.len;
        if (next_idx >= active_len + history_len) {
            // No more matches. We don't wrap or reset the match currently.
            return false;
        }
        const hl: FlattenedHighlight = if (next_idx < active_len)
            self.active_results.items[active_len - 1 - next_idx]
        else
            self.history_results.items[next_idx - active_len];

        // Pin it so we can track any movement
        const tracked = try hl.untracked().track(self.screen);
        errdefer tracked.deinit(self.screen);

        // Free our previous match and setup our new selection
        prev.deinit(self.screen);
        self.selected = .{
            .idx = next_idx,
            .highlight = tracked,
        };

        return true;
    }

    fn selectPrev(self: *ScreenSearch) Allocator.Error!bool {
        // Get our previous match so we can change it. If we have no
        // prior match, we have the easy task of getting the last.
        var prev = if (self.selected) |*m| m else {
            // Get our highlight (oldest match)
            const hl: FlattenedHighlight = hl: {
                if (self.history_results.items.len > 0) {
                    // History is in reverse order, so last item is oldest
                    const len = self.history_results.items.len;
                    break :hl self.history_results.items[len - 1];
                } else if (self.active_results.items.len > 0) {
                    // Active is in forward order, so first item is oldest
                    break :hl self.active_results.items[0];
                } else {
                    // No matches at all. Can't select anything.
                    return false;
                }
            };

            // Pin it so we can track any movement
            const tracked = try hl.untracked().track(self.screen);
            errdefer tracked.deinit(self.screen);

            // Our selection is the last index since we just started
            // and we store our selection.
            const active_len = self.active_results.items.len;
            const history_len = self.history_results.items.len;
            self.selected = .{
                .idx = active_len + history_len - 1,
                .highlight = tracked,
            };
            return true;
        };

        // Can't go below zero
        if (prev.idx == 0) {
            // No more matches. We don't wrap or reset the match currently.
            return false;
        }

        const next_idx = prev.idx - 1;
        const active_len = self.active_results.items.len;
        const hl: FlattenedHighlight = if (next_idx < active_len)
            self.active_results.items[active_len - 1 - next_idx]
        else
            self.history_results.items[next_idx - active_len];

        // Pin it so we can track any movement
        const tracked = try hl.untracked().track(self.screen);
        errdefer tracked.deinit(self.screen);

        // Free our previous match and setup our new selection
        prev.deinit(self.screen);
        self.selected = .{
            .idx = next_idx,
            .highlight = tracked,
        };

        return true;
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
        const sel = matches[0].untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }
    {
        const sel = matches[1].untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
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
        const sel = matches[0].untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
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
            const sel = matches[1].untracked();
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 0,
                .y = 0,
            } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 3,
                .y = 0,
            } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
        }
        {
            const sel = matches[0].untracked();
            try testing.expectEqual(point.Point{ .active = .{
                .x = 1,
                .y = 1,
            } }, t.screens.active.pages.pointFromPin(.active, sel.start).?);
            try testing.expectEqual(point.Point{ .active = .{
                .x = 4,
                .y = 1,
            } }, t.screens.active.pages.pointFromPin(.active, sel.end).?);
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
            const sel = matches[0].untracked();
            try testing.expectEqual(point.Point{ .active = .{
                .x = 2,
                .y = 0,
            } }, t.screens.active.pages.pointFromPin(.active, sel.start).?);
            try testing.expectEqual(point.Point{ .active = .{
                .x = 5,
                .y = 0,
            } }, t.screens.active.pages.pointFromPin(.active, sel.end).?);
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
        const sel = matches[0].untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 1,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }
}

test "select next" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{ .cols = 10, .rows = 2 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice("Fizz\r\nBuzz\r\nFizz\r\nBang");

    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();

    // Initially no selection
    try testing.expect(search.selectedMatch() == null);

    // Select our next match (first)
    try search.searchAll();
    _ = try search.select(.next);
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }

    // Next match
    _ = try search.select(.next);
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }

    // Next match (no wrap)
    _ = try search.select(.next);
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }
}

test "select in active changes contents completely" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice("Fizz\r\nBuzz\r\nFizz\r\nBang");

    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();
    _ = try search.select(.next);
    _ = try search.select(.next);
    {
        // Initial selection is the first fizz
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }

    // Erase the screen, move our cursor to the top, and change contents.
    try s.nextSlice("\x1b[2J\x1b[H"); // Clear screen and move home
    try s.nextSlice("Fuzz\r\nFizz\r\nHello!");

    try search.reloadActive();
    {
        // Our selection should move to the first
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 1,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }

    // Erase the screen, redraw with same contents.
    try s.nextSlice("\x1b[2J\x1b[H"); // Clear screen and move home
    try s.nextSlice("Fuzz\r\nFizz\r\nFizz");

    try search.reloadActive();
    {
        // Our selection should not move to the first
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 1,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }
}

test "select into history" {
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

    // Get all matches
    _ = try search.select(.next);
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }

    // Erase the screen, redraw with same contents.
    try s.nextSlice("\x1b[2J\x1b[H"); // Clear screen and move home
    try s.nextSlice("yo yo");

    try search.reloadActive();
    {
        // Our selection should not move since the history is still active.
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }

    // Create some new history by adding more lines.
    try s.nextSlice("\r\nfizz\r\nfizz\r\nfizz"); // Clear screen and move home
    try search.reloadActive();
    {
        // Our selection should not move since the history is still not
        // pruned.
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }
}

test "select prev" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{ .cols = 10, .rows = 2 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice("Fizz\r\nBuzz\r\nFizz\r\nBang");

    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();

    // Initially no selection
    try testing.expect(search.selectedMatch() == null);

    // Select prev (oldest first)
    try search.searchAll();
    _ = try search.select(.prev);
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }

    // Prev match (towards newest)
    _ = try search.select(.prev);
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }

    // Prev match (no wrap, stays at newest)
    _ = try search.select(.prev);
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }
}

test "select prev then next" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{ .cols = 10, .rows = 2 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice("Fizz\r\nBuzz\r\nFizz\r\nBang");

    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();

    // Select next (newest first)
    _ = try search.select(.next);
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
    }

    // Select next (older)
    _ = try search.select(.next);
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
    }

    // Select prev (back to newer)
    _ = try search.select(.prev);
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
    }
}

test "select prev with history" {
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
    try s.nextSlice("Fizz.");

    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();

    // Select prev (oldest first, should be in history)
    _ = try search.select(.prev);
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }

    // Select prev (towards newer, should move to active area)
    _ = try search.select(.prev);
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 1,
        } }, t.screens.active.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 3,
            .y = 1,
        } }, t.screens.active.pages.pointFromPin(.active, sel.end).?);
    }
}

test "screen search no scrollback has no history" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback = 0,
    });
    defer t.deinit(alloc);

    // Alt screen has no scrollback
    _ = try t.switchScreen(.alternate);

    var s = t.vtStream();
    defer s.deinit();

    // This will probably stop working at some point and we'll have
    // no way to test it using public APIs, but at the time of writing
    // this test, CSI 22 J (scroll complete) pushes into scrollback
    // with alt screen.
    try s.nextSlice("Fizz\r\n");
    try s.nextSlice("\x1b[22J");
    try s.nextSlice("hello.");

    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();
    try testing.expectEqual(0, search.active_results.items.len);

    // Get all matches
    const matches = try search.matches(alloc);
    defer alloc.free(matches);
    try testing.expectEqual(0, matches.len);
}

test "reloadActive partial history cleanup on appendSlice error" {
    // This test verifies that when reloadActive fails at appendSlice (after
    // the loop), all FlattenedHighlight items are properly cleaned up.
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

    // Write multiple "Fizz" matches that will end up in history.
    // We need enough content to push "Fizz" entries into scrollback.
    try s.nextSlice("Fizz\r\nFizz\r\n");
    while (list.totalPages() < 3) try s.nextSlice("\r\n");
    for (0..list.rows) |_| try s.nextSlice("\r\n");
    try s.nextSlice("Fizz.");

    // Complete initial search
    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();

    // Now trigger reloadActive by adding more content that changes the
    // active/history boundary. First add more "Fizz" entries to history.
    try s.nextSlice("\r\nFizz\r\nFizz\r\n");
    while (list.totalPages() < 4) try s.nextSlice("\r\n");
    for (0..list.rows) |_| try s.nextSlice("\r\n");

    // Arm the tripwire to fail at appendSlice (after the loop completes).
    // At this point, there are FlattenedHighlight items in the results list
    // that need cleanup.
    const tw = reloadActive_tw;
    defer tw.end(.reset) catch unreachable;
    tw.errorAlways(.history_append_existing, error.OutOfMemory);

    // reloadActive is called by select(), which should trigger the error path.
    // If the bug exists, testing.allocator will report a memory leak
    // because FlattenedHighlight items weren't cleaned up.
    try testing.expectError(error.OutOfMemory, search.select(.next));
}

test "reloadActive partial history cleanup on loop append error" {
    // This test verifies that when reloadActive fails inside the loop
    // (after some items have been appended), all FlattenedHighlight items
    // are properly cleaned up.
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

    // Write multiple "Fizz" matches that will end up in history.
    // We need enough content to push "Fizz" entries into scrollback.
    try s.nextSlice("Fizz\r\nFizz\r\n");
    while (list.totalPages() < 3) try s.nextSlice("\r\n");
    for (0..list.rows) |_| try s.nextSlice("\r\n");
    try s.nextSlice("Fizz.");

    // Complete initial search
    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();

    // Now trigger reloadActive by adding more content that changes the
    // active/history boundary. First add more "Fizz" entries to history.
    try s.nextSlice("\r\nFizz\r\nFizz\r\n");
    while (list.totalPages() < 4) try s.nextSlice("\r\n");
    for (0..list.rows) |_| try s.nextSlice("\r\n");

    // Arm the tripwire to fail after the first loop append succeeds.
    // This leaves at least one FlattenedHighlight in the results list
    // that needs cleanup.
    const tw = reloadActive_tw;
    defer tw.end(.reset) catch unreachable;
    tw.errorAfter(.history_append_new, error.OutOfMemory, 1);

    // reloadActive is called by select(), which should trigger the error path.
    // If the bug exists, testing.allocator will report a memory leak
    // because FlattenedHighlight items weren't cleaned up.
    try testing.expectError(error.OutOfMemory, search.select(.next));
}
