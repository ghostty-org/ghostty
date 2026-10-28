//! SIMD-optimized routines. If `build_options.simd` is false, then the API
//! still works but we fall back to pure Zig scalar implementations.

const std = @import("std");

const codepoint_width = @import("codepoint_width.zig");
pub const base64 = @import("base64.zig");
pub const index_of = @import("index_of.zig");
pub const vt = @import("vt.zig");
pub const codepointWidth = codepoint_width.codepointWidth;

/// The number of vector lanes to use for manually vectorized hot
/// loops operating on elements of type T, or null if the target has
/// no usable SIMD support and a plain scalar loop should be used
/// instead (e.g. wasm32 without simd128).
///
/// This is twice the native vector width so that each iteration works
/// two vector registers, giving better instruction-level parallelism.
pub fn lanes(comptime T: type) ?comptime_int {
    const native = std.simd.suggestVectorLength(T) orelse return null;
    return native * 2;
}

test {
    @import("std").testing.refAllDecls(@This());
}
