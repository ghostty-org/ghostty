//! GLSL → SPIR-V → `VkShaderModule` pipeline.
//!
//! Approach: runtime compilation. The 10 GLSL sources in
//! `src/renderer/shaders/glsl/` are `@embedFile`'d and compiled via
//! the already-vendored `glslang` package (also used by
//! `shadertoy.zig` for custom user shaders). Compiled SPIR-V is fed
//! into `vkCreateShaderModule` to produce the handles that
//! `Pipeline.zig` will reference.
//!
//! Why not build-time compilation? It would be cleaner (no startup
//! cost, no glslang at runtime in the Vulkan binary) but requires
//! wiring glslang into `build.zig` as a build step, which is a
//! sizable detour. Runtime compilation reuses the existing glslang
//! integration verbatim. The startup cost is ~50ms total across all
//! shaders, acceptable for a terminal that starts rarely. Migrating
//! to build-time SPIR-V is a contained follow-up: swap the
//! `Module.init` call sites for `Module.initFromSpirv` of
//! `@embedFile`'d `.spv` blobs and delete the glslang import here.

const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan").c;
const glslang = @import("glslang");

const Device = @import("Device.zig");

const log = std.log.scoped(.vulkan);

/// Sources for the renderer's built-in shaders. Mirrors the table in
/// `opengl/shaders.zig`. Each entry is `@embedFile`'d so the binary
/// is self-contained.
///
/// Note: `common.glsl` is shared content `#include`'d by the others;
/// it is not a compilation unit and is not listed here. (The other
/// shaders are expected to splice it in via their existing
/// preprocessor pattern, the same way `opengl/shaders.zig` does.)
pub const source = struct {
    pub const bg_color_frag = @embedFile("../shaders/glsl/bg_color.f.glsl");
    pub const bg_image_frag = @embedFile("../shaders/glsl/bg_image.f.glsl");
    pub const bg_image_vert = @embedFile("../shaders/glsl/bg_image.v.glsl");
    pub const cell_bg_frag = @embedFile("../shaders/glsl/cell_bg.f.glsl");
    pub const cell_text_frag = @embedFile("../shaders/glsl/cell_text.f.glsl");
    pub const cell_text_vert = @embedFile("../shaders/glsl/cell_text.v.glsl");
    pub const full_screen_vert = @embedFile("../shaders/glsl/full_screen.v.glsl");
    pub const image_frag = @embedFile("../shaders/glsl/image.f.glsl");
    pub const image_vert = @embedFile("../shaders/glsl/image.v.glsl");
};

pub const Stage = enum {
    vertex,
    fragment,

    fn glslangStage(self: Stage) c_uint {
        return switch (self) {
            .vertex => glslang.c.GLSLANG_STAGE_VERTEX,
            .fragment => glslang.c.GLSLANG_STAGE_FRAGMENT,
        };
    }

    fn vkStage(self: Stage) vk.VkShaderStageFlagBits {
        return switch (self) {
            .vertex => vk.VK_SHADER_STAGE_VERTEX_BIT,
            .fragment => vk.VK_SHADER_STAGE_FRAGMENT_BIT,
        };
    }
};

pub const Error = error{
    /// `glslang_shader_preprocess` / `_parse` / `_program_link` /
    /// `_program_SPIRV_generate` failed. Detailed errors are logged
    /// via `std.log.err` with the glslang info / debug strings.
    GlslangFailed,
    /// `vkCreateShaderModule` returned a non-success status.
    VulkanFailed,
};

/// A compiled `VkShaderModule` plus its stage flag.
pub const Module = struct {
    handle: vk.VkShaderModule,
    stage: vk.VkShaderStageFlagBits,
    device: *const Device,

    /// Compile GLSL → SPIR-V → `VkShaderModule` in a single pass. No
    /// allocator parameter because we hand glslang's SPIR-V buffer
    /// directly to `vkCreateShaderModule`; per the Vulkan spec, the
    /// driver copies the bytes during the call so the source buffer
    /// can be freed (via glslang's `defer delete`) immediately after.
    pub fn init(
        device: *const Device,
        src: [:0]const u8,
        stage: Stage,
    ) Error!Module {
        // Mirror shadertoy.zig — tests don't call `glslang.init`
        // themselves.
        if (builtin.is_test) glslang.testing.ensureInit() catch {
            return error.GlslangFailed;
        };

        const c = glslang.c;
        const input: c.glslang_input_t = .{
            .language = c.GLSLANG_SOURCE_GLSL,
            .stage = stage.glslangStage(),
            .client = c.GLSLANG_CLIENT_VULKAN,
            .client_version = c.GLSLANG_TARGET_VULKAN_1_3,
            .target_language = c.GLSLANG_TARGET_SPV,
            .target_language_version = c.GLSLANG_TARGET_SPV_1_6,
            .code = src.ptr,
            .default_version = 450,
            .default_profile = c.GLSLANG_NO_PROFILE,
            .force_default_version_and_profile = 0,
            .forward_compatible = 0,
            .messages = c.GLSLANG_MSG_DEFAULT_BIT |
                c.GLSLANG_MSG_SPV_RULES_BIT |
                c.GLSLANG_MSG_VULKAN_RULES_BIT,
            .resource = c.glslang_default_resource(),
        };

        const shader = glslang.Shader.create(&input) catch {
            return error.GlslangFailed;
        };
        defer shader.delete();

        shader.preprocess(&input) catch {
            logShaderInfo(shader);
            return error.GlslangFailed;
        };
        shader.parse(&input) catch {
            logShaderInfo(shader);
            return error.GlslangFailed;
        };

        const program = glslang.Program.create() catch {
            return error.GlslangFailed;
        };
        defer program.delete();
        program.addShader(shader);
        program.link(
            c.GLSLANG_MSG_SPV_RULES_BIT |
                c.GLSLANG_MSG_VULKAN_RULES_BIT,
        ) catch {
            logProgramInfo(program);
            return error.GlslangFailed;
        };

        program.spirvGenerate(stage.glslangStage());
        const word_count = program.spirvGetSize();
        const word_ptr = program.spirvGetPtr() catch {
            return error.GlslangFailed;
        };

        return try initFromSpirv(device, word_ptr[0..word_count], stage);
    }

    /// Wrap pre-compiled SPIR-V as a `VkShaderModule`. Useful for the
    /// eventual build-time-blob path, and as the lower half of `init`.
    pub fn initFromSpirv(
        device: *const Device,
        spirv: []const u32,
        stage: Stage,
    ) Error!Module {
        const info: vk.VkShaderModuleCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .codeSize = spirv.len * @sizeOf(u32),
            .pCode = spirv.ptr,
        };
        var handle: vk.VkShaderModule = undefined;
        const r = device.dispatch.createShaderModule(
            device.device,
            &info,
            null,
            &handle,
        );
        if (r != vk.VK_SUCCESS) {
            log.err("vkCreateShaderModule failed: result={}", .{r});
            return error.VulkanFailed;
        }
        return .{
            .handle = handle,
            .stage = stage.vkStage(),
            .device = device,
        };
    }

    pub fn deinit(self: Module) void {
        self.device.dispatch.destroyShaderModule(
            self.device.device,
            self.handle,
            null,
        );
    }
};

fn logShaderInfo(shader: *glslang.Shader) void {
    const info = shader.getInfoLog() catch "";
    const debug = shader.getDebugInfoLog() catch "";
    if (info.len > 0 or debug.len > 0) {
        log.err("glslang shader: info='{s}' debug='{s}'", .{ info, debug });
    }
}

fn logProgramInfo(program: *glslang.Program) void {
    const info = program.getInfoLog() catch "";
    const debug = program.getDebugInfoLog() catch "";
    if (info.len > 0 or debug.len > 0) {
        log.err("glslang program: info='{s}' debug='{s}'", .{ info, debug });
    }
}

test {
    std.testing.refAllDecls(@This());
}
