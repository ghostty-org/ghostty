const c = @import("c.zig").c;

extern fn atexit(callback: *const fn () callconv(.c) void) c_int;

pub fn init() !void {
    if (c.glslang_initialize_process() == 0) return error.GlslangInitFailed;
}

/// Like `init`, but also registers an `atexit` hook that tears down
/// glslang's per-thread `TPoolAllocator` on the calling thread plus
/// the shim's process-wide SPV cache. Call this from libghostty's
/// long-running runtime (the GUI thread that runs user-shader
/// compiles via `shadertoy.spirvFromGlsl`); do NOT call it from
/// short-lived build-time tools like `vulkan_spvgen`, where the
/// shim's cleanup races glslang's own static-destructor teardown
/// and heap-corrupts at exit.
///
/// Why we need this: the user's custom-shader compile path
/// (`shadertoy.spirvFromGlsl` → `glslang_shader_preprocess`)
/// allocates ~6 MB into glslang's thread-local pool. Zig's pthread
/// spawn doesn't run C++ thread_local destructors and there is no
/// `FinalizeThread` hook in glslang's C API, so those pages leak
/// for the process lifetime. The shim's
/// `ghastty_glslang_finalize_process` `delete`s the pool, clears
/// the SPV cache, and calls `glslang::FinalizeProcess`.
///
/// Registering from libghostty (rather than from the host
/// application) keeps the shim symbol referenced so the linker
/// doesn't DCE it out of libghostty.so. Built-in shaders are
/// precompiled at build time and don't go through the shim
/// anymore; without this reference the shim's exported functions
/// get garbage-collected.
pub fn initWithAtexit() !void {
    try init();
    _ = atexit(&c.ghastty_glslang_finalize_process);
}

pub fn finalize() void {
    c.glslang_finalize_process();
}
