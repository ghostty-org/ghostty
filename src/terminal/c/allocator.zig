const std = @import("std");
const testing = std.testing;
const lib = @import("../lib.zig");
const CAllocator = lib.alloc.Allocator;

/// Allocate a buffer of `len` bytes using the given allocator
/// (or the default allocator if NULL).
///
/// Returns a pointer to the allocated buffer, or NULL if the
/// allocation failed.
pub fn alloc(
    alloc_: ?*const CAllocator,
    len: usize,
) callconv(lib.calling_conv) ?[*]u8 {
    const allocator = lib.alloc.default(alloc_);
    const buf = allocator.alloc(u8, len) catch return null;
    return buf.ptr;
}

/// Free memory that was allocated by a libghostty-vt function.
///
/// This must be used to free buffers returned by functions like
/// `format_alloc`. Pass the same allocator (or NULL for the default)
/// that was used for the allocation.
pub fn free(
    alloc_: ?*const CAllocator,
    ptr: ?[*]u8,
    len: usize,
) callconv(lib.calling_conv) void {
    const mem = ptr orelse return;
    const allocator = lib.alloc.default(alloc_);
    allocator.free(mem[0..len]);
}

test "alloc returns non-null" {
    const ptr = alloc(&lib.alloc.test_allocator, 16);
    try testing.expect(ptr != null);
    free(&lib.alloc.test_allocator, ptr, 16);
}

test "alloc with null allocator" {
    const ptr = alloc(null, 8);
    try testing.expect(ptr != null);
    free(null, ptr, 8);
}

test "alloc zero length" {
    const ptr = alloc(&lib.alloc.test_allocator, 0);
    defer free(&lib.alloc.test_allocator, ptr, 0);
}

test "free null pointer" {
    free(&lib.alloc.test_allocator, null, 0);
}

test "free allocated memory" {
    const allocator = lib.alloc.default(&lib.alloc.test_allocator);
    const mem = try allocator.alloc(u8, 16);
    free(&lib.alloc.test_allocator, mem.ptr, mem.len);
}

test "free with null allocator" {
    // null allocator falls back to the default (test allocator in tests)
    const allocator = lib.alloc.default(null);
    const mem = try allocator.alloc(u8, 8);
    free(null, mem.ptr, mem.len);
}
