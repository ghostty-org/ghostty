const std = @import("std");
const log = std.log.scoped(.directx11);
const com = @import("com.zig");
const dxgi = @import("dxgi.zig");
const d3d11 = @import("d3d11.zig");

const HRESULT = com.HRESULT;
const GUID = com.GUID;
const IUnknown = com.IUnknown;
const IDXGISwapChain = dxgi.IDXGISwapChain;

pub const Device = struct {
    device: *d3d11.ID3D11Device,
    context: *d3d11.ID3D11DeviceContext,
    swap_chain: *dxgi.IDXGISwapChain1,
    panel_native: *dxgi.ISwapChainPanelNative,
    rtv: ?*d3d11.ID3D11RenderTargetView,
    width: u32,
    height: u32,

    pub const InitError = error{
        DeviceCreationFailed,
        QueryInterfaceFailed,
        GetAdapterFailed,
        GetFactoryFailed,
        SwapChainCreationFailed,
        SetSwapChainFailed,
        BackBufferFailed,
        RenderTargetViewFailed,
    };

    pub fn init(panel_native_ptr: *anyopaque, width: u32, height: u32) InitError!Device {
        log.info("init called: panel=0x{x}, size={}x{}", .{ @intFromPtr(panel_native_ptr), width, height });

        // Cast the opaque pointer to ISwapChainPanelNative.
        const panel_native: *dxgi.ISwapChainPanelNative = @ptrCast(@alignCast(panel_native_ptr));

        // Create D3D11 device and immediate context.
        var device: ?*d3d11.ID3D11Device = null;
        var context: ?*d3d11.ID3D11DeviceContext = null;
        const feature_levels = [_]d3d11.D3D_FEATURE_LEVEL{.@"11_0"};
        var hr = d3d11.D3D11CreateDevice(
            null, // default adapter
            .HARDWARE,
            null, // no software rasterizer
            d3d11.D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            &feature_levels,
            feature_levels.len,
            d3d11.D3D11_SDK_VERSION,
            &device,
            null, // don't need actual feature level back
            &context,
        );
        if (com.FAILED(hr)) {
            log.err("D3D11CreateDevice failed: hr=0x{x}", .{@as(u32, @bitCast(hr))});
            return InitError.DeviceCreationFailed;
        }

        const dev = device.?;
        errdefer _ = dev.Release();
        const ctx = context.?;
        errdefer _ = ctx.Release();

        log.debug("D3D11CreateDevice OK: device=0x{x}", .{@intFromPtr(dev)});

        // QueryInterface device -> IDXGIDevice
        var dxgi_device_opt: ?*anyopaque = null;
        hr = dev.vtable.QueryInterface(dev, &dxgi.IDXGIDevice.IID, &dxgi_device_opt);
        if (com.FAILED(hr) or dxgi_device_opt == null) {
            log.err("QI for IDXGIDevice failed: hr=0x{x}", .{@as(u32, @bitCast(hr))});
            return InitError.QueryInterfaceFailed;
        }
        const dxgi_device: *dxgi.IDXGIDevice = @ptrCast(@alignCast(dxgi_device_opt.?));
        defer _ = dxgi_device.Release();

        // Get the adapter from the DXGI device.
        var adapter: ?*dxgi.IDXGIAdapter = null;
        hr = dxgi_device.GetAdapter(&adapter);
        if (com.FAILED(hr) or adapter == null) {
            log.err("GetAdapter failed: hr=0x{x}", .{@as(u32, @bitCast(hr))});
            return InitError.GetAdapterFailed;
        }
        defer _ = adapter.?.Release();

        // Get IDXGIFactory2 from the adapter.
        var factory_opt: ?*anyopaque = null;
        hr = adapter.?.GetParent(&dxgi.IDXGIFactory2.IID, &factory_opt);
        if (com.FAILED(hr) or factory_opt == null) {
            log.err("GetParent(IDXGIFactory2) failed: hr=0x{x}", .{@as(u32, @bitCast(hr))});
            return InitError.GetFactoryFailed;
        }
        const factory: *dxgi.IDXGIFactory2 = @ptrCast(@alignCast(factory_opt.?));
        defer _ = factory.Release();

        // Create swap chain for composition.
        const desc = dxgi.DXGI_SWAP_CHAIN_DESC1{
            .Width = width,
            .Height = height,
            .Format = .B8G8R8A8_UNORM,
            .Stereo = 0,
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .BufferUsage = dxgi.DXGI_USAGE_RENDER_TARGET_OUTPUT,
            .BufferCount = 2,
            .Scaling = .STRETCH,
            .SwapEffect = .FLIP_SEQUENTIAL,
            .AlphaMode = .PREMULTIPLIED,
            .Flags = 0,
        };

        var swap_chain: ?*dxgi.IDXGISwapChain1 = null;
        hr = factory.CreateSwapChainForComposition(
            @ptrCast(dev),
            &desc,
            null,
            &swap_chain,
        );
        if (com.FAILED(hr) or swap_chain == null) {
            log.err("CreateSwapChainForComposition failed: hr=0x{x}", .{@as(u32, @bitCast(hr))});
            return InitError.SwapChainCreationFailed;
        }
        const sc = swap_chain.?;
        errdefer _ = sc.Release();

        // Attach the swap chain to the SwapChainPanel.
        hr = panel_native.SetSwapChain(@ptrCast(sc));
        if (com.FAILED(hr)) {
            log.err("SetSwapChain failed: hr=0x{x}", .{@as(u32, @bitCast(hr))});
            return InitError.SetSwapChainFailed;
        }
        errdefer _ = panel_native.SetSwapChain(null);

        // Get the back buffer and create a render target view.
        const rtv = createRenderTargetView(dev, sc) orelse {
            log.err("createRenderTargetView failed", .{});
            return InitError.RenderTargetViewFailed;
        };

        log.info("device initialised: {}x{}", .{ width, height });

        return Device{
            .device = dev,
            .context = ctx,
            .swap_chain = sc,
            .panel_native = panel_native,
            .rtv = rtv,
            .width = width,
            .height = height,
        };
    }

    pub fn deinit(self: *Device) void {
        // Release render target view.
        if (self.rtv) |rtv| {
            _ = rtv.Release();
            self.rtv = null;
        }

        // Detach swap chain from the panel.
        _ = self.panel_native.SetSwapChain(null);

        // Release in reverse creation order.
        _ = self.swap_chain.Release();
        _ = self.context.Release();
        _ = self.device.Release();
    }

    pub const ResizeError = error{
        ResizeBuffersFailed,
        RenderTargetViewFailed,
    };

    pub fn resize(self: *Device, width: u32, height: u32) ResizeError!void {
        // Release current render target view.
        if (self.rtv) |rtv| {
            _ = rtv.Release();
            self.rtv = null;
        }

        // Resize swap chain buffers.
        const hr = self.swap_chain.ResizeBuffers(0, width, height, .UNKNOWN, 0);
        if (com.FAILED(hr)) {
            log.err("IDXGISwapChain1::ResizeBuffers failed: hr=0x{x}", .{@as(u32, @bitCast(hr))});
            return ResizeError.ResizeBuffersFailed;
        }

        // Recreate render target view.
        self.rtv = createRenderTargetView(self.device, self.swap_chain) orelse {
            return ResizeError.RenderTargetViewFailed;
        };

        self.width = width;
        self.height = height;
    }

    pub const PresentError = error{
        PresentFailed,
    };

    pub fn present(self: *Device) PresentError!void {
        const hr = self.swap_chain.Present(1, 0);
        if (com.FAILED(hr)) {
            log.err("IDXGISwapChain1::Present failed: hr=0x{x}", .{@as(u32, @bitCast(hr))});
            return PresentError.PresentFailed;
        }
    }

    pub fn clearRenderTarget(self: *Device, color: [4]f32) void {
        const rtv = self.rtv orelse return;

        // Set viewport to full swap chain dimensions.
        const viewport = d3d11.D3D11_VIEWPORT{
            .TopLeftX = 0.0,
            .TopLeftY = 0.0,
            .Width = @floatFromInt(self.width),
            .Height = @floatFromInt(self.height),
            .MinDepth = 0.0,
            .MaxDepth = 1.0,
        };
        self.context.RSSetViewports(&.{viewport});

        // Bind the render target.
        self.context.OMSetRenderTargets(&.{rtv}, null);

        // Clear to the specified color.
        self.context.ClearRenderTargetView(rtv, &color);
    }

    /// Get the back buffer from the swap chain and create a render target view.
    fn createRenderTargetView(
        device: *d3d11.ID3D11Device,
        swap_chain: *dxgi.IDXGISwapChain1,
    ) ?*d3d11.ID3D11RenderTargetView {
        // Get back buffer as ID3D11Texture2D.
        var back_buffer_opt: ?*anyopaque = null;
        var hr = swap_chain.GetBuffer(0, &d3d11.ID3D11Texture2D.IID, &back_buffer_opt);
        if (com.FAILED(hr) or back_buffer_opt == null) {
            log.err("IDXGISwapChain1::GetBuffer failed: hr=0x{x}", .{@as(u32, @bitCast(hr))});
            return null;
        }
        const back_buffer: *d3d11.ID3D11Texture2D = @ptrCast(@alignCast(back_buffer_opt.?));
        defer _ = back_buffer.Release();

        // Create render target view from the back buffer.
        var rtv: ?*d3d11.ID3D11RenderTargetView = null;
        hr = device.CreateRenderTargetView(@ptrCast(back_buffer), null, &rtv);
        if (com.FAILED(hr) or rtv == null) {
            log.err("ID3D11Device::CreateRenderTargetView failed: hr=0x{x}", .{@as(u32, @bitCast(hr))});
            return null;
        }

        return rtv.?;
    }
};
