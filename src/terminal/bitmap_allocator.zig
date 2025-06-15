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

            // From the chunk index, we can find the starting bitmap index
            // and the bit within the last bitmap.
            var bitmap_idx = @divFloor(chunk_idx, 64);
            const bitmap_bit = chunk_idx % 64;
            const bitmaps = self.bitmap.ptr(base);

            // If our chunk count is over 64 then we need to handle the
            // case where we have to mark multiple bitmaps.
            if (chunk_count > 64) {
                const bitmaps_full = @divFloor(chunk_count, 64);
                for (0..bitmaps_full) |i| bitmaps[bitmap_idx + i] = std.math.maxInt(u64);
                bitmap_idx += bitmaps_full;
            }

            // Set the bitmap to mark the chunks as free. Note we have to
            // do chunk_count % 64 to handle the case where our chunk count
            // is using multiple bitmaps.
            const bitmap = &bitmaps[bitmap_idx];
            for (0..chunk_count % 64) |i| {
                const mask = @as(u64, 1) << @intCast(bitmap_bit + i);
                bitmap.* |= mask;
            }
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

    // Large chunks require special handling. In this case we look for
    // divFloor sequential chunks that are maxInt, then look for the mod
    // normally in the next bitmap.
    if (n > @bitSizeOf(u64)) {
        const div = @divFloor(n, @bitSizeOf(u64));
        const mod = n % @bitSizeOf(u64);
        var seq: usize = 0;
        for (bitmaps, 0..) |*bitmap, idx| {
            // If we aren't fully empty then reset the sequence
            if (bitmap.* != std.math.maxInt(u64)) {
                seq = 0;
                continue;
            }

            // If we haven't reached the sequence count we're looking for
            // then add one and continue, we're still accumulating blanks.
            if (seq != div) {
                seq += 1;
                if (seq != div or mod > 0) continue;
            }

            // We've reached the seq count see if this has mod starting empty
            // blanks.
            if (mod > 0) {
                const final = @as(u64, std.math.maxInt(u64)) >> @intCast(64 - mod);
                if (bitmap.* & final == 0) {
                    // No blanks, reset.
                    seq = 0;
                    continue;
                }

                bitmap.* ^= final;
            }

            // Found! Set all in our sequence to full and mask our final.
            // The "zero_mod" modifier below handles the case where we have
            // a perfectly divisible number of chunks so we don't have to
            // mark the trailing bitmap.
            const zero_mod = @intFromBool(mod == 0);
            const start_idx = idx - (seq - zero_mod);
            const end_idx = idx + zero_mod;
            for (start_idx..end_idx) |i| bitmaps[i] = 0;

            return (start_idx * 64);
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
        0b11111111_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
        bitmaps[0],
    );
    try testing.expectEqual(
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
        bitmaps[1],
    );
    try testing.expectEqual(
        0b11111111_11111111_11111111_11111111_11111111_11111111_11111111_11111110,
        bitmaps[2],
    );
    try testing.expectEqual(@as(usize, 64), idx);
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
