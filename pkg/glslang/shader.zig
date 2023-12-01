const std = @import("std");
const c = @import("c.zig");
const testlib = @import("test.zig");

pub const Shader = opaque {
    pub fn create(input: *const c.glslang_input_t) !*Shader {
        if (c.glslang_shader_create(input)) |ptr| return @ptrCast(ptr);
        return error.OutOfMemory;
    }

    pub fn delete(self: *Shader) void {
        c.glslang_shader_delete(@ptrCast(self));
    }

    pub fn preprocess(self: *Shader, input: *const c.glslang_input_t) !void {
        if (c.glslang_shader_preprocess(@ptrCast(self), input) == 0)
            return error.GlslangFailed;
    }

    pub fn parse(self: *Shader, input: *const c.glslang_input_t) !void {
        if (c.glslang_shader_parse(@ptrCast(self), input) == 0)
            return error.GlslangFailed;
    }

    pub fn getInfoLog(self: *Shader) ![:0]const u8 {
        const ptr = c.glslang_shader_get_info_log(@ptrCast(self));
        return std.mem.sliceTo(ptr, 0);
    }

    pub fn getDebugInfoLog(self: *Shader) ![:0]const u8 {
        const ptr = c.glslang_shader_get_info_debug_log(@ptrCast(self));
        return std.mem.sliceTo(ptr, 0);
    }
};

test {
    const input: c.glslang_input_t = .{
        .language = c.GLSLANG_SOURCE_GLSL,
        .stage = c.GLSLANG_STAGE_FRAGMENT,
        .client = c.GLSLANG_CLIENT_VULKAN,
        .client_version = c.GLSLANG_TARGET_VULKAN_1_2,
        .target_language = c.GLSLANG_TARGET_SPV,
        .target_language_version = c.GLSLANG_TARGET_SPV_1_5,
        .code = @embedFile("test/simple.frag"),
        .default_version = 100,
        .default_profile = c.GLSLANG_NO_PROFILE,
        .force_default_version_and_profile = 0,
        .forward_compatible = 0,
        .messages = c.GLSLANG_MSG_DEFAULT_BIT,
        .resource = c.glslang_default_resource(),
    };

    try testlib.ensureInit();
    const shader = try Shader.create(&input);
    defer shader.delete();
    try shader.preprocess(&input);
    try shader.parse(&input);
}
