//! Memory-layout properties shared with C API callers.
//!
//! The C ABI defines how values are represented in memory so code written in
//! different languages can safely exchange them. One part of that contract is
//! alignment: some values must begin at an address divisible by 2, 4, 8, or
//! another power of two. Reading a value from a less-aligned address can be
//! slow on some CPUs and invalid on others.
//!
//! This module derives those properties from Zig's compile-time target data.
//! It does not call or link libc. Keeping the calculation here gives allocators
//! and ABI metadata one source of truth.

const std = @import("std");
const builtin = @import("builtin");

/// Largest address alignment required by a fundamental C ABI type, in bytes.
///
/// For example, a value of 16 means storage intended to hold an arbitrary C
/// value must begin at an address evenly divisible by 16. The Wasm allocator
/// uses this value for caller-owned ABI storage, and `ghostty_type_json`
/// publishes it so hosts know the guarantee made by that allocator.
pub const max_alignment: u16 = max: {
    var result: u16 = @alignOf(*anyopaque);
    for (std.enums.values(std.Target.CType)) |c_type| {
        result = @max(result, builtin.target.cTypeAlignment(c_type));
    }
    break :max result;
};
