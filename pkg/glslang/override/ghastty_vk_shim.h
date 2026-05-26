// Vulkan-targeted GLSL compilation that exposes glslang's
// C++-only features (auto-map bindings/locations, source/target
// environment translation for `gl_VertexID` → `gl_VertexIndex`)
// through a C-compatible entry point.
//
// glslang's public C API (`glslang_c_interface.h`) doesn't expose
// `setAutoMapBindings` / `setAutoMapLocations` / `setEnvInput` —
// they only live on the C++ `glslang::TShader` class. The CLI
// (`glslangValidator -V --auto-map-locations --auto-map-bindings`)
// and Qt's `QShaderBaker` both call them internally; this shim is
// the equivalent for libghostty.
//
// Used by `src/renderer/vulkan/shaders.zig` for both the renderer's
// built-in shaders and user-supplied custom shaders. The same
// function covers both because user-shader compilation happens at
// runtime against `libghostty.so`, not as a build step.

#ifndef GHASTTY_VK_SHIM_H
#define GHASTTY_VK_SHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    GHASTTY_GLSLANG_STAGE_VERTEX = 0,
    GHASTTY_GLSLANG_STAGE_FRAGMENT = 1,
} ghastty_glslang_stage_t;

// Compile a null-terminated GLSL source to Vulkan-flavored SPIR-V.
//
// Preconditions: `spv_out`, `spv_len_out`, and `err_out` MUST all be
//   non-null. The function rejects any null out-pointer with rc=1
//   and no error string (since `err_out` is itself part of the
//   contract). `source` may be null; that produces a normal failure
//   with `*err_out` set.
//
// On success: returns 0. `*spv_out` points to a freshly allocated
//   array of `*spv_len_out` 32-bit SPIR-V words. Caller frees it
//   with `ghastty_glslang_free_spirv`. `*err_out` is NULL.
//
// On failure: returns non-zero. `*err_out` points to a freshly
//   allocated null-terminated error message (or NULL on out-arg
//   precondition violation OR on internal OOM). Caller frees it
//   with `ghastty_glslang_free_error`. `*spv_out` is NULL,
//   `*spv_len_out` is 0.
int ghastty_glslang_compile_vulkan(
    const char* source,
    ghastty_glslang_stage_t stage,
    uint32_t** spv_out,
    size_t* spv_len_out,
    char** err_out);

void ghastty_glslang_free_spirv(uint32_t* spv);
void ghastty_glslang_free_error(char* err);

// Release the process-wide glslang state: the per-thread
// TPoolAllocator pages (the high-water-mark pool memory that
// otherwise leaks for the process lifetime because Zig pthreads
// don't run C++ thread_local destructors) AND the shim's
// SPV cache.
//
// Idempotent. Call ONCE from the host's shutdown path AFTER all
// renderer threads have joined — calling it while a renderer
// thread might still touch glslang::TShader / TProgram is
// undefined behavior per glslang's contract.
//
// libghostty's own renderer-thread teardown (Vulkan.threadExit)
// is what serializes this safely: by the time the host's main()
// returns from QApplication::exec(), every renderer thread has
// already run threadExit and is joined.
void ghastty_glslang_finalize_process(void);

#ifdef __cplusplus
}
#endif

#endif /* GHASTTY_VK_SHIM_H */
