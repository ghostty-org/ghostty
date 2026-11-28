//! Blocking queue implementation aimed primarily for message passing
//! between threads.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const compat_thread = @import("../lib/compat/thread.zig");

const log = std.log.scoped(.blocking_queue);

/// Returns a blocking queue implementation for type T.
///
/// This is tailor made for ghostty usage so it isn't meant to be maximally
/// generic, but I'm happy to make it more generic over time. Traits of this
/// queue that are specific to our usage:
///
///   - Fixed size. We expect our queue to quickly drain and also not be
///     too large so we prefer a fixed size queue for now.
///   - No blocking pop. We use an external event loop mechanism such as
///     eventfd to notify our waiter that there is no data available so
///     we don't need to implement a blocking pop.
///   - Drain function. Most queues usually pop one at a time. We have
///     a mechanism for draining since on every IO loop our TTY drains
///     the full queue so we can get rid of the overhead of a ton of
///     locks and bounds checking and do a one-time drain.
///
/// One key usage pattern is that our blocking queues are single producer
/// single consumer (SPSC). This should let us do some interesting optimizations
/// in the future. At the time of writing this, the blocking queue implementation
/// is purposely naive to build something quickly, but we should benchmark
/// and make this more optimized as necessary.
pub fn BlockingQueue(
    comptime T: type,
    comptime capacity: usize,
) type {
    return struct {
        const Self = @This();

        // The type we use for queue size types. We can optimize this
        // in the future to be the correct bit-size for our preallocated
        // size for this queue.
        pub const Size = u32;

        // The bounds of this queue. We recast this to Size so we can do math.
        const bounds: Size = @intCast(capacity);

        /// Specifies the timeout for an operation.
        pub const Timeout = union(enum) {
            /// Fail instantly (non-blocking).
            instant: void,

            /// Run forever or until interrupted
            forever: void,

            /// Nanoseconds
            ns: u64,
        };

        /// Our data. The values are undefined until they are written.
        data: [bounds]T = undefined,

        /// The next location to write (next empty loc) and next location
        /// to read (next non-empty loc). The number of written elements.
        write: Size = 0,
        read: Size = 0,
        len: Size = 0,

        /// The big mutex that must be held to read/write.
        mutex: std.Io.Mutex = .init,

        /// A CV for being notified when the queue is no longer full. This is
        /// used for writing. Note we DON'T have a CV for waiting on the
        /// queue not being EMPTY because we use external notifiers for that.
        cond_not_full: std.Io.Condition = .init,
        not_full_waiters: usize = 0,

        /// Allocate the blocking queue on the heap.
        pub fn create(alloc: Allocator) Allocator.Error!*Self {
            const ptr = try alloc.create(Self);
            errdefer alloc.destroy(ptr);

            ptr.* = .{
                .data = undefined,
                .len = 0,
                .write = 0,
                .read = 0,
                .mutex = .init,
                .cond_not_full = .init,
                .not_full_waiters = 0,
            };

            return ptr;
        }

        /// Free all the resources for this queue. This should only be
        /// called once all producers and consumers have quit.
        pub fn destroy(self: *Self, alloc: Allocator) void {
            self.* = undefined;
            alloc.destroy(self);
        }

        /// Push a value to the queue. This returns the total size of the
        /// queue (unread items) after the push. A return value of zero
        /// means that the push failed.
        pub fn push(self: *Self, io: std.Io, value: T, timeout: Timeout) Size {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            // The
            if (self.full()) {
                switch (timeout) {
                    // If we're not waiting, then we failed to write.
                    .instant => return 0,

                    .forever => {
                        self.not_full_waiters += 1;
                        defer self.not_full_waiters -= 1;
                        self.cond_not_full.waitUncancelable(io, &self.mutex);
                    },

                    .ns => |ns| {
                        self.not_full_waiters += 1;
                        defer self.not_full_waiters -= 1;
                        compat_thread.waitTimeout(
                            &self.cond_not_full,
                            io,
                            &self.mutex,
                            .{
                                .duration = .{
                                    .raw = .fromNanoseconds(ns),
                                    .clock = .awake,
                                },
                            },
                        ) catch return 0;
                    },
                }

                // If we're still full, then we failed to write. This can
                // happen in situations where we are interrupted.
                if (self.full()) return 0;
            }

            // Add our data and update our accounting
            self.data[self.write] = value;
            self.write += 1;
            if (self.write >= bounds) self.write -= bounds;
            self.len += 1;

            return self.len;
        }

        /// Pop a value from the queue without blocking.
        pub fn pop(self: *Self, io: std.Io) ?T {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            // If we're empty we have nothing
            if (self.len == 0) return null;

            // Get the index we're going to read data from and do some
            // accounting. We don't copy the value here to avoid copying twice.
            const n = self.read;
            self.read += 1;
            if (self.read >= bounds) self.read -= bounds;
            self.len -= 1;

            // If we have consumers waiting on a full queue, notify.
            if (self.not_full_waiters > 0) self.cond_not_full.signal(io);

            return self.data[n];
        }

        /// Pop all values from the queue. This will hold the big mutex
        /// until `deinit` is called on the return value. This is used if
        /// you know you're going to "pop" and utilize all the values
        /// quickly to avoid many locks, bounds checks, and cv signals.
        pub fn drain(self: *Self, io: std.Io) DrainIterator {
            self.mutex.lockUncancelable(io);
            return .{ .queue = self };
        }

        pub const DrainIterator = struct {
            queue: *Self,

            pub fn next(self: *DrainIterator) ?T {
                if (self.queue.len == 0) return null;

                // Read and account
                const n = self.queue.read;
                self.queue.read += 1;
                if (self.queue.read >= bounds) self.queue.read -= bounds;
                self.queue.len -= 1;

                return self.queue.data[n];
            }

            pub fn deinit(self: *DrainIterator, io: std.Io) void {
                // If we have consumers waiting on a full queue, notify.
                if (self.queue.not_full_waiters > 0) self.queue.cond_not_full.signal(io);

                // Unlock
                self.queue.mutex.unlock(io);
            }
        };

        /// A thread that keeps a queue drained, handing every value it
        /// takes off to `handle`.
        ///
        /// This is for teardown. A thread that consumes a queue sometimes
        /// has to join threads that push into it, or the queue's consumer
        /// is a thread that has already been joined. Either way, a producer
        /// blocked on a full queue never wakes up and the join never
        /// returns. Start a drain thread before joining and finish it
        /// afterwards.
        ///
        /// While it runs it's a second consumer of the queue. That's safe
        /// because `pop` holds the queue's lock, but values it takes are
        /// gone from the queue: `handle` decides what happens to them.
        ///
        /// `name` is the name given to the thread, which is what shows up
        /// in a debugger or `top`.
        pub fn DrainThread(
            comptime Context: type,
            comptime handle: fn (Context, T) void,
            comptime name: []const u8,
        ) type {
            // Linux and FreeBSD allow at most 15 bytes, and `setName` fails
            // rather than truncating, so a longer name would be silently
            // lost.
            if (name.len > 15) @compileError("drain thread name \"" ++
                name ++ "\" is longer than 15 bytes");

            return struct {
                const Drain = @This();

                queue: *Self,
                context: Context,
                io: std.Io = undefined,
                stop: std.atomic.Value(bool) = .init(false),
                thread: ?std.Thread = null,

                /// Start draining. This must not be moved until `finish`
                /// returns.
                pub fn start(self: *Drain, io: std.Io) void {
                    self.io = io;
                    self.thread = thread: {
                        const thread = std.Thread.spawn(.{}, run, .{self}) catch |err| {
                            log.warn("drain thread spawn failed, may stall err={}", .{err});
                            break :thread null;
                        };
                        thread.setName(io, name) catch {};
                        break :thread thread;
                    };
                }

                /// Stop draining. Call this once every thread that might
                /// push into the queue has been joined, so that the last
                /// pass catches everything they pushed.
                pub fn finish(self: *Drain) void {
                    const thread = self.thread orelse return;
                    self.stop.store(true, .release);
                    thread.join();
                    self.thread = null;
                }

                fn run(self: *Drain) void {
                    while (true) {
                        // Read the flag before draining so that the last
                        // pass comes after every push made before `finish`
                        // was called.
                        const stopping = self.stop.load(.acquire);
                        while (self.queue.pop(self.io)) |value| handle(self.context, value);
                        if (stopping) return;
                        std.Io.sleep(self.io, .fromMilliseconds(1), .awake) catch {};
                    }
                }
            };
        }

        /// Returns true if the queue is full. This is not public because
        /// it requires the lock to be held.
        inline fn full(self: *Self) bool {
            return self.len == bounds;
        }
    };
}

test "basic push and pop" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    const Q = BlockingQueue(u64, 4);
    const q = try Q.create(alloc);
    defer q.destroy(alloc);

    // Should have no values
    try testing.expect(q.pop(io) == null);

    // Push until we're full
    try testing.expectEqual(@as(Q.Size, 1), q.push(io, 1, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 2), q.push(io, 2, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 3), q.push(io, 3, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 4), q.push(io, 4, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 0), q.push(io, 5, .{ .instant = {} }));

    // Pop!
    try testing.expect(q.pop(io).? == 1);
    try testing.expect(q.pop(io).? == 2);
    try testing.expect(q.pop(io).? == 3);
    try testing.expect(q.pop(io).? == 4);
    try testing.expect(q.pop(io) == null);

    // Drain does nothing
    var it = q.drain(io);
    try testing.expect(it.next() == null);
    it.deinit(io);

    // Verify we can still push
    try testing.expectEqual(@as(Q.Size, 1), q.push(io, 1, .{ .instant = {} }));
}

test "timed push" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    const Q = BlockingQueue(u64, 1);
    const q = try Q.create(alloc);
    defer q.destroy(alloc);

    // Push
    try testing.expectEqual(@as(Q.Size, 1), q.push(io, 1, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 0), q.push(io, 2, .{ .instant = {} }));

    // Timed push should fail
    try testing.expectEqual(@as(Q.Size, 0), q.push(io, 2, .{ .ns = 1000 }));
}

test "DrainThread releases a producer blocked on a full queue" {
    const testing = std.testing;
    if (builtin.single_threaded) return error.SkipZigTest;
    const alloc = testing.allocator;
    const io = testing.io;

    const Q = BlockingQueue(u64, 4);
    const q = try Q.create(alloc);
    defer q.destroy(alloc);

    // Collects what the drain takes off, in order.
    const Seen = struct {
        values: [8]u64 = undefined,
        len: usize = 0,

        fn handle(self: *@This(), value: u64) void {
            self.values[self.len] = value;
            self.len += 1;
        }
    };
    var seen: Seen = .{};

    // Fill the queue, then block pushing one more, as a thread being
    // joined would.
    for (1..5) |i| try testing.expect(q.push(io, i, .instant) > 0);
    const S = struct {
        fn producer(queue: *Q) void {
            _ = queue.push(testing.io, 5, .forever);
        }
    };
    const producer = try std.Thread.spawn(.{}, S.producer, .{q});

    var drain: Q.DrainThread(*Seen, Seen.handle, "test-drain") = .{
        .queue = q,
        .context = &seen,
    };
    drain.start(io);

    // `setName` fails rather than truncating a name that's too long, and
    // the failure is ignored, so check that the name actually took.
    if (builtin.os.tag == .linux) {
        var buf: [std.Thread.max_name_len:0]u8 = undefined;
        const thread_name = try drain.thread.?.getName(&buf);
        try testing.expectEqualStrings("test-drain", thread_name.?);
    }

    producer.join();
    drain.finish();

    try testing.expect(q.pop(io) == null);
    try testing.expectEqualSlices(u64, &.{ 1, 2, 3, 4, 5 }, seen.values[0..seen.len]);
}
