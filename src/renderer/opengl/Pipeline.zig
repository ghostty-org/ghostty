//! Wrapper for handling render pipelines.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const builtin = @import("builtin");
const gl = @import("opengl");

const OpenGL = @import("../OpenGL.zig");
const Texture = @import("Texture.zig");
const Buffer = @import("buffer.zig").Buffer;

const log = std.log.scoped(.opengl);

/// Options for initializing a render pipeline.
pub const Options = struct {
    /// GLSL source of the vertex function
    vertex_fn: [:0]const u8,
    /// GLSL source of the fragment function
    fragment_fn: [:0]const u8,

    /// Vertex step function
    step_fn: StepFunction = .per_vertex,

    /// Whether to enable blending.
    blending_enabled: bool = true,

    pub const StepFunction = enum {
        constant,
        per_vertex,
        per_instance,
    };
};

program: gl.Program,

fbo: gl.Framebuffer,

vao: gl.VertexArray,

stride: usize,

blending_enabled: bool,

pub fn init(comptime VertexAttributes: ?type, opts: Options) !Self {
    // Load and compile our shaders.
    const program = try gl.Program.createVF(
        opts.vertex_fn,
        opts.fragment_fn,
    );
    errdefer program.destroy();

    const pbind = try program.use();
    defer pbind.unbind();

    const fbo = try gl.Framebuffer.create();
    errdefer fbo.destroy();
    const fbobind = try fbo.bind(.framebuffer);
    defer fbobind.unbind();

    const vao = try gl.VertexArray.create();
    errdefer vao.destroy();
    const vaobind = try vao.bind();
    defer vaobind.unbind();

    if (VertexAttributes) |VA| try autoAttribute(VA, vaobind, opts.step_fn);

    return .{
        .program = program,
        .fbo = fbo,
        .vao = vao,
        .stride = if (VertexAttributes) |VA| @sizeOf(VA) else 0,
        .blending_enabled = opts.blending_enabled,
    };
}

pub fn deinit(self: *const Self) void {
    self.program.destroy();
}

fn autoAttribute(
    T: type,
    vaobind: gl.VertexArray.Binding,
    step_fn: Options.StepFunction,
) !void {
    const divisor: gl.c.GLuint = switch (step_fn) {
        .per_vertex => 0,
        .per_instance => 1,
        .constant => std.math.maxInt(gl.c.GLuint),
    };

    inline for (@typeInfo(T).@"struct".fields, 0..) |field, i| {
        try vaobind.enableAttribArray(i);
        try vaobind.attributeBinding(i, 0);
        try vaobind.bindingDivisor(i, divisor);

        const offset = @offsetOf(T, field.name);

        const FT = switch (@typeInfo(field.type)) {
            .@"struct" => |s| s.backing_integer.?,
            .@"enum" => |e| e.tag_type,
            else => field.type,
        };

        const size, const IT = switch (@typeInfo(FT)) {
            .array => |a| .{ a.len, a.child },
            else => .{ 1, FT },
        };

        try switch (IT) {
            u8 => vaobind.attributeIFormat(
                i,
                size,
                gl.c.GL_UNSIGNED_BYTE,
                offset,
            ),
            u16 => vaobind.attributeIFormat(
                i,
                size,
                gl.c.GL_UNSIGNED_SHORT,
                offset,
            ),
            u32 => vaobind.attributeIFormat(
                i,
                size,
                gl.c.GL_UNSIGNED_INT,
                offset,
            ),
            i8 => vaobind.attributeIFormat(
                i,
                size,
                gl.c.GL_BYTE,
                offset,
            ),
            i16 => vaobind.attributeIFormat(
                i,
                size,
                gl.c.GL_SHORT,
                offset,
            ),
            i32 => vaobind.attributeIFormat(
                i,
                size,
                gl.c.GL_INT,
                offset,
            ),
            f16 => vaobind.attributeFormat(
                i,
                size,
                gl.c.GL_HALF_FLOAT,
                false,
                offset,
            ),
            f32 => vaobind.attributeFormat(
                i,
                size,
                gl.c.GL_FLOAT,
                false,
                offset,
            ),
            f64 => vaobind.attributeLFormat(
                i,
                size,
                offset,
            ),
            else => unreachable,
        };
    }
}
