const Self = @This();

const std = @import("std");
const global = @import("../global.zig");
const Allocator = std.mem.Allocator;
const Timestamp = std.Io.Timestamp;

pub const capacity = 256;

pub const Frame = struct {
    start: Timestamp,
    end: Timestamp,
};

pub const InFlight = struct {
    generation: u64,
    start: Timestamp,
};

mutex: std.Io.Mutex = .init,
enabled: std.atomic.Value(bool) = .init(false),
generation: u64 = 0,
frames: ?[]Frame = null,
len: usize = 0,
next: usize = 0,

pub fn enable(self: *Self, alloc: Allocator) Allocator.Error!void {
    const frames = try alloc.alloc(Frame, capacity);
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());

    std.debug.assert(self.frames == null);
    self.generation +%= 1;
    self.frames = frames;
    self.len = 0;
    self.next = 0;
    self.enabled.store(true, .release);
}

pub fn disable(self: *Self, alloc: Allocator) void {
    self.mutex.lockUncancelable(global.io());
    self.enabled.store(false, .release);
    self.generation +%= 1;
    const frames = self.frames;
    self.frames = null;
    self.len = 0;
    self.next = 0;
    self.mutex.unlock(global.io());

    if (frames) |items| alloc.free(items);
}

pub fn begin(self: *Self, time: Timestamp) ?InFlight {
    if (!self.enabled.load(.acquire)) return null;
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    if (self.frames == null) return null;

    return .{
        .generation = self.generation,
        .start = time,
    };
}

pub fn complete(self: *Self, inflight: ?InFlight, time: Timestamp) void {
    const frame = inflight orelse return;
    if (!self.enabled.load(.acquire)) return;

    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    const frames = self.frames orelse return;
    if (frame.generation != self.generation) return;

    frames[self.next] = .{
        .start = frame.start,
        .end = time,
    };
    self.next = (self.next + 1) % capacity;
    self.len = @min(self.len + 1, capacity);
}

pub fn snapshot(self: *Self, out: *[capacity]Frame) usize {
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    const frames = self.frames orelse return 0;

    const oldest = if (self.len == capacity) self.next else 0;
    for (0..self.len) |i| out[i] = frames[(oldest + i) % capacity];
    return self.len;
}

test "completed frames keep their own timing across asynchronous completion" {
    const testing = std.testing;
    const timestamp = struct {
        fn at(ns: i64) Timestamp {
            return .fromNanoseconds(ns);
        }
    }.at;

    var timings: Self = .{};
    try timings.enable(testing.allocator);
    defer timings.disable(testing.allocator);

    const first = timings.begin(timestamp(2)).?;
    const second = timings.begin(timestamp(4)).?;

    timings.complete(second, timestamp(6));
    timings.complete(first, timestamp(7));

    var frames: [capacity]Frame = undefined;
    try testing.expectEqual(@as(usize, 2), timings.snapshot(&frames));
    try testing.expectEqual(@as(i96, 4), frames[0].start.toNanoseconds());
    try testing.expectEqual(@as(i96, 2), frames[1].start.toNanoseconds());

    timings.disable(testing.allocator);
    try timings.enable(testing.allocator);
    timings.complete(first, timestamp(8));
    try testing.expectEqual(@as(usize, 0), timings.snapshot(&frames));
}
