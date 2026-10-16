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

pub const ArcImage = @import("../datastruct/main.zig").AtomicRefCounted(Image);

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
