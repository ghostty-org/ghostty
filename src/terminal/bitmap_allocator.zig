const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
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

        pub const base_align: std.mem.Alignment = .fromByteUnits(@alignOf(u64));
        pub const bitmap_bit_size = @bitSizeOf(u64);

        /// The bitmap of available chunks. Each bit represents a chunk. A
        /// 0 means the chunk is free and a 1 means it's used, so an
        /// all-zero bitmap is a fully free allocator.
        bitmap: Offset(u64),
        bitmap_count: usize,

        /// Lowest bitmap word index that may contain a free bit; words
        /// below it are fully allocated, so alloc scans can start here
        /// instead of at zero.
        search_start: usize = 0,

        /// The contiguous buffer of chunks.
        chunks: Offset(u8),

        /// Initialize the allocator map with a given buf and memory layout.
        pub fn init(buf: OffsetBuf, l: Layout) Self {
            assert(base_align.check(@intFromPtr(buf.start())));

            // Clear our bitmaps to note that all chunks are free.
            const bitmap = buf.member(u64, l.bitmap_start);
            @memset(bitmap.ptr(buf)[0..l.bitmap_count], 0);

            return initAssumeZeroed(buf, l);
        }

        /// Initialize the allocator map over memory that the caller
        /// guarantees is already zero-filled.
        ///
        /// This writes nothing to the buffer: an all-zero bitmap already
        /// marks every chunk as free. Behavior is undefined if the bitmap
        /// region is not zero.
        pub fn initAssumeZeroed(buf: OffsetBuf, l: Layout) Self {
            assert(base_align.check(@intFromPtr(buf.start())));
            return .{
                .bitmap = buf.member(u64, l.bitmap_start),
                .bitmap_count = l.bitmap_count,
                .chunks = buf.member(u8, l.chunks_start),
            };
        }

        /// Returns the number of bytes required to allocate n elements of
        /// type T. This accounts for the chunk size alignment used by the
        /// bitmap allocator.
        pub fn bytesRequired(comptime T: type, n: usize) usize {
            const byte_count = @sizeOf(T) * n;
            return alignForward(usize, byte_count, chunk_size);
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
            // Words below search_start have no free bits, so no free span
            // can start in or cross them and it is safe to skip them.
            const bitmaps = self.bitmap.ptr(base);
            const start = @min(self.search_start, self.bitmap_count);
            const rel = findFreeChunks(bitmaps[start..self.bitmap_count], chunk_count) orelse
                return error.OutOfMemory;
            const idx = start * bitmap_bit_size + rel;

            // Advance past any words the allocation just filled so the
            // next scan starts at the first word with a free bit.
            self.search_start = start: {
                var new_start = start;
                while (new_start < self.bitmap_count and
                    bitmaps[new_start] == std.math.maxInt(u64))
                {
                    new_start += 1;
                }
                break :start new_start;
            };

            const chunks = self.chunks.ptr(base);
            const ptr: [*]T = @ptrCast(@alignCast(&chunks[idx * chunk_size]));
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

            // The freed word gains free bits, so scans must not skip it.
            self.search_start = @min(
                self.search_start,
                @divFloor(chunk_idx, bitmap_bit_size),
            );

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

                bitmaps[i] &= ~(~@as(u64, 0) >> @intCast(64 - bits) << @intCast(bit));
                rem -= bits;
            }

            // Mark any full bitmaps worth of bits that need to be marked.
            i += 1;
            while (rem > 64) : (i += 1) {
                bitmaps[i] = 0;
                rem -= 64;
            }

            // Mark any bits at the start of this last bitmap if it needs it.
            if (rem > 0) {
                bitmaps[i] &= ~(~@as(u64, 0) >> @intCast(64 - rem));
            }
        }

        /// Returns the total capacity in bytes.
        pub fn capacityBytes(self: Self) usize {
            return self.bitmap_count * bitmap_bit_size * chunk_size;
        }

        /// Returns the number of bytes currently in use.
        pub fn usedBytes(self: Self, base: anytype) usize {
            const bitmaps = self.bitmap.ptr(base);
            var used_chunks: usize = 0;
            for (bitmaps[0..self.bitmap_count]) |bitmap| used_chunks += @popCount(bitmap);
            return used_chunks * chunk_size;
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
                if (bitmaps[bitmap] & (@as(u64, 1) << @intCast(bit)) == 0) {
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

            // The chunks region must be exactly the bytes addressable by
            // the bitmaps: one chunk per bit of every bitmap. Anything more
            // is unreachable waste, while anything less would let alloc
            // hand out memory beyond the region, since init marks every
            // bitmap bit as free.
            const chunks_end = chunks_start + (aligned_chunk_count * chunk_size);
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
            const prefix = @clz(bitmaps[i]);

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
                if (bitmaps[i] != 0) continue :search;

                // This bitmap is completely free, we can subtract 64 from
                // our remaining number.
                rem -= 64;
            }

            // If the number of available chunks at the start of this bitmap
            // is less than the remaining required, we have to try again.
            if (@ctz(bitmaps[i]) < rem) continue;

            const suffix = (n - prefix) % 64;

            // Found! Mark everything between our start and end as used.
            bitmaps[start_bitmap] |= ~@as(u64, 0) >> @intCast(start_bit) << @intCast(start_bit);
            const full_bitmaps = @divFloor(n - prefix - suffix, 64);
            for (bitmaps[start_bitmap + 1 ..][0..full_bitmaps]) |*bitmap| {
                bitmap.* = std.math.maxInt(u64);
            }
            if (suffix > 0) bitmaps[i] |= ~@as(u64, 0) >> @intCast(64 - suffix);

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
        // Work on the inverted word so that free chunks are 1 bits.
        const free = ~bitmap.*;
        var shifted: u64 = free;
        for (1..n) |i| shifted &= free >> @intCast(i);

        // If we have zero then we have no matches
        if (shifted == 0) continue;

        // Trailing zeroes gets us the index of the first bit index with at
        // least `n` sequential 1s. In the example above, that would be `4`.
        const bit = @ctz(shifted);

        // Calculate the mask so we can mark it as used
        const mask = (@as(u64, std.math.maxInt(u64)) >> @intCast(64 - n)) << @intCast(bit);
        bitmap.* |= mask;

        return (idx * 64) + bit;
    }

    return null;
}

test "findFreeChunks single found" {
    const testing = std.testing;

    var bitmaps = [_]u64{
        0b01111111_11111111_11111111_11111111_11111111_11111111_11110001_11111111,
    };
    const idx = findFreeChunks(&bitmaps, 2).?;
    try testing.expectEqual(@as(usize, 9), idx);
    try testing.expectEqual(
        0b01111111_11111111_11111111_11111111_11111111_11111111_11110111_11111111,
        bitmaps[0],
    );
}

test "findFreeChunks single not found" {
    const testing = std.testing;

    var bitmaps = [_]u64{0b01111000_11111111_11111111_11111111_11111111_11111111_11111111_11111111};
    const idx = findFreeChunks(&bitmaps, 4);
    try testing.expect(idx == null);
}

test "findFreeChunks multiple found" {
    const testing = std.testing;

    var bitmaps = [_]u64{
        0b01111000_11111111_11111111_11111111_11111111_11111111_11111111_10001111,
        0b01111111_11000001_11111111_11111111_11111111_11111111_11000001_11111111,
    };
    const idx = findFreeChunks(&bitmaps, 4).?;
    try testing.expectEqual(@as(usize, 73), idx);
    try testing.expectEqual(
        0b01111111_11000001_11111111_11111111_11111111_11111111_11011111_11111111,
        bitmaps[1],
    );
}

test "findFreeChunks exactly 64 chunks" {
    const testing = std.testing;

    var bitmaps = [_]u64{
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
    };
    const idx = findFreeChunks(&bitmaps, 64).?;
    try testing.expectEqual(
        0b11111111_11111111_11111111_11111111_11111111_11111111_11111111_11111111,
        bitmaps[0],
    );
    try testing.expectEqual(@as(usize, 0), idx);
}

test "findFreeChunks larger than 64 chunks" {
    const testing = std.testing;

    var bitmaps = [_]u64{
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
    };
    const idx = findFreeChunks(&bitmaps, 65).?;
    try testing.expectEqual(
        0b11111111_11111111_11111111_11111111_11111111_11111111_11111111_11111111,
        bitmaps[0],
    );
    try testing.expectEqual(
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000001,
        bitmaps[1],
    );
    try testing.expectEqual(@as(usize, 0), idx);
}

test "findFreeChunks larger than 64 chunks not at beginning" {
    const testing = std.testing;

    var bitmaps = [_]u64{
        0b00000000_11111111_11111111_11111111_11111111_11111111_11111111_11111111,
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
    };
    const idx = findFreeChunks(&bitmaps, 65).?;
    try testing.expectEqual(
        0b11111111_11111111_11111111_11111111_11111111_11111111_11111111_11111111,
        bitmaps[0],
    );
    try testing.expectEqual(
        0b00000001_11111111_11111111_11111111_11111111_11111111_11111111_11111111,
        bitmaps[1],
    );
    try testing.expectEqual(
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
        bitmaps[2],
    );
    try testing.expectEqual(@as(usize, 56), idx);
}

test "findFreeChunks larger than 64 chunks exact" {
    const testing = std.testing;

    var bitmaps = [_]u64{
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
    };
    const idx = findFreeChunks(&bitmaps, 128).?;
    try testing.expectEqual(
        0b11111111_11111111_11111111_11111111_11111111_11111111_11111111_11111111,
        bitmaps[0],
    );
    try testing.expectEqual(
        0b11111111_11111111_11111111_11111111_11111111_11111111_11111111_11111111,
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

test "BitmapAllocator layout chunks region matches bitmap addressable bytes" {
    const testing = std.testing;

    // The chunks region must be exactly the bytes addressable by the
    // bitmaps: one chunk per bit of every bitmap. Prior to this being
    // fixed, the region was over-reserved by a factor of chunk_size
    // (~186 KiB of dead space per standard page), while capacities
    // smaller than one full bitmap were under-reserved, allowing
    // out-of-bounds allocations.
    inline for (.{ 1, 2, 4, 16, 32 }) |chunk| {
        const Alloc = BitmapAllocator(chunk);
        for ([_]usize{
            1,
            chunk,
            chunk + 1,
            48,
            64,
            512,
            1024,
            2048,
            8192,
            8193,
        }) |cap| {
            const layout = Alloc.layout(cap);
            const chunks_size = layout.total_size - layout.chunks_start;

            // Reserved == addressable by the bitmaps. This must match
            // capacityBytes() which is computed from the bitmap count.
            try testing.expectEqual(
                layout.bitmap_count * Alloc.bitmap_bit_size * chunk,
                chunks_size,
            );

            // We always reserve at least the requested capacity.
            try testing.expect(chunks_size >= cap);
        }
    }
}

test "BitmapAllocator layout small capacity cannot alloc out of bounds" {
    // Regression test: for capacities smaller than one full bitmap of
    // chunks, init marks all bitmap bits as free, so alloc will hand out
    // chunks up to the full bitmap. The layout must reserve that entire
    // addressable region or those allocations would be out of bounds of
    // the backing buffer.
    const Alloc = BitmapAllocator(16);
    const cap = 48; // 3 chunks, bitmap addresses 64

    const testing = std.testing;
    const alloc = testing.allocator;
    const layout = Alloc.layout(cap);
    const buf = try alloc.alignedAlloc(u8, Alloc.base_align, layout.total_size);
    defer alloc.free(buf);

    var bm = Alloc.init(.init(buf), layout);

    // Allocate every chunk the bitmap can hand out and verify each is
    // fully within the backing buffer. Writing to each allocation lets
    // the testing allocator catch any out-of-bounds corruption.
    const buf_start = @intFromPtr(buf.ptr);
    const buf_end = buf_start + buf.len;
    var count: usize = 0;
    while (bm.alloc(u8, buf, 16)) |slice| {
        try testing.expect(@intFromPtr(slice.ptr) >= buf_start);
        try testing.expect(@intFromPtr(slice.ptr) + slice.len <= buf_end);
        @memset(slice, 0xAA);
        count += 1;
    } else |err| {
        try testing.expectEqual(error.OutOfMemory, err);
    }
    try testing.expectEqual(Alloc.bitmap_bit_size, count);
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
        &@as([3]u64, @splat(0)),
        bm.bitmap.ptr(buf)[0..3],
    );
}

test "BitmapAllocator search hint skips full words" {
    const Alloc = BitmapAllocator(1);
    // Capacity such that we'll have 3 bitmaps.
    const cap = Alloc.bitmap_bit_size * 3;

    const testing = std.testing;
    const alloc = testing.allocator;
    const layout = Alloc.layout(cap);
    const buf = try alloc.alignedAlloc(u8, Alloc.base_align, layout.total_size);
    defer alloc.free(buf);

    var bm = Alloc.init(.init(buf), layout);
    try testing.expectEqual(@as(usize, 0), bm.search_start);

    // Fill the first bitmap word exactly with single-chunk allocations.
    var first: []u8 = undefined;
    for (0..Alloc.bitmap_bit_size) |i| {
        const slice = try bm.alloc(u8, buf, 1);
        if (i == 0) first = slice;
    }

    // The first word is exhausted so scans start at the second word.
    try testing.expectEqual(@as(usize, 1), bm.search_start);

    // The next allocation is the first chunk of the second word, so
    // the skipped-word index arithmetic must still yield the right
    // chunk address.
    const next = try bm.alloc(u8, buf, 1);
    try testing.expectEqual(
        @intFromPtr(first.ptr) + Alloc.bitmap_bit_size,
        @intFromPtr(next.ptr),
    );

    // Freeing a chunk in the first word lowers the hint so the freed
    // space is found again.
    bm.free(buf, first);
    try testing.expectEqual(@as(usize, 0), bm.search_start);
    const again = try bm.alloc(u8, buf, 1);
    try testing.expectEqual(@intFromPtr(first.ptr), @intFromPtr(again.ptr));
}

test "BitmapAllocator search hint does not skip partial words" {
    const Alloc = BitmapAllocator(1);
    // Capacity such that we'll have 2 bitmaps.
    const cap = Alloc.bitmap_bit_size * 2;

    const testing = std.testing;
    const alloc = testing.allocator;
    const layout = Alloc.layout(cap);
    const buf = try alloc.alignedAlloc(u8, Alloc.base_align, layout.total_size);
    defer alloc.free(buf);

    var bm = Alloc.init(.init(buf), layout);

    // Allocate all but 4 chunks of the first word.
    var first: []u8 = undefined;
    for (0..Alloc.bitmap_bit_size - 4) |i| {
        const slice = try bm.alloc(u8, buf, 1);
        if (i == 0) first = slice;
    }

    // An 8-chunk run can't fit the 4 remaining bits (small runs never
    // span words), so it comes from the second word — but the hint
    // must stay at the first word, which still has free bits.
    const big = try bm.alloc(u8, buf, 8);
    try testing.expectEqual(
        @intFromPtr(first.ptr) + Alloc.bitmap_bit_size,
        @intFromPtr(big.ptr),
    );
    try testing.expectEqual(@as(usize, 0), bm.search_start);

    // A 4-chunk run fits the first word's remaining bits exactly; a
    // hint that skipped the partial word would wrongly place this in
    // the second word (or report OutOfMemory once that filled).
    const small = try bm.alloc(u8, buf, 4);
    try testing.expectEqual(
        @intFromPtr(first.ptr) + Alloc.bitmap_bit_size - 4,
        @intFromPtr(small.ptr),
    );

    // Now the first word is full and the hint advances past it.
    try testing.expectEqual(@as(usize, 1), bm.search_start);
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
        &@as([3]u64, @splat(0)),
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
        &@as([3]u64, @splat(0)),
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
        &@as([3]u64, @splat(0)),
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
        &@as([3]u64, @splat(0)),
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
        &@as([3]u64, @splat(0)),
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
        &@as([3]u64, @splat(0)),
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
        &@as([4]u64, @splat(0)),
        bm.bitmap.ptr(buf)[0..4],
    );
}

test "BitmapAllocator bytesRequired" {
    const testing = std.testing;

    // Chunk size of 16 bytes (like grapheme_chunk in page.zig)
    {
        const Alloc = BitmapAllocator(16);

        // Single byte rounds up to chunk size
        try testing.expectEqual(16, Alloc.bytesRequired(u8, 1));
        try testing.expectEqual(16, Alloc.bytesRequired(u8, 16));
        try testing.expectEqual(32, Alloc.bytesRequired(u8, 17));

        // u21 (4 bytes each)
        try testing.expectEqual(16, Alloc.bytesRequired(u21, 1)); // 4 bytes -> 16
        try testing.expectEqual(16, Alloc.bytesRequired(u21, 4)); // 16 bytes -> 16
        try testing.expectEqual(32, Alloc.bytesRequired(u21, 5)); // 20 bytes -> 32
        try testing.expectEqual(32, Alloc.bytesRequired(u21, 6)); // 24 bytes -> 32
    }

    // Chunk size of 4 bytes
    {
        const Alloc = BitmapAllocator(4);

        try testing.expectEqual(4, Alloc.bytesRequired(u8, 1));
        try testing.expectEqual(4, Alloc.bytesRequired(u8, 4));
        try testing.expectEqual(8, Alloc.bytesRequired(u8, 5));

        // u32 (4 bytes each) - exactly one chunk per element
        try testing.expectEqual(4, Alloc.bytesRequired(u32, 1));
        try testing.expectEqual(8, Alloc.bytesRequired(u32, 2));
    }

    // Chunk size of 32 bytes (like string_chunk in page.zig)
    {
        const Alloc = BitmapAllocator(32);

        try testing.expectEqual(32, Alloc.bytesRequired(u8, 1));
        try testing.expectEqual(32, Alloc.bytesRequired(u8, 32));
        try testing.expectEqual(64, Alloc.bytesRequired(u8, 33));
    }
}
