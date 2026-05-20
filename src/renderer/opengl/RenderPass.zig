//! Wrapper for handling render passes.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");

const Sampler = @import("Sampler.zig");
const Target = @import("Target.zig");
const Texture = @import("Texture.zig");
const Pipeline = @import("Pipeline.zig");
const Buffer = @import("buffer.zig").Buffer;

const log = std.log.scoped(.opengl);

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
    samplers: []const ?Sampler = &.{},
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
/// Errors during GL bind / state setup short-circuit the step (we have
/// no recovery story mid-pass) but are logged so they're not silent.
pub fn step(self: *Self, s: Step) void {
    if (s.draw.instance_count == 0) return;

    const pbind = s.pipeline.program.use() catch |err| {
        log.warn("render pass: program bind failed err={}", .{err});
        return;
    };
    defer pbind.unbind();

    const vaobind = s.pipeline.vao.bind() catch |err| {
        log.warn("render pass: VAO bind failed err={}", .{err});
        return;
    };
    defer vaobind.unbind();

    const fbobind = switch (self.attachments[0].target) {
        .target => |t| t.framebuffer.bind(.framebuffer) catch |err| {
            log.warn("render pass: framebuffer bind failed err={}", .{err});
            return;
        },
        .texture => |t| bind: {
            const fbobind = s.pipeline.fbo.bind(.framebuffer) catch |err| {
                log.warn("render pass: pipeline fbo bind failed err={}", .{err});
                return;
            };
            fbobind.texture2D(.color0, t.target, t.texture, 0) catch |err| {
                log.warn("render pass: texture2D attach failed err={}", .{err});
                fbobind.unbind();
                return;
            };
            break :bind fbobind;
        },
    };
    defer fbobind.unbind();

    defer self.step_number += 1;

    // Set the viewport to match the attachment we're rendering into.
    // Ghostty's GTK apprt keeps the GL viewport in sync via GLArea, but
    // other apprts (e.g. embedded) do not, so we set it explicitly for
    // every step rather than relying on external viewport state.
    {
        const vp_w, const vp_h = switch (self.attachments[0].target) {
            .target => |t| .{ t.width, t.height },
            .texture => |t| .{ t.width, t.height },
        };
        gl.viewport(0, 0, @intCast(vp_w), @intCast(vp_h)) catch return;
    }

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

    // Bind relevant samplers.
    for (s.samplers, 0..) |s_, i| if (s_) |sampler| {
        _ = sampler.sampler.bind(@intCast(i)) catch return;
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
