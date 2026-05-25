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
    /// Device + dispatch table for recording commands.
    device: *const Device,
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
device: *const Device,
step_number: usize = 0,

/// Last `Step.uniforms` value seen in this pass. The OpenGL backend
/// keeps the bound UBO across draw calls implicitly (GL state
/// persists), and the renderer's image/overlay draw calls in
/// `image.zig` don't pass `uniforms` at all — they expect the
/// previously-bound UBO to still be live. Vulkan needs explicit
/// descriptor-set updates per pipeline, so we cache the last UBO
/// buffer here and reuse it when a step doesn't supply one. Reset
/// to null at `begin`.
last_uniforms: ?vk.VkBuffer = null,

/// Begin a render pass. Transitions the first attachment to
/// `COLOR_ATTACHMENT_OPTIMAL` and opens a `vkCmdBeginRendering`
/// scope with the caller's clear color (defaults to opaque black).
///
/// We only act on attachments[0] for now — the renderer's calls
/// always pass exactly one attachment per pass, matching the
/// OpenGL backend's `RenderPass.Options.attachments` use.
pub fn begin(opts: Options) Self {
    const self: Self = .{
        .attachments = opts.attachments,
        .cb = opts.cb,
        .device = opts.device,
    };

    if (opts.attachments.len == 0) return self;

    const attach = opts.attachments[0];
    const view: vk.VkImageView, const image: vk.VkImage,
    const width: u32, const height: u32 = switch (attach.target) {
        .texture => |t| .{ t.view, t.image, @intCast(t.width), @intCast(t.height) },
        .target => |t| .{ t.view, t.image, t.width, t.height },
    };
    // Always Y-flip the viewport regardless of attachment kind.
    //
    // `cell_text` is projection-driven (vertex shader applies
    // `projection_matrix` to pixel coords) while `cell_bg` is
    // fragment-position-driven (derives grid_pos from
    // `gl_FragCoord.xy / cell_size`). For those two to agree on
    // where "row 0" lands in the framebuffer, the viewport
    // orientation must be the same for both — anything else
    // produces the cell-bg-at-top-while-cell-text-at-bottom
    // disagreement seen on the custom-shader (back_texture) path.
    // For the dmabuf `Target` we needed the Y-flip anyway (Qt mmaps
    // origin-upper-left). For shadertoy sampling: with both the
    // back_texture and frame.target Y-flipped, an upper-left
    // `gl_FragCoord` in the post fragment maps to texel y=0 (top
    // of back_texture = top of original render), which is what
    // `uv = fragCoord/iResolution` + `texture(iChannel0, uv)`
    // expects in Vulkan-native convention.

    // Transition to COLOR_ATTACHMENT_OPTIMAL. Sources from
    // UNDEFINED (fresh target) or whatever — we always discard
    // prior contents (loadOp = CLEAR / LOAD covered below; here we
    // just need write access).
    {
        const barrier: vk.VkImageMemoryBarrier = .{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = 0,
            .dstAccessMask = vk.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .oldLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresourceRange = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };
        opts.device.dispatch.cmdPipelineBarrier(
            opts.cb,
            vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            0,
            0, null,
            0, null,
            1, &barrier,
        );
    }

    const clear_value: vk.VkClearValue = if (attach.clear_color) |c| .{
        .color = .{ .float32 = c },
    } else .{ .color = .{ .float32 = .{ 0, 0, 0, 1 } } };

    const color_attachment: vk.VkRenderingAttachmentInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
        .pNext = null,
        .imageView = view,
        .imageLayout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .resolveMode = vk.VK_RESOLVE_MODE_NONE,
        .resolveImageView = null,
        .resolveImageLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
        // Always clear: the renderer redraws every cell each frame,
        // so prior contents are never useful. CLEAR is also free on
        // tiled GPUs (avoids a full attachment load).
        .loadOp = vk.VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = vk.VK_ATTACHMENT_STORE_OP_STORE,
        .clearValue = clear_value,
    };
    const info: vk.VkRenderingInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_RENDERING_INFO,
        .pNext = null,
        .flags = 0,
        .renderArea = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{ .width = width, .height = height },
        },
        .layerCount = 1,
        .viewMask = 0,
        .colorAttachmentCount = 1,
        .pColorAttachments = &color_attachment,
        .pDepthAttachment = null,
        .pStencilAttachment = null,
    };
    opts.device.dispatch.cmdBeginRendering(opts.cb, &info);

    // Dynamic state: viewport + scissor follow the attachment size.
    //
    // Negative `height` (Vulkan 1.1 maintenance1 / core) flips the Y
    // axis at viewport time so the renderer's OpenGL-style projection
    // matrices (Y-up clip space, `ortho2d` with bottom > top) keep
    // producing pixels at the expected location on screen. Without
    // this, everything renders upside-down — text intended for the
    // top of the window appears at the bottom. `gl_FragCoord` still
    // reports origin-upper-left, matching `cell_bg.f.glsl`'s
    // `layout(origin_upper_left)` request.
    const viewport: vk.VkViewport = .{
        .x = 0,
        .y = @floatFromInt(height),
        .width = @floatFromInt(width),
        .height = -@as(f32, @floatFromInt(height)),
        .minDepth = 0,
        .maxDepth = 1,
    };
    opts.device.dispatch.cmdSetViewport(opts.cb, 0, 1, &viewport);
    const scissor: vk.VkRect2D = .{
        .offset = .{ .x = 0, .y = 0 },
        .extent = .{ .width = width, .height = height },
    };
    opts.device.dispatch.cmdSetScissor(opts.cb, 0, 1, &scissor);

    return self;
}

/// Record one step of the pass.
///
/// Updates the pipeline's descriptor sets from the Step's resources
/// and emits the draw call. Resource conventions match the OpenGL
/// backend (so `generic.zig` call sites work unchanged):
///
///   - `uniforms`     → set 0, binding `pipeline.uniforms_binding`
///                      (UBO; the Globals block from `common.glsl`)
///   - `buffers[0]`   → vertex buffer at binding 0 (when the pipeline
///                      has a non-zero `vertex_stride`; ignored
///                      otherwise). Matches OpenGL's "0th buffer is
///                      the VBO" convention.
///   - `buffers[i]`, i≥1
///                    → set 2, binding `i` (storage buffer)
///   - `textures[i]`  → set 1, binding `i` (combined image sampler).
///                      The sampler is `samplers[i]` if provided,
///                      otherwise the pipeline's owned fallback
///                      `pipeline.sampler` (so the renderer can pass
///                      plain textures and let the pipeline pick the
///                      sampler config it needs).
///
/// Skips silently when the pipeline hasn't been constructed yet
/// (`VkPipeline == null`) — pipelines for shaders we haven't wired
/// up are default-null and we filter them out instead of crashing
/// on a null handle.
pub fn step(self: *Self, s: Step) void {
    if (s.pipeline.pipeline == null) return;
    if (s.draw.vertex_count == 0) return;

    const dev = self.device;

    // ---- vertex buffer (buffers[0]) ----------------------------
    if (s.pipeline.vertex_stride > 0 and s.buffers.len > 0) {
        if (s.buffers[0]) |vbo| {
            const offsets = [_]vk.VkDeviceSize{0};
            const bufs = [_]vk.VkBuffer{vbo};
            dev.dispatch.cmdBindVertexBuffers(
                self.cb,
                0, // first binding
                1, // binding count
                &bufs,
                &offsets,
            );
        }
    }

    // ---- update descriptor sets ---------------------------------
    //
    // We do one vkUpdateDescriptorSets call per descriptor write to
    // keep the code straightforward; the total writes per frame are
    // tiny (1 UBO + a handful of storage buffers + a handful of
    // samplers) so batching wouldn't move the needle.

    // UBO (set 0). The OpenGL backend's image/overlay draws don't
    // pass `uniforms` — they expect the previously-bound UBO to
    // persist. Fall back to `last_uniforms` when the Step doesn't
    // supply one. Track the new one for later steps.
    const ubo: ?vk.VkBuffer = s.uniforms orelse self.last_uniforms;
    if (s.uniforms) |b| self.last_uniforms = b;
    if (s.pipeline.descriptor_sets[0] != null) if (ubo) |ubo_buffer| {
        const buffer_info: vk.VkDescriptorBufferInfo = .{
            .buffer = ubo_buffer,
            .offset = 0,
            .range = vk.VK_WHOLE_SIZE,
        };
        const write: vk.VkWriteDescriptorSet = .{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = s.pipeline.descriptor_sets[0],
            .dstBinding = s.pipeline.uniforms_binding,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .pImageInfo = null,
            .pBufferInfo = &buffer_info,
            .pTexelBufferView = null,
        };
        dev.dispatch.updateDescriptorSets(dev.device, 1, &write, 0, null);
    };

    // Samplers (set 1)
    if (s.pipeline.descriptor_sets[1] != null) {
        const slot_count = @max(s.textures.len, s.samplers.len);
        for (0..slot_count) |slot| {
            const tex_opt: ?Texture = if (slot < s.textures.len) s.textures[slot] else null;
            const tex = tex_opt orelse continue;
            const samp_opt: ?Sampler = if (slot < s.samplers.len) s.samplers[slot] else null;
            const sampler_handle: vk.VkSampler = if (samp_opt) |samp|
                samp.sampler
            else if (s.pipeline.sampler != null)
                s.pipeline.sampler
            else
                continue;

            const image_info: vk.VkDescriptorImageInfo = .{
                .sampler = sampler_handle,
                .imageView = tex.view,
                .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            };
            const write: vk.VkWriteDescriptorSet = .{
                .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .pNext = null,
                .dstSet = s.pipeline.descriptor_sets[1],
                .dstBinding = @intCast(slot),
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .pImageInfo = &image_info,
                .pBufferInfo = null,
                .pTexelBufferView = null,
            };
            dev.dispatch.updateDescriptorSets(dev.device, 1, &write, 0, null);
        }
    }

    // Storage buffers (set 2). `buffers[0]` is reserved for the
    // vertex buffer (handled above), so storage starts at slot 1.
    if (s.pipeline.descriptor_sets[2] != null and s.buffers.len > 1) {
        for (s.buffers[1..], 1..) |maybe_buf, slot| {
            const buf = maybe_buf orelse continue;
            const buffer_info: vk.VkDescriptorBufferInfo = .{
                .buffer = buf,
                .offset = 0,
                .range = vk.VK_WHOLE_SIZE,
            };
            const write: vk.VkWriteDescriptorSet = .{
                .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .pNext = null,
                .dstSet = s.pipeline.descriptor_sets[2],
                .dstBinding = @intCast(slot),
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .pImageInfo = null,
                .pBufferInfo = &buffer_info,
                .pTexelBufferView = null,
            };
            dev.dispatch.updateDescriptorSets(dev.device, 1, &write, 0, null);
        }
    }

    // ---- bind descriptor sets -----------------------------------
    //
    // `cmdBindDescriptorSets` only accepts contiguous, non-null
    // handles starting at `firstSet`. To handle the cell_bg case
    // (sets 0 and 2, no set 1), we make one call per maximal
    // contiguous run of non-null sets.
    var start: usize = 0;
    while (start < s.pipeline.set_count) {
        if (s.pipeline.descriptor_sets[start] == null) {
            start += 1;
            continue;
        }
        var end = start + 1;
        while (end < s.pipeline.set_count and s.pipeline.descriptor_sets[end] != null) : (end += 1) {}
        dev.dispatch.cmdBindDescriptorSets(
            self.cb,
            vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
            s.pipeline.layout,
            @intCast(start),
            @intCast(end - start),
            &s.pipeline.descriptor_sets[start],
            0,
            null,
        );
        start = end;
    }

    dev.dispatch.cmdBindPipeline(
        self.cb,
        vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
        s.pipeline.pipeline,
    );
    dev.dispatch.cmdDraw(
        self.cb,
        @intCast(s.draw.vertex_count),
        @intCast(s.draw.instance_count),
        0,
        0,
    );
    self.step_number += 1;
}

/// Close the rendering scope and leave the attachment in a layout
/// the host can read back via the dmabuf export. `GENERAL` is the
/// safest choice for unknown consumer access patterns; the host
/// (Qt RHI) can transition again if it wants something more
/// specific.
pub fn complete(self: *const Self) void {
    if (self.attachments.len == 0) return;

    self.device.dispatch.cmdEndRendering(self.cb);

    // Final layout depends on what consumes the attachment next.
    // A `.texture` attachment is the custom-shader back_texture, read
    // by the post pass's sampler — transition to SHADER_READ_ONLY so
    // the descriptor write's declared layout matches reality
    // (otherwise validation flags VUID-vkCmdDraw-imageLayout-00344
    // and some drivers can mishandle sampling from an out-of-spec
    // layout). A `.target` attachment is the dmabuf-backed
    // `frame.target`; the next op is
    // `Target.recordCopyToDmabuf` which transitions from GENERAL
    // anyway, so leave it in GENERAL here.
    const image: vk.VkImage, const new_layout: vk.VkImageLayout, const dst_stage: vk.VkPipelineStageFlags, const dst_access: vk.VkAccessFlags =
        switch (self.attachments[0].target) {
            .texture => |t| .{
                t.image,
                vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                vk.VK_ACCESS_SHADER_READ_BIT,
            },
            .target => |t| .{
                t.image,
                vk.VK_IMAGE_LAYOUT_GENERAL,
                vk.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
                0,
            },
        };

    const barrier: vk.VkImageMemoryBarrier = .{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = vk.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        .dstAccessMask = dst_access,
        .oldLayout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .newLayout = new_layout,
        .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = .{
            .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };
    self.device.dispatch.cmdPipelineBarrier(
        self.cb,
        vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        dst_stage,
        0,
        0, null,
        0, null,
        1, &barrier,
    );
}

test {
    std.testing.refAllDecls(@This());
}
