//! Typed Zig wrapper around the Ghastty Vulkan-friendly glslang
//! compile shim (`pkg/glslang/override/ghastty_vk_shim.h`). The shim
//! itself is a small C entry point that wraps glslang's C++-only
//! `setAutoMapBindings` / `setAutoMapLocations` / `setEnvInput` knobs
//! the upstream C ABI doesn't expose.
//!
//! Callers use this instead of poking `glslang.c.ghastty_*` directly:
//! the malloc/free dance for the shim's out-pointers is finicky
//! (separate free entry points for SPIR-V and error strings, both
//! optional, both have to be dropped on the right path) and was
//! previously open-coded across two near-identical 25-line blocks
//! in `src/renderer/vulkan/shaders.zig`. This module is the binding
//! layer; the renderer just calls `compileToSpv` and gets a Zig
//! `[]const u32` slice.

const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @import("c.zig").c;

const log = std.log.scoped(.glslang);

pub const Stage = enum {
    vertex,
    fragment,

    fn cValue(self: Stage) c.ghastty_glslang_stage_t {
        return switch (self) {
            .vertex => c.GHASTTY_GLSLANG_STAGE_VERTEX,
            .fragment => c.GHASTTY_GLSLANG_STAGE_FRAGMENT,
        };
    }
};

pub const Error = error{
    /// The compile-shim's underlying glslang C++ pipeline (TShader
    /// preprocess / parse + TProgram link + GlslangToSpv) failed.
    /// The shim's error message is logged via `std.log.err` before
    /// this error is returned — no allocation is propagated to the
    /// caller.
    GlslangFailed,
} || Allocator.Error;

/// Compile a null-terminated GLSL source string to a Vulkan-flavored
/// SPIR-V binary.
///
/// On success, returns a slice owned by `alloc`; the caller frees with
/// `alloc.free(spv)`. The shim hands back its own malloc'd buffer
/// which we copy into `alloc` so the caller's `defer alloc.free` works
/// without remembering a separate `ghastty_glslang_free_spirv` call.
///
/// On failure, the shim's error string is logged with `std.log.err`
/// and `error.GlslangFailed` is returned — the C-side malloc'd error
/// buffer is freed before returning so callers don't have to.
pub fn compileToSpv(
    alloc: Allocator,
    source: [:0]const u8,
    stage: Stage,
) Error![]const u32 {
    var spv_ptr: [*c]u32 = undefined;
    var spv_len: usize = 0;
    var err_ptr: [*c]u8 = undefined;

    const rc = c.ghastty_glslang_compile_vulkan(
        source.ptr,
        stage.cValue(),
        &spv_ptr,
        &spv_len,
        &err_ptr,
    );
    if (rc != 0) {
        if (err_ptr != null) {
            log.err("ghastty_glslang_compile_vulkan: rc={} {s}", .{
                rc,
                std.mem.span(@as([*:0]const u8, @ptrCast(err_ptr))),
            });
            c.ghastty_glslang_free_error(err_ptr);
        } else {
            log.err("ghastty_glslang_compile_vulkan: rc={} (no error string)", .{rc});
        }
        return error.GlslangFailed;
    }
    defer c.ghastty_glslang_free_spirv(spv_ptr);

    // Copy out of the shim's malloc into `alloc` so the caller's
    // free path is symmetric with every other allocator-owned slice.
    const owned = try alloc.alloc(u32, spv_len);
    @memcpy(owned, spv_ptr[0..spv_len]);
    return owned;
}
