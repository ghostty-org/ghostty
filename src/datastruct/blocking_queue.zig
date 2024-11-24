//! Blocking queue implementation aimed primarily for message passing
//! between threads.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

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
        mutex: std.Thread.Mutex = .{},

        /// A CV for being notified when the queue is no longer full. This is
        /// used for writing. Note we DON'T have a CV for waiting on the
        /// queue not being EMPTY because we use external notifiers for that.
        cond_not_full: std.Thread.Condition = .{},
        not_full_waiters: usize = 0,

        /// Allocate the blocking queue on the heap.
        pub fn create(alloc: Allocator) !*Self {
            const ptr = try alloc.create(Self);
            errdefer alloc.destroy(ptr);

            ptr.* = .{
                .data = undefined,
                .len = 0,
                .write = 0,
                .read = 0,
                .mutex = .{},
                .cond_not_full = .{},
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
        pub fn push(self: *Self, value: T, timeout: Timeout) Size {
            self.mutex.lock();
            defer self.mutex.unlock();

            // The
            if (self.full()) {
                switch (timeout) {
                    // If we're not waiting, then we failed to write.
                    .instant => return 0,

                    .forever => {
                        self.not_full_waiters += 1;
                        defer self.not_full_waiters -= 1;
                        self.cond_not_full.wait(&self.mutex);
                    },

                    .ns => |ns| {
                        self.not_full_waiters += 1;
                        defer self.not_full_waiters -= 1;
                        self.cond_not_full.timedWait(&self.mutex, ns) catch return 0;
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
        pub fn pop(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            // If we're empty we have nothing
            if (self.len == 0) return null;

            // Get the index we're going to read data from and do some
            // accounting. We don't copy the value here to avoid copying twice.
            const n = self.read;
            self.read += 1;
            if (self.read >= bounds) self.read -= bounds;
            self.len -= 1;

            // If we have consumers waiting on a full queue, notify.
            if (self.not_full_waiters > 0) self.cond_not_full.signal();

            return self.data[n];
        }

        /// Pop all values from the queue. This will hold the big mutex
        /// until `deinit` is called on the return value. This is used if
        /// you know you're going to "pop" and utilize all the values
        /// quickly to avoid many locks, bounds checks, and cv signals.
        pub fn drain(self: *Self) DrainIterator {
            self.mutex.lock();
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

            pub fn deinit(self: *DrainIterator) void {
                // If we have consumers waiting on a full queue, notify.
                if (self.queue.not_full_waiters > 0) self.queue.cond_not_full.signal();

                // Unlock
                self.queue.mutex.unlock();
            }
        };

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

    const Q = BlockingQueue(u64, 4);
    const q = try Q.create(alloc);
    defer q.destroy(alloc);

    // Should have no values
    try testing.expect(q.pop() == null);

    // Push until we're full
    try testing.expectEqual(@as(Q.Size, 1), q.push(1, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 2), q.push(2, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 3), q.push(3, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 4), q.push(4, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 0), q.push(5, .{ .instant = {} }));

    // Pop!
    try testing.expect(q.pop().? == 1);
    try testing.expect(q.pop().? == 2);
    try testing.expect(q.pop().? == 3);
    try testing.expect(q.pop().? == 4);
    try testing.expect(q.pop() == null);

    // Drain does nothing
    var it = q.drain();
    try testing.expect(it.next() == null);
    it.deinit();

    // Verify we can still push
    try testing.expectEqual(@as(Q.Size, 1), q.push(1, .{ .instant = {} }));
}

test "timed push" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const Q = BlockingQueue(u64, 1);
    const q = try Q.create(alloc);
    defer q.destroy(alloc);

    // Push
    try testing.expectEqual(@as(Q.Size, 1), q.push(1, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 0), q.push(2, .{ .instant = {} }));

    // Timed push should fail
    try testing.expectEqual(@as(Q.Size, 0), q.push(2, .{ .ns = 1000 }));
}
