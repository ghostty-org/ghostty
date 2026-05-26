// See `ghastty_vk_shim.h` for the contract.

#include "ghastty_vk_shim.h"

#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include <glslang/Public/ShaderLang.h>
#include <glslang/Public/ResourceLimits.h>
#include <SPIRV/GlslangToSpv.h>

// glslang's `InitializeProcess` / `FinalizeProcess` must bracket
// any use of `glslang::TShader` / `glslang::TProgram`. The existing
// C-API path in `pkg/glslang/init.zig` calls `glslang_initialize_process`
// at startup, and per the glslang headers the C and C++ inits share
// state, so we don't initialize again here — calling `InitializeProcess`
// twice without a matching `FinalizeProcess` leaks reference counts.

namespace {

std::string drain_logs(glslang::TShader* shader, glslang::TProgram* program) {
    std::string s;
    if (shader != nullptr) {
        const char* info = shader->getInfoLog();
        const char* debug = shader->getInfoDebugLog();
        if (info != nullptr && info[0] != '\0') { s += info; s += "\n"; }
        if (debug != nullptr && debug[0] != '\0') { s += debug; s += "\n"; }
    }
    if (program != nullptr) {
        const char* info = program->getInfoLog();
        const char* debug = program->getInfoDebugLog();
        if (info != nullptr && info[0] != '\0') { s += info; s += "\n"; }
        if (debug != nullptr && debug[0] != '\0') { s += debug; s += "\n"; }
    }
    return s;
}

char* dup_to_c(const std::string& s) {
    char* p = static_cast<char*>(std::malloc(s.size() + 1));
    if (p == nullptr) return nullptr;
    std::memcpy(p, s.data(), s.size());
    p[s.size()] = '\0';
    return p;
}

} // namespace

extern "C" int ghastty_glslang_compile_vulkan(
    const char* source,
    ghastty_glslang_stage_t stage,
    uint32_t** spv_out,
    size_t* spv_len_out,
    char** err_out) {

    // Reject any null out-pointer up-front. The previous code
    // dereferenced all three unconditionally on line 1 of the
    // function body — the in-tree Zig caller (`pkg/glslang/vk.zig`)
    // always passes valid pointers, but this is a C ABI export and
    // a future consumer that omits any out-arg would crash here
    // before any error message could be reported. Returning early
    // surfaces the precondition cleanly.
    if (spv_out == nullptr || spv_len_out == nullptr || err_out == nullptr) {
        return 1;
    }

    *spv_out = nullptr;
    *spv_len_out = 0;
    *err_out = nullptr;

    if (source == nullptr) {
        *err_out = dup_to_c("source pointer is null");
        return 1;
    }

    EShLanguage lang;
    switch (stage) {
        case GHASTTY_GLSLANG_STAGE_VERTEX:   lang = EShLangVertex;   break;
        case GHASTTY_GLSLANG_STAGE_FRAGMENT: lang = EShLangFragment; break;
        default:
            *err_out = dup_to_c("unknown stage");
            return 1;
    }

    glslang::TShader shader(lang);
    const char* sources[1] = { source };
    shader.setStrings(sources, 1);

    // Source environment is OpenGL GLSL, target environment is Vulkan.
    // The cross-environment setup is what lets glslang translate
    // OpenGL-only builtins (`gl_VertexID`, `gl_InstanceID`, etc.) to
    // their Vulkan equivalents (`gl_VertexIndex`, `gl_InstanceIndex`)
    // during SPIR-V generation. Matches `glslangValidator -V` and
    // Qt's `QShaderBaker`.
    shader.setEnvInput(
        glslang::EShSourceGlsl,
        lang,
        glslang::EShClientVulkan,
        /*version*/ 100);
    shader.setEnvClient(
        glslang::EShClientVulkan,
        glslang::EShTargetVulkan_1_3);
    shader.setEnvTarget(
        glslang::EShTargetSpv,
        glslang::EShTargetSpv_1_6);

    // Auto-map: assign descriptor bindings and shader I/O locations
    // for any `layout`-less declarations. Required for OpenGL GLSL
    // that doesn't bother with explicit locations (which Vulkan SPIR-V
    // requires).
    shader.setAutoMapBindings(true);
    shader.setAutoMapLocations(true);

    const TBuiltInResource* resources = GetDefaultResources();
    const EShMessages messages = static_cast<EShMessages>(
        EShMsgDefault | EShMsgSpvRules | EShMsgVulkanRules);

    if (!shader.parse(resources, /*default_version*/ 450,
                      ECoreProfile, /*force_default*/ false,
                      /*forward_compatible*/ true, messages)) {
        *err_out = dup_to_c(drain_logs(&shader, nullptr));
        return 1;
    }

    glslang::TProgram program;
    program.addShader(&shader);
    if (!program.link(messages)) {
        *err_out = dup_to_c(drain_logs(&shader, &program));
        return 1;
    }
    // mapIO() is what actually applies the auto-bind / auto-map
    // resolution to the SPIR-V output. Without it the
    // `setAutoMap*(true)` calls above are no-ops.
    if (!program.mapIO()) {
        std::string s = "glslang TProgram::mapIO() failed:\n";
        s += drain_logs(&shader, &program);
        *err_out = dup_to_c(s);
        return 1;
    }

    std::vector<unsigned int> spv;
    glslang::GlslangToSpv(*program.getIntermediate(lang), spv);
    if (spv.empty()) {
        *err_out = dup_to_c(
            "GlslangToSpv produced no SPIR-V output");
        return 1;
    }

    const size_t bytes = spv.size() * sizeof(uint32_t);
    uint32_t* out = static_cast<uint32_t*>(std::malloc(bytes));
    if (out == nullptr) {
        *err_out = dup_to_c("malloc failed for SPIR-V output buffer");
        return 1;
    }
    std::memcpy(out, spv.data(), bytes);
    *spv_out = out;
    *spv_len_out = spv.size();
    return 0;
}

extern "C" void ghastty_glslang_free_spirv(uint32_t* spv) {
    std::free(spv);
}

extern "C" void ghastty_glslang_free_error(char* err) {
    std::free(err);
}
