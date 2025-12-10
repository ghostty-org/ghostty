//! Search thread that handles searching a terminal for a string match.
//! This is expected to run on a dedicated thread to try to prevent too much
//! overhead to other terminal read/write operations.
//!
//! The current architecture of search does acquire global locks for accessing
//! terminal data, so there's still added contention, but we do our best to
//! minimize this by trading off memory usage (copying data to minimize lock
//! time).
pub const Thread = @This();

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Mutex = std.Thread.Mutex;
const xev = @import("../../global.zig").xev;
const internal_os = @import("../../os/main.zig");
const BlockingQueue = @import("../../datastruct/main.zig").BlockingQueue;
const MessageData = @import("../../datastruct/main.zig").MessageData;
const point = @import("../point.zig");
const FlattenedHighlight = @import("../highlight.zig").Flattened;
const UntrackedHighlight = @import("../highlight.zig").Untracked;
const ScreenSet = @import("../ScreenSet.zig");
const Selection = @import("../Selection.zig");
const Terminal = @import("../Terminal.zig");

const ScreenSearch = @import("screen.zig").ScreenSearch;
const ViewportSearch = @import("viewport.zig").ViewportSearch;

const log = std.log.scoped(.search_thread);

// TODO: Some stuff that could be improved:
// - pause the refresh timer when the terminal isn't focused
// - we probably want to know our progress through the search
//   for viewport matches so we can show n/total UI.
// - notifications should be coalesced to avoid spamming a massive
//   amount of events if the terminal is changing rapidly.

/// The interval at which we refresh the terminal state to check if
/// there are any changes that require us to re-search. This should be
/// balanced to be fast enough to be responsive but not so fast that
/// we hold the terminal lock too often.
const REFRESH_INTERVAL = 24; // 40 FPS

/// Allocator used for some state
alloc: std.mem.Allocator,

/// The mailbox that can be used to send this thread messages. Note
/// this is a blocking queue so if it is full you will get errors (or block).
mailbox: *Mailbox,

/// The event loop for the search thread.
loop: xev.Loop,

/// This can be used to wake up the renderer and force a render safely from
/// any thread.
wakeup: xev.Async,
wakeup_c: xev.Completion = .{},

/// This can be used to stop the thread on the next loop iteration.
stop: xev.Async,
stop_c: xev.Completion = .{},

/// The timer used for refreshing the terminal state to determine if
/// we have a stale active area, viewport, screen change, etc. This is
/// CPU intensive so we stop doing this under certain conditions.
refresh: xev.Timer,
refresh_c: xev.Completion = .{},
refresh_active: bool = false,

/// Search state. Starts as null and is populated when a search is
/// started (a needle is given).
search: ?Search = null,

/// The options used to initialize this thread.
opts: Options,

/// Initialize the thread. This does not START the thread. This only sets
/// up all the internal state necessary prior to starting the thread. It
/// is up to the caller to start the thread with the threadMain entrypoint.
pub fn init(alloc: Allocator, opts: Options) !Thread {
    // The mailbox for messaging this thread
    var mailbox = try Mailbox.create(alloc);
    errdefer mailbox.destroy(alloc);

    // Create our event loop.
    var loop = try xev.Loop.init(.{});
    errdefer loop.deinit();

    // This async handle is used to "wake up" the renderer and force a render.
    var wakeup_h = try xev.Async.init();
    errdefer wakeup_h.deinit();

    // This async handle is used to stop the loop and force the thread to end.
    var stop_h = try xev.Async.init();
    errdefer stop_h.deinit();

    // Refresh timer, see comments.
    var refresh_h = try xev.Timer.init();
    errdefer refresh_h.deinit();

    return .{
        .alloc = alloc,
        .mailbox = mailbox,
        .loop = loop,
        .wakeup = wakeup_h,
        .stop = stop_h,
        .refresh = refresh_h,
        .opts = opts,
    };
}

/// Clean up the thread. This is only safe to call once the thread
/// completes executing; the caller must join prior to this.
pub fn deinit(self: *Thread) void {
    self.refresh.deinit();
    self.wakeup.deinit();
    self.stop.deinit();
    self.loop.deinit();
    // Nothing can possibly access the mailbox anymore, destroy it.
    self.mailbox.destroy(self.alloc);

    if (self.search) |*s| s.deinit();
}

/// The main entrypoint for the thread.
pub fn threadMain(self: *Thread) void {
    // Call child function so we can use errors...
    self.threadMain_() catch |err| {
        // In the future, we should expose this on the thread struct.
        log.warn("search thread err={}", .{err});
    };
}

fn threadMain_(self: *Thread) !void {
    defer log.debug("search thread exited", .{});

    // Right now, on Darwin, `std.Thread.setName` can only name the current
    // thread, and we have no way to get the current thread from within it,
    // so instead we use this code to name the thread instead.
    if (comptime builtin.os.tag.isDarwin()) {
        internal_os.macos.pthread_setname_np(&"search".*);

        // We can run with lower priority than other threads.
        const class: internal_os.macos.QosClass = .utility;
        if (internal_os.macos.setQosClass(class)) {
            log.debug("thread QoS class set class={}", .{class});
        } else |err| {
            log.warn("error setting QoS class err={}", .{err});
        }
    }

    // Start the async handlers
    self.wakeup.wait(&self.loop, &self.wakeup_c, Thread, self, wakeupCallback);
    self.stop.wait(&self.loop, &self.stop_c, Thread, self, stopCallback);

    // Send an initial wakeup so we drain our mailbox immediately.
    try self.wakeup.notify();

    // Start the refresh timer
    self.startRefreshTimer();

    // Run
    log.debug("starting search thread", .{});
    defer {
        log.debug("starting search thread shutdown", .{});

        // Send the quit message
        if (self.opts.event_cb) |cb| {
            cb(.quit, self.opts.event_userdata);
        }
    }

    // Unlike some of our other threads, we interleave search work
    // with our xev loop so that we can try to make forward search progress
    // while also listening for messages.
    while (true) {
        // If our loop is canceled then we drain our messages and quit.
        if (self.loop.stopped()) {
            while (self.mailbox.pop()) |message| {
                log.debug("mailbox message ignored during shutdown={}", .{message});
            }

            return;
        }

        const s: *Search = if (self.search) |*s| s else {
            // If we're not actively searching, we can block the loop
            // until it does some work.
            try self.loop.run(.once);
            continue;
        };

        // If we have an active search, we always send any pending
        // notifications. Even if the search is complete, there may be
        // notifications to send.
        if (self.opts.event_cb) |cb| {
            s.notify(
                self.alloc,
                cb,
                self.opts.event_userdata,
            );
        }

        if (s.isComplete()) {
            // If our search is complete, there's no more work to do, we
            // can block until we have an xev action.
            try self.loop.run(.once);
            continue;
        }

        // Tick the search. This will trigger any event callbacks, lock
        // for data loading, etc.
        switch (s.tick()) {
            // We're complete now when we were not before. Notify!
            .complete => {},

            // Forward progress was made.
            .progress => {},

            // All searches are blocked. Let's grab the lock and feed data.
            .blocked => {
                self.opts.mutex.lock();
                defer self.opts.mutex.unlock();
                s.feed(self.alloc, self.opts.terminal);
            },
        }

        // We have an active search, so we only want to process messages
        // we have but otherwise return immediately so we can continue the
        // search. If the above completed the search, we still want to
        // go around the loop as quickly as possible to send notifications,
        // and then we'll block on the loop next time.
        try self.loop.run(.no_wait);
    }
}

/// Drain the mailbox.
fn drainMailbox(self: *Thread) !void {
    while (self.mailbox.pop()) |message| {
        log.debug("mailbox message={}", .{message});
        switch (message) {
            .change_needle => |v| {
                defer v.deinit();
                try self.changeNeedle(v.slice());
            },
            .select => |v| try self.select(v),
        }
    }
}

fn select(self: *Thread, sel: ScreenSearch.Select) !void {
    const s = if (self.search) |*s| s else return;
    const screen_search = s.screens.getPtr(s.last_screen.key) orelse return;

    self.opts.mutex.lock();
    defer self.opts.mutex.unlock();

    // The selection will trigger a selection change notification
    // if it did change.
    if (try screen_search.select(sel)) scroll: {
        if (screen_search.selected) |m| {
            // Selection changed, let's scroll the viewport to see it
            // since we have the lock anyways.
            const screen = self.opts.terminal.screens.get(
                s.last_screen.key,
            ) orelse break :scroll;
            screen.scroll(.{ .pin = m.highlight.start.* });
        }
    }
}

/// Change the search term to the given value.
fn changeNeedle(self: *Thread, needle: []const u8) !void {
    log.debug("changing search needle to '{s}'", .{needle});

    // Stop the previous search
    if (self.search) |*s| {
        // If our search is unchanged, do nothing.
        if (std.ascii.eqlIgnoreCase(s.viewport.needle(), needle)) return;

        s.deinit();
        self.search = null;

        // When the search changes then we need to emit that it stopped.
        if (self.opts.event_cb) |cb| {
            cb(
                .{ .total_matches = 0 },
                self.opts.event_userdata,
            );
            cb(
                .{ .selected_match = null },
                self.opts.event_userdata,
            );
            cb(
                .{ .viewport_matches = &.{} },
                self.opts.event_userdata,
            );
        }
    }

    // No needle means stop the search.
    if (needle.len == 0) return;

    // Setup our search state.
    self.search = try .init(self.alloc, needle);

    // We need to grab the terminal lock and do an initial feed.
    self.opts.mutex.lock();
    defer self.opts.mutex.unlock();
    self.search.?.feed(self.alloc, self.opts.terminal);
}

fn startRefreshTimer(self: *Thread) void {
    // Set our active state so it knows we're running. We set this before
    // even checking the active state in case we have a pending shutdown.
    self.refresh_active = true;

    // If our timer is already active, then we don't have to do anything.
    if (self.refresh_c.state() == .active) return;

    // Start the timer which loops
    self.refresh.run(
        &self.loop,
        &self.refresh_c,
        REFRESH_INTERVAL,
        Thread,
        self,
        refreshCallback,
    );
}

fn stopRefreshTimer(self: *Thread) void {
    // This will stop the refresh on the next iteration.
    self.refresh_active = false;
}

fn wakeupCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch |err| {
        log.warn("error in wakeup err={}", .{err});
        return .rearm;
    };

    const self = self_.?;

    // When we wake up, we drain the mailbox. Mailbox producers should
    // wake up our thread after publishing.
    self.drainMailbox() catch |err|
        log.warn("error draining mailbox err={}", .{err});

    return .rearm;
}

fn stopCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch unreachable;
    self_.?.loop.stop();
    return .disarm;
}

fn refreshCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch unreachable;
    const self: *Thread = self_ orelse {
        // This shouldn't happen so we log it.
        log.warn("refresh callback fired without data set", .{});
        return .disarm;
    };

    // Run our feed if we have a search active.
    if (self.search) |*s| {
        self.opts.mutex.lock();
        defer self.opts.mutex.unlock();
        s.feed(self.alloc, self.opts.terminal);
    }

    // Only continue if we're still active
    if (self.refresh_active) self.refresh.run(
        &self.loop,
        &self.refresh_c,
        REFRESH_INTERVAL,
        Thread,
        self,
        refreshCallback,
    );

    return .disarm;
}

pub const Options = struct {
    /// Mutex that must be held while reading/writing the terminal.
    mutex: *Mutex,

    /// The terminal data to search.
    terminal: *Terminal,

    /// The callback for events from the search thread along with optional
    /// userdata. This can be null if you don't want to receive events,
    /// which could be useful for a one-time search (although, odd, you
    /// should use our search structures directly then).
    event_cb: ?EventCallback = null,
    event_userdata: ?*anyopaque = null,
};

pub const EventCallback = *const fn (event: Event, userdata: ?*anyopaque) void;

/// The type used for sending messages to the thread.
pub const Mailbox = BlockingQueue(Message, 64);

/// The messages that can be sent to the thread.
pub const Message = union(enum) {
    /// Represents a write request. Magic number comes from the max size
    /// we want this union to be.
    pub const WriteReq = MessageData(u8, 255);

    /// Change the search term. If no prior search term is given this
    /// will start a search. If an existing search term is given this will
    /// stop the prior search and start a new one.
    change_needle: WriteReq,

    /// Select a search result.
    select: ScreenSearch.Select,
};

/// Events that can be emitted from the search thread. The caller
/// chooses to handle these as they see fit.
pub const Event = union(enum) {
    /// Search is quitting. The search thread is exiting.
    quit,

    /// Search is complete for the given needle on all screens.
    complete,

    /// Total matches on the current active screen have changed.
    total_matches: usize,

    /// Selected match changed.
    selected_match: ?SelectedMatch,

    /// Matches in the viewport have changed. The memory is owned by the
    /// search thread and is only valid during the callback.
    viewport_matches: []const FlattenedHighlight,

    pub const SelectedMatch = struct {
        idx: usize,
        highlight: FlattenedHighlight,
    };
};

/// Search state.
const Search = struct {
    /// Active viewport search for the active screen.
    viewport: ViewportSearch,

    /// The searchers for all the screens.
    screens: std.EnumMap(ScreenSet.Key, ScreenSearch),

    /// All state related to screen switches, collected so that when
    /// we switch screens it makes everything related stale, too.
    last_screen: ScreenState,

    /// True if we sent the complete notification yet.
    last_complete: bool,

    /// The last viewport matches we found.
    stale_viewport_matches: bool,

    const ScreenState = struct {
        /// Last active screen key
        key: ScreenSet.Key,

        /// Last notified total matches count
        total: ?usize = null,

        /// Last notified selected match index
        selected: ?SelectedMatch = null,

        const SelectedMatch = struct {
            idx: usize,
            highlight: UntrackedHighlight,
        };
    };

    pub fn init(
        alloc: Allocator,
        needle: []const u8,
    ) Allocator.Error!Search {
        var vp: ViewportSearch = try .init(alloc, needle);
        errdefer vp.deinit();

        // We use dirty tracking for active area changes. Start with it
        // dirty so the first change is re-searched.
        vp.active_dirty = true;

        return .{
            .viewport = vp,
            .screens = .init(.{}),
            .last_screen = .{ .key = .primary },
            .last_complete = false,
            .stale_viewport_matches = true,
        };
    }

    pub fn deinit(self: *Search) void {
        self.viewport.deinit();
        var it = self.screens.iterator();
        while (it.next()) |entry| entry.value.deinit();
    }

    /// Returns true if all searches on all screens are complete.
    pub fn isComplete(self: *Search) bool {
        var it = self.screens.iterator();
        while (it.next()) |entry| {
            if (!entry.value.state.isComplete()) return false;
        }

        return true;
    }

    pub const Tick = enum {
        /// All searches are complete.
        complete,

        /// Progress was made on at least one screen.
        progress,

        /// All incomplete searches are blocked on feed.
        blocked,
    };

    /// Tick the search forward as much as possible without acquiring
    /// the big lock. Returns the overall tick progress.
    pub fn tick(self: *Search) Tick {
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

        // log.debug("tick result={}", .{result});
        return result;
    }

    /// Grab the mutex and update any state that requires it, such as
    /// feeding additional data to the searches or updating the active screen.
    pub fn feed(
        self: *Search,
        alloc: Allocator,
        t: *Terminal,
    ) void {
        // Update our active screen
        if (t.screens.active_key != self.last_screen.key) {
            // The default values will force resets of a bunch of other
            // state too to force recalculations and notifications.
            self.last_screen = .{ .key = t.screens.active_key };
        }

        // Reconcile our screens with the terminal screens. Remove
        // searchers for screens that no longer exist and add searchers
        // for screens that do exist but we don't have yet.
        {
            // Remove screens we have that no longer exist or changed.
            var it = self.screens.iterator();
            while (it.next()) |entry| {
                const remove: bool = remove: {
                    // If the screen doesn't exist at all, remove it.
                    const actual = t.screens.all.get(entry.key) orelse break :remove true;

                    // If the screen pointer changed, remove it, the screen
                    // was totally reinitialized.
                    break :remove actual != entry.value.screen;
                };

                if (remove) {
                    entry.value.deinit();
                    _ = self.screens.remove(entry.key);
                }
            }
        }
        {
            // Add screens that exist but we don't have yet.
            var it = t.screens.all.iterator();
            while (it.next()) |entry| {
                if (self.screens.contains(entry.key)) continue;
                self.screens.put(entry.key, ScreenSearch.init(
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
                });
            }
        }

        // See the `search_viewport_dirty` flag on the terminal to know
        // what exactly this is for. But, if this is set, we know the renderer
        // found the viewport/active area dirty, so we should mark it as
        // dirty in our viewport searcher so it forces a re-search.
        if (t.flags.search_viewport_dirty) {
            t.flags.search_viewport_dirty = false;

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

    /// Notify about any changes to the search state.
    ///
    /// This doesn't require any locking as it only reads internal state.
    pub fn notify(
        self: *Search,
        alloc: Allocator,
        cb: EventCallback,
        ud: ?*anyopaque,
    ) void {
        const screen_search = self.screens.get(self.last_screen.key) orelse return;

        // Check our total match data
        const total = screen_search.matchesLen();
        if (total != self.last_screen.total) {
            log.debug("notifying total matches={}", .{total});
            self.last_screen.total = total;
            cb(.{ .total_matches = total }, ud);
        }

        // Check our viewport matches. If they're stale, we do the
        // viewport search now. We do this as part of notify and not
        // tick because the viewport search is very fast and doesn't
        // require ticked progress or feeds.
        if (self.stale_viewport_matches) viewport: {
            // We always make stale as false. Even if we fail below
            // we require a re-feed to re-search the viewport. The feed
            // process will make it stale again.
            self.stale_viewport_matches = false;

            var arena: ArenaAllocator = .init(alloc);
            defer arena.deinit();
            const arena_alloc = arena.allocator();
            var results: std.ArrayList(FlattenedHighlight) = .empty;
            while (self.viewport.next()) |hl| {
                const hl_cloned = hl.clone(arena_alloc) catch continue;
                results.append(arena_alloc, hl_cloned) catch |err| switch (err) {
                    error.OutOfMemory => {
                        log.warn(
                            "error collecting viewport matches err={}",
                            .{err},
                        );

                        // Reset the viewport so we force an update on the
                        // next feed.
                        self.viewport.reset();
                        break :viewport;
                    },
                };
            }

            log.debug("notifying viewport matches len={}", .{results.items.len});
            cb(.{ .viewport_matches = results.items }, ud);
        }

        // Check our last selected match data.
        if (screen_search.selected) |m| match: {
            const flattened = screen_search.selectedMatch() orelse break :match;
            const untracked = flattened.untracked();
            if (self.last_screen.selected) |prev| {
                if (prev.idx == m.idx and prev.highlight.eql(untracked)) {
                    // Same selection, don't update it.
                    break :match;
                }
            }

            // New selection, notify!
            self.last_screen.selected = .{
                .idx = m.idx,
                .highlight = untracked,
            };

            log.debug("notifying selection updated idx={}", .{m.idx});
            cb(
                .{ .selected_match = .{
                    .idx = m.idx,
                    .highlight = flattened,
                } },
                ud,
            );
        } else if (self.last_screen.selected != null) {
            log.debug("notifying selection cleared", .{});
            self.last_screen.selected = null;
            cb(
                .{ .selected_match = null },
                ud,
            );
        }

        // Send our complete notification if we just completed.
        if (!self.last_complete and self.isComplete()) {
            log.debug("notifying search complete", .{});
            self.last_complete = true;
            cb(.complete, ud);
        }
    }
};

const TestUserData = struct {
    const Self = @This();
    reset: std.Thread.ResetEvent = .{},
    total: usize = 0,
    selected: ?Event.SelectedMatch = null,
    viewport: []FlattenedHighlight = &.{},

    fn deinit(self: *Self) void {
        for (self.viewport) |*hl| hl.deinit(testing.allocator);
        testing.allocator.free(self.viewport);
    }

    fn callback(event: Event, userdata: ?*anyopaque) void {
        const ud: *Self = @ptrCast(@alignCast(userdata.?));
        switch (event) {
            .quit => {},
            .complete => ud.reset.set(),
            .total_matches => |v| ud.total = v,
            .selected_match => |v| ud.selected = v,
            .viewport_matches => |v| {
                for (ud.viewport) |*hl| hl.deinit(testing.allocator);
                testing.allocator.free(ud.viewport);

                ud.viewport = testing.allocator.alloc(
                    FlattenedHighlight,
                    v.len,
                ) catch unreachable;
                for (ud.viewport, v) |*dst, src| {
                    dst.* = src.clone(testing.allocator) catch unreachable;
                }
            },
        }
    }
};

test {
    const alloc = testing.allocator;
    var mutex: std.Thread.Mutex = .{};
    var t: Terminal = try .init(alloc, .{ .cols = 20, .rows = 2 });
    defer t.deinit(alloc);

    var stream = t.vtStream();
    defer stream.deinit();
    try stream.nextSlice("Hello, world");

    var ud: TestUserData = .{};
    defer ud.deinit();
    var thread: Thread = try .init(alloc, .{
        .mutex = &mutex,
        .terminal = &t,
        .event_cb = &TestUserData.callback,
        .event_userdata = &ud,
    });
    defer thread.deinit();

    var os_thread = try std.Thread.spawn(
        .{},
        threadMain,
        .{&thread},
    );

    // Start our search
    _ = thread.mailbox.push(
        .{ .change_needle = try .init(
            alloc,
            @as([]const u8, "world"),
        ) },
        .forever,
    );
    try thread.wakeup.notify();

    // Wait for completion
    try ud.reset.timedWait(100 * std.time.ns_per_ms);

    // Stop the thread
    try thread.stop.notify();
    os_thread.join();

    // 1 total matches
    try testing.expectEqual(1, ud.total);
    try testing.expectEqual(1, ud.viewport.len);
    {
        const sel = ud.viewport[0].untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 7,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 11,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }
}
