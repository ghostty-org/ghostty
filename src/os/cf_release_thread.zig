//! Represents the CFRelease thread. Pools of CFTypeRefs are sent to
//! this thread to be released, so that their release callback logic
//! doesn't block the execution of a high throughput thread like the
//! renderer thread.
pub const Thread = @This();

const std = @import("std");
const builtin = @import("builtin");
const macos = @import("macos");

const internal_os = @import("../os/main.zig");
const xev = @import("../global.zig").xev;
const BlockingQueue = @import("../datastruct/main.zig").BlockingQueue;

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.cf_release_thread);

pub const Message = union(enum) {
    /// Release a slice of CFTypeRefs. Uses alloc to free the slice after
    /// releasing all the refs.
    release: struct {
        refs: []*anyopaque,
        alloc: Allocator,
    },
};

/// The type used for sending messages to the thread. For now this is
/// hardcoded with a capacity. We can make this a comptime parameter in
/// the future if we want it configurable.
pub const Mailbox = BlockingQueue(Message, 64);

/// Allocator used for some state
alloc: std.mem.Allocator,

/// The main event loop for the thread. The user data of this loop
/// is always the allocator used to create the loop. This is a convenience
/// so that users of the loop always have an allocator.
loop: xev.Loop,

/// This can be used to wake up the thread.
wakeup: xev.Async,
wakeup_c: xev.Completion = .{},

/// This can be used to stop the thread on the next loop iteration.
stop: xev.Async,
stop_c: xev.Completion = .{},

/// The mailbox that can be used to send this thread messages. Note
/// this is a blocking queue so if it is full you will get errors (or block).
mailbox: *Mailbox,

flags: packed struct {
    /// This is set to true only when an abnormal exit is detected. It
    /// tells our mailbox system to drain and ignore all messages.
    drain: bool = false,
} = .{},

/// Initialize the thread. This does not START the thread. This only sets
/// up all the internal state necessary prior to starting the thread. It
/// is up to the caller to start the thread with the threadMain entrypoint.
pub fn init(
    alloc: Allocator,
) !Thread {
    // Create our event loop.
    var loop = try xev.Loop.init(.{});
    errdefer loop.deinit();

    // This async handle is used to "wake up" the thread to collect objects.
    var wakeup_h = try xev.Async.init();
    errdefer wakeup_h.deinit();

    // This async handle is used to stop the loop and force the thread to end.
    var stop_h = try xev.Async.init();
    errdefer stop_h.deinit();

    // The mailbox for messaging this thread
    var mailbox = try Mailbox.create(alloc);
    errdefer mailbox.destroy(alloc);

    return Thread{
        .alloc = alloc,
        .loop = loop,
        .wakeup = wakeup_h,
        .stop = stop_h,
        .mailbox = mailbox,
    };
}

/// Clean up the thread. This is only safe to call once the thread
/// completes executing; the caller must join prior to this.
pub fn deinit(self: *Thread) void {
    self.stop.deinit();
    self.wakeup.deinit();
    self.loop.deinit();

    // Nothing can possibly access the mailbox anymore, destroy it.
    self.mailbox.destroy(self.alloc);
}

/// The main entrypoint for the thread.
pub fn threadMain(self: *Thread) void {
    // Call child function so we can use errors...
    self.threadMain_() catch |err| {
        log.warn("error in cf release thread err={}", .{err});
    };

    // If our loop is not stopped, then we need to keep running so that
    // messages are drained and we can wait for the surface to send a stop
    // message.
    if (!self.loop.stopped()) {
        log.warn("abrupt cf release thread exit detected, starting xev to drain mailbox", .{});
        defer log.debug("cf release thread fully exiting after abnormal failure", .{});
        self.flags.drain = true;
        self.loop.run(.until_done) catch |err| {
            log.err("failed to start xev loop for draining err={}", .{err});
        };
    }
}

fn threadMain_(self: *Thread) !void {
    defer log.debug("cf release thread exited", .{});

    // Right now, on Darwin, `std.Thread.setName` can only name the current
    // thread, and we have no way to get the current thread from within it,
    // so instead we use this code to name the thread instead.
    if (builtin.os.tag.isDarwin()) {
        internal_os.macos.pthread_setname_np(&"cf_release".*);
    }

    // Start the async handlers. We start these first so that they're
    // registered even if anything below fails so we can drain the mailbox.
    self.wakeup.wait(&self.loop, &self.wakeup_c, Thread, self, wakeupCallback);
    self.stop.wait(&self.loop, &self.stop_c, Thread, self, stopCallback);

    // Run
    log.debug("starting cf release thread", .{});
    defer log.debug("starting cf release thread shutdown", .{});
    try self.loop.run(.until_done);
}

/// Drain the mailbox, handling all the messages in our terminal implementation.
fn drainMailbox(self: *Thread) !void {
    // If we're draining, we just drain the mailbox and return.
    if (self.flags.drain) {
        while (self.mailbox.pop()) |_| {}
        return;
    }

    while (self.mailbox.pop()) |message| {
        // log.debug("mailbox message={}", .{message});
        switch (message) {
            .release => |msg| {
                for (msg.refs) |ref| macos.foundation.CFRelease(ref);
                // log.debug("Released {} CFTypeRefs.", .{ msg.refs.len });
                msg.alloc.free(msg.refs);
            },
        }
    }
}

fn wakeupCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch |err| {
        log.err("error in wakeup err={}", .{err});
        return .rearm;
    };

    const t = self_.?;

    // When we wake up, we check the mailbox. Mailbox producers should
    // wake up our thread after publishing.
    t.drainMailbox() catch |err|
        log.err("error draining mailbox err={}", .{err});

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
