const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const point = @import("../point.zig");
const FlattenedHighlight = @import("../highlight.zig").Flattened;
const ScreenSet = @import("../ScreenSet.zig");
const Terminal = @import("../Terminal.zig");

const ScreenSearch = @import("screen.zig").ScreenSearch;
const ViewportSearch = @import("viewport.zig").ViewportSearch;

const log = std.log.scoped(.search_terminal);

/// Searches for a needle within an entire Terminal, orchestrating a
/// ScreenSearch per live screen plus a viewport search for the active
/// screen.
///
/// This reconciles per-screen searchers against the terminal's active
/// ScreenSet, retains results across primary/alt screen switches, and
/// recovers from resize/reflow, resets, scrollback pruning, etc.
///
/// The main ownership contract is that this is safe to call concurrently
/// with Terminal IO as long as you're not calling a function that takes
/// a terminal as an argument. Each function has more specific details about
/// its behavior.
pub const TerminalSearch = struct {
    /// Allocator used for all search state.
    alloc: Allocator,

    /// Active viewport search for the active screen.
    viewport: ViewportSearch,

    /// The searchers for all the screens.
    screens: std.EnumMap(ScreenSet.Key, ScreenSearch),

    /// ScreenSet generations captured when each searcher was initialized.
    /// Allocators may reuse a destroyed Screen address, so pointer equality
    /// alone cannot distinguish replacement screens from stale handles.
    screen_generations: std.EnumMap(ScreenSet.Key, usize),

    /// The active screen key as of the last feed. All single-screen
    /// reads (total matches, selection, etc.) resolve against this.
    active_key: ScreenSet.Key,

    /// True when the cached viewport matches are stale and must be
    /// recollected from the viewport searcher on the next
    /// `viewportMatches` call.
    stale_viewport_matches: bool,

    /// Cached viewport matches. The viewport search's sliding window
    /// drains on read, so results are collected once per viewport
    /// change and cached here.
    viewport_matches: std.ArrayList(FlattenedHighlight),

    /// Overall status of the search. See `status`.
    pub const Status = enum {
        /// `tick` can make progress without terminal access.
        running,

        /// Blocked until the next `feed`. This is also the initial
        /// state, since a search that has never been fed has never
        /// seen the terminal.
        feed_required,

        /// Caught up with the terminal state as of the last feed.
        complete,
    };

    /// Viewport scroll behavior applied by `select` when a match
    /// becomes selected.
    pub const SelectScroll = enum {
        /// Scroll so the match is visible, only if it is not already.
        if_needed,

        /// Never scroll.
        none,
    };

    /// Initialize a search for the given needle. The needle is copied.
    ///
    /// This doesn't read any terminal state. The first `feed` does.
    pub fn init(
        alloc: Allocator,
        needle_unowned: []const u8,
    ) Allocator.Error!TerminalSearch {
        var vp: ViewportSearch = try .init(alloc, needle_unowned);
        errdefer vp.deinit();

        // We use dirty tracking for active area changes. Start with it
        // dirty so the first change is re-searched.
        vp.active_dirty = true;

        return .{
            .alloc = alloc,
            .viewport = vp,
            .screens = .init(.{}),
            .screen_generations = .init(.{}),
            .active_key = .primary,
            .stale_viewport_matches = true,
            .viewport_matches = .empty,
        };
    }

    /// Release all state. The terminal must be the same one given to
    /// every other call, or null if the terminal has already been
    /// deinitialized. When the terminal is alive this releases tracked
    /// pins held within it. When it is null, those pins died with the
    /// terminal's page storage, so only search-owned memory is freed.
    pub fn deinit(self: *TerminalSearch, t_: ?*Terminal) void {
        self.clearViewportMatches();
        self.viewport_matches.deinit(self.alloc);
        self.viewport.deinit();
        var it = self.screens.iterator();
        while (it.next()) |entry| {
            const valid = if (t_) |t| self.screenIsValid(
                &t.screens,
                entry.key,
                entry.value,
            ) else false;
            if (valid) {
                entry.value.deinit();
            } else {
                entry.value.deinitScreenInvalid();
            }
        }
    }

    fn screenIsValid(
        self: *const TerminalSearch,
        screens: *const ScreenSet,
        key: ScreenSet.Key,
        search: *const ScreenSearch,
    ) bool {
        const generation = self.screen_generations.get(key) orelse return false;
        if (generation != screens.generation(key)) return false;
        const actual = screens.get(key) orelse return false;
        return actual == search.screen;
    }

    /// The needle that this search is using, borrowed.
    pub fn needle(self: *const TerminalSearch) []const u8 {
        return self.viewport.needle();
    }

    /// The searcher for the active screen as of the last feed. Null if
    /// the search has never been fed (or the screen failed to
    /// initialize).
    pub fn activeScreenSearch(self: *TerminalSearch) ?*ScreenSearch {
        return self.screens.getPtr(self.active_key);
    }

    /// Returns true if all searches on all screens are complete.
    pub fn isComplete(self: *TerminalSearch) bool {
        var it = self.screens.iterator();
        while (it.next()) |entry| {
            if (!entry.value.state.isComplete()) return false;
        }

        return true;
    }

    /// The overall search status derived from the per-screen search
    /// states.
    ///
    /// Unlike `isComplete`, a search that has never been fed reports
    /// `feed_required` rather than `complete`. An empty screen map
    /// means the search has never seen the terminal, so reporting it
    /// as complete would be technically true but useless to a caller
    /// deciding what to do next.
    pub fn status(self: *TerminalSearch) Status {
        var saw_any = false;
        var result: Status = .complete;
        var it = self.screens.iterator();
        while (it.next()) |entry| {
            saw_any = true;
            switch (entry.value.state) {
                // Progress is possible without a feed.
                .active, .history => return .running,

                // Blocked until fed.
                .history_feed => result = .feed_required,

                .complete => {},
            }
        }

        if (!saw_any) return .feed_required;
        return result;
    }

    pub const Tick = enum {
        /// All searches are complete.
        complete,

        /// Progress was made on at least one screen.
        progress,

        /// All incomplete searches are blocked on feed.
        blocked,
    };

    /// Tick the search forward as much as possible without reading
    /// any terminal state, so this is safe to call concurrently with
    /// terminal IO. Returns the overall tick progress.
    pub fn tick(self: *TerminalSearch) Tick {
        var result: Tick = .complete;
        var it = self.screens.iterator();
        while (it.next()) |entry| {
            if (entry.value.tick()) {
                result = .progress;
            } else |err| switch (err) {
                // Ignore... nothing we can do.
                error.OutOfMemory => log.warn(
                    "error ticking screen search key={} err={}",
                    .{ entry.key, err },
                ),

                // Ignore, good for us. State remains whatever it is.
                error.SearchComplete => {},

                // Ignore, too, progressed
                error.FeedRequired => switch (result) {
                    // If we think we're complete, we're not because we're
                    // blocked now (nothing made progress).
                    .complete => result = .blocked,

                    // If we made some progress, we remain in progress
                    // since blocked means no progress at all.
                    .progress => {},

                    // If we're blocked already then we remain blocked.
                    .blocked => {},
                },
            }
        }

        return result;
    }

    /// Read the terminal to update any search state that requires it,
    /// such as reconciling screens, feeding more data to the
    /// searchers, and detecting viewport changes.
    ///
    /// This reads the terminal, so the caller must ensure the terminal
    /// isn't modified for the duration of this call (e.g. by holding a
    /// lock). Feeding is also the only way the search learns about
    /// terminal changes, so callers should feed periodically while a
    /// search is in use, even after it reports complete.
    ///
    /// `active_dirty` should be true when the active area may have
    /// changed since the last feed, which triggers a re-scan of the
    /// active area. Callers that know when the active area changes
    /// (e.g. Ghostty's renderer-maintained dirty flag) can pass false
    /// to skip the re-scan. Callers without that knowledge should
    /// always pass true. That is always correct, just slightly more
    /// work, and the active area search is cheap by design.
    pub fn feed(
        self: *TerminalSearch,
        t: *Terminal,
        active_dirty: bool,
    ) void {
        const alloc = self.alloc;

        // Update our active screen
        if (t.screens.active_key != self.active_key) {
            self.active_key = t.screens.active_key;
        }

        // Reconcile our screens with the terminal screens. Remove
        // searchers for screens that no longer exist and add searchers
        // for screens that do exist but we don't have yet.
        {
            // Remove screens we have that no longer exist or changed.
            var it = self.screens.iterator();
            while (it.next()) |entry| {
                const remove = !self.screenIsValid(
                    &t.screens,
                    entry.key,
                    entry.value,
                );

                if (remove) {
                    entry.value.deinitScreenInvalid();
                    _ = self.screens.remove(entry.key);
                    _ = self.screen_generations.remove(entry.key);
                }
            }
        }
        {
            // Add screens that exist but we don't have yet.
            var it = t.screens.all.iterator();
            while (it.next()) |entry| {
                if (self.screens.contains(entry.key)) continue;
                const screen_search = ScreenSearch.init(
                    alloc,
                    entry.value.*,
                    self.viewport.needle(),
                ) catch |err| switch (err) {
                    error.OutOfMemory => {
                        // OOM is probably going to sink the entire ship but
                        // we can just ignore it and wait on the next
                        // reconciliation to try again.
                        log.warn(
                            "error initializing screen search for key={} err={}",
                            .{ entry.key, err },
                        );
                        continue;
                    },
                };
                self.screens.put(entry.key, screen_search);
                self.screen_generations.put(
                    entry.key,
                    t.screens.generation(entry.key),
                );
            }
        }

        // The caller told us the active area may have changed, so mark
        // our viewport searcher dirty (forcing a re-search) and reload
        // the active area for the active screen.
        if (active_dirty) {
            // Mark our viewport dirty so it researches the active
            self.viewport.active_dirty = true;

            // Reload our active area for our active screen
            if (self.screens.getPtr(t.screens.active_key)) |screen_search| {
                screen_search.reloadActive() catch |err| switch (err) {
                    error.OutOfMemory => log.warn(
                        "error reloading active area for screen key={} err={}",
                        .{ t.screens.active_key, err },
                    ),
                };
            }
        }

        // Check our viewport for changes.
        if (self.viewport.update(&t.screens.active.pages)) |updated| {
            if (updated) self.stale_viewport_matches = true;
        } else |err| switch (err) {
            error.OutOfMemory => log.warn(
                "error updating viewport search err={}",
                .{err},
            ),
        }

        // Feed data
        var it = self.screens.iterator();
        while (it.next()) |entry| {
            if (entry.value.state.needsFeed()) {
                entry.value.feed() catch |err| switch (err) {
                    error.OutOfMemory => log.warn(
                        "error feeding screen search key={} err={}",
                        .{ entry.key, err },
                    ),
                };
            }
        }
    }

    /// Return the matches on the pages covering the viewport, as of
    /// the last feed. Note this can include matches slightly outside
    /// the visible viewport when they share a page with it.
    ///
    /// The results are cached, since the underlying viewport search
    /// drains as it is read. Matches are collected once after a feed
    /// notices a viewport change and the cached results are returned
    /// otherwise. The returned slice is owned by the search and valid
    /// until the next call to this function, the next feed, or deinit.
    ///
    /// This doesn't read any terminal state, so it is safe to call
    /// concurrently with terminal IO.
    pub fn viewportMatches(
        self: *TerminalSearch,
    ) Allocator.Error![]const FlattenedHighlight {
        if (!self.stale_viewport_matches) return self.viewport_matches.items;

        // We always mark the cache fresh, even if collection fails
        // below: a failed collection isn't retried until the next feed
        // marks the cache stale again.
        self.stale_viewport_matches = false;

        self.clearViewportMatches();
        errdefer {
            self.clearViewportMatches();

            // Reset the viewport so we force an update (and therefore a
            // re-collection) on the next feed.
            self.viewport.reset();
        }
        while (self.viewport.next()) |hl| {
            var hl_cloned = try hl.clone(self.alloc);
            errdefer hl_cloned.deinit(self.alloc);
            try self.viewport_matches.append(self.alloc, hl_cloned);
        }

        return self.viewport_matches.items;
    }

    fn clearViewportMatches(self: *TerminalSearch) void {
        for (self.viewport_matches.items) |*hl| hl.deinit(self.alloc);
        self.viewport_matches.clearRetainingCapacity();
    }

    /// Select the next or previous search result on the active screen,
    /// wrapping around at the ends, and optionally scrolling the
    /// viewport so the newly selected match is visible.
    ///
    /// This feeds first so the selection always works against current
    /// terminal state, making it safe to call at any time relative to
    /// feeds. Like `feed`, this reads (and possibly scrolls) the
    /// terminal, so the caller must ensure the terminal isn't
    /// otherwise being used for the duration of this call.
    ///
    /// Returns true if a match is selected after the operation, or
    /// false if there are no matches to select.
    pub fn select(
        self: *TerminalSearch,
        t: *Terminal,
        to: ScreenSearch.Select,
        scroll: SelectScroll,
    ) Allocator.Error!bool {
        // A screen can be removed or replaced between feeds. Reconcile
        // while holding the terminal lock before touching any
        // ScreenSearch pins.
        self.feed(t, false);
        const screen_search = self.screens.getPtr(self.active_key) orelse
            return false;

        // Make the selection. Ignore the result because we don't
        // care if the selection didn't change.
        _ = try screen_search.select(to);

        // Grab our match if we have one. If we don't have a selection
        // then there was nothing to select.
        const flattened = screen_search.selectedMatch() orelse return false;

        switch (scroll) {
            .none => return true,
            .if_needed => {},
        }

        // Grab the current screen and see if this match is visible within
        // the viewport already. If it is, we do nothing.
        const screen = t.screens.get(self.active_key) orelse return true;

        // Grab the viewport. Viewports and selections are usually small
        // so this check isn't very expensive, despite appearing O(N^2),
        // both Ns are usually equal to 1.
        var it = screen.pages.pageIterator(
            .right_down,
            .{ .viewport = .{} },
            null,
        );
        const hl_chunks = flattened.chunks.slice();
        while (it.next()) |chunk| {
            for (0..hl_chunks.len) |i| {
                const hl_chunk = hl_chunks.get(i);
                if (chunk.overlaps(.{
                    .node = hl_chunk.node,
                    .start = hl_chunk.start,
                    .end = hl_chunk.end,
                })) return true;
            }
        }

        screen.scroll(.{ .pin = flattened.startPin() });
        return true;
    }
};

test "starts feed required and runs to complete" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{ .cols = 10, .rows = 2 });
    defer t.deinit(alloc);

    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("Fizz\r\nBuzz\r\nFizz\r\nBang");

    var search: TerminalSearch = try .init(alloc, "Fizz");
    defer search.deinit(&t);

    // A fresh search has never seen the terminal, so it must report
    // feed_required even though isComplete() is trivially true.
    try testing.expect(search.isComplete());
    try testing.expectEqual(TerminalSearch.Status.feed_required, search.status());

    // Pump until complete.
    while (search.status() != .complete) {
        switch (search.status()) {
            .feed_required => search.feed(&t, true),
            .running => _ = search.tick(),
            .complete => unreachable,
        }
    }

    const screen_search = search.activeScreenSearch().?;
    try testing.expectEqual(2, screen_search.matchesLen());
}

test "viewport matches are cached until the next feed" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("Fizz\r\nBuzz\r\nFizz\r\nBang");

    var search: TerminalSearch = try .init(alloc, "Fizz");
    defer search.deinit(&t);
    search.feed(&t, true);

    // The sliding window drains on read, so a second read must return
    // the cached results rather than an empty list.
    try testing.expectEqual(2, (try search.viewportMatches()).len);
    try testing.expectEqual(2, (try search.viewportMatches()).len);

    // A feed that observes a change refreshes the cache.
    stream.nextSlice("\r\nFizz");
    search.feed(&t, true);
    try testing.expectEqual(3, (try search.viewportMatches()).len);
}

test "select after active screen removal" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{ .cols = 20, .rows = 2 });
    defer t.deinit(alloc);

    _ = try t.switchScreen(.alternate);

    var search: TerminalSearch = try .init(alloc, "needle");
    defer search.deinit(&t);
    search.feed(&t, false);
    try testing.expectEqual(ScreenSet.Key.alternate, search.active_key);
    try testing.expect(search.screens.contains(.alternate));

    _ = try t.switchScreen(.primary);
    t.screens.remove(alloc, .alternate);

    // The select must reconcile against the live ScreenSet before
    // touching any pins from the removed screen.
    _ = try search.select(&t, .next, .if_needed);
    try testing.expectEqual(ScreenSet.Key.primary, search.active_key);
    try testing.expect(!search.screens.contains(.alternate));
}

test "select scrolls the viewport only when needed" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback_bytes = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);

    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("Fizz\r\n");
    for (0..30) |_| stream.nextSlice("\r\n");
    stream.nextSlice("Fizz");

    var search: TerminalSearch = try .init(alloc, "Fizz");
    defer search.deinit(&t);
    while (search.status() != .complete) {
        switch (search.status()) {
            .feed_required => search.feed(&t, true),
            .running => _ = search.tick(),
            .complete => unreachable,
        }
    }

    // Whether the selected match is within the visible viewport rows.
    // pointFromPin only bounds-checks the top of the region, so rows
    // below the viewport must be rejected by the row count.
    const Visible = struct {
        fn check(term: *Terminal, s: *TerminalSearch) bool {
            const pin = s.activeScreenSearch().?.selectedMatch().?.startPin();
            const pages = &term.screens.active.pages;
            const pt = pages.pointFromPin(.viewport, pin) orelse return false;
            return pt.viewport.y < pages.rows;
        }
    };

    // First match is at the bottom which is already visible: no scroll.
    try testing.expect(try search.select(&t, .next, .if_needed));
    try testing.expectEqual(
        point.Point{ .active = .{ .x = 0, .y = 1 } },
        t.screens.active.pages.pointFromPin(
            .active,
            search.activeScreenSearch().?.selectedMatch().?.startPin(),
        ).?,
    );
    try testing.expect(Visible.check(&t, &search));

    // Second match is in scrollback: selecting it must scroll the
    // viewport so it becomes visible.
    try testing.expect(try search.select(&t, .next, .if_needed));
    try testing.expect(Visible.check(&t, &search));

    // With scrolling disabled the viewport must stay where it is even
    // though the next selection (wrap back to the bottom) is not
    // visible.
    try testing.expect(try search.select(&t, .next, .none));
    try testing.expect(!Visible.check(&t, &search));
}

test "deinit after the terminal is gone" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback_bytes = std.math.maxInt(usize),
    });

    var stream = t.vtStream();
    stream.nextSlice("Fizz\r\nBuzz\r\nFizz");

    // Run to complete and select a match so the search holds tracked
    // pins within the terminal's page storage.
    var search: TerminalSearch = try .init(alloc, "Fizz");
    while (search.status() != .complete) {
        switch (search.status()) {
            .feed_required => search.feed(&t, true),
            .running => _ = search.tick(),
            .complete => unreachable,
        }
    }
    try testing.expect(try search.select(&t, .next, .none));

    // Deinitialize the terminal first. The pins died with the page
    // storage, so deinit with a null terminal must free only
    // search-owned memory without touching the terminal.
    stream.deinit();
    t.deinit(alloc);
    search.deinit(null);
}

test "no matches selects nothing" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{ .cols = 10, .rows = 2 });
    defer t.deinit(alloc);

    var search: TerminalSearch = try .init(alloc, "Fizz");
    defer search.deinit(&t);
    search.feed(&t, true);
    try testing.expect(!try search.select(&t, .next, .if_needed));
    try testing.expect(!try search.select(&t, .prev, .if_needed));
}

test "feed after complete discovers prepended snapshot history" {
    const alloc = testing.allocator;
    const io = testing.io;
    const snapshot = @import("../snapshot/main.zig");

    // A source terminal with several pages of scrollback where every line
    // is a match, so the expected total is simply the number of lines.
    var source: Terminal = try .init(io, alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback_bytes = std.math.maxInt(usize),
    });
    defer source.deinit(alloc);
    var needle_count: usize = 0;
    {
        var stream = source.vtStream();
        defer stream.deinit();
        const list = &source.screens.active.pages;
        while (list.totalPages() < 4) : (needle_count += 1) {
            stream.nextSlice("needle\r\n");
        }
    }

    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try snapshot.encode(alloc, &encoded.writer, &source, .{
        .continuation = .ground,
    });

    // Restore only through READY. The terminal is usable while its history
    // pages are still in flight.
    var reader: std.Io.Reader = .fixed(encoded.written());
    var decoder: snapshot.Decoder = .init(&reader);
    var decoded = try decoder.ready(alloc, io, .{
        .max_continuation_bytes = 0,
    });
    defer decoded.deinit(alloc);
    var t = decoded.toOwned();
    defer t.deinit(alloc);
    const pages_at_ready = t.screens.active.pages.totalPages();

    const Pump = struct {
        fn run(search: *TerminalSearch, term: *Terminal) void {
            while (search.status() != .complete) {
                switch (search.status()) {
                    .feed_required => search.feed(term, true),
                    .running => _ = search.tick(),
                    .complete => unreachable,
                }
            }
        }
    };

    // Search the READY state to completion and select the oldest match.
    var search: TerminalSearch = try .init(alloc, "needle");
    defer search.deinit(&t);
    Pump.run(&search, &t);
    const partial = search.activeScreenSearch().?.matchesLen();
    try testing.expect(partial > 0);
    try testing.expect(partial < needle_count);
    try testing.expect(try search.select(&t, .prev, .none));
    const selected_idx = search.activeScreenSearch().?.selected.?.idx;
    try testing.expectEqual(partial - 1, selected_idx);
    const selected_before = search.activeScreenSearch().?.selectedMatch().?.untracked();

    // Restore every history page below the live terminal.
    var restored_pages: usize = 0;
    while (try decoder.next(alloc, &t)) |progress| : (restored_pages += 1) {
        try testing.expect(progress.rows > 0);
    }
    try testing.expect(restored_pages > 0);
    try testing.expectEqual(
        pages_at_ready + restored_pages,
        t.screens.active.pages.totalPages(),
    );

    // Refresh the existing search the way ghostty_search_run does: feed,
    // then tick to completion. It must now cover the restored history.
    search.feed(&t, true);
    Pump.run(&search, &t);
    const screen_search = search.activeScreenSearch().?;
    try testing.expectEqual(needle_count, screen_search.matchesLen());

    // Restored results are older than everything already cached, so the
    // selection keeps both its index and its target.
    try testing.expectEqual(selected_idx, screen_search.selected.?.idx);
    const selected_after = screen_search.selectedMatch().?.untracked();
    try testing.expect(selected_before.start.eql(selected_after.start));
    try testing.expect(selected_before.end.eql(selected_after.end));

    // Results stay ordered newest to oldest, ending at the very first line.
    const matches = try screen_search.matches(alloc);
    defer alloc.free(matches);
    const pages = &t.screens.active.pages;
    var prev_y: ?usize = null;
    for (matches) |hl| {
        const pt = pages.pointFromPin(.screen, hl.startPin()).?;
        if (prev_y) |y| try testing.expect(pt.screen.y < y);
        prev_y = pt.screen.y;
    }
    try testing.expectEqual(0, prev_y.?);

    // A search created after the restore agrees with the refreshed one.
    var fresh: TerminalSearch = try .init(alloc, "needle");
    defer fresh.deinit(&t);
    Pump.run(&fresh, &t);
    try testing.expectEqual(
        needle_count,
        fresh.activeScreenSearch().?.matchesLen(),
    );
}
