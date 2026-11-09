//! Keeps a blocking queue drained from another thread while its
//! consumer can't.
const std = @import("std");
const builtin = @import("builtin");
const BlockingQueue = @import("blocking_queue.zig").BlockingQueue;

const log = std.log.scoped(.queue_drain);

/// A thread that keeps `Queue` (a `BlockingQueue`) drained, handing every
/// value it takes off to `handle`.
///
/// This is for teardown. A thread that consumes a queue sometimes has to
/// join threads that push into it, or the queue's consumer is a thread
/// that has already been joined. Either way, a producer blocked on a full
/// queue never wakes up and the join never returns. Start a drain before
/// joining and finish it afterwards.
///
/// While a drain runs it's a second consumer of the queue. That's safe
/// because `pop` holds the queue's lock, but values the drain takes are
/// gone from the queue: `handle` decides what happens to them.
pub fn QueueDrain(
    comptime Queue: type,
    comptime Context: type,
    comptime handle: fn (Context, Value(Queue)) void,
) type {
    return struct {
        const Self = @This();

        queue: *Queue,
        context: Context,
        io: std.Io = undefined,
        stop: std.atomic.Value(bool) = .init(false),
        thread: ?std.Thread = null,

        /// Start draining. This must not be moved until `finish` returns.
        pub fn start(self: *Self, io: std.Io) void {
            self.io = io;
            self.thread = thread: {
                const thread = std.Thread.spawn(.{}, run, .{self}) catch |err| {
                    log.warn("queue drain thread spawn failed, may stall err={}", .{err});
                    break :thread null;
                };
                thread.setName(io, @typeName(Queue) ++ " drain thread") catch {};
                break :thread thread;
            };
        }

        /// Stop draining. Call this once every thread that might push
        /// into the queue has been joined, so that the last pass catches
        /// everything they pushed.
        pub fn finish(self: *Self) void {
            const thread = self.thread orelse return;
            self.stop.store(true, .release);
            thread.join();
            self.thread = null;
        }

        fn run(self: *Self) void {
            while (true) {
                // Read the flag before draining so that the last pass comes
                // after every push made before `finish` was called.
                const stopping = self.stop.load(.acquire);
                while (self.queue.pop(self.io)) |value| handle(self.context, value);
                if (stopping) return;
                std.Io.sleep(self.io, .fromMilliseconds(1), .awake) catch {};
            }
        }
    };
}

/// The type of the values in a `BlockingQueue`.
fn Value(comptime Queue: type) type {
    return @typeInfo(@FieldType(Queue, "data")).array.child;
}

test "QueueDrain releases a producer blocked on a full queue" {
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

    var drain: QueueDrain(Q, *Seen, Seen.handle) = .{ .queue = q, .context = &seen };
    drain.start(io);
    producer.join();
    drain.finish();

    try testing.expect(q.pop(io) == null);
    try testing.expectEqualSlices(u64, &.{ 1, 2, 3, 4, 5 }, seen.values[0..seen.len]);
}
