//! This file contains helpers for wasm compilation.
const std = @import("std");
const builtin = @import("builtin");
const options = @import("build_options");

comptime {
    if (!builtin.target.isWasm()) {
        @compileError("wasm.zig should only be analyzed for wasm32 builds");
    }
}

/// True if we're in shared memory mode. If true, then the memory buffer
/// in JS will be backed by a SharedArrayBuffer and some behaviors change.
pub const shared_mem = options.wasm_shared;

/// The allocator to use in wasm environments.
///
/// The return values of this should NOT be sent to the host environment
/// unless toHostOwned is called on them. In this case, the caller is expected
/// to call free. If a pointer is NOT host-owned, then the wasm module is
/// expected to call the normal alloc.free/destroy functions.
pub const alloc = if (builtin.is_test)
    std.testing.allocator
else
    std.heap.wasm_allocator;

/// For host-owned allocations:
/// We need to keep track of our own pointer lengths because Zig
/// allocators usually don't do this and we need to be able to send
/// a direct pointer back to the host system. A more appropriate thing
/// to do would be to probably make a custom allocator that keeps track
/// of size.
var allocs: std.AutoHashMapUnmanaged([*]u8, usize) = .{};

/// Allocate len bytes and return a pointer to the memory in the host.
/// The data is not zeroed.
pub export fn malloc(len: usize) ?[*]u8 {
    return alloc_(len) catch return null;
}

fn alloc_(len: usize) ![*]u8 {
    // Create the allocation
    const slice = try alloc.alloc(u8, len);
    errdefer alloc.free(slice);

    // Store the size so we can deallocate later
    try allocs.putNoClobber(alloc, slice.ptr, slice.len);
    errdefer _ = allocs.remove(slice.ptr);

    return slice.ptr;
}

/// Free an allocation from malloc.
pub export fn free(ptr: ?[*]u8) void {
    if (ptr) |v| {
        if (allocs.get(v)) |len| {
            const slice = v[0..len];
            alloc.free(slice);
            _ = allocs.remove(v);
        }
    }
}

/// Convert an allocated pointer of any type to a host-owned pointer.
/// This pushes the responsibility to free it to the host. The returned
/// pointer will match the pointer but is typed correctly for returning
/// to the host.
pub fn toHostOwned(ptr: anytype) ![*]u8 {
    // Convert our pointer to a byte array
    const info = @typeInfo(@TypeOf(ptr)).Pointer;
    const T = info.child;
    const size = @sizeOf(T);
    const casted = @as([*]u8, @ptrFromInt(@intFromPtr(ptr)));

    // Store the information about it
    try allocs.putNoClobber(alloc, casted, size);
    errdefer _ = allocs.remove(casted);

    return casted;
}

/// Returns true if the value is host owned.
pub fn isHostOwned(ptr: anytype) bool {
    const casted = @as([*]u8, @ptrFromInt(@intFromPtr(ptr)));
    return allocs.contains(casted);
}

/// Convert a pointer back to a module-owned value. The caller is expected
/// to cast or have the valid pointer for alloc calls.
pub fn toModuleOwned(ptr: anytype) void {
    const casted = @as([*]u8, @ptrFromInt(@intFromPtr(ptr)));
    _ = allocs.remove(casted);
}

test "basics" {
    const testing = std.testing;
    const buf = malloc(32).?;
    try testing.expect(allocs.size == 1);
    free(buf);
    try testing.expect(allocs.size == 0);
}

test "toHostOwned" {
    const testing = std.testing;

    const Point = struct { x: u32 = 0, y: u32 = 0 };
    const p = try alloc.create(Point);
    errdefer alloc.destroy(p);
    const ptr = try toHostOwned(p);
    try testing.expect(allocs.size == 1);
    try testing.expect(isHostOwned(p));
    try testing.expect(isHostOwned(ptr));
    free(ptr);
    try testing.expect(allocs.size == 0);
}
