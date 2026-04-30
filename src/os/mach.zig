const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const mem = std.mem;
const Allocator = std.mem.Allocator;

/// macOS virtual memory tags for use with mach_vm_map/mach_vm_allocate.
/// These identify memory regions in tools like vmmap and Instruments.
pub const VMTag = enum(u8) {
    application_specific_1 = 240,
    application_specific_2 = 241,
    application_specific_3 = 242,
    application_specific_4 = 243,
    application_specific_5 = 244,
    application_specific_6 = 245,
    application_specific_7 = 246,
    application_specific_8 = 247,
    application_specific_9 = 248,
    application_specific_10 = 249,
    application_specific_11 = 250,
    application_specific_12 = 251,
    application_specific_13 = 252,
    application_specific_14 = 253,
    application_specific_15 = 254,
    application_specific_16 = 255,

    // We ignore the rest because we never realistic set them.
    _,

    /// Converts the tag to the format expected by mach_vm_map/mach_vm_allocate.
    /// Equivalent to C macro: VM_MAKE_TAG(tag)
    pub fn make(self: VMTag) i32 {
        return @bitCast(@as(u32, @intFromEnum(self)) << 24);
    }
};

/// Creates a page allocator that tags all allocated memory with the given
/// VMTag.
pub fn taggedPageAllocator(tag: VMTag) Allocator {
    return .{
        // We smuggle the tag in as the context pointer.
        .ptr = @ptrFromInt(@as(usize, @intFromEnum(tag))),
        .vtable = &TaggedPageAllocator.vtable,
    };
}

/// This is based heavily on the Zig 0.15.2 PageAllocator implementation,
/// with only the posix implementation. Zig 0.15.2 is MIT licensed.
const TaggedPageAllocator = struct {
    pub const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(context: *anyopaque, n: usize, alignment: mem.Alignment, ra: usize) ?[*]u8 {
        _ = ra;
        assert(n > 0);
        const tag: VMTag = @enumFromInt(@as(u8, @truncate(@intFromPtr(context))));
        return map(n, alignment, tag);
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: mem.Alignment, new_len: usize, return_address: usize) bool {
        _ = context;
        _ = alignment;
        _ = return_address;
        return realloc(memory, new_len, false) != null;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        _ = context;
        _ = alignment;
        _ = return_address;
        return realloc(memory, new_len, true);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: mem.Alignment, return_address: usize) void {
        _ = context;
        _ = alignment;
        _ = return_address;
        return unmap(@alignCast(memory));
    }

    pub fn map(n: usize, alignment: mem.Alignment, tag: VMTag) ?[*]u8 {
        const page_size = std.heap.pageSize();
        if (n >= std.math.maxInt(usize) - page_size) return null;
        const alignment_bytes = alignment.toByteUnits();

        const aligned_len = mem.alignForward(usize, n, page_size);
        const max_drop_len = alignment_bytes - @min(alignment_bytes, page_size);
        const overalloc_len = if (max_drop_len <= aligned_len - n)
            aligned_len
        else
            mem.alignForward(usize, aligned_len + max_drop_len, page_size);
        const hint = @atomicLoad(@TypeOf(std.heap.next_mmap_addr_hint), &std.heap.next_mmap_addr_hint, .unordered);
        const slice = std.posix.mmap(
            hint,
            overalloc_len,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            tag.make(),
            0,
        ) catch return null;
        const result_ptr = mem.alignPointer(slice.ptr, alignment_bytes) orelse return null;
        // Unmap the extra bytes that were only requested in order to guarantee
        // that the range of memory we were provided had a proper alignment in it
        // somewhere. The extra bytes could be at the beginning, or end, or both.
        const drop_len = result_ptr - slice.ptr;
        if (drop_len != 0) std.posix.munmap(slice[0..drop_len]);
        const remaining_len = overalloc_len - drop_len;
        if (remaining_len > aligned_len) std.posix.munmap(@alignCast(result_ptr[aligned_len..remaining_len]));
        const new_hint: [*]align(std.heap.page_size_min) u8 = @alignCast(result_ptr + aligned_len);
        _ = @cmpxchgStrong(@TypeOf(std.heap.next_mmap_addr_hint), &std.heap.next_mmap_addr_hint, hint, new_hint, .monotonic, .monotonic);
        return result_ptr;
    }

    pub fn unmap(memory: []align(std.heap.page_size_min) u8) void {
        const page_aligned_len = mem.alignForward(usize, memory.len, std.heap.pageSize());
        std.posix.munmap(memory.ptr[0..page_aligned_len]);
    }

    pub fn realloc(uncasted_memory: []u8, new_len: usize, may_move: bool) ?[*]u8 {
        const memory: []align(std.heap.page_size_min) u8 = @alignCast(uncasted_memory);
        const page_size = std.heap.pageSize();
        const new_size_aligned = mem.alignForward(usize, new_len, page_size);

        const page_aligned_len = mem.alignForward(usize, memory.len, page_size);
        if (new_size_aligned == page_aligned_len)
            return memory.ptr;

        if (std.posix.MREMAP != void) {
            // TODO: if the next_mmap_addr_hint is within the remapped range, update it
            const new_memory = std.posix.mremap(memory.ptr, memory.len, new_len, .{ .MAYMOVE = may_move }, null) catch return null;
            return new_memory.ptr;
        }

        if (new_size_aligned < page_aligned_len) {
            const ptr = memory.ptr + new_size_aligned;
            // TODO: if the next_mmap_addr_hint is within the unmapped range, update it
            std.posix.munmap(@alignCast(ptr[0 .. page_aligned_len - new_size_aligned]));
            return memory.ptr;
        }

        return null;
    }
};

test "VMTag.make" {
    try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 240) << 24)), VMTag.application_specific_1.make());
}
