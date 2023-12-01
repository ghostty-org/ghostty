const std = @import("std");
const c = @import("c.zig");
const testlib = @import("test.zig");
const Shader = @import("shader.zig").Shader;

pub const Program = opaque {
    pub fn create() !*Program {
        if (c.glslang_program_create()) |ptr| return @ptrCast(ptr);
        return error.OutOfMemory;
    }

    pub fn delete(self: *Program) void {
        c.glslang_program_delete(@ptrCast(self));
    }

    pub fn addShader(self: *Program, shader: *Shader) void {
        c.glslang_program_add_shader(@ptrCast(self), @ptrCast(shader));
    }

    pub fn link(self: *Program, messages: c_int) !void {
        if (c.glslang_program_link(@ptrCast(self), messages) != 0) return;
        return error.GlslangFailed;
    }

    pub fn spirvGenerate(self: *Program, stage: c.glslang_stage_t) void {
        c.glslang_program_SPIRV_generate(@ptrCast(self), stage);
    }

    pub fn spirvGetSize(self: *Program) usize {
        return @intCast(c.glslang_program_SPIRV_get_size(@ptrCast(self)));
    }

    pub fn spirvGet(self: *Program, buf: []u32) void {
        c.glslang_program_SPIRV_get(@ptrCast(self), buf.ptr);
    }

    pub fn spirvGetPtr(self: *Program) ![*]u32 {
        return @ptrCast(c.glslang_program_SPIRV_get_ptr(@ptrCast(self)));
    }

    pub fn spirvGetMessages(self: *Program) ![:0]const u8 {
        const ptr = c.glslang_program_SPIRV_get_messages(@ptrCast(self));
        return std.mem.sliceTo(ptr, 0);
    }

    pub fn getInfoLog(self: *Program) ![:0]const u8 {
        const ptr = c.glslang_program_get_info_log(@ptrCast(self));
        return std.mem.sliceTo(ptr, 0);
    }

    pub fn getDebugInfoLog(self: *Program) ![:0]const u8 {
        const ptr = c.glslang_program_get_info_debug_log(@ptrCast(self));
        return std.mem.sliceTo(ptr, 0);
    }
};

test {
    var program = try Program.create();
    defer program.delete();
}
