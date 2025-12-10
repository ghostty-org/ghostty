//! This contains convenience functions for allocating various types.
//!
//! The primary use case for this is Wasm builds. Ghostty relies a lot on
//! pointers to various types for ABI compatibility and creating those pointers
//! in Wasm is tedious. This file contains a purely additive set of functions
//! that can be exposed to the Wasm module without changing the API from the
//! C library.
//!
//! Given these are convenience methods, they always use the default allocator.
//! If a caller is using a custom allocator, they have the expertise to
//! allocate these types manually using their custom allocator.

// Get our default allocator at comptime since it is known.
const default = @import("../allocator.zig").default;
const alloc = default(null);

pub const Opaque = *anyopaque;

pub fn allocOpaque() callconv(.c) ?*Opaque {
    return alloc.create(*anyopaque) catch return null;
}

pub fn freeOpaque(ptr: ?*Opaque) callconv(.c) void {
    if (ptr) |p| alloc.destroy(p);
}

pub fn allocU8Array(len: usize) callconv(.c) ?[*]u8 {
    const slice = alloc.alloc(u8, len) catch return null;
    return slice.ptr;
}

pub fn freeU8Array(ptr: ?[*]u8, len: usize) callconv(.c) void {
    if (ptr) |p| alloc.free(p[0..len]);
}

pub fn allocU16Array(len: usize) callconv(.c) ?[*]u16 {
    const slice = alloc.alloc(u16, len) catch return null;
    return slice.ptr;
}

pub fn freeU16Array(ptr: ?[*]u16, len: usize) callconv(.c) void {
    if (ptr) |p| alloc.free(p[0..len]);
}

pub fn allocU8() callconv(.c) ?*u8 {
    return alloc.create(u8) catch return null;
}

pub fn freeU8(ptr: ?*u8) callconv(.c) void {
    if (ptr) |p| alloc.destroy(p);
}

pub fn allocUsize() callconv(.c) ?*usize {
    return alloc.create(usize) catch return null;
}

pub fn freeUsize(ptr: ?*usize) callconv(.c) void {
    if (ptr) |p| alloc.destroy(p);
}
