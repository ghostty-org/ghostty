const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Shared ownership of an allocated slice. Atomic reference-counting defers
/// freeing the slice and control block until the last reference is released.
///
/// Shared elements are immutable by contract. Publishing a reference to
/// another thread requires external synchronization.
///
/// Use the same allocator for the slice, control block, makeMut and release.
/// It must outlive all references and support cross-thread frees when
/// references are transferred between threads.
///
/// Like Rust's `Arc<T>`, clone shares ownership and `.makeMut()` copies the
/// slice's elements only when it is shared. Copies preserve slice alignment
/// and any sentinel.
/// https://doc.rust-lang.org/std/sync/struct.Arc.html#method.make_mut
pub fn AtomicRefCounted(comptime T: type) type {
    const is_slice = switch (@typeInfo(T)) {
        .pointer => |pointer| pointer.size == .slice,
        else => false,
    };
    if (!is_slice)
        @compileError("AtomicRefCounted(" ++ @typeName(T) ++ ") requires a slice type");

    return struct {
        const Self = @This();

        refs: std.atomic.Value(usize) = .init(1),
        value: T,

        /// Initialise an instance, after this point the data is still uniquely
        /// owned until a copy of the shared AtomicRefCounted(T) is made with
        /// .clone(). On allocation failure the caller retains ownership of
        /// value.
        pub fn init(alloc: Allocator, value: T) Allocator.Error!*const Self {
            const result = try alloc.create(Self);
            result.* = .{ .value = value };
            return result;
        }

        /// Clone shared ownership, incrementing the ref-count, without copying
        /// the inner value.
        ///
        /// Paired with .release(alloc) to decrement.
        pub fn clone(self: *const Self) *const Self {
            const previous = @constCast(self).refs.fetchAdd(1, .monotonic);
            if (previous >= std.math.maxInt(isize))
                @panic("AtomicRefCounted reference count overflow");
            std.debug.assert(previous > 0);
            return self;
        }

        /// Decrement the ref-count, freeing the slice and control block when
        /// the last reference is released.
        pub fn release(self: *const Self, alloc: Allocator) void {
            const mutable = @constCast(self);
            const previous = mutable.refs.fetchSub(1, .release);
            std.debug.assert(previous > 0);
            if (previous == 1) {
                _ = mutable.refs.load(.acquire);
                alloc.free(mutable.value);
                alloc.destroy(mutable);
            }
        }

        /// Return a pointer to a value safe for mutation, replacing this handle with
        /// an independent copy of the value if other owners exist. Failure leaves the
        /// handle unchanged.
        ///
        /// The caller must finish mutable access before cloning, releasing or
        /// publishing the reference.
        pub fn makeMut(handle: *(*const Self), alloc: Allocator) Allocator.Error!*T {
            const current = handle.*;
            // Acquire synchronizes with prior owners' releases before mutation.
            if (current.refs.load(.acquire) == 1) return &@constCast(current).value;

            const info = @typeInfo(T).pointer;
            const copy = try alloc.allocWithOptions(
                info.child,
                current.value.len,
                comptime std.mem.Alignment.fromByteUnitsOptional(info.attrs.@"align"),
                comptime info.sentinel(),
            );
            errdefer alloc.free(copy);
            @memcpy(copy, current.value);
            const replacement = try Self.init(alloc, copy);
            handle.* = replacement;
            current.release(alloc);
            return &@constCast(replacement).value;
        }
    };
}

test "AtomicRefCounted frees the slice and control block only on final release" {
    const testing = std.testing;
    var tracked = testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = tracked.allocator();
    const Arc = AtomicRefCounted([]u16);
    const pixels = try alloc.dupe(u16, &.{ 1, 2, 3 });
    const shared = try Arc.init(alloc, pixels);
    try testing.expectEqual(1, shared.refs.load(.monotonic));
    const retained = shared.clone();
    try testing.expectEqual(2, retained.refs.load(.monotonic));
    shared.release(alloc);
    try testing.expectEqual(1, retained.refs.load(.monotonic));
    try testing.expectEqual(@as(usize, 0), tracked.freed_bytes);
    try testing.expectEqualSlices(u16, &.{ 1, 2, 3 }, retained.value);
    retained.release(alloc);
    try testing.expectEqual(tracked.allocated_bytes, tracked.freed_bytes);
}

test "AtomicRefCounted slices preserve ownership through mutable copies and allocation failures" {
    const testing = std.testing;
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = failing.allocator();
    const Arc = AtomicRefCounted([]u8);
    const pixels = try alloc.dupe(u8, "rgba");
    var shared = try Arc.init(alloc, pixels);
    defer shared.release(alloc);
    try testing.expectEqual(1, shared.refs.load(.monotonic));
    try testing.expectEqual(pixels.ptr, shared.value.ptr);

    failing.fail_index = failing.alloc_index;
    const unique = try Arc.makeMut(&shared, alloc);
    try testing.expect(!failing.has_induced_failure);
    try testing.expectEqual(pixels.ptr, unique.ptr);
    unique.*[0] = 'R';

    const retained = shared.clone();
    defer retained.release(alloc);
    try testing.expectEqual(2, shared.refs.load(.monotonic));
    for (0..2) |offset| {
        failing.fail_index = failing.alloc_index + offset;
        try testing.expectError(error.OutOfMemory, Arc.makeMut(&shared, alloc));
        try testing.expectEqual(retained, shared);
        try testing.expectEqual(pixels.ptr, shared.value.ptr);
        try testing.expectEqual(2, shared.refs.load(.monotonic));
        try testing.expectEqualSlices(u8, "Rgba", shared.value);
    }
    failing.fail_index = std.math.maxInt(usize);
    const mutable = try Arc.makeMut(&shared, alloc);
    try testing.expect(shared != retained);
    try testing.expect(mutable.ptr != retained.value.ptr);
    try testing.expectEqual(1, shared.refs.load(.monotonic));
    try testing.expectEqual(1, retained.refs.load(.monotonic));
    mutable.*[1] = 'G';
    try testing.expectEqualSlices(u8, "Rgba", retained.value);
    try testing.expectEqualSlices(u8, "RGba", shared.value);
}

test "AtomicRefCounted can release its final reference on another thread" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const Arc = AtomicRefCounted([]u8);
    const shared = try Arc.init(alloc, try alloc.dupe(u8, "rgba"));
    const worker = struct {
        fn run(value: *const Arc, allocator: Allocator) !void {
            defer value.release(allocator);
            try testing.expectEqual(1, value.refs.load(.monotonic));
            for (0..1000) |_| {
                const cloned = value.clone();
                try testing.expectEqual(2, value.refs.load(.monotonic));
                cloned.release(allocator);
                try testing.expectEqual(1, value.refs.load(.monotonic));
            }
            try testing.expectEqualSlices(u8, "rgba", value.value);
        }
    };
    const thread = std.Thread.spawn(.{}, worker.run, .{ shared, alloc }) catch |err| {
        shared.release(alloc);
        return err;
    };
    thread.join();
}

test "AtomicRefCounted allocation failure leaves the slice with the caller" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const pixels = try alloc.dupe(u8, "rgba");
    defer alloc.free(pixels);
    var failing = testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, AtomicRefCounted([]u8).init(failing.allocator(), pixels));
    try testing.expectEqualSlices(u8, "rgba", pixels);
}

test "AtomicRefCounted makeMut preserves slice alignment and sentinels" {
    const testing = std.testing;
    inline for (.{ []align(16) u8, [:0]align(32) u8, [:0]const u8 }) |Slice| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        const alloc = failing.allocator();
        const info = @typeInfo(Slice).pointer;
        const Arc = AtomicRefCounted(Slice);
        const pixels = try alloc.allocWithOptions(
            info.child,
            4,
            comptime std.mem.Alignment.fromByteUnitsOptional(info.attrs.@"align"),
            comptime info.sentinel(),
        );
        @memcpy(pixels, "rgba");
        var shared = try Arc.init(alloc, pixels);
        defer shared.release(alloc);

        failing.fail_index = failing.alloc_index;
        const unique = try Arc.makeMut(&shared, alloc);
        try testing.expect(!failing.has_induced_failure);
        try testing.expectEqual(pixels.ptr, unique.ptr);
        try testing.expectEqual(1, shared.refs.load(.monotonic));

        const retained = shared.clone();
        defer retained.release(alloc);
        failing.fail_index = failing.alloc_index + 1;
        try testing.expectError(error.OutOfMemory, Arc.makeMut(&shared, alloc));
        try testing.expect(failing.has_induced_failure);
        try testing.expectEqual(retained, shared);
        try testing.expectEqual(2, shared.refs.load(.monotonic));
        try testing.expectEqualSlices(u8, "rgba", shared.value);

        failing.fail_index = std.math.maxInt(usize);
        const mutable = try Arc.makeMut(&shared, alloc);
        try testing.expectEqual(Slice, @TypeOf(mutable.*));
        try testing.expect(shared != retained);
        try testing.expect(mutable.ptr != retained.value.ptr);
        const alignment = info.attrs.@"align" orelse @alignOf(info.child);
        try testing.expectEqual(@as(usize, 0), @intFromPtr(mutable.ptr) % alignment);
        try testing.expectEqual(1, shared.refs.load(.monotonic));
        try testing.expectEqual(1, retained.refs.load(.monotonic));
        if (comptime info.sentinel()) |sentinel| {
            try testing.expectEqual(sentinel, shared.value.ptr[shared.value.len]);
            try testing.expectEqual(sentinel, retained.value.ptr[retained.value.len]);
        }
        if (comptime !info.attrs.@"const") {
            mutable.*[0] = 'R';
            try testing.expectEqualSlices(u8, "Rgba", shared.value);
        }
        try testing.expectEqualSlices(u8, "rgba", retained.value);
    }
}
