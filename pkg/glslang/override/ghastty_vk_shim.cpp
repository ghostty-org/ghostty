// See `ghastty_vk_shim.h` for the contract.

#include "ghastty_vk_shim.h"

#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include <glslang/Include/PoolAlloc.h>
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

// Process-wide SPIR-V cache keyed by (source, stage). The renderer
// builds one Vulkan.Shaders per surface (per tab/split), which calls
// `Module.init` → `compileToSpv` for all 9 built-in shaders + every
// user custom shader. Each compile pulls memory from glslang's
// thread-local TPoolAllocator, which is a raw pointer in glslang's
// TLS that is NEVER released when a renderer thread exits (Zig
// pthread spawn doesn't run C++ thread_local destructors and there
// is no FinalizeThread hook). With N tabs, the leaked pool pages
// add up to tens of MB — observed via heaptrack as the dominant
// leak source (~17 MB across 15k+ allocations from
// glslang::TPoolAllocator::allocate).
//
// Cache the resulting SPIR-V instead. The built-in shaders produce
// byte-identical SPV regardless of which surface compiles them; the
// custom shaders only change when the user edits their config. So
// after the first surface, every other surface's compile is a
// cache hit with zero glslang work and zero new pool pages.
//
// Key format: source bytes followed by a single byte stage tag
// (0=vertex, 1=fragment). Disambiguates the rare case where two
// stages share identical source text.
std::mutex& spv_cache_mutex() {
    static std::mutex m;
    return m;
}
std::unordered_map<std::string, std::vector<uint32_t>>& spv_cache() {
    static std::unordered_map<std::string, std::vector<uint32_t>> c;
    return c;
}

std::string make_cache_key(const char* source, ghastty_glslang_stage_t stage) {
    std::string key(source);
    key.push_back(static_cast<char>(stage));
    return key;
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

    // Cache hit: copy SPV from the cache and return without ever
    // touching glslang. See the cache rationale comment above the
    // map for why this is critical for the multi-tab leak.
    const std::string key = make_cache_key(source, stage);
    {
        std::lock_guard<std::mutex> lg(spv_cache_mutex());
        auto it = spv_cache().find(key);
        if (it != spv_cache().end()) {
            const std::vector<uint32_t>& cached = it->second;
            const size_t bytes = cached.size() * sizeof(uint32_t);
            uint32_t* out = static_cast<uint32_t*>(std::malloc(bytes));
            if (out == nullptr) {
                *err_out = dup_to_c(
                    "malloc failed for cached SPIR-V copy");
                return 1;
            }
            std::memcpy(out, cached.data(), bytes);
            *spv_out = out;
            *spv_len_out = cached.size();
            return 0;
        }
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

    // Populate the cache with the freshly-compiled SPV. Stored by
    // value (std::move into the map); the SPV vector is the same
    // data we just memcpy'd to `out` so the caller's malloc'd copy
    // and the cache entry are independent. Future calls with this
    // (source, stage) skip glslang entirely.
    {
        std::lock_guard<std::mutex> lg(spv_cache_mutex());
        spv_cache().emplace(key, std::move(spv));
    }
    return 0;
}

extern "C" void ghastty_glslang_free_spirv(uint32_t* spv) {
    std::free(spv);
}

extern "C" void ghastty_glslang_free_error(char* err) {
    std::free(err);
}

extern "C" void ghastty_glslang_finalize_process(void) {
    // Drop the cached SPV blobs first. The map owns the std::vector
    // pages it holds; clearing returns them to the heap. Done before
    // FinalizeProcess so a malicious post-finalize compile attempt
    // (which would re-enter glslang on a dead process state) trips
    // glslang's own checks rather than handing out stale cache hits.
    {
        std::lock_guard<std::mutex> lg(spv_cache_mutex());
        spv_cache().clear();
    }
    // Free this thread's TPoolAllocator pages. heaptrack pointed
    // the ~12 MB glslang leak at TPoolAllocator::allocate calls
    // rooted in shadertoy.spirvFromGlsl on the GUI thread (since
    // ghostty_surface_new runs glslang synchronously from
    // MainWindow::newTab) — that pool's pages persist until thread
    // exit, but the GUI thread doesn't exit until process
    // termination. glslang::FinalizeProcess only frees the
    // process-wide SharedSymbolTables, NOT this pool. Call popAll()
    // explicitly to release the pages back to the system allocator.
    //
    // Safe here because (a) we're called from atexit, every render
    // thread has joined via Vulkan.threadExit (which also runs its
    // own popAll-equivalent via ThreadState.cleanup); (b) the SPV
    // cache was cleared above, so no compiled blob references the
    // pool; (c) FinalizeProcess below won't reach into this pool
    // either.
    glslang::GetThreadPoolAllocator().popAll();

    // Release glslang's process-wide shared state (the version-
    // indexed SharedSymbolTables built at first compile).
    glslang::FinalizeProcess();
}
