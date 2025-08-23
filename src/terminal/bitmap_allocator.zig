const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const size = @import("size.zig");
const getOffset = size.getOffset;
const Offset = size.Offset;
const OffsetBuf = size.OffsetBuf;
const alignForward = std.mem.alignForward;

/// A relatively naive bitmap allocator that uses memory offsets against
/// a fixed backing buffer so that the backing buffer can be easily moved
/// without having to update pointers.
///
/// The chunk size determines the size of each chunk in bytes. This is the
/// minimum distributed unit of memory. For example, if you request a
/// 1-byte allocation, you'll use a chunk of chunk_size bytes. Likewise,
/// if your chunk size is 4, and you request a 5-byte allocation, you'll
/// use 2 chunks.
///
/// The allocator is susceptible to fragmentation. If you allocate and free
/// memory in a way that leaves small holes in the memory, you may not be
/// able to allocate large chunks of memory even if there is enough free
/// memory in aggregate. To avoid fragmentation, use a chunk size that is
/// large enough to cover most of your allocations.
///
// Notes for contributors: this is highly contributor friendly part of
// the code. If you can improve this, add tests, show benchmarks, then
// please do so!
pub fn BitmapAllocator(comptime chunk_size: comptime_int) type {
    return struct {
        const Self = @This();

        comptime {
            assert(std.math.isPowerOfTwo(chunk_size));
        }

        pub const base_align = @alignOf(u64);
        pub const bitmap_bit_size = @bitSizeOf(u64);

        /// The bitmap of available chunks. Each bit represents a chunk. A
        /// 1 means the chunk is free and a 0 means it's used. We use 1
        /// for free since it makes it very slightly faster to find free
        /// chunks.
        bitmap: Offset(u64),
        bitmap_count: usize,

        /// The contiguous buffer of chunks.
        chunks: Offset(u8),

        /// Initialize the allocator map with a given buf and memory layout.
        pub fn init(buf: OffsetBuf, l: Layout) Self {
            assert(@intFromPtr(buf.start()) % base_align == 0);

            // Initialize our bitmaps to all 1s to note that all chunks are free.
            const bitmap = buf.member(u64, l.bitmap_start);
            const bitmap_ptr = bitmap.ptr(buf);
            @memset(bitmap_ptr[0..l.bitmap_count], std.math.maxInt(u64));

            return .{
                .bitmap = bitmap,
                .bitmap_count = l.bitmap_count,
                .chunks = buf.member(u8, l.chunks_start),
            };
        }

        /// Allocate n elements of type T. This will return error.OutOfMemory
        /// if there isn't enough space in the backing buffer.
        ///
        /// Use (size.zig).getOffset to get the base offset from the backing
        /// memory for portable storage.
        pub fn alloc(
            self: *Self,
            comptime T: type,
            base: anytype,
            n: usize,
        ) Allocator.Error![]T {
            // note: we don't handle alignment yet, we just require that all
            // types are properly aligned. This is a limitation that should be
            // fixed but we haven't needed it. Contributor friendly: add tests
            // and fix this.
            assert(chunk_size % @alignOf(T) == 0);
            assert(n > 0);

            const byte_count = std.math.mul(usize, @sizeOf(T), n) catch
                return error.OutOfMemory;
            const chunk_count = std.math.divCeil(usize, byte_count, chunk_size) catch
                return error.OutOfMemory;

            // Find the index of the free chunk. This also marks it as used.
            const bitmaps = self.bitmap.ptr(base);
            const idx = findFreeChunks(bitmaps[0..self.bitmap_count], chunk_count) orelse
                return error.OutOfMemory;

            const chunks = self.chunks.ptr(base);
            const ptr: [*]T = @alignCast(@ptrCast(&chunks[idx * chunk_size]));
            return ptr[0..n];
        }

        pub fn free(self: *Self, base: anytype, slice: anytype) void {
            // Convert the slice of whatever type to a slice of bytes. We
            // can then use the byte len and chunk size to determine the
            // number of chunks that were allocated.
            const bytes = std.mem.sliceAsBytes(slice);
            const aligned_len = std.mem.alignForward(usize, bytes.len, chunk_size);
            const chunk_count = @divExact(aligned_len, chunk_size);

            // From the pointer, we can calculate the exact index.
            const chunks = self.chunks.ptr(base);
            const chunk_idx = @divExact(@intFromPtr(slice.ptr) - @intFromPtr(chunks), chunk_size);

            const bitmaps = self.bitmap.ptr(base);

            // Current bitmap index.
            var i: usize = @divFloor(chunk_idx, 64);
            // Number of chunks we still have to mark as free.
            var rem: usize = chunk_count;

            // Mark any bits in the starting bitmap that need to be marked.
            {
                // Bit index.
                const bit = chunk_idx % 64;
                // Number of bits we need to mark in this bitmap.
                const bits = @min(rem, 64 - bit);

                bitmaps[i] |= ~@as(u64, 0) >> @intCast(64 - bits) << @intCast(bit);
                rem -= bits;
            }

            // Mark any full bitmaps worth of bits that need to be marked.
            i += 1;
            while (rem > 64) : (i += 1) {
                bitmaps[i] = std.math.maxInt(u64);
                rem -= 64;
            }

            // Mark any bits at the start of this last bitmap if it needs it.
            if (rem > 0) {
                bitmaps[i] |= ~@as(u64, 0) >> @intCast(64 - rem);
            }
        }

        /// For testing only.
        fn isAllocated(self: *Self, base: anytype, slice: anytype) bool {
            comptime assert(@import("builtin").is_test);

            const bytes = std.mem.sliceAsBytes(slice);
            const aligned_len = std.mem.alignForward(usize, bytes.len, chunk_size);
            const chunk_count = @divExact(aligned_len, chunk_size);

            const chunks = self.chunks.ptr(base);
            const chunk_idx = @divExact(@intFromPtr(slice.ptr) - @intFromPtr(chunks), chunk_size);

            const bitmaps = self.bitmap.ptr(base);

            for (chunk_idx..chunk_idx + chunk_count) |i| {
                const bitmap = @divFloor(i, bitmap_bit_size);
                const bit = i % bitmap_bit_size;
                if (bitmaps[bitmap] & (@as(u64, 1) << @intCast(bit)) != 0) {
                    return false;
                }
            }

            return true;
        }

        /// For debugging
        fn dumpBitmaps(self: *Self, base: anytype) void {
            const bitmaps = self.bitmap.ptr(base);
            for (bitmaps[0..self.bitmap_count], 0..) |bitmap, idx| {
                std.log.warn("bm={b} idx={}", .{ bitmap, idx });
            }
        }

        pub const Layout = struct {
            total_size: usize,
            bitmap_count: usize,
            bitmap_start: usize,
            chunks_start: usize,
        };

        /// Get the layout for the given capacity. The capacity is in
        /// number of bytes, not chunks. The capacity will likely be
        /// rounded up to the nearest chunk size and bitmap size so
        /// everything is perfectly divisible.
        pub fn layout(cap: usize) Layout {
            // Align the cap forward to our chunk size so we always have
            // a full chunk at the end.
            const aligned_cap = alignForward(usize, cap, chunk_size);

            // Calculate the number of bitmaps. We need 1 bitmap per 64 chunks.
            // We align the chunk count forward so our bitmaps are full so we
            // don't have to handle the case where we have a partial bitmap.
            const chunk_count = @divExact(aligned_cap, chunk_size);
            const aligned_chunk_count = alignForward(usize, chunk_count, 64);
            const bitmap_count = @divExact(aligned_chunk_count, 64);

            const bitmap_start = 0;
            const bitmap_end = @sizeOf(u64) * bitmap_count;
            const chunks_start = alignForward(usize, bitmap_end, @alignOf(u8));
            const chunks_end = chunks_start + (aligned_cap * chunk_size);
            const total_size = chunks_end;

            return Layout{
                .total_size = total_size,
                .bitmap_count = bitmap_count,
                .bitmap_start = bitmap_start,
                .chunks_start = chunks_start,
            };
        }
    };
}

/// Find `n` sequential free chunks in the given bitmaps and return the index
/// of the first chunk. If no chunks are found, return `null`. This also updates
/// the bitmap to mark the chunks as used.
fn findFreeChunks(bitmaps: []u64, n: usize) ?usize {
    // NOTE: This is a naive implementation that just iterates through the
    // bitmaps. There is very likely a more efficient way to do this but
    // I'm not a bit twiddling expert. Perhaps even SIMD could be used here
    // but unsure. Contributor friendly: let's benchmark and improve this!

    // Large chunks require special handling.
    if (n > @bitSizeOf(u64)) {
        var i: usize = 0;
        search: while (i < bitmaps.len) {
            // Number of chunks available at the end of this bitmap.
            const prefix = @clz(~bitmaps[i]);

            // If there are no chunks available at the end of this bitmap
            // then we can't start in it, so we'll try the next one.
            if (prefix == 0) {
                i += 1;
                continue;
            }

            // Starting position if we manage to find the span we need here.
            const start_bitmap = i;
            const start_bit = 64 - prefix;

            // The remaining number of sequential free chunks we need to find.
            var rem: usize = n - prefix;

            i += 1;
            while (rem > 64) : (i += 1) {
                // We ran out of bitmaps, there's no sufficiently large gap.
                if (i >= bitmaps.len) return null;

                // There's more than 64 remaining chunks and this bitmap has
                // content in it, so we try starting again with this bitmap.
                if (bitmaps[i] != std.math.maxInt(u64)) continue :search;

                // This bitmap is completely free, we can subtract 64 from
                // our remaining number.
                rem -= 64;
            }

            // If the number of available chunks at the start of this bitmap
            // is less than the remaining required, we have to try again.
            if (@ctz(~bitmaps[i]) < rem) continue;

            const suffix = (n - prefix) % 64;

            // Found! Mark everything between our start and end as full.
            bitmaps[start_bitmap] ^= ~@as(u64, 0) >> @intCast(start_bit) << @intCast(start_bit);
            const full_bitmaps = @divFloor(n - prefix - suffix, 64);
            for (bitmaps[start_bitmap + 1 ..][0..full_bitmaps]) |*bitmap| {
                bitmap.* = 0;
            }
            if (suffix > 0) bitmaps[i] ^= ~@as(u64, 0) >> @intCast(64 - suffix);

            return start_bitmap * 64 + start_bit;
        }

        return null;
    }

    assert(n <= @bitSizeOf(u64));
    for (bitmaps, 0..) |*bitmap, idx| {
        // Shift the bitmap to find `n` sequential free chunks.
        // EXAMPLE:
        // n = 4
        // shifted = 001111001011110010
        //         & 000111100101111001
        //         & 000011110010111100
        //         & 000001111001011110
        //         = 000001000000010000
        //                ^       ^
        // In this example there are 2 places with at least 4 sequential 1s.
        var shifted: u64 = bitmap.*;
        for (1..n) |i| shifted &= bitmap.* >> @intCast(i);

        // If we have zero then we have no matches
        if (shifted == 0) continue;

        // Trailing zeroes gets us the index of the first bit index with at
        // least `n` sequential 1s. In the example above, that would be `4`.
        const bit = @ctz(shifted);

        // Calculate the mask so we can mark it as used
        const mask = (@as(u64, std.math.maxInt(u64)) >> @intCast(64 - n)) << @intCast(bit);
        bitmap.* ^= mask;

        return (idx * 64) + bit;
    }

    return null;
}

test "findFreeChunks single found" {
    const testing = std.testing;

    var bitmaps = [_]u64{
        0b10000000_00000000_00000000_00000000_00000000_00000000_00001110_00000000,
    };
    const idx = findFreeChunks(&bitmaps, 2).?;
    try testing.expectEqual(@as(usize, 9), idx);
    try testing.expectEqual(
        0b10000000_00000000_00000000_00000000_00000000_00000000_00001000_00000000,
        bitmaps[0],
    );
}

test "findFreeChunks single not found" {
    const testing = std.testing;

    var bitmaps = [_]u64{0b10000111_00000000_00000000_00000000_00000000_00000000_00000000_00000000};
    const idx = findFreeChunks(&bitmaps, 4);
    try testing.expect(idx == null);
}

test "findFreeChunks multiple found" {
    const testing = std.testing;

    var bitmaps = [_]u64{
        0b10000111_00000000_00000000_00000000_00000000_00000000_00000000_01110000,
        0b10000000_00111110_00000000_00000000_00000000_00000000_00111110_00000000,
    };
    const idx = findFreeChunks(&bitmaps, 4).?;
    try testing.expectEqual(@as(usize, 73), idx);
    try testing.expectEqual(
        0b10000000_00111110_00000000_00000000_00000000_00000000_00100000_00000000,
        bitmaps[1],
    );
}

test "findFreeChunks exactly 64 chunks" {
    const testing = std.testing;

    var bitmaps = [_]u64{
        0b11111111_11111111_11111111_11111111_11111111_11111111_11111111_11111111,
    };
    const idx = findFreeChunks(&bitmaps, 64).?;
    try testing.expectEqual(
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
        bitmaps[0],
    );
    try testing.expectEqual(@as(usize, 0), idx);
}

test "findFreeChunks larger than 64 chunks" {
    const testing = std.testing;

    var bitmaps = [_]u64{
        0b11111111_11111111_11111111_11111111_11111111_11111111_11111111_11111111,
        0b11111111_11111111_11111111_11111111_11111111_11111111_11111111_11111111,
    };
    const idx = findFreeChunks(&bitmaps, 65).?;
    try testing.expectEqual(
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
        bitmaps[0],
    );
    try testing.expectEqual(
        0b11111111_11111111_11111111_11111111_11111111_11111111_11111111_11111110,
        bitmaps[1],
    );
    try testing.expectEqual(@as(usize, 0), idx);
}

test "findFreeChunks larger than 64 chunks not at beginning" {
    const testing = std.testing;

    var bitmaps = [_]u64{
        0b11111111_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
        0b11111111_11111111_11111111_11111111_11111111_11111111_11111111_11111111,
        0b11111111_11111111_11111111_11111111_11111111_11111111_11111111_11111111,
    };
    const idx = findFreeChunks(&bitmaps, 65).?;
    try testing.expectEqual(
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
        bitmaps[0],
    );
    try testing.expectEqual(
        0b11111110_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
        bitmaps[1],
    );
    try testing.expectEqual(
        0b11111111_11111111_11111111_11111111_11111111_11111111_11111111_11111111,
        bitmaps[2],
    );
    try testing.expectEqual(@as(usize, 56), idx);
}

test "findFreeChunks larger than 64 chunks exact" {
    const testing = std.testing;

    var bitmaps = [_]u64{
        0b11111111_11111111_11111111_11111111_11111111_11111111_11111111_11111111,
        0b11111111_11111111_11111111_11111111_11111111_11111111_11111111_11111111,
    };
    const idx = findFreeChunks(&bitmaps, 128).?;
    try testing.expectEqual(
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
        bitmaps[0],
    );
    try testing.expectEqual(
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
        bitmaps[1],
    );
    try testing.expectEqual(@as(usize, 0), idx);
}

test "BitmapAllocator layout" {
    const Alloc = BitmapAllocator(4);
    const cap = 64 * 4;

    const testing = std.testing;
    const layout = Alloc.layout(cap);

    // We expect to use one bitmap since the cap is bytes.
    try testing.expectEqual(@as(usize, 1), layout.bitmap_count);
}

test "BitmapAllocator alloc sequentially" {
    const Alloc = BitmapAllocator(4);
    const cap = 64;

    const testing = std.testing;
    const alloc = testing.allocator;
    const layout = Alloc.layout(cap);
    const buf = try alloc.alignedAlloc(u8, Alloc.base_align, layout.total_size);
    defer alloc.free(buf);

    var bm = Alloc.init(.init(buf), layout);
    const ptr = try bm.alloc(u8, buf, 1);
    ptr[0] = 'A';

    const ptr2 = try bm.alloc(u8, buf, 1);
    try testing.expect(@intFromPtr(ptr.ptr) != @intFromPtr(ptr2.ptr));

    // Should grab the next chunk
    try testing.expectEqual(@intFromPtr(ptr.ptr) + 4, @intFromPtr(ptr2.ptr));

    // Free ptr and next allocation should be back
    bm.free(buf, ptr);
    const ptr3 = try bm.alloc(u8, buf, 1);
    try testing.expectEqual(@intFromPtr(ptr.ptr), @intFromPtr(ptr3.ptr));
}

test "BitmapAllocator alloc non-byte" {
    const Alloc = BitmapAllocator(4);
    const cap = 128;

    const testing = std.testing;
    const alloc = testing.allocator;
    const layout = Alloc.layout(cap);
    const buf = try alloc.alignedAlloc(u8, Alloc.base_align, layout.total_size);
    defer alloc.free(buf);

    var bm = Alloc.init(.init(buf), layout);
    const ptr = try bm.alloc(u21, buf, 1);
    ptr[0] = 'A';

    const ptr2 = try bm.alloc(u21, buf, 1);
    try testing.expect(@intFromPtr(ptr.ptr) != @intFromPtr(ptr2.ptr));
    try testing.expectEqual(@intFromPtr(ptr.ptr) + 4, @intFromPtr(ptr2.ptr));

    // Free ptr and next allocation should be back
    bm.free(buf, ptr);
    const ptr3 = try bm.alloc(u21, buf, 1);
    try testing.expectEqual(@intFromPtr(ptr.ptr), @intFromPtr(ptr3.ptr));
}

test "BitmapAllocator alloc non-byte multi-chunk" {
    const Alloc = BitmapAllocator(4 * @sizeOf(u21));
    const cap = 128;

    const testing = std.testing;
    const alloc = testing.allocator;
    const layout = Alloc.layout(cap);
    const buf = try alloc.alignedAlloc(u8, Alloc.base_align, layout.total_size);
    defer alloc.free(buf);

    var bm = Alloc.init(.init(buf), layout);
    const ptr = try bm.alloc(u21, buf, 6);
    try testing.expectEqual(@as(usize, 6), ptr.len);
    for (ptr) |*v| v.* = 'A';

    const ptr2 = try bm.alloc(u21, buf, 1);
    try testing.expect(@intFromPtr(ptr.ptr) != @intFromPtr(ptr2.ptr));
    try testing.expectEqual(@intFromPtr(ptr.ptr) + (@sizeOf(u21) * 4 * 2), @intFromPtr(ptr2.ptr));

    // Free ptr and next allocation should be back
    bm.free(buf, ptr);
    const ptr3 = try bm.alloc(u21, buf, 1);
    try testing.expectEqual(@intFromPtr(ptr.ptr), @intFromPtr(ptr3.ptr));
}

test "BitmapAllocator alloc large" {
    const Alloc = BitmapAllocator(2);
    const cap = 256;

    const testing = std.testing;
    const alloc = testing.allocator;
    const layout = Alloc.layout(cap);
    const buf = try alloc.alignedAlloc(u8, Alloc.base_align, layout.total_size);
    defer alloc.free(buf);

    var bm = Alloc.init(.init(buf), layout);
    const ptr = try bm.alloc(u8, buf, 129);
    ptr[0] = 'A';
    bm.free(buf, ptr);
}

test "BitmapAllocator alloc and free one bitmap" {
    const Alloc = BitmapAllocator(1);
    // Capacity such that we'll have 3 bitmaps.
    const cap = Alloc.bitmap_bit_size * 3;

    const testing = std.testing;
    const alloc = testing.allocator;
    const layout = Alloc.layout(cap);
    const buf = try alloc.alignedAlloc(u8, Alloc.base_align, layout.total_size);
    defer alloc.free(buf);

    var bm = Alloc.init(.init(buf), layout);

    // Allocate exactly one bitmap worth of bytes.
    const slice = try bm.alloc(u8, buf, Alloc.bitmap_bit_size);
    try testing.expectEqual(Alloc.bitmap_bit_size, slice.len);

    @memset(slice, 0x11);
    try testing.expectEqualSlices(
        u8,
        &@as([Alloc.bitmap_bit_size]u8, @splat(0x11)),
        slice,
    );

    // Free it
    try testing.expect(bm.isAllocated(buf, slice));
    bm.free(buf, slice);
    try testing.expect(!bm.isAllocated(buf, slice));

    // All of our bitmaps should be free.
    try testing.expectEqualSlices(
        u64,
        &@as([3]u64, @splat(~@as(u64, 0))),
        bm.bitmap.ptr(buf)[0..3],
    );
}

test "BitmapAllocator alloc and free half bitmap" {
    const Alloc = BitmapAllocator(1);
    // Capacity such that we'll have 3 bitmaps.
    const cap = Alloc.bitmap_bit_size * 3;

    const testing = std.testing;
    const alloc = testing.allocator;
    const layout = Alloc.layout(cap);
    const buf = try alloc.alignedAlloc(u8, Alloc.base_align, layout.total_size);
    defer alloc.free(buf);

    var bm = Alloc.init(.init(buf), layout);

    // Allocate exactly half a bitmap worth of bytes.
    const slice = try bm.alloc(u8, buf, Alloc.bitmap_bit_size / 2);
    try testing.expectEqual(Alloc.bitmap_bit_size / 2, slice.len);

    @memset(slice, 0x11);
    try testing.expectEqualSlices(
        u8,
        &@as([Alloc.bitmap_bit_size / 2]u8, @splat(0x11)),
        slice,
    );

    // Free it
    try testing.expect(bm.isAllocated(buf, slice));
    bm.free(buf, slice);
    try testing.expect(!bm.isAllocated(buf, slice));

    // All of our bitmaps should be free.
    try testing.expectEqualSlices(
        u64,
        &@as([3]u64, @splat(~@as(u64, 0))),
        bm.bitmap.ptr(buf)[0..3],
    );
}

test "BitmapAllocator alloc and free two half bitmaps" {
    const Alloc = BitmapAllocator(1);
    // Capacity such that we'll have 3 bitmaps.
    const cap = Alloc.bitmap_bit_size * 3;

    const testing = std.testing;
    const alloc = testing.allocator;
    const layout = Alloc.layout(cap);
    const buf = try alloc.alignedAlloc(u8, Alloc.base_align, layout.total_size);
    defer alloc.free(buf);

    var bm = Alloc.init(.init(buf), layout);

    // Allocate exactly one bitmap worth of bytes across two allocations.
    const slice = try bm.alloc(u8, buf, Alloc.bitmap_bit_size / 2);
    try testing.expectEqual(Alloc.bitmap_bit_size / 2, slice.len);

    @memset(slice, 0x11);
    try testing.expectEqualSlices(
        u8,
        &@as([Alloc.bitmap_bit_size / 2]u8, @splat(0x11)),
        slice,
    );

    const slice2 = try bm.alloc(u8, buf, Alloc.bitmap_bit_size / 2);
    try testing.expectEqual(Alloc.bitmap_bit_size / 2, slice2.len);

    @memset(slice2, 0x22);
    try testing.expectEqualSlices(
        u8,
        &@as([Alloc.bitmap_bit_size / 2]u8, @splat(0x22)),
        slice2,
    );
    try testing.expectEqualSlices(
        u8,
        &@as([Alloc.bitmap_bit_size / 2]u8, @splat(0x11)),
        slice,
    );

    // Free them
    try testing.expect(bm.isAllocated(buf, slice2));
    bm.free(buf, slice2);
    try testing.expect(!bm.isAllocated(buf, slice2));
    try testing.expect(bm.isAllocated(buf, slice));
    bm.free(buf, slice);
    try testing.expect(!bm.isAllocated(buf, slice));

    // All of our bitmaps should be free.
    try testing.expectEqualSlices(
        u64,
        &@as([3]u64, @splat(~@as(u64, 0))),
        bm.bitmap.ptr(buf)[0..3],
    );
}

test "BitmapAllocator alloc and free 1.5 bitmaps" {
    const Alloc = BitmapAllocator(1);
    // Capacity such that we'll have 3 bitmaps.
    const cap = Alloc.bitmap_bit_size * 3;

    const testing = std.testing;
    const alloc = testing.allocator;
    const layout = Alloc.layout(cap);
    const buf = try alloc.alignedAlloc(u8, Alloc.base_align, layout.total_size);
    defer alloc.free(buf);

    var bm = Alloc.init(.init(buf), layout);

    // Allocate exactly 1.5 bitmaps worth of bytes.
    const slice = try bm.alloc(u8, buf, 3 * Alloc.bitmap_bit_size / 2);
    try testing.expectEqual(3 * Alloc.bitmap_bit_size / 2, slice.len);

    @memset(slice, 0x11);
    try testing.expectEqualSlices(
        u8,
        &@as([3 * Alloc.bitmap_bit_size / 2]u8, @splat(0x11)),
        slice,
    );

    // Free them
    try testing.expect(bm.isAllocated(buf, slice));
    bm.free(buf, slice);
    try testing.expect(!bm.isAllocated(buf, slice));

    // All of our bitmaps should be free.
    try testing.expectEqualSlices(
        u64,
        &@as([3]u64, @splat(~@as(u64, 0))),
        bm.bitmap.ptr(buf)[0..3],
    );
}

test "BitmapAllocator alloc and free two 1.5 bitmaps" {
    const Alloc = BitmapAllocator(1);
    // Capacity such that we'll have 3 bitmaps.
    const cap = Alloc.bitmap_bit_size * 3;

    const testing = std.testing;
    const alloc = testing.allocator;
    const layout = Alloc.layout(cap);
    const buf = try alloc.alignedAlloc(u8, Alloc.base_align, layout.total_size);
    defer alloc.free(buf);

    var bm = Alloc.init(.init(buf), layout);

    // Allocate exactly 3 bitmaps worth of bytes across two allocations.
    const slice = try bm.alloc(u8, buf, 3 * Alloc.bitmap_bit_size / 2);
    try testing.expectEqual(3 * Alloc.bitmap_bit_size / 2, slice.len);

    @memset(slice, 0x11);
    try testing.expectEqualSlices(
        u8,
        &@as([3 * Alloc.bitmap_bit_size / 2]u8, @splat(0x11)),
        slice,
    );

    const slice2 = try bm.alloc(u8, buf, 3 * Alloc.bitmap_bit_size / 2);
    try testing.expectEqual(3 * Alloc.bitmap_bit_size / 2, slice2.len);

    @memset(slice2, 0x22);
    try testing.expectEqualSlices(
        u8,
        &@as([3 * Alloc.bitmap_bit_size / 2]u8, @splat(0x22)),
        slice2,
    );
    try testing.expectEqualSlices(
        u8,
        &@as([3 * Alloc.bitmap_bit_size / 2]u8, @splat(0x11)),
        slice,
    );

    // Free them
    try testing.expect(bm.isAllocated(buf, slice2));
    bm.free(buf, slice2);
    try testing.expect(!bm.isAllocated(buf, slice2));
    try testing.expect(bm.isAllocated(buf, slice));
    bm.free(buf, slice);
    try testing.expect(!bm.isAllocated(buf, slice));

    // All of our bitmaps should be free.
    try testing.expectEqualSlices(
        u64,
        &@as([3]u64, @splat(~@as(u64, 0))),
        bm.bitmap.ptr(buf)[0..3],
    );
}

test "BitmapAllocator alloc and free 1.5 bitmaps offset by 0.75" {
    const Alloc = BitmapAllocator(1);
    // Capacity such that we'll have 3 bitmaps.
    const cap = Alloc.bitmap_bit_size * 3;

    const testing = std.testing;
    const alloc = testing.allocator;
    const layout = Alloc.layout(cap);
    const buf = try alloc.alignedAlloc(u8, Alloc.base_align, layout.total_size);
    defer alloc.free(buf);

    var bm = Alloc.init(.init(buf), layout);

    // Allocate three quarters of a bitmap first.
    const slice = try bm.alloc(u8, buf, 3 * Alloc.bitmap_bit_size / 4);
    try testing.expectEqual(3 * Alloc.bitmap_bit_size / 4, slice.len);

    @memset(slice, 0x11);
    try testing.expectEqualSlices(
        u8,
        &@as([3 * Alloc.bitmap_bit_size / 4]u8, @splat(0x11)),
        slice,
    );

    // Then a 1.5 bitmap sized allocation, so that it spans
    // from 0.75 to 2.25, occupying bits in 3 different bitmaps.
    const slice2 = try bm.alloc(u8, buf, 3 * Alloc.bitmap_bit_size / 2);
    try testing.expectEqual(3 * Alloc.bitmap_bit_size / 2, slice2.len);

    @memset(slice2, 0x22);
    try testing.expectEqualSlices(
        u8,
        &@as([3 * Alloc.bitmap_bit_size / 2]u8, @splat(0x22)),
        slice2,
    );
    try testing.expectEqualSlices(
        u8,
        &@as([3 * Alloc.bitmap_bit_size / 4]u8, @splat(0x11)),
        slice,
    );

    // Free them
    try testing.expect(bm.isAllocated(buf, slice2));
    bm.free(buf, slice2);
    try testing.expect(!bm.isAllocated(buf, slice2));
    try testing.expect(bm.isAllocated(buf, slice));
    bm.free(buf, slice);
    try testing.expect(!bm.isAllocated(buf, slice));

    // All of our bitmaps should be free.
    try testing.expectEqualSlices(
        u64,
        &@as([3]u64, @splat(~@as(u64, 0))),
        bm.bitmap.ptr(buf)[0..3],
    );
}

test "BitmapAllocator alloc and free three 0.75 bitmaps" {
    const Alloc = BitmapAllocator(1);
    // Capacity such that we'll have 3 bitmaps.
    const cap = Alloc.bitmap_bit_size * 3;

    const testing = std.testing;
    const alloc = testing.allocator;
    const layout = Alloc.layout(cap);
    const buf = try alloc.alignedAlloc(u8, Alloc.base_align, layout.total_size);
    defer alloc.free(buf);

    var bm = Alloc.init(.init(buf), layout);

    // Allocate three quarters of a bitmap three times.
    const slice = try bm.alloc(u8, buf, 3 * Alloc.bitmap_bit_size / 4);
    try testing.expectEqual(3 * Alloc.bitmap_bit_size / 4, slice.len);

    @memset(slice, 0x11);
    try testing.expectEqualSlices(
        u8,
        &@as([3 * Alloc.bitmap_bit_size / 4]u8, @splat(0x11)),
        slice,
    );

    const slice2 = try bm.alloc(u8, buf, 3 * Alloc.bitmap_bit_size / 4);
    try testing.expectEqual(3 * Alloc.bitmap_bit_size / 4, slice2.len);

    @memset(slice2, 0x22);
    try testing.expectEqualSlices(
        u8,
        &@as([3 * Alloc.bitmap_bit_size / 4]u8, @splat(0x22)),
        slice2,
    );
    try testing.expectEqualSlices(
        u8,
        &@as([3 * Alloc.bitmap_bit_size / 4]u8, @splat(0x11)),
        slice,
    );

    const slice3 = try bm.alloc(u8, buf, 3 * Alloc.bitmap_bit_size / 4);
    try testing.expectEqual(3 * Alloc.bitmap_bit_size / 4, slice3.len);

    @memset(slice3, 0x33);
    try testing.expectEqualSlices(
        u8,
        &@as([3 * Alloc.bitmap_bit_size / 4]u8, @splat(0x33)),
        slice3,
    );
    try testing.expectEqualSlices(
        u8,
        &@as([3 * Alloc.bitmap_bit_size / 4]u8, @splat(0x22)),
        slice2,
    );
    try testing.expectEqualSlices(
        u8,
        &@as([3 * Alloc.bitmap_bit_size / 4]u8, @splat(0x11)),
        slice,
    );

    // Free them
    try testing.expect(bm.isAllocated(buf, slice2));
    bm.free(buf, slice2);
    try testing.expect(!bm.isAllocated(buf, slice2));
    try testing.expect(bm.isAllocated(buf, slice));
    bm.free(buf, slice);
    try testing.expect(!bm.isAllocated(buf, slice));
    try testing.expect(bm.isAllocated(buf, slice3));
    bm.free(buf, slice3);
    try testing.expect(!bm.isAllocated(buf, slice3));

    // All of our bitmaps should be free.
    try testing.expectEqualSlices(
        u64,
        &@as([3]u64, @splat(~@as(u64, 0))),
        bm.bitmap.ptr(buf)[0..3],
    );
}

test "BitmapAllocator alloc and free two 1.5 bitmaps offset 0.75" {
    const Alloc = BitmapAllocator(1);
    // Capacity such that we'll have 4 bitmaps.
    const cap = Alloc.bitmap_bit_size * 4;

    const testing = std.testing;
    const alloc = testing.allocator;
    const layout = Alloc.layout(cap);
    const buf = try alloc.alignedAlloc(u8, Alloc.base_align, layout.total_size);
    defer alloc.free(buf);

    var bm = Alloc.init(.init(buf), layout);

    // First allocate a 0.75 bitmap
    const slice = try bm.alloc(u8, buf, 3 * Alloc.bitmap_bit_size / 4);
    try testing.expectEqual(3 * Alloc.bitmap_bit_size / 4, slice.len);

    @memset(slice, 0x11);
    try testing.expectEqualSlices(
        u8,
        &@as([3 * Alloc.bitmap_bit_size / 4]u8, @splat(0x11)),
        slice,
    );

    // Then two 1.5 bitmaps
    const slice2 = try bm.alloc(u8, buf, 3 * Alloc.bitmap_bit_size / 2);
    try testing.expectEqual(3 * Alloc.bitmap_bit_size / 2, slice2.len);

    @memset(slice2, 0x22);
    try testing.expectEqualSlices(
        u8,
        &@as([3 * Alloc.bitmap_bit_size / 2]u8, @splat(0x22)),
        slice2,
    );
    try testing.expectEqualSlices(
        u8,
        &@as([3 * Alloc.bitmap_bit_size / 4]u8, @splat(0x11)),
        slice,
    );

    const slice3 = try bm.alloc(u8, buf, 3 * Alloc.bitmap_bit_size / 2);
    try testing.expectEqual(3 * Alloc.bitmap_bit_size / 2, slice3.len);

    @memset(slice3, 0x33);
    try testing.expectEqualSlices(
        u8,
        &@as([3 * Alloc.bitmap_bit_size / 2]u8, @splat(0x33)),
        slice3,
    );
    try testing.expectEqualSlices(
        u8,
        &@as([3 * Alloc.bitmap_bit_size / 2]u8, @splat(0x22)),
        slice2,
    );
    try testing.expectEqualSlices(
        u8,
        &@as([3 * Alloc.bitmap_bit_size / 4]u8, @splat(0x11)),
        slice,
    );

    // Free them
    try testing.expect(bm.isAllocated(buf, slice2));
    bm.free(buf, slice2);
    try testing.expect(!bm.isAllocated(buf, slice2));
    try testing.expect(bm.isAllocated(buf, slice));
    bm.free(buf, slice);
    try testing.expect(!bm.isAllocated(buf, slice));
    try testing.expect(bm.isAllocated(buf, slice3));
    bm.free(buf, slice3);
    try testing.expect(!bm.isAllocated(buf, slice3));

    // All of our bitmaps should be free.
    try testing.expectEqualSlices(
        u64,
        &@as([4]u64, @splat(~@as(u64, 0))),
        bm.bitmap.ptr(buf)[0..4],
    );
}
