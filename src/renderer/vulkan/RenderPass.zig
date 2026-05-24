//! Per-pass recording helper for `vkCmdBeginRendering` /
//! `vkCmdEndRendering` (Vulkan 1.3 dynamic rendering — no
//! `VkRenderPass` object needed) plus the per-`step` resource
//! binding + draw-call emission.
//!
//! **Stub.** The TYPES are wired so `GenericRenderer(Vulkan)` can
//! resolve at comptime and `-Drenderer=vulkan` builds. The bodies of
//! `step` and `complete` @panic — the actual command-recording layer
//! (descriptor sets, pipeline binding, vertex buffer binding, draw
//! calls) lands in a follow-up commit once the integration is
//! validated end-to-end.
//!
//! Counterpart: `src/renderer/opengl/RenderPass.zig`.

const Self = @This();

const std = @import("std");
const vk = @import("vulkan").c;

const Device = @import("Device.zig");
const Pipeline = @import("Pipeline.zig");
const Sampler = @import("Sampler.zig");
const Target = @import("Target.zig");
const Texture = @import("Texture.zig");
const bufferpkg = @import("buffer.zig");

const log = std.log.scoped(.vulkan);

/// Primitive topology. Variant names match `pkg/opengl/primitives.zig`'s
/// `gl.Primitive` so the renderer's call sites in `generic.zig` (e.g.
/// `.draw = .{ .type = .triangle, ... }`) work against either backend
/// without per-backend branching. Mapped to `VkPrimitiveTopology` at
/// command-recording time.
pub const Primitive = enum {
    point,
    line,
    line_strip,
    triangle,
    triangle_strip,

    pub fn toVk(self: Primitive) vk.VkPrimitiveTopology {
        return switch (self) {
            .point => vk.VK_PRIMITIVE_TOPOLOGY_POINT_LIST,
            .line => vk.VK_PRIMITIVE_TOPOLOGY_LINE_LIST,
            .line_strip => vk.VK_PRIMITIVE_TOPOLOGY_LINE_STRIP,
            .triangle => vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
            .triangle_strip => vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP,
        };
    }
};

pub const Options = struct {
    /// Caller-recorded command buffer to emit commands into. Provided
    /// by the enclosing `Frame`.
    cb: vk.VkCommandBuffer,

    /// Color attachments for the pass. With dynamic rendering each
    /// attachment is a render target + optional clear color.
    attachments: []const Attachment,

    pub const Attachment = struct {
        target: union(enum) {
            texture: Texture,
            target: Target,
        },
        clear_color: ?[4]f32 = null,
    };
};

/// Describes one rendering step within the pass: which pipeline to
/// bind, which resources (uniforms / vertex buffers / textures /
/// samplers) to bind, and the draw call to issue.
pub const Step = struct {
    pipeline: Pipeline,
    uniforms: ?vk.VkBuffer = null,
    buffers: []const ?vk.VkBuffer = &.{},
    textures: []const ?Texture = &.{},
    samplers: []const ?Sampler = &.{},
    draw: Draw,

    pub const Draw = struct {
        type: Primitive,
        vertex_count: usize,
        instance_count: usize = 1,
    };
};

pub const Error = error{
    /// Reserved for actual command-recording failures once `step` is
    /// implemented. Currently unused — the panic stub bypasses any
    /// error path.
    VulkanFailed,
};

attachments: []const Options.Attachment,
cb: vk.VkCommandBuffer,
step_number: usize = 0,

pub fn begin(opts: Options) Self {
    // The real implementation will record `vkCmdBeginRendering` here
    // with a `VkRenderingInfo` derived from `attachments`. Stub: just
    // hold onto the inputs.
    return .{
        .attachments = opts.attachments,
        .cb = opts.cb,
    };
}

pub fn step(self: *Self, s: Step) void {
    _ = self;
    _ = s;
    @panic("vulkan/RenderPass.step: not yet implemented — pipeline " ++
        "binding, descriptor sets, and draw recording land in a " ++
        "follow-up commit on `qt-vulkan-renderer`.");
}

pub fn complete(self: *const Self) void {
    _ = self;
    @panic("vulkan/RenderPass.complete: not yet implemented — needs " ++
        "`vkCmdEndRendering` + barrier-to-SHADER_READ once `step` " ++
        "actually records commands.");
}

test {
    std.testing.refAllDecls(@This());
}
