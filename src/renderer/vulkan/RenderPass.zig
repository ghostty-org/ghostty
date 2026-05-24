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
device: ?*const Device = null,
step_number: usize = 0,

pub fn begin(opts: Options) Self {
    return .{
        .attachments = opts.attachments,
        .cb = opts.cb,
    };
}

/// Bind the pass's first attachment and start a `vkCmdBeginRendering`
/// scope. Caller wires the device in via `setDevice` before drawing
/// — until that's done this is a no-op so the renderer's frame loop
/// doesn't crash mid-bring-up.
pub fn setDevice(self: *Self, dev: *const Device) void {
    self.device = dev;
}

/// Record one step of the pass.
///
/// **Body is a stub.** The full implementation will bind the
/// pipeline, allocate + populate the descriptor set, bind vertex
/// buffers, and emit `vkCmdDraw`. Until that lands, step records
/// nothing — the frame loop runs end-to-end without drawing any
/// real terminal content but doesn't crash either, so the rest of
/// the Vulkan integration (per-surface CB + fence, target dmabuf
/// handoff, Qt-side import) can be developed in parallel.
pub fn step(self: *Self, s: Step) void {
    _ = self;
    _ = s;
    // No-op stub. Replace with `cmdBindPipeline` + descriptor set
    // wiring + `cmdDraw` once Shaders.init + DescriptorPool
    // integration lands.
}

/// Close the rendering scope. Currently a no-op — `RenderPass.begin`
/// never opens one because step is also a no-op. Real implementation
/// will pair `vkCmdEndRendering` here with the matching
/// `vkCmdBeginRendering` in `begin`.
pub fn complete(self: *const Self) void {
    _ = self;
}

test {
    std.testing.refAllDecls(@This());
}
