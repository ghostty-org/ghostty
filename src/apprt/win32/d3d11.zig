/// Direct3D 11 device and swap chain management for Win32.
const std = @import("std");
const c = @import("c.zig");
const dx = @import("../../renderer/directx/d3d11.zig");

const log = std.log.scoped(.win32_d3d11);

const HWND = c.HWND;

/// Holds the D3D11 device, immediate context, and swap chain.
pub const D3D11Context = struct {
    device: dx.ID3D11Device,
    context: dx.ID3D11DeviceContext,
    swap_chain: dx.IDXGISwapChain,
    feature_level: dx.D3D_FEATURE_LEVEL,
    width: u32,
    height: u32,
};

/// Creates a D3D11 device and swap chain for the given window.
pub fn createDeviceAndSwapChain(hwnd: HWND, width: u32, height: u32) !D3D11Context {
    var flags: dx.D3D11_CREATE_DEVICE_FLAG = 0;
    if (std.debug.runtime_safety) {
        flags |= dx.D3D11_CREATE_DEVICE_DEBUG;
    }

    const feature_levels = [_]dx.D3D_FEATURE_LEVEL{
        .@"11_1",
        .@"11_0",
        .@"10_1",
        .@"10_0",
    };

    const sc_desc = dx.DXGI_SWAP_CHAIN_DESC{
        .BufferDesc = .{
            .Width = width,
            .Height = height,
            .Format = .R8G8B8A8_UNORM,
            .RefreshRate = .{ .Numerator = 0, .Denominator = 1 },
        },
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .BufferUsage = dx.DXGI_USAGE_RENDER_TARGET_OUTPUT,
        .BufferCount = 2,
        .OutputWindow = hwnd,
        .Windowed = dx.TRUE,
        .SwapEffect = .FLIP_DISCARD,
    };

    var device: ?dx.ID3D11Device = null;
    var context: ?dx.ID3D11DeviceContext = null;
    var swap_chain: ?dx.IDXGISwapChain = null;
    var feature_level: dx.D3D_FEATURE_LEVEL = .@"11_0";

    const hr = dx.D3D11CreateDeviceAndSwapChain(
        null, // Default adapter
        .HARDWARE,
        null, // No software rasterizer
        flags,
        &feature_levels,
        feature_levels.len,
        dx.D3D11_SDK_VERSION,
        &sc_desc,
        &swap_chain,
        &device,
        &feature_level,
        &context,
    );

    if (dx.FAILED(hr)) {
        log.err("D3D11CreateDeviceAndSwapChain failed: hr=0x{x}", .{@as(u32, @bitCast(hr))});
        return error.D3D11CreateFailed;
    }

    log.info("Created D3D11 device (feature level: {})", .{@intFromEnum(feature_level)});

    return .{
        .device = device.?,
        .context = context.?,
        .swap_chain = swap_chain.?,
        .feature_level = feature_level,
        .width = width,
        .height = height,
    };
}

/// Present the swap chain.
pub fn present(ctx: *D3D11Context, sync_interval: u32) !void {
    const hr = ctx.swap_chain.Present(sync_interval, 0);
    if (dx.FAILED(hr)) {
        log.warn("Present failed: hr=0x{x}", .{@as(u32, @bitCast(hr))});
        return error.PresentFailed;
    }
}

/// Resize the swap chain buffers.
pub fn resizeBuffers(ctx: *D3D11Context, width: u32, height: u32) !void {
    if (width == 0 or height == 0) return;

    const hr = ctx.swap_chain.ResizeBuffers(0, width, height, .UNKNOWN, 0);
    if (dx.FAILED(hr)) {
        log.warn("ResizeBuffers failed: hr=0x{x}", .{@as(u32, @bitCast(hr))});
        return error.ResizeBuffersFailed;
    }

    ctx.width = width;
    ctx.height = height;
    log.debug("Resized swap chain to {}x{}", .{ width, height });
}

/// Release all D3D11 resources.
pub fn destroyContext(ctx: *D3D11Context) void {
    ctx.context.ClearState();
    _ = ctx.swap_chain.Release();
    _ = ctx.context.Release();
    _ = ctx.device.Release();
    log.info("Destroyed D3D11 context", .{});
}
