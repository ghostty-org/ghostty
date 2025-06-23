//! Wrapper for handling render passes.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const builtin = @import("builtin");
const objc = @import("objc");

const mtl = @import("api.zig");
const Pipeline = @import("Pipeline.zig");
const Texture = @import("Texture.zig");
const Target = @import("Target.zig");
const Metal = @import("../Metal.zig");
const Buffer = @import("buffer.zig").Buffer;

const log = std.log.scoped(.metal);

/// Options for beginning a render pass.
pub const Options = struct {
    /// MTLCommandBuffer
    command_buffer: objc.Object,
    /// Color attachments for this render pass.
    attachments: []const Attachment,

    /// Describes a color attachment.
    pub const Attachment = struct {
        target: union(enum) {
            texture: Texture,
            target: Target,
        },
        clear_color: ?[4]f64 = null,
    };
};

/// Describes a step in a render pass.
pub const Step = struct {
    pipeline: Pipeline,
    /// MTLBuffer
    uniforms: ?objc.Object = null,
    /// MTLBuffer
    buffers: []const ?objc.Object = &.{},
    textures: []const ?Texture = &.{},
    draw: Draw,

    /// Describes the draw call for this step.
    pub const Draw = struct {
        type: mtl.MTLPrimitiveType,
        vertex_count: usize,
        instance_count: usize = 1,
    };
};

/// MTLRenderCommandEncoder
encoder: objc.Object,

/// Begin a render pass.
pub fn begin(
    opts: Options,
) Self {
    // Create a pass descriptor
    const desc = desc: {
        const MTLRenderPassDescriptor = objc.getClass("MTLRenderPassDescriptor").?;
        const desc = MTLRenderPassDescriptor.msgSend(
            objc.Object,
            objc.sel("renderPassDescriptor"),
            .{},
        );

        // Set our color attachment to be our drawable surface.
        const attachments = objc.Object.fromId(
            desc.getProperty(?*anyopaque, "colorAttachments"),
        );
        for (opts.attachments, 0..) |at, i| {
            const attachment = attachments.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, i)},
            );

            attachment.setProperty(
                "loadAction",
                @intFromEnum(@as(
                    mtl.MTLLoadAction,
                    if (at.clear_color != null)
                        .clear
                    else
                        .load,
                )),
            );
            attachment.setProperty(
                "storeAction",
                @intFromEnum(mtl.MTLStoreAction.store),
            );
            attachment.setProperty("texture", switch (at.target) {
                .texture => |t| t.texture.value,
                .target => |t| t.texture.value,
            });
            if (at.clear_color) |c| attachment.setProperty(
                "clearColor",
                mtl.MTLClearColor{
                    .red = c[0],
                    .green = c[1],
                    .blue = c[2],
                    .alpha = c[3],
                },
            );
        }

        break :desc desc;
    };

    // MTLRenderCommandEncoder
    const encoder = opts.command_buffer.msgSend(
        objc.Object,
        objc.sel("renderCommandEncoderWithDescriptor:"),
        .{desc.value},
    );

    return .{ .encoder = encoder };
}

/// Add a step to this render pass.
pub fn step(self: *const Self, s: Step) void {
    if (s.draw.instance_count == 0) return;

    // Set pipeline state
    self.encoder.msgSend(
        void,
        objc.sel("setRenderPipelineState:"),
        .{s.pipeline.state.value},
    );

    if (s.buffers.len > 0) {
        // We reserve index 0 for the vertex buffer, this isn't very
        // flexible but it lines up with the API we have for OpenGL.
        if (s.buffers[0]) |buf| {
            self.encoder.msgSend(
                void,
                objc.sel("setVertexBuffer:offset:atIndex:"),
                .{ buf.value, @as(c_ulong, 0), @as(c_ulong, 0) },
            );
            self.encoder.msgSend(
                void,
                objc.sel("setFragmentBuffer:offset:atIndex:"),
                .{ buf.value, @as(c_ulong, 0), @as(c_ulong, 0) },
            );
        }

        // Set the rest of the buffers starting at index 2, this is
        // so that we can use index 1 for the uniforms if present.
        //
        // Also, we set buffers (and textures) for both stages.
        //
        // Again, not very flexible, but it's consistent and predictable,
        // and we need to treat the uniforms as special because of OpenGL.
        //
        // TODO: Maybe in the future add info to the pipeline struct which
        //       allows it to define a mapping between provided buffers and
        //       what index they get set at for the vertex / fragment stage.
        for (s.buffers[1..], 2..) |b, i| if (b) |buf| {
            self.encoder.msgSend(
                void,
                objc.sel("setVertexBuffer:offset:atIndex:"),
                .{ buf.value, @as(c_ulong, 0), @as(c_ulong, i) },
            );
            self.encoder.msgSend(
                void,
                objc.sel("setFragmentBuffer:offset:atIndex:"),
                .{ buf.value, @as(c_ulong, 0), @as(c_ulong, i) },
            );
        };
    }

    // Set the uniforms as buffer index 1 if present.
    if (s.uniforms) |buf| {
        self.encoder.msgSend(
            void,
            objc.sel("setVertexBuffer:offset:atIndex:"),
            .{ buf.value, @as(c_ulong, 0), @as(c_ulong, 1) },
        );
        self.encoder.msgSend(
            void,
            objc.sel("setFragmentBuffer:offset:atIndex:"),
            .{ buf.value, @as(c_ulong, 0), @as(c_ulong, 1) },
        );
    }

    // Set textures.
    for (s.textures, 0..) |t, i| if (t) |tex| {
        self.encoder.msgSend(
            void,
            objc.sel("setVertexTexture:atIndex:"),
            .{ tex.texture.value, @as(c_ulong, i) },
        );
        self.encoder.msgSend(
            void,
            objc.sel("setFragmentTexture:atIndex:"),
            .{ tex.texture.value, @as(c_ulong, i) },
        );
    };

    // Draw!
    self.encoder.msgSend(
        void,
        objc.sel("drawPrimitives:vertexStart:vertexCount:instanceCount:"),
        .{
            @intFromEnum(s.draw.type),
            @as(c_ulong, 0),
            @as(c_ulong, s.draw.vertex_count),
            @as(c_ulong, s.draw.instance_count),
        },
    );
}

/// Complete this render pass.
/// This struct can no longer be used after calling this.
pub fn complete(self: *const Self) void {
    self.encoder.msgSend(void, objc.sel("endEncoding"), .{});
}
