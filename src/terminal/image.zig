const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

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

/// Shared ownership of a value with a deinit(Allocator) method.
/// Implemented by atomic reference-counting to defer deinit to the last reference
///
/// Shared values are not thread-safe for mutation.
///
/// The allocator must outlive all references and support
/// cross-thread frees when references are transferred between threads.
pub fn AtomicRefCounted(comptime T: type) type {
    return struct {
        const Self = @This();

        refs: std.atomic.Value(usize) = .init(1),
        allocator: Allocator,
        value: T,

        /// Initialise an instance, after this point the data is still uniquely
        /// owned until a copy of the shared AtomicRefCounted(T) is made with
        /// .clone() On allocation failure the caller retains ownership of
        /// value.
        pub fn init(alloc: Allocator, value: T) Allocator.Error!*const Self {
            const result = try alloc.create(Self);
            result.* = .{ .allocator = alloc, .value = value };
            return result;
        }

        /// Clone shared ownership, incrementing the ref-count, without copying
        /// the inner value.
        ///
        /// Paired with .release() to decrement
        pub fn clone(self: *const Self) *const Self {
            const previous =
                @constCast(self).refs.fetchAdd(1, .monotonic);
            std.debug.assert(previous > 0);
            return self;
        }

        /// Release to decrement the ref-count, potentially deinitialising the
        /// inner allocation as well if the ref-count drops to 0.
        pub fn release(self: *const Self) void {
            const mutable =
                @constCast(self);
            const previous = mutable.refs.fetchSub(1, .release);
            std.debug.assert(previous > 0);
            if (previous == 1) {
                _ =
                    mutable.refs.load(.acquire);
                const alloc = self.allocator;
                mutable.value.deinit(alloc);
                alloc.destroy(mutable);
            }
        }

        /// Attempt to consume a unique shared reference (ref-count = 0) and
        /// own the value for exclusive mutation. Failure leaves the reference
        /// unchanged.
        ///
        /// To bump the ref-count for sharing again use .publish()
        pub fn tryOwn(self: *const Self) ?*Self {
            const mutable = @constCast(self);
            if (mutable.refs.cmpxchgStrong(1, 0, .acquire, .monotonic) != null) return null;
            return mutable;
        }

        /// Remove exclusive ownership and restore one shared ref-count.
        pub fn publish(self: *Self) *const Self {
            std.debug.assert(self.refs.load(.monotonic) == 0);
            self.refs.store(1, .release);
            return self;
        }

        /// Destroy a privately owned Arc instead of publishing it again. This
        /// performs .deinit() on the inner value and should only be called
        /// when the self is exclusively owned with a ref-count of 0.
        fn deinit(self: *Self) void {
            std.debug.assert(self.refs.load(.monotonic) == 0);
            const alloc =
                self.allocator;
            self.value.deinit(alloc);
            alloc.destroy(self);
        }
    };
}

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
    // No shared references exist now
    try std.testing.expectEqual(0, owned.refs.raw);
    try std.testing.expectEqual(*ArcCpuImage, @TypeOf(owned));
    try std.testing.expectEqual(image, owned);
    try std.testing.expectEqual(pixels.ptr, owned.value.data.ptr);
    // Mutation is safe as ownership is unique and no writes/reads can race
    owned.value.data[0] = 'R';
    // Restored to a normal shared reference of 1
    const published = owned.publish();
    defer published.release();
    try std.testing.expectEqual(1, published.refs.raw);

    try std.testing.expectEqual(image, published);
    try std.testing.expectEqualSlices(u8, "Rgba", published.value.data);
    const cloned = published.clone();
    cloned.release();
    try std.testing.expectEqual(1, published.refs.raw);
}

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
        fn run(value: *const ArcCpuImage) !void {
            defer value.release();
            for (0..1000) |_| value.clone().release();
            try std.testing.expectEqualSlices(u8, value.value.data, "rgba");
        }
    };
    const thread = std.Thread.spawn(.{}, worker.run, .{image}) catch |err| {
        image.release();
        return err;
    };
    thread.join();
}

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
