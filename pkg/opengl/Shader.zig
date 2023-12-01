const Shader = @This();

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.opengl);

const c = @import("c.zig");
const errors = @import("errors.zig");
const glad = @import("glad.zig");

id: c.GLuint,

pub inline fn create(typ: c.GLenum) errors.Error!Shader {
    const id = glad.context.CreateShader.?(typ);
    if (id == 0) {
        try errors.mustError();
        unreachable;
    }

    log.debug("shader created id={}", .{id});
    return Shader{ .id = id };
}

/// Set the source and compile a shader.
pub inline fn setSourceAndCompile(s: Shader, source: [:0]const u8) !void {
    glad.context.ShaderSource.?(s.id, 1, &@as([*c]const u8, @ptrCast(source)), null);
    glad.context.CompileShader.?(s.id);

    // Check if compilation succeeded
    var success: c_int = undefined;
    glad.context.GetShaderiv.?(s.id, c.GL_COMPILE_STATUS, &success);
    if (success == c.GL_TRUE) return;
    log.err("shader compilation failure id={} message={s}", .{
        s.id,
        std.mem.sliceTo(&s.getInfoLog(), 0),
    });
    return error.CompileFailed;
}

/// getInfoLog returns the info log for this shader. This attempts to
/// keep the log fully stack allocated and is therefore limited to a max
/// amount of elements.
//
// NOTE(mitchellh): we can add a dynamic version that uses an allocator
// if we ever need it.
pub inline fn getInfoLog(s: Shader) [512]u8 {
    var msg: [512]u8 = undefined;
    glad.context.GetShaderInfoLog.?(s.id, msg.len, null, &msg);
    return msg;
}

pub inline fn destroy(s: Shader) void {
    assert(s.id != 0);
    glad.context.DeleteShader.?(s.id);
    log.debug("shader destroyed id={}", .{s.id});
}
