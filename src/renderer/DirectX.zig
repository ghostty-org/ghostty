//! Graphics API wrapper for Direct3D 11.
pub const DirectX = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const shadertoy = @import("shadertoy.zig");
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const configpkg = @import("../config.zig");
const rendererpkg = @import("../renderer.zig");
const Renderer = rendererpkg.GenericRenderer(DirectX);

const d3d11 = @import("directx/d3d11.zig");

pub const GraphicsAPI = DirectX;
pub const Target = @import("directx/Target.zig");
pub const Frame = @import("directx/Frame.zig");
pub const RenderPass = @import("directx/RenderPass.zig");
pub const Pipeline = @import("directx/Pipeline.zig");
const bufferpkg = @import("directx/buffer.zig");
pub const Buffer = bufferpkg.Buffer;
pub const Sampler = @import("directx/Sampler.zig");
pub const Texture = @import("directx/Texture.zig");
pub const shaders = @import("directx/shaders.zig");

/// Target for custom shader compilation.
pub const custom_shader_target: shadertoy.Target = .hlsl;
/// D3D11 screen space has +Y down.
pub const custom_shader_y_is_down = true;
/// Double buffering for D3D11.
pub const swap_chain_count = 2;

const log = std.log.scoped(.directx);

alloc: std.mem.Allocator,

/// Alpha blending mode
blending: configpkg.Config.AlphaBlending,

/// D3D11 device (owned by the apprt surface, not released here).
device: d3d11.ID3D11Device,

/// D3D11 immediate context (owned by the apprt surface, not released here).
context: d3d11.ID3D11DeviceContext,

/// The most recently presented target.
last_target: ?Target = null,

/// The apprt surface, stored during threadEnter.
surface: ?*apprt.Surface = null,

/// Overlay resources for unfocused split dimming (lazily initialized).
overlay_vs: ?d3d11.ID3D11VertexShader = null,
overlay_ps: ?d3d11.ID3D11PixelShader = null,
overlay_blend: ?d3d11.ID3D11BlendState = null,
overlay_cbuf: ?d3d11.ID3D11Buffer = null,

pub fn init(alloc: Allocator, opts: rendererpkg.Options) !DirectX {
    const surface = opts.rt_surface;
    const ctx = surface.d3d11_ctx orelse return error.NoD3D11Context;

    return .{
        .alloc = alloc,
        .blending = opts.config.blending,
        .device = ctx.device,
        .context = ctx.context,
    };
}

pub fn deinit(self: *DirectX) void {
    if (self.overlay_cbuf) |b| _ = b.Release();
    if (self.overlay_blend) |b| _ = b.Release();
    if (self.overlay_ps) |ps| _ = ps.Release();
    if (self.overlay_vs) |vs| _ = vs.Release();
    self.* = undefined;
}

/// Called early right after surface creation.
pub fn surfaceInit(surface: *apprt.Surface) !void {
    _ = surface;
    // D3D11 device creation happens in the surface.
}

/// Called just prior to spinning up the renderer thread.
pub fn finalizeSurfaceInit(self: *const DirectX, surface: *apprt.Surface) !void {
    _ = self;
    _ = surface;
    // D3D11 doesn't need context release like OpenGL.
}

/// Called when renderer thread begins.
pub fn threadEnter(self: *DirectX, surface: *apprt.Surface) !void {
    self.surface = surface;
}

/// Called when renderer thread exits.
pub fn threadExit(self: *const DirectX) void {
    _ = self;
}

/// Actions taken before doing anything in `drawFrame`.
pub fn drawFrameStart(self: *DirectX) void {
    _ = self;
}

/// Actions taken after `drawFrame` is done.
pub fn drawFrameEnd(self: *DirectX) void {
    if (self.surface) |s| {
        s.presentD3D11() catch |err| {
            log.warn("Present failed: {}", .{err});
        };
    }
}

pub fn initShaders(
    self: *const DirectX,
    alloc: Allocator,
    custom_shaders: []const [:0]const u8,
) !shaders.Shaders {
    _ = alloc;
    return try shaders.Shaders.init(
        self.alloc,
        self.device,
        custom_shaders,
    );
}

/// Get the current size of the runtime surface.
pub fn surfaceSize(self: *const DirectX) !struct { width: u32, height: u32 } {
    if (self.surface) |s| {
        const size = try s.getSize();
        return .{ .width = size.width, .height = size.height };
    }
    return .{ .width = 800, .height = 600 };
}

/// Initialize a new render target.
pub fn initTarget(self: *const DirectX, width: usize, height: usize) !Target {
    return Target.init(.{
        .device = self.device,
        .width = width,
        .height = height,
        .format = if (self.blending.isLinear()) .R8G8B8A8_UNORM_SRGB else .R8G8B8A8_UNORM,
    });
}

/// Present the provided target by copying it to the swap chain back buffer.
pub fn present(self: *DirectX, target: Target) !void {
    self.last_target = target;

    const surface = self.surface orelse return;
    const swap_chain = surface.getSwapChain() orelse return;

    // Get the back buffer from the swap chain
    var raw: ?*anyopaque = null;
    const hr = swap_chain.GetBuffer(0, &d3d11.IID_ID3D11Texture2D, &raw);
    if (d3d11.FAILED(hr)) {
        log.warn("GetBuffer failed: hr=0x{x}", .{@as(u32, @bitCast(hr))});
        return;
    }
    const bb: d3d11.ID3D11Texture2D = @ptrCast(@alignCast(raw orelse return));
    defer _ = bb.Release();

    if (target.texture) |src_tex| {
        self.context.CopyResource(@ptrCast(bb), @ptrCast(src_tex));
    }

    // Draw unfocused split overlay if needed.
    if (surface.getUnfocusedSplitOverlay()) |color| {
        self.drawOverlay(bb, color);
    }

    self.context.Flush();
}

/// Draw a semi-transparent colored overlay on the back buffer for unfocused split dimming.
fn drawOverlay(self: *DirectX, bb: d3d11.ID3D11Texture2D, color: [4]f32) void {
    // Lazily initialize overlay resources.
    if (self.overlay_vs == null) {
        self.initOverlay() catch |err| {
            log.warn("Failed to init overlay resources: {}", .{err});
            return;
        };
    }

    // Create a temporary RTV for the back buffer.
    var rtv: ?d3d11.ID3D11RenderTargetView = null;
    const hr = self.device.CreateRenderTargetView(@ptrCast(bb), null, &rtv);
    if (d3d11.FAILED(hr) or rtv == null) return;
    defer _ = rtv.?.Release();

    const ctx = self.context;

    // Set render target.
    const rtvs = [_]?d3d11.ID3D11RenderTargetView{rtv};
    ctx.OMSetRenderTargets(1, @ptrCast(&rtvs), null);

    // Set viewport from surface dimensions.
    const size = (self.surface orelse return).getSize() catch return;
    const vp = d3d11.D3D11_VIEWPORT{
        .TopLeftX = 0,
        .TopLeftY = 0,
        .Width = @floatFromInt(size.width),
        .Height = @floatFromInt(size.height),
        .MinDepth = 0,
        .MaxDepth = 1,
    };
    ctx.RSSetViewports(1, @ptrCast(&vp));

    // Update constant buffer with overlay color.
    ctx.UpdateSubresource(@ptrCast(self.overlay_cbuf.?), 0, null, @ptrCast(&color), 0, 0);

    // Bind shaders.
    ctx.VSSetShader(self.overlay_vs);
    ctx.PSSetShader(self.overlay_ps);
    ctx.IASetInputLayout(null);
    ctx.IASetPrimitiveTopology(.TRIANGLELIST);

    // Bind constant buffer.
    const bufs = [_]?d3d11.ID3D11Buffer{self.overlay_cbuf.?};
    ctx.PSSetConstantBuffers(0, 1, &bufs);

    // Enable alpha blending (premultiplied).
    ctx.OMSetBlendState(self.overlay_blend, null, 0xFFFFFFFF);

    // Draw full-screen triangle.
    ctx.DrawInstanced(3, 1, 0, 0);

    // Unbind render target so Present works correctly.
    const null_rtvs = [_]?d3d11.ID3D11RenderTargetView{null};
    ctx.OMSetRenderTargets(1, @ptrCast(&null_rtvs), null);
}

/// Compile and create D3D11 resources for the overlay effect.
fn initOverlay(self: *DirectX) !void {
    // Vertex shader: full-screen triangle from SV_VertexID.
    const vs_src: [:0]const u8 =
        \\struct VSOut { float4 pos : SV_Position; };
        \\VSOut vs_main(uint vid : SV_VertexID) {
        \\    VSOut o;
        \\    o.pos.x = (vid == 2) ? 3.0 : -1.0;
        \\    o.pos.y = (vid == 0) ? -3.0 : 1.0;
        \\    o.pos.z = 1.0; o.pos.w = 1.0;
        \\    return o;
        \\}
    ;

    // Pixel shader: output constant color from cbuffer.
    const ps_src: [:0]const u8 =
        \\cbuffer OverlayColor : register(b0) { float4 overlay_color; };
        \\float4 ps_main(float4 pos : SV_Position) : SV_Target {
        \\    return overlay_color;
        \\}
    ;

    // Compile vertex shader.
    var vs_blob: ?d3d11.ID3DBlob = null;
    var vs_errors: ?d3d11.ID3DBlob = null;
    var hr = d3d11.D3DCompile(
        vs_src.ptr, vs_src.len, "overlay_vs", null, null,
        "vs_main", "vs_5_0",
        d3d11.D3DCOMPILE_ENABLE_STRICTNESS | d3d11.D3DCOMPILE_OPTIMIZATION_LEVEL3,
        0, &vs_blob, &vs_errors,
    );
    if (vs_errors) |e| _ = e.Release();
    if (d3d11.FAILED(hr)) return error.DirectXFailed;
    defer _ = vs_blob.?.Release();

    const vs_code = vs_blob.?.GetBufferPointer() orelse return error.DirectXFailed;
    const vs_size = vs_blob.?.GetBufferSize();
    hr = self.device.CreateVertexShader(vs_code, vs_size, null, &self.overlay_vs);
    if (d3d11.FAILED(hr)) return error.DirectXFailed;

    // Compile pixel shader.
    var ps_blob: ?d3d11.ID3DBlob = null;
    var ps_errors: ?d3d11.ID3DBlob = null;
    hr = d3d11.D3DCompile(
        ps_src.ptr, ps_src.len, "overlay_ps", null, null,
        "ps_main", "ps_5_0",
        d3d11.D3DCOMPILE_ENABLE_STRICTNESS | d3d11.D3DCOMPILE_OPTIMIZATION_LEVEL3,
        0, &ps_blob, &ps_errors,
    );
    if (ps_errors) |e| _ = e.Release();
    if (d3d11.FAILED(hr)) return error.DirectXFailed;
    defer _ = ps_blob.?.Release();

    const ps_code = ps_blob.?.GetBufferPointer() orelse return error.DirectXFailed;
    const ps_size = ps_blob.?.GetBufferSize();
    hr = self.device.CreatePixelShader(ps_code, ps_size, null, &self.overlay_ps);
    if (d3d11.FAILED(hr)) return error.DirectXFailed;

    // Create blend state (premultiplied alpha).
    const blend_desc = d3d11.D3D11_BLEND_DESC{
        .RenderTarget = [_]d3d11.D3D11_RENDER_TARGET_BLEND_DESC{.{
            .BlendEnable = d3d11.TRUE,
            .SrcBlend = .ONE,
            .DestBlend = .INV_SRC_ALPHA,
            .BlendOp = .ADD,
            .SrcBlendAlpha = .ONE,
            .DestBlendAlpha = .INV_SRC_ALPHA,
            .BlendOpAlpha = .ADD,
            .RenderTargetWriteMask = @as(d3d11.BYTE, @intCast(d3d11.D3D11_COLOR_WRITE_ENABLE_ALL)),
        }} ++ (.{d3d11.D3D11_RENDER_TARGET_BLEND_DESC{}} ** 7),
    };
    hr = self.device.CreateBlendState(&blend_desc, &self.overlay_blend);
    if (d3d11.FAILED(hr)) return error.DirectXFailed;

    // Create constant buffer (16 bytes = float4).
    const cbuf_desc = d3d11.D3D11_BUFFER_DESC{
        .ByteWidth = 16,
        .Usage = .DEFAULT,
        .BindFlags = d3d11.D3D11_BIND_CONSTANT_BUFFER,
        .CPUAccessFlags = 0,
        .MiscFlags = 0,
        .StructureByteStride = 0,
    };
    hr = self.device.CreateBuffer(&cbuf_desc, null, &self.overlay_cbuf);
    if (d3d11.FAILED(hr)) return error.DirectXFailed;
}

/// Present the last presented target again.
pub fn presentLastTarget(self: *DirectX) !void {
    if (self.last_target) |target| try self.present(target);
}

/// Begin a frame.
pub inline fn beginFrame(
    self: *const DirectX,
    renderer: *Renderer,
    target: *Target,
) !Frame {
    _ = self;
    return try Frame.begin(.{}, renderer, target);
}

/// Returns the options for creating uniform buffers.
pub inline fn uniformBufferOptions(self: DirectX) bufferpkg.Options {
    return .{
        .device = self.device,
        .context = self.context,
        .bind_flags = d3d11.D3D11_BIND_CONSTANT_BUFFER,
    };
}

/// Returns the options for creating foreground cell buffers.
pub inline fn fgBufferOptions(self: DirectX) bufferpkg.Options {
    return .{
        .device = self.device,
        .context = self.context,
        .bind_flags = d3d11.D3D11_BIND_VERTEX_BUFFER,
    };
}

/// Returns the options for creating background cell buffers.
pub inline fn bgBufferOptions(self: DirectX) bufferpkg.Options {
    return .{
        .device = self.device,
        .context = self.context,
        .bind_flags = d3d11.D3D11_BIND_SHADER_RESOURCE,
        .structured = true,
    };
}

/// Returns the options for creating image vertex buffers.
pub inline fn imageBufferOptions(self: DirectX) bufferpkg.Options {
    return .{
        .device = self.device,
        .context = self.context,
        .bind_flags = d3d11.D3D11_BIND_VERTEX_BUFFER,
    };
}

/// Returns the options for creating background image buffers.
pub inline fn bgImageBufferOptions(self: DirectX) bufferpkg.Options {
    return .{
        .device = self.device,
        .context = self.context,
        .bind_flags = d3d11.D3D11_BIND_VERTEX_BUFFER,
    };
}

/// Returns the options for creating custom shader textures.
pub inline fn textureOptions(self: DirectX) Texture.Options {
    return .{
        .device = self.device,
        .context = self.context,
        .format = .R8G8B8A8_UNORM_SRGB,
        .bind_flags = d3d11.D3D11_BIND_SHADER_RESOURCE | d3d11.D3D11_BIND_RENDER_TARGET,
    };
}

/// Returns the options for creating samplers.
pub inline fn samplerOptions(self: DirectX) Sampler.Options {
    return .{
        .device = self.device,
        .filter = .MIN_MAG_MIP_LINEAR,
        .address_u = .CLAMP,
        .address_v = .CLAMP,
    };
}

/// Pixel format for image texture options.
pub const ImageTextureFormat = enum {
    gray,
    rgba,
    bgra,

    fn toDxgiFormat(self: ImageTextureFormat, srgb: bool) d3d11.DXGI_FORMAT {
        return switch (self) {
            .gray => .R8_UNORM,
            .rgba => if (srgb) .R8G8B8A8_UNORM_SRGB else .R8G8B8A8_UNORM,
            .bgra => if (srgb) .B8G8R8A8_UNORM_SRGB else .B8G8R8A8_UNORM,
        };
    }
};

/// Returns the options for creating image textures.
pub inline fn imageTextureOptions(
    self: DirectX,
    format: ImageTextureFormat,
    srgb: bool,
) Texture.Options {
    return .{
        .device = self.device,
        .context = self.context,
        .format = format.toDxgiFormat(srgb),
        .bind_flags = d3d11.D3D11_BIND_SHADER_RESOURCE,
    };
}

/// Initializes a Texture suitable for the provided font atlas.
pub fn initAtlasTexture(
    self: *const DirectX,
    atlas: *const font.Atlas,
) Texture.Error!Texture {
    const format: d3d11.DXGI_FORMAT = switch (atlas.format) {
        .grayscale => .R8_UNORM,
        .bgra => .B8G8R8A8_UNORM_SRGB,
        else => @panic("unsupported atlas format for DirectX texture"),
    };

    return try Texture.init(
        .{
            .device = self.device,
            .context = self.context,
            .format = format,
            .bind_flags = d3d11.D3D11_BIND_SHADER_RESOURCE,
            .is_atlas = true,
        },
        atlas.size,
        atlas.size,
        null,
    );
}
