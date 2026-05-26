pub const c = @cImport({
    @cInclude("glslang/Include/glslang_c_interface.h");
    @cInclude("glslang/Public/resource_limits_c.h");
    // Ghastty-specific extension to glslang's C ABI: a Vulkan-
    // friendly compile entry point that wraps the C++ TShader API
    // (setAutoMapBindings / setAutoMapLocations / setEnvInput) the
    // upstream C interface doesn't expose. See
    // `pkg/glslang/override/ghastty_vk_shim.h`.
    @cInclude("ghastty_vk_shim.h");
});
