const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const ArcPixels = @import("../datastruct/main.zig").AtomicRefCounted([]u8);

/// A CPU image descriptor owning a shared reference to immutable pixels.
/// Clone before retaining another owner and deinit each owned reference.
pub const Image = struct {
    width: u32,
    height: u32,
    format: Format,
    pixels: *const ArcPixels,

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

    pub fn clone(self: Image) Image {
        var result = self;
        result.pixels = self.pixels.clone();
        return result;
    }

    pub fn deinit(self: Image, alloc: Allocator) void {
        self.pixels.release(alloc);
    }
};

test "CPU image makeMut reuses unique pixels without allocating" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const alloc = failing.allocator();
    const pixels = try alloc.dupe(u8, "rgba");
    var image: Image = .{
        .width = 1,
        .height = 1,
        .format = .rgba,
        .pixels = try ArcPixels.init(alloc, pixels),
    };
    defer image.deinit(alloc);
    const original = image.pixels;
    try std.testing.expectEqual(1, image.pixels.refs.load(.monotonic));
    const temporary = image.clone();
    try std.testing.expectEqual(2, image.pixels.refs.load(.monotonic));
    temporary.deinit(alloc);
    try std.testing.expectEqual(1, image.pixels.refs.load(.monotonic));
    failing.fail_index = failing.alloc_index;
    const mutable = try ArcPixels.makeMut(&image.pixels, alloc);
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(1, image.pixels.refs.load(.monotonic));
    try std.testing.expectEqual(original, image.pixels);
    try std.testing.expectEqual(pixels.ptr, mutable.ptr);
    mutable.*[0] = 'R';
    const cloned = image.clone();
    try std.testing.expectEqual(2, image.pixels.refs.load(.monotonic));
    try std.testing.expectEqualSlices(u8, "Rgba", cloned.pixels.value);
    cloned.deinit(alloc);
    try std.testing.expectEqual(1, image.pixels.refs.load(.monotonic));
}

test "CPU image makeMut preserves other readers" {
    const alloc = std.testing.allocator;
    var image: Image = .{
        .width = 1,
        .height = 1,
        .format = .rgba,
        .pixels = try ArcPixels.init(alloc, try alloc.dupe(u8, "rgba")),
    };
    defer image.deinit(alloc);
    const retained = image.clone();
    defer retained.deinit(alloc);

    try std.testing.expectEqual(2, image.pixels.refs.load(.monotonic));
    const mutable = try ArcPixels.makeMut(&image.pixels, alloc);
    try std.testing.expect(image.pixels != retained.pixels);
    try std.testing.expect(mutable.ptr != retained.pixels.value.ptr);
    try std.testing.expectEqual(retained.width, image.width);
    try std.testing.expectEqual(retained.height, image.height);
    try std.testing.expectEqual(retained.format, image.format);
    try std.testing.expectEqualSlices(u8, "rgba", mutable.*);
    mutable.*[0] = 'R';
    try std.testing.expectEqualSlices(u8, "rgba", retained.pixels.value);
    try std.testing.expectEqualSlices(u8, "Rgba", image.pixels.value);
    try std.testing.expectEqual(1, retained.pixels.refs.load(.monotonic));
    try std.testing.expectEqual(1, image.pixels.refs.load(.monotonic));
}

test "CPU image makeMut allocation failure preserves shared ownership" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const alloc = failing.allocator();
    var image: Image = .{
        .width = 1,
        .height = 1,
        .format = .rgba,
        .pixels = try ArcPixels.init(alloc, try alloc.dupe(u8, "rgba")),
    };
    defer image.deinit(alloc);
    const retained = image.clone();
    defer retained.deinit(alloc);

    try std.testing.expectEqual(2, image.pixels.refs.load(.monotonic));
    // Fail both the pixel copy and the replacement control block allocation.
    for (0..2) |fail_index| {
        failing.fail_index = failing.alloc_index + fail_index;
        try std.testing.expectError(error.OutOfMemory, ArcPixels.makeMut(&image.pixels, alloc));
        try std.testing.expectEqual(retained.pixels, image.pixels);
        try std.testing.expectEqual(2, image.pixels.refs.load(.monotonic));
        try std.testing.expectEqualSlices(u8, "rgba", image.pixels.value);
    }
}

test "CPU image retains immutable pixels without copying" {
    const alloc = std.testing.allocator;
    const data = try alloc.dupe(u8, &.{ 1, 2, 3, 4 });
    const image: Image = .{
        .width = 1,
        .height = 1,
        .format = .rgba,
        .pixels = try ArcPixels.init(alloc, data),
    };
    try std.testing.expectEqual(1, image.pixels.refs.load(.monotonic));
    const retained = image.clone();
    try std.testing.expectEqual(2, retained.pixels.refs.load(.monotonic));
    image.deinit(alloc);
    defer retained.deinit(alloc);
    try std.testing.expectEqual(1, retained.pixels.refs.load(.monotonic));
    try std.testing.expectEqual(*const ArcPixels, @TypeOf(retained.pixels));
    try std.testing.expectEqual(data.ptr, retained.pixels.value.ptr);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, retained.pixels.value);
}

test "CPU image can release its final reference on another thread" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const pixels = try alloc.dupe(u8, "rgba");
    const image: Image = .{
        .width = 1,
        .height = 1,
        .format = .rgba,
        .pixels = try ArcPixels.init(alloc, pixels),
    };
    const worker = struct {
        fn run(value: Image, image_alloc: Allocator) !void {
            defer value.deinit(image_alloc);
            try std.testing.expectEqual(1, value.pixels.refs.load(.monotonic));
            for (0..1000) |_| {
                const cloned = value.clone();
                try std.testing.expectEqual(2, value.pixels.refs.load(.monotonic));
                cloned.deinit(image_alloc);
                try std.testing.expectEqual(1, value.pixels.refs.load(.monotonic));
            }
            try std.testing.expectEqualSlices(u8, value.pixels.value, "rgba");
        }
    };
    const thread = std.Thread.spawn(.{}, worker.run, .{ image, alloc }) catch |err| {
        image.deinit(alloc);
        return err;
    };
    thread.join();
}

test "CPU image allocation failure leaves pixels with caller" {
    const alloc = std.testing.allocator;
    const pixels = try alloc.dupe(u8, "rgba");
    defer alloc.free(pixels);
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, ArcPixels.init(failing.allocator(), pixels));
    try std.testing.expectEqualSlices(u8, "rgba", pixels);
}
