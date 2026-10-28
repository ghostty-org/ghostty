//! Wasm allocation conveniences for caller-owned storage and opaque out slots.
//!
//! The primary use case for this is Wasm builds. Ghostty relies a lot on
//! pointers to various types for ABI compatibility and creating those pointers
//! in Wasm is tedious. This file contains the small set of functions exposed by
//! the Wasm module without changing the API from the C library.
//!
//! Given these are convenience methods, they always use the default allocator.
//! If a caller is using a custom allocator, they have the expertise to
//! allocate these types manually using their custom allocator.

const std = @import("std");
const c_abi = @import("../c_abi.zig");

// Get our default allocator at comptime since it is known.
const default = @import("../allocator.zig").default;
const alloc = default(null);
const wasm_alignment: std.mem.Alignment = .fromByteUnits(c_abi.max_alignment);

/// A nullable opaque C handle stored in a constructor out-parameter slot.
pub const Opaque = ?*anyopaque;

/// Allocate `len` bytes of uninitialized, caller-owned Wasm ABI storage.
///
/// The returned pointer is aligned for any fundamental C ABI type and must be
/// released with `freeBytes` using the same `len`. Returns null when `len` is
/// zero or allocation fails.
pub fn allocBytes(len: usize) callconv(.c) ?[*]u8 {
    if (len == 0) return null;
    return alloc.rawAlloc(len, wasm_alignment, @returnAddress());
}

/// Release storage returned by `allocBytes`.
///
/// `len` must exactly match the allocation length. A null pointer is ignored.
pub fn freeBytes(ptr: ?[*]u8, len: usize) callconv(.c) void {
    const p = ptr orelse return;
    if (len == 0) return;
    alloc.rawFree(p[0..len], wasm_alignment, @returnAddress());
}

/// Allocate a null-initialized slot for an opaque constructor out-parameter.
///
/// The slot may be reused after each value is removed with `takeOpaque`. It
/// must eventually be released with `freeOpaque`.
pub fn allocOpaque() callconv(.c) ?*Opaque {
    const ptr = allocBytes(@sizeOf(Opaque)) orelse return null;
    const result: *Opaque = @ptrCast(@alignCast(ptr));
    result.* = null;
    return result;
}

/// Release a slot returned by `allocOpaque` without freeing its stored handle.
///
/// Call the handle's type-specific destructor before freeing a populated slot.
/// A null slot pointer is ignored.
pub fn freeOpaque(ptr: ?*Opaque) callconv(.c) void {
    freeBytes(@ptrCast(ptr), @sizeOf(Opaque));
}

/// Remove and return the handle in an opaque out-parameter slot.
///
/// The slot is reset to null so it can be safely reused for another
/// constructor. This does not free either the handle or the slot. Returns null
/// when the slot pointer is null or the slot is empty.
pub fn takeOpaque(ptr: ?*Opaque) callconv(.c) Opaque {
    const p = ptr orelse return null;
    const result = p.*;
    p.* = null;
    return result;
}

test "Wasm allocation" {
    const ptr = allocBytes(1) orelse return error.OutOfMemory;
    defer freeBytes(ptr, 1);

    try std.testing.expectEqual(
        @as(usize, 0),
        @intFromPtr(ptr) % c_abi.max_alignment,
    );
    ptr[0] = 42;
    try std.testing.expectEqual(@as(u8, 42), ptr[0]);

    try std.testing.expect(allocBytes(0) == null);
    freeBytes(null, 0);
}

test "opaque slots are initialized and reusable" {
    const slot = allocOpaque() orelse return error.OutOfMemory;
    defer freeOpaque(slot);

    try std.testing.expect(takeOpaque(slot) == null);

    var value: u8 = 42;
    slot.* = &value;
    try std.testing.expectEqual(@as(?*anyopaque, &value), takeOpaque(slot));
    try std.testing.expect(takeOpaque(slot) == null);
}
