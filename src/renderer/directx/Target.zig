//! Represents a render target for Direct3D 11.
//!
//! Wraps an ID3D11Texture2D + ID3D11RenderTargetView, optionally with
//! an ID3D11ShaderResourceView for reading the target as a texture.
const Self = @This();

const std = @import("std");
const d3d11 = @import("d3d11.zig");

const log = std.log.scoped(.directx);

pub const Options = struct {
    device: d3d11.ID3D11Device,
    width: usize,
    height: usize,
    format: d3d11.DXGI_FORMAT,
};

texture: ?d3d11.ID3D11Texture2D = null,
rtv: ?d3d11.ID3D11RenderTargetView = null,
srv: ?d3d11.ID3D11ShaderResourceView = null,
width: usize = 0,
height: usize = 0,

pub fn init(opts: Options) !Self {
    const w: u32 = @intCast(@max(opts.width, 1));
    const h: u32 = @intCast(@max(opts.height, 1));

    const desc = d3d11.D3D11_TEXTURE2D_DESC{
        .Width = w,
        .Height = h,
        .MipLevels = 1,
        .ArraySize = 1,
        .Format = opts.format,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .Usage = .DEFAULT,
        .BindFlags = d3d11.D3D11_BIND_RENDER_TARGET | d3d11.D3D11_BIND_SHADER_RESOURCE,
    };

    var texture: ?d3d11.ID3D11Texture2D = null;
    var hr = opts.device.CreateTexture2D(&desc, null, &texture);
    if (d3d11.FAILED(hr)) {
        log.err("CreateTexture2D (target) failed: hr=0x{x}", .{@as(u32, @bitCast(hr))});
        return error.DirectXFailed;
    }
    errdefer _ = texture.?.Release();

    // Create render target view
    var rtv: ?d3d11.ID3D11RenderTargetView = null;
    hr = opts.device.CreateRenderTargetView(@ptrCast(texture.?), null, &rtv);
    if (d3d11.FAILED(hr)) {
        log.err("CreateRenderTargetView failed: hr=0x{x}", .{@as(u32, @bitCast(hr))});
        return error.DirectXFailed;
    }
    errdefer _ = rtv.?.Release();

    // Create shader resource view
    const srv_desc = d3d11.D3D11_SHADER_RESOURCE_VIEW_DESC{
        .Format = opts.format,
        .ViewDimension = .TEXTURE2D,
        .u = .{
            .Texture2D = .{
                .MostDetailedMip = 0,
                .MipLevels = 1,
            },
        },
    };

    var srv: ?d3d11.ID3D11ShaderResourceView = null;
    hr = opts.device.CreateShaderResourceView(@ptrCast(texture.?), &srv_desc, &srv);
    if (d3d11.FAILED(hr)) {
        log.err("CreateShaderResourceView (target) failed: hr=0x{x}", .{@as(u32, @bitCast(hr))});
        return error.DirectXFailed;
    }

    return .{
        .texture = texture,
        .rtv = rtv,
        .srv = srv,
        .width = opts.width,
        .height = opts.height,
    };
}

pub fn deinit(self: *Self) void {
    if (self.rtv) |rtv| _ = rtv.Release();
    if (self.srv) |srv| _ = srv.Release();
    if (self.texture) |tex| _ = tex.Release();
    self.* = .{};
}
