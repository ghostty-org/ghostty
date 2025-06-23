//! Wrapper for handling render passes.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const builtin = @import("builtin");
const gl = @import("opengl");

const OpenGL = @import("../OpenGL.zig");
const Target = @import("Target.zig");
const Texture = @import("Texture.zig");
const Pipeline = @import("Pipeline.zig");
const RenderPass = @import("RenderPass.zig");
const Buffer = @import("buffer.zig").Buffer;

/// Options for beginning a render pass.
pub const Options = struct {
    /// Color attachments for this render pass.
    attachments: []const Attachment,

    /// Describes a color attachment.
    pub const Attachment = struct {
        target: union(enum) {
            texture: Texture,
            target: Target,
        },
        clear_color: ?[4]f32 = null,
    };
};

/// Describes a step in a render pass.
pub const Step = struct {
    pipeline: Pipeline,
    uniforms: ?gl.Buffer = null,
    buffers: []const ?gl.Buffer = &.{},
    textures: []const ?Texture = &.{},
    draw: Draw,

    /// Describes the draw call for this step.
    pub const Draw = struct {
        type: gl.Primitive,
        vertex_count: usize,
        instance_count: usize = 1,
    };
};

attachments: []const Options.Attachment,

step_number: usize = 0,

/// Begin a render pass.
pub fn begin(
    opts: Options,
) Self {
    return .{
        .attachments = opts.attachments,
    };
}

/// Add a step to this render pass.
///
/// TODO: Errors are silently ignored in this function, maybe they shouldn't be?
pub fn step(self: *Self, s: Step) void {
    if (s.draw.instance_count == 0) return;

    const pbind = s.pipeline.program.use() catch return;
    defer pbind.unbind();

    const vaobind = s.pipeline.vao.bind() catch return;
    defer vaobind.unbind();

    const fbobind = switch (self.attachments[0].target) {
        .target => |t| t.framebuffer.bind(.framebuffer) catch return,
        .texture => |t| bind: {
            const fbobind = s.pipeline.fbo.bind(.framebuffer) catch return;
            fbobind.texture2D(.color0, t.target, t.texture, 0) catch {
                fbobind.unbind();
                return;
            };
            break :bind fbobind;
        },
    };
    defer fbobind.unbind();

    defer self.step_number += 1;

    // If we have a clear color and this is the
    // first step in the pass, go ahead and clear.
    if (self.step_number == 0) if (self.attachments[0].clear_color) |c| {
        gl.clearColor(c[0], c[1], c[2], c[3]);
        gl.clear(gl.c.GL_COLOR_BUFFER_BIT);
    };

    // Bind the uniform buffer we bind at index 1 to align with Metal.
    if (s.uniforms) |ubo| {
        _ = ubo.bindBase(.uniform, 1) catch return;
    }

    // Bind relevant texture units.
    for (s.textures, 0..) |t, i| if (t) |tex| {
        gl.Texture.active(@intCast(i)) catch return;
        _ = tex.texture.bind(tex.target) catch return;
    };

    // Bind 0th buffer as the vertex buffer,
    // and bind the rest as storage buffers.
    if (s.buffers.len > 0) {
        if (s.buffers[0]) |vbo| vaobind.bindVertexBuffer(
            0,
            vbo.id,
            0,
            @intCast(s.pipeline.stride),
        ) catch return;

        for (s.buffers[1..], 1..) |b, i| if (b) |buf| {
            _ = buf.bindBase(.storage, @intCast(i)) catch return;
        };
    }

    if (s.pipeline.blending_enabled) {
        gl.enable(gl.c.GL_BLEND) catch return;
        gl.blendFunc(gl.c.GL_ONE, gl.c.GL_ONE_MINUS_SRC_ALPHA) catch return;
    } else {
        gl.disable(gl.c.GL_BLEND) catch return;
    }

    gl.drawArraysInstanced(
        s.draw.type,
        0,
        @intCast(s.draw.vertex_count),
        @intCast(s.draw.instance_count),
    ) catch return;
}

/// Complete this render pass.
/// This struct can no longer be used after calling this.
pub fn complete(self: *const Self) void {
    _ = self;
    gl.flush();
}
