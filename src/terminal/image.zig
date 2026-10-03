const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// An owned, mutable Image residing on the CPU, borrowing should use
/// ArcImage for an immutable reference-counted image.
pub const Image = struct {
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

    /// Duplicate the image with an independent copy of its pixels.
    pub fn dupe(self: *const Image, alloc: Allocator) Allocator.Error!Image {
        var result = self.*;
        result.data = try alloc.dupe(u8, self.data);
        return result;
    }

    pub fn deinit(self: *Image, alloc: Allocator) void {
        alloc.free(self.data);
        self.* = undefined;
    }
};

pub const ArcImage = AtomicRefCounted(Image);

/// Shared ownership of a value with a deinit(Allocator) method. Implemented by
/// atomic reference-counting to defer deinit to the last reference
///
/// The allocator of used to initialize the control block (AtomicRefCounted)
/// must be the same as the allocator of the value for T so that .deinit(alloc)
/// can correctly free inner allocations alongside the control block.
///
/// Like Rust's Arc, clone shares ownership and makeMut clones the inner value
/// only when it is shared. .makeMut() requires T.dupe(Allocator) for deep
/// copying. https://doc.rust-lang.org/std/sync/struct.Arc.html#method.make_mut
///
/// The allocator used must outlive all references and support cross-thread
/// frees when references are transferred between threads.
pub fn AtomicRefCounted(comptime T: type) type {
    return struct {
        const Self =
            @This();

        refs: std.atomic.Value(usize) = .init(1),
        value: T,

        /// Initialise an instance, after this point the data is still uniquely
        /// owned until a copy of the shared AtomicRefCounted(T) is made with
        /// .clone() On allocation failure the caller retains ownership of
        /// value.
        pub fn init(alloc: Allocator, value: T) Allocator.Error!*const Self {
            const result = try alloc.create(Self);
            result.* = .{ .value = value };
            return result;
        }

        /// Clone shared ownership, incrementing the ref-count, without copying
        /// the inner value.
        ///
        /// Paired with .release(alloc) to decrement
        pub fn clone(self: *const Self) *const Self {
            const previous =
                @constCast(self).refs.fetchAdd(1, .monotonic);
            if (previous >= std.math.maxInt(isize))
                @panic("AtomicRefCounted reference count overflow");
            std.debug.assert(previous > 0);
            return self;
        }

        /// Release to decrement the ref-count, potentially deinitialising the
        /// inner allocation as well if the ref-count drops to 0.
        pub fn release(self: *const Self, alloc: Allocator) void {
            const mutable =
                @constCast(self);
            const previous = mutable.refs.fetchSub(1, .release);
            std.debug.assert(previous > 0);
            if (previous == 1) {
                _ =
                    mutable.refs.load(.acquire);
                mutable.value.deinit(alloc);
                alloc.destroy(mutable);
            }
        }

        /// Return an owned value safe for mutation, replacing this handle with a clone of the
        /// value if other owners exist. Failure leaves the handle unchanged.
        pub fn makeMut(handle: **const Self, alloc: Allocator) Allocator.Error!*T {
            comptime {
                if (!std.meta.hasFn(T, "dupe"))
                    @compileError("AtomicRefCounted(" ++ @typeName(T) ++ ").makeMut requires pub fn dupe(*const T, Allocator) Allocator.Error!T");
                _ = @as(*const fn (*const T, Allocator) Allocator.Error!T, &T.dupe);
            }
            const current = handle.*;
            // Acquire synchronizes with prior owners' releases before mutation.
            if (current.refs.load(.acquire) == 1) return &@constCast(current).value;

            var copy = try current.value.dupe(alloc);
            errdefer copy.deinit(alloc);
            const replacement = try Self.init(alloc, copy);
            handle.* = replacement;
            current.release(alloc);
            return &@constCast(replacement).value;
        }
    };
}

test "CPU image makeMut reuses unique pixels without allocating" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const alloc = failing.allocator();
    const pixels = try alloc.dupe(u8, "rgba");
    var image = try ArcImage.init(alloc, .{
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = pixels,
    });
    defer image.release(alloc);
    const original = image;
    try std.testing.expectEqual(1, image.refs.load(.monotonic));
    const temporary = image.clone();
    try std.testing.expectEqual(2, image.refs.load(.monotonic));
    temporary.release(alloc);
    try std.testing.expectEqual(1, image.refs.load(.monotonic));
    failing.fail_index = failing.alloc_index;
    const mutable = try ArcImage.makeMut(&image, alloc);
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(1, image.refs.load(.monotonic));
    try std.testing.expectEqual(original, image);
    try std.testing.expectEqual(pixels.ptr, mutable.data.ptr);
    mutable.data[0] = 'R';
    const cloned = image.clone();
    try std.testing.expectEqual(2, image.refs.load(.monotonic));
    try std.testing.expectEqualSlices(u8, "Rgba", cloned.value.data);
    cloned.release(alloc);
    try std.testing.expectEqual(1, image.refs.load(.monotonic));
}

test "CPU image makeMut preserves other readers" {
    const alloc = std.testing.allocator;
    var image = try ArcImage.init(alloc, .{
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = try alloc.dupe(u8, "rgba"),
    });
    defer image.release(alloc);
    const retained = image.clone();
    defer retained.release(alloc);

    try std.testing.expectEqual(2, image.refs.load(.monotonic));
    const mutable = try ArcImage.makeMut(&image, alloc);
    try std.testing.expect(image != retained);
    try std.testing.expect(mutable.data.ptr != retained.value.data.ptr);
    try std.testing.expectEqual(retained.value.width, mutable.width);
    try std.testing.expectEqual(retained.value.height, mutable.height);
    try std.testing.expectEqual(retained.value.format, mutable.format);
    try std.testing.expectEqualSlices(u8, "rgba", mutable.data);
    mutable.data[0] = 'R';
    try std.testing.expectEqualSlices(u8, "rgba", retained.value.data);
    try std.testing.expectEqualSlices(u8, "Rgba", image.value.data);
    try std.testing.expectEqual(1, retained.refs.load(.monotonic));
    try std.testing.expectEqual(1, image.refs.load(.monotonic));
}

test "CPU image makeMut allocation failure preserves shared ownership" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const alloc = failing.allocator();
    var image = try ArcImage.init(alloc, .{
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = try alloc.dupe(u8, "rgba"),
    });
    defer image.release(alloc);
    const retained = image.clone();
    defer retained.release(alloc);

    try std.testing.expectEqual(2, image.refs.load(.monotonic));
    // Fail both the pixel copy and the replacement control block allocation.
    for (0..2) |fail_index| {
        failing.fail_index = failing.alloc_index + fail_index;
        try std.testing.expectError(error.OutOfMemory, ArcImage.makeMut(&image, alloc));
        try std.testing.expectEqual(retained, image);
        try std.testing.expectEqual(2, image.refs.load(.monotonic));
        try std.testing.expectEqualSlices(u8, "rgba", image.value.data);
    }
}

test "CPU image retains immutable pixels without copying" {
    const alloc = std.testing.allocator;
    const data = try alloc.dupe(u8, &.{ 1, 2, 3, 4 });
    const image = try ArcImage.init(alloc, .{
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = data,
    });
    try std.testing.expectEqual(1, image.refs.load(.monotonic));
    const retained = image.clone();
    try std.testing.expectEqual(2, retained.refs.load(.monotonic));
    image.release(alloc);
    defer retained.release(alloc);
    try std.testing.expectEqual(1, retained.refs.load(.monotonic));
    try std.testing.expectEqual(*const ArcImage, @TypeOf(retained));
    try std.testing.expectEqual(data.ptr, retained.value.data.ptr);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, retained.value.data);
}

test "CPU image can release its final reference on another thread" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const pixels = try alloc.dupe(u8, "rgba");
    const image = try ArcImage.init(alloc, .{
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = pixels,
    });
    const worker = struct {
        fn run(value: *const ArcImage, image_alloc: Allocator) !void {
            defer value.release(image_alloc);
            try std.testing.expectEqual(1, value.refs.load(.monotonic));
            for (0..1000) |_| {
                const cloned = value.clone();
                try std.testing.expectEqual(2, value.refs.load(.monotonic));
                cloned.release(image_alloc);
                try std.testing.expectEqual(1, value.refs.load(.monotonic));
            }
            try std.testing.expectEqualSlices(u8, value.value.data, "rgba");
        }
    };
    const thread = std.Thread.spawn(.{}, worker.run, .{ image, alloc }) catch |err| {
        image.release(alloc);
        return err;
    };
    thread.join();
}

test "CPU image allocation failure leaves pixels with caller" {
    const alloc = std.testing.allocator;
    const pixels = try alloc.dupe(u8, "rgba");
    defer alloc.free(pixels);
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, ArcImage.init(failing.allocator(), .{
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
    try std.testing.expectEqual(1, shared.refs.load(.monotonic));
    const retained = shared.clone();
    try std.testing.expectEqual(2, retained.refs.load(.monotonic));
    shared.release(alloc);
    try std.testing.expectEqual(1, retained.refs.load(.monotonic));
    try std.testing.expectEqual(0, destroyed);
    retained.release(alloc);
    try std.testing.expectEqual(1, destroyed);

    const unique = try Arc.init(alloc, .{ .destroyed = &destroyed });
    try std.testing.expectEqual(1, unique.refs.load(.monotonic));
    try std.testing.expectEqual(1, destroyed);
    unique.release(alloc);
    try std.testing.expectEqual(2, destroyed);
}
