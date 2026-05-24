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
// On success: returns 0. `*spv_out` points to a freshly allocated
//   array of `*spv_len_out` 32-bit SPIR-V words. Caller frees it
//   with `ghastty_glslang_free_spirv`. `*err_out` is NULL.
//
// On failure: returns non-zero. `*err_out` points to a freshly
//   allocated null-terminated error message. Caller frees it with
//   `ghastty_glslang_free_error`. `*spv_out` is NULL,
//   `*spv_len_out` is 0.
int ghastty_glslang_compile_vulkan(
    const char* source,
    ghastty_glslang_stage_t stage,
    uint32_t** spv_out,
    size_t* spv_len_out,
    char** err_out);

void ghastty_glslang_free_spirv(uint32_t* spv);
void ghastty_glslang_free_error(char* err);

#ifdef __cplusplus
}
#endif

#endif /* GHASTTY_VK_SHIM_H */
