const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// A data structure where you can get stable (never copied) pointers to
/// a type that automatically grows if necessary. The values can be "put back"
/// but are expected to be put back IN ORDER.
///
/// This is implemented specifically for libuv write requests, since the
/// write requests must have a stable pointer and are guaranteed to be processed
/// in order for a single stream.
///
/// This is NOT thread safe.
pub fn SegmentedPool(comptime T: type, comptime prealloc: usize) type {
    return struct {
        const Self = @This();

        /// Each segment is a fixed-size array of T allocated on the
        /// heap, giving stable pointers across growth.
        const Segment = *[prealloc]T;

        i: usize = 0,
        available: usize = prealloc,
        len: usize = prealloc,
        segments: std.ArrayList(Segment) = .empty,
        prealloc_segment: [prealloc]T = undefined,

        pub fn deinit(self: *Self, alloc: Allocator) void {
            for (self.segments.items) |seg| {
                alloc.destroy(seg);
            }
            self.segments.deinit(alloc);
            self.* = undefined;
        }

        /// Get a pointer to the element at index `idx` across
        /// all segments (prealloc + dynamic).
        fn at(self: *Self, idx: usize) *T {
            if (idx < prealloc) {
                return &self.prealloc_segment[idx];
            }
            const adjusted = idx - prealloc;
            const seg_idx = adjusted / prealloc;
            const elem_idx = adjusted % prealloc;
            return &self.segments.items[seg_idx][elem_idx];
        }

        /// Get the next available value out of the list. This will not
        /// grow the list.
        pub fn get(self: *Self) !*T {
            // Error to not have any
            if (self.available == 0) return error.OutOfValues;

            // The index we grab is just i % len, so we wrap around to the front.
            const idx = @mod(self.i, self.len);
            self.i +%= 1; // Wrapping addition so we go back to 0
            self.available -= 1;
            return self.at(idx);
        }

        /// Get the next available value out of the list and grow the list
        /// if necessary.
        pub fn getGrow(self: *Self, alloc: Allocator) !*T {
            if (self.available == 0) try self.grow(alloc);
            return try self.get();
        }

        fn grow(self: *Self, alloc: Allocator) !void {
            // We need to add enough segments to double the total length.
            const new_len = self.len * 2;
            const new_segs_needed = (new_len - 1) / prealloc - self.segments.items.len;

            const new = try self.segments.addManyAsSlice(alloc, new_segs_needed);
            for (new) |s| s.* = try alloc.create([prealloc]T);

            self.i = self.len;
            self.available = self.len;
            self.len = new_len;
        }

        /// Put a value back. The value put back is expected to be the
        /// in order of get.
        pub fn put(self: *Self) void {
            self.available += 1;
            assert(self.available <= self.len);
        }
    };
}

test "SegmentedPool" {
    var list: SegmentedPool(u8, 2) = .{};
    defer list.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), list.available);

    // Get to capacity
    const v1 = try list.get();
    const v2 = try list.get();
    try testing.expect(v1 != v2);
    try testing.expectError(error.OutOfValues, list.get());

    // Test writing for later
    v1.* = 42;

    // Put a value back
    list.put();
    const temp = try list.get();
    try testing.expect(v1 == temp);
    try testing.expect(temp.* == 42);
    try testing.expectError(error.OutOfValues, list.get());

    // Grow
    const v3 = try list.getGrow(testing.allocator);
    try testing.expect(v1 != v3 and v2 != v3);
    _ = try list.get();
    try testing.expectError(error.OutOfValues, list.get());

    // Put a value back
    list.put();
    try testing.expect(v1 == try list.get());
    try testing.expectError(error.OutOfValues, list.get());
}
