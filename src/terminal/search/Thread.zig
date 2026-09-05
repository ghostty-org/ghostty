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
const Mutex = std.Io.Mutex;
const global = @import("../../global.zig");
const xev = global.xev;
const internal_os = @import("../../os/main.zig");
const BlockingQueue = @import("../../datastruct/main.zig").BlockingQueue;
const MessageData = @import("../../datastruct/main.zig").MessageData;
const point = @import("../point.zig");
const FlattenedHighlight = @import("../highlight.zig").Flattened;
const UntrackedHighlight = @import("../highlight.zig").Untracked;
const ScreenSet = @import("../ScreenSet.zig");
const Terminal = @import("../Terminal.zig");

const ScreenSearch = @import("screen.zig").ScreenSearch;
const TerminalSearch = @import("terminal.zig").TerminalSearch;

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
search: ?TerminalSearch = null,

/// The last-notified values used to diff search state into events.
notify_state: NotifyState = .{},

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

    if (self.search) |*s| {
        self.opts.mutex.lockUncancelable(global.io());
        defer self.opts.mutex.unlock(global.io());
        s.deinit(self.opts.terminal);
    }
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
            while (self.mailbox.pop(global.io())) |message| {
                log.debug("mailbox message ignored during shutdown={}", .{message});
            }

            return;
        }

        const s: *TerminalSearch = if (self.search) |*s| s else {
            // If we're not actively searching, we can block the loop
            // until it does some work.
            try self.loop.run(.once);
            continue;
        };

        // If we have an active search, we always send any pending
        // notifications. Even if the search is complete, there may be
        // notifications to send.
        if (self.opts.event_cb) |cb| {
            self.notify(s, cb, self.opts.event_userdata);
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
                self.opts.mutex.lockUncancelable(global.io());
                defer self.opts.mutex.unlock(global.io());
                self.feedLocked(s);
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

/// Feed the search from the terminal state. The terminal mutex must
/// be held by the caller.
fn feedLocked(self: *Thread, s: *TerminalSearch) void {
    const t = self.opts.terminal;

    // See the `search_viewport_dirty` flag on the terminal to know
    // what exactly this is for. But, if this is set, we know the renderer
    // found the viewport/active area dirty, so the active area must be
    // re-scanned.
    const active_dirty = t.flags.search_viewport_dirty;
    t.flags.search_viewport_dirty = false;

    s.feed(t, active_dirty);
}

/// Drain the mailbox.
fn drainMailbox(self: *Thread) !void {
    while (self.mailbox.pop(global.io())) |message| {
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

    self.opts.mutex.lockUncancelable(global.io());
    defer self.opts.mutex.unlock(global.io());

    if (try s.select(self.opts.terminal, sel, .if_needed)) {
        // No matter what we reset our selected match cache. This will
        // trigger a callback which will trigger the renderer to wake up
        // so it can be notified the screen scrolled.
        self.notify_state.selected = null;
    }
}

/// Change the search term to the given value.
fn changeNeedle(self: *Thread, needle: []const u8) !void {
    log.debug("changing search needle to '{s}'", .{needle});

    // Stop the previous search
    if (self.search) |*s| {
        // If our search is unchanged, do nothing.
        if (std.ascii.eqlIgnoreCase(s.needle(), needle)) return;

        {
            self.opts.mutex.lockUncancelable(global.io());
            defer self.opts.mutex.unlock(global.io());
            s.deinit(self.opts.terminal);
        }
        self.search = null;
        self.notify_state = .{};

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
    self.notify_state = .{};

    // We need to grab the terminal lock and do an initial feed.
    self.opts.mutex.lockUncancelable(global.io());
    defer self.opts.mutex.unlock(global.io());
    self.feedLocked(&self.search.?);
}

/// Notify about any changes to the search state by diffing against
/// the last-notified values.
///
/// This doesn't require any locking as it only reads search-owned state.
fn notify(
    self: *Thread,
    s: *TerminalSearch,
    cb: EventCallback,
    ud: ?*anyopaque,
) void {
    const state = &self.notify_state;

    // A screen switch makes all previously notified per-screen state
    // stale, so reset it to force recalculations and notifications.
    if (state.key != s.active_key) {
        state.key = s.active_key;
        state.total = null;
        state.selected = null;
    }

    const screen_search = s.activeScreenSearch() orelse return;

    // Check our total match data
    const total = screen_search.matchesLen();
    if (total != state.total) {
        log.debug("notifying total matches={}", .{total});
        state.total = total;
        cb(.{ .total_matches = total }, ud);
    }

    // Check our viewport matches. If they're stale, we collect them
    // now. We do this as part of notify and not tick because the
    // viewport search is very fast and doesn't require ticked progress
    // or feeds.
    if (s.stale_viewport_matches) viewport: {
        const matches = s.viewportMatches() catch |err| {
            log.warn("error collecting viewport matches err={}", .{err});
            break :viewport;
        };

        log.debug("notifying viewport matches len={}", .{matches.len});
        cb(.{ .viewport_matches = matches }, ud);
    }

    // Check our last selected match data.
    if (screen_search.selected) |m| match: {
        const flattened = screen_search.selectedMatch() orelse break :match;
        const untracked = flattened.untracked();
        if (state.selected) |prev| {
            if (prev.idx == m.idx and prev.highlight.eql(untracked)) {
                // Same selection, don't update it.
                break :match;
            }
        }

        // New selection, notify!
        state.selected = .{
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
    } else if (state.selected != null) {
        log.debug("notifying selection cleared", .{});
        state.selected = null;
        cb(
            .{ .selected_match = null },
            ud,
        );
    }

    // Send our complete notification if we just completed.
    if (!state.complete and s.isComplete()) {
        log.debug("notifying search complete", .{});
        state.complete = true;
        cb(.complete, ud);
    }
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
        self.opts.mutex.lockUncancelable(global.io());
        defer self.opts.mutex.unlock(global.io());
        self.feedLocked(s);
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

/// The last-notified values used by `notify` to diff search state
/// into events.
const NotifyState = struct {
    /// The active screen key the state below was captured against.
    key: ScreenSet.Key = .primary,

    /// Last notified total matches count
    total: ?usize = null,

    /// Last notified selected match
    selected: ?Selected = null,

    /// True if we sent the complete notification yet.
    complete: bool = false,

    const Selected = struct {
        idx: usize,
        highlight: UntrackedHighlight,
    };
};

const TestUserData = struct {
    const Self = @This();
    reset: std.Io.Event = .unset,
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
            .complete => ud.reset.set(global.io()),
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
    const io = testing.io;
    var mutex: std.Io.Mutex = .init;
    var t: Terminal = try .init(io, alloc, .{ .cols = 20, .rows = 2 });
    defer t.deinit(alloc);

    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("Hello, world");

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
        io,
        .{ .change_needle = try .init(
            alloc,
            @as([]const u8, "world"),
        ) },
        .forever,
    );
    try thread.wakeup.notify();

    // Wait for completion
    try ud.reset.waitTimeout(testing.io, .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(100) } });

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
