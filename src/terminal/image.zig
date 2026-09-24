const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// TODO(review)
/// An owned, mutable Image residing on the CPU, borrowing should use
/// ArcCpuImage for an immutable reference-counted image.
pub const CpuImage = struct {
    width: u32,
    height: u32,
    format: Format,
    data: []u8,

    pub const Format = enum {
        gray,
        gray_alpha,
        rgb,
        bgr,
        rgba,
        bgra,

        pub fn bpp(self: Format) usize {
            return switch (self) {
                .gray => 1,
                .gray_alpha => 2,
                .rgb, .bgr => 3,
                .rgba, .bgra => 4,
            };
        }
    };

    pub fn deinit(self: *CpuImage, alloc: Allocator) void {
        alloc.free(self.data);
        self.* = undefined;
    }
};

pub const ArcCpuImage = AtomicRefCounted(CpuImage);

/// TODO(review)
/// Atomic shared ownership of a value with a deinit(Allocator) method.
/// Shared values are immutable. Publication across threads requires external
/// synchronization. The allocator must outlive all references and support
/// cross-thread frees when references are transferred between threads.
pub fn AtomicRefCounted(comptime T: type) type {
    return struct {
        const Self = @This();

        refs: std.atomic.Value(usize) = .init(1),
        allocator: Allocator,
        value: T,

        /// TODO(review)
        /// Transfer an owned value into shared storage without copying it.
        /// On allocation failure the caller retains ownership of value.
        /// The value must support deinitialization with alloc.
        pub fn init(alloc: Allocator, value: T) Allocator.Error!*const Self {
            const result = try alloc.create(Self);
            result.* = .{ .allocator = alloc, .value = value };
            return result;
        }

        /// TODO(review)
        /// Clone shared ownership without copying the inner value.
        pub fn clone(self: *const Self) *const Self {
            const previous = @constCast(self).refs.fetchAdd(1, .monotonic);
            std.debug.assert(previous > 0);
            return self;
        }

        /// TODO(review)
        /// Consume the sole shared reference and return this allocation for
        /// exclusive mutation. A zero count marks private ownership. Failure
        /// leaves the reference unchanged. Exclude all access through the
        /// consumed reference until publish, including clone and release.
        pub fn tryOwn(self: *const Self) ?*Self {
            const mutable = @constCast(self);
            if (mutable.refs.cmpxchgStrong(1, 0, .acquire, .monotonic) != null) return null;
            return mutable;
        }

        /// TODO(review)
        /// Consume exclusive ownership and restore one shared reference.
        /// Publication to another thread still requires external synchronization.
        pub fn publish(self: *Self) *const Self {
            std.debug.assert(self.refs.load(.monotonic) == 0);
            self.refs.store(1, .release);
            return self;
        }

        /// TODO(review)
        /// Destroy a privately owned Arc instead of publishing it again.
        pub fn deinit(self: *Self) void {
            std.debug.assert(self.refs.load(.monotonic) == 0);
            const alloc = self.allocator;
            self.value.deinit(alloc);
            alloc.destroy(self);
        }

        pub fn release(self: *const Self) void {
            const mutable = @constCast(self);
            const previous = mutable.refs.fetchSub(1, .release);
            std.debug.assert(previous > 0);
            if (previous == 1) {
                _ = mutable.refs.load(.acquire);
                const alloc = self.allocator;
                mutable.value.deinit(alloc);
                alloc.destroy(mutable);
            }
        }
    };
}

// TODO(review)
test "CPU image takes unique ownership without copying" {
    const alloc = std.testing.allocator;
    const pixels = try alloc.dupe(u8, "rgba");
    const image = try ArcCpuImage.init(alloc, .{
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = pixels,
    });
    const retained = image.clone();
    try std.testing.expect(image.tryOwn() == null);
    retained.release();
    const owned = image.tryOwn().?;
    try std.testing.expectEqual(*ArcCpuImage, @TypeOf(owned));
    try std.testing.expectEqual(image, owned);
    try std.testing.expectEqual(pixels.ptr, owned.value.data.ptr);
    owned.value.data[0] = 'R';
    const published = owned.publish();
    defer published.release();
    try std.testing.expectEqual(image, published);
    try std.testing.expectEqualSlices(u8, "Rgba", published.value.data);
    const cloned = published.clone();
    cloned.release();
}

// TODO(review)
test "CPU image retains immutable pixels without copying" {
    const alloc = std.testing.allocator;
    const data = try alloc.dupe(u8, &.{ 1, 2, 3, 4 });
    const image = try ArcCpuImage.init(alloc, .{
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = data,
    });
    const retained = image.clone();
    image.release();
    defer retained.release();
    try std.testing.expectEqual(*const ArcCpuImage, @TypeOf(retained));
    try std.testing.expectEqual(data.ptr, retained.value.data.ptr);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, retained.value.data);
}

// TODO(review)
test "CPU image can release its final reference on another thread" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const pixels = try alloc.dupe(u8, "rgba");
    const image = try ArcCpuImage.init(alloc, .{
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = pixels,
    });
    const worker = struct {
        fn run(value: *const ArcCpuImage) void {
            defer value.release();
            for (0..1000) |_| value.clone().release();
            std.debug.assert(std.mem.eql(u8, value.value.data, "rgba"));
        }
    };
    const thread = std.Thread.spawn(.{}, worker.run, .{image}) catch |err| {
        image.release();
        return err;
    };
    thread.join();
}

// TODO(review)
test "CPU image allocation failure leaves pixels with caller" {
    const alloc = std.testing.allocator;
    const pixels = try alloc.dupe(u8, "rgba");
    defer alloc.free(pixels);
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, ArcCpuImage.init(failing.allocator(), .{
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = pixels,
    }));
    try std.testing.expectEqualSlices(u8, "rgba", pixels);
}

// TODO(review)
test {
    std.testing.refAllDecls(@This());
}

// TODO(review)
test "AtomicRefCounted releases the inner value only on final release" {
    const Value = struct {
        destroyed: *usize,

        pub fn deinit(self: *@This(), _: Allocator) void {
            self.destroyed.* += 1;
        }
    };
    const Arc = AtomicRefCounted(Value);
    const alloc = std.testing.allocator;
    var destroyed: usize = 0;
    const shared = try Arc.init(alloc, .{ .destroyed = &destroyed });
    const retained = shared.clone();
    shared.release();
    try std.testing.expectEqual(0, destroyed);
    retained.release();
    try std.testing.expectEqual(1, destroyed);

    const unique = try Arc.init(alloc, .{ .destroyed = &destroyed });
    const owned = unique.tryOwn().?;
    try std.testing.expectEqual(1, destroyed);
    owned.deinit();
    try std.testing.expectEqual(2, destroyed);
}
