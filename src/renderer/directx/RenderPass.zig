//! Render pass for Direct3D 11 -- issues draw calls against a render target.
const Self = @This();

const std = @import("std");
const d3d11 = @import("d3d11.zig");

const Sampler = @import("Sampler.zig");
const Target = @import("Target.zig");
const Texture = @import("Texture.zig");
const Pipeline = @import("Pipeline.zig");
const BufferHandle = @import("buffer.zig").BufferHandle;

pub const Options = struct {
    attachments: []const Attachment,

    pub const Attachment = struct {
        target: union(enum) {
            texture: Texture,
            target: Target,
        },
        clear_color: ?[4]f32 = null,
    };
};

/// Primitive topology with names matching OpenGL's Primitive enum
/// so that generic.zig can use the same `.triangle` / `.triangle_strip` literals.
pub const Primitive = enum(u32) {
    point = @intFromEnum(d3d11.D3D11_PRIMITIVE_TOPOLOGY.POINTLIST),
    line = @intFromEnum(d3d11.D3D11_PRIMITIVE_TOPOLOGY.LINELIST),
    line_strip = @intFromEnum(d3d11.D3D11_PRIMITIVE_TOPOLOGY.LINESTRIP),
    triangle = @intFromEnum(d3d11.D3D11_PRIMITIVE_TOPOLOGY.TRIANGLELIST),
    triangle_strip = @intFromEnum(d3d11.D3D11_PRIMITIVE_TOPOLOGY.TRIANGLESTRIP),

    pub fn toD3D11(self: Primitive) d3d11.D3D11_PRIMITIVE_TOPOLOGY {
        return @enumFromInt(@intFromEnum(self));
    }
};

pub const Step = struct {
    pipeline: Pipeline,
    uniforms: ?BufferHandle = null,
    buffers: []const ?BufferHandle = &.{},
    textures: []const ?Texture = &.{},
    samplers: []const ?Sampler = &.{},
    draw: Draw,

    pub const Draw = struct {
        type: Primitive,
        vertex_count: usize,
        instance_count: usize = 1,
    };
};

context: d3d11.ID3D11DeviceContext,
attachments: []const Options.Attachment,
step_number: usize = 0,

pub fn begin(ctx: d3d11.ID3D11DeviceContext, opts: Options) Self {
    return .{
        .context = ctx,
        .attachments = opts.attachments,
    };
}

pub fn step(self: *Self, s: Step) void {
    if (s.draw.instance_count == 0) return;
    const ctx = self.context;

    defer self.step_number += 1;

    // On first step, set render target and optionally clear.
    if (self.step_number == 0) {
        if (self.attachments.len > 0) {
            const att = self.attachments[0];
            const rtv = switch (att.target) {
                .target => |t| t.rtv,
                .texture => |t| t.rtv,
            };
            if (rtv) |rv| {
                ctx.OMSetRenderTargets(1, @ptrCast(&rv), null);

                // Set viewport to match target dimensions
                const dims = switch (att.target) {
                    .target => |t| .{ t.width, t.height },
                    .texture => |t| .{ t.width, t.height },
                };
                if (dims[0] > 0 and dims[1] > 0) {
                    const vp = d3d11.D3D11_VIEWPORT{
                        .TopLeftX = 0,
                        .TopLeftY = 0,
                        .Width = @floatFromInt(dims[0]),
                        .Height = @floatFromInt(dims[1]),
                        .MinDepth = 0,
                        .MaxDepth = 1,
                    };
                    ctx.RSSetViewports(1, @ptrCast(&vp));
                }

                // Clear if requested
                if (att.clear_color) |c| {
                    ctx.ClearRenderTargetView(rv, &c);
                }
            }
        }
    }

    // Set shaders
    ctx.VSSetShader(s.pipeline.vertex_shader);
    ctx.PSSetShader(s.pipeline.pixel_shader);

    // Set input layout
    ctx.IASetInputLayout(s.pipeline.input_layout);

    // Set primitive topology
    ctx.IASetPrimitiveTopology(s.draw.type.toD3D11());

    // Set blend state
    if (s.pipeline.blending_enabled) {
        ctx.OMSetBlendState(s.pipeline.blend_state, null, 0xFFFFFFFF);
    } else {
        ctx.OMSetBlendState(null, null, 0xFFFFFFFF);
    }

    // Bind uniform constant buffer to b0 and b1 for both VS and PS.
    // Built-in shaders use b0, shadertoy/custom shaders use b1 (binding = 1 in GLSL prefix).
    // Binding to both is negligible cost and covers both cases.
    if (s.uniforms) |ubo| {
        if (ubo.buf) |b| {
            const bufs = [_]?d3d11.ID3D11Buffer{b};
            ctx.VSSetConstantBuffers(0, 1, &bufs);
            ctx.PSSetConstantBuffers(0, 1, &bufs);
            ctx.VSSetConstantBuffers(1, 1, &bufs);
            ctx.PSSetConstantBuffers(1, 1, &bufs);
        }
    }

    // Collect all SRVs to bind.
    // Layout: t0 = structured buffer SRV (from buffers[1+]), t1+ = texture SRVs
    var srv_array: [8]?d3d11.ID3D11ShaderResourceView = .{null} ** 8;
    var max_srv_slot: usize = 0;

    // Bind buffers:
    // buffers[0] = vertex buffer (IASetVertexBuffers)
    // buffers[1+] = structured buffers (SRV at t0+)
    if (s.buffers.len > 0) {
        if (s.buffers[0]) |vbo| {
            if (vbo.buf) |b| {
                const stride_val: d3d11.UINT = @intCast(s.pipeline.stride);
                const offset_val: d3d11.UINT = 0;
                const vbufs = [_]?d3d11.ID3D11Buffer{b};
                ctx.IASetVertexBuffers(0, 1, &vbufs, @ptrCast(&stride_val), @ptrCast(&offset_val));
            }
        }

        // Structured buffers go to SRV slots starting at t0
        for (s.buffers[1..], 0..) |buf_opt, i| {
            if (i < srv_array.len) {
                if (buf_opt) |bh| {
                    srv_array[i] = bh.srv;
                    if (i + 1 > max_srv_slot) max_srv_slot = i + 1;
                }
            }
        }
    }

    // Textures go after structured buffers.
    // When structured buffers exist (buffers[1+]), they occupy t0+, so textures start after.
    // When no structured buffers exist (e.g. custom shaders), textures start at t0.
    const texture_base: usize = if (s.buffers.len > 1) s.buffers.len - 1 else 0;
    for (s.textures, 0..) |t, i| {
        const slot = i + texture_base;
        if (slot < srv_array.len) {
            if (t) |tex| {
                srv_array[slot] = tex.srv;
                if (slot + 1 > max_srv_slot) max_srv_slot = slot + 1;
            }
        }
    }

    // Bind SRVs to both VS and PS
    if (max_srv_slot > 0) {
        ctx.VSSetShaderResources(0, @intCast(max_srv_slot), &srv_array);
        ctx.PSSetShaderResources(0, @intCast(max_srv_slot), &srv_array);
    }

    // Bind samplers
    if (s.samplers.len > 0) {
        var sampler_array: [4]?d3d11.ID3D11SamplerState = .{null} ** 4;
        const count = @min(s.samplers.len, sampler_array.len);
        for (s.samplers[0..count], 0..) |sam, i| {
            if (sam) |sa| {
                sampler_array[i] = sa.sampler;
            }
        }
        ctx.PSSetSamplers(0, @intCast(count), &sampler_array);
        ctx.VSSetSamplers(0, @intCast(count), &sampler_array);
    }

    // Draw
    ctx.DrawInstanced(
        @intCast(s.draw.vertex_count),
        @intCast(s.draw.instance_count),
        0,
        0,
    );
}

pub fn complete(self: *const Self) void {
    _ = self;
    // D3D11 doesn't need explicit flush per pass
}
