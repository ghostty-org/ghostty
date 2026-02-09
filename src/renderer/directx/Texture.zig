//! GPU texture wrapper for Direct3D 11.
const Self = @This();

const std = @import("std");
const d3d11 = @import("d3d11.zig");

const log = std.log.scoped(.directx);

pub const Options = struct {
    device: d3d11.ID3D11Device,
    context: d3d11.ID3D11DeviceContext,
    format: d3d11.DXGI_FORMAT = .R8G8B8A8_UNORM_SRGB,
    bind_flags: d3d11.D3D11_BIND_FLAG = d3d11.D3D11_BIND_SHADER_RESOURCE,
    /// Whether this is a rectangle texture (pixel-coordinate addressing).
    is_atlas: bool = false,
};

texture: ?d3d11.ID3D11Texture2D = null,
srv: ?d3d11.ID3D11ShaderResourceView = null,
rtv: ?d3d11.ID3D11RenderTargetView = null,
width: usize = 0,
height: usize = 0,
format: d3d11.DXGI_FORMAT = .UNKNOWN,
device: d3d11.ID3D11Device,
context: d3d11.ID3D11DeviceContext,

pub const Error = error{
    DirectXFailed,
};

pub fn init(
    opts: Options,
    width: usize,
    height: usize,
    data: ?[]const u8,
) Error!Self {
    const w: u32 = @intCast(@max(width, 1));
    const h: u32 = @intCast(@max(height, 1));

    const desc = d3d11.D3D11_TEXTURE2D_DESC{
        .Width = w,
        .Height = h,
        .MipLevels = 1,
        .ArraySize = 1,
        .Format = opts.format,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .Usage = .DEFAULT,
        .BindFlags = opts.bind_flags,
    };

    const row_pitch = w * formatBytesPerPixel(opts.format);

    const init_data: ?*const d3d11.D3D11_SUBRESOURCE_DATA = if (data) |d|
        &d3d11.D3D11_SUBRESOURCE_DATA{
            .pSysMem = @ptrCast(d.ptr),
            .SysMemPitch = row_pitch,
        }
    else
        null;

    var texture: ?d3d11.ID3D11Texture2D = null;
    var hr = opts.device.CreateTexture2D(&desc, init_data, &texture);
    if (d3d11.FAILED(hr)) {
        log.err("CreateTexture2D failed: hr=0x{x}", .{@as(u32, @bitCast(hr))});
        return error.DirectXFailed;
    }
    errdefer _ = texture.?.Release();

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
        log.err("CreateShaderResourceView (texture) failed: hr=0x{x}", .{@as(u32, @bitCast(hr))});
        return error.DirectXFailed;
    }

    // Create render target view if bind flags include RENDER_TARGET
    var rtv: ?d3d11.ID3D11RenderTargetView = null;
    if (opts.bind_flags & d3d11.D3D11_BIND_RENDER_TARGET != 0) {
        const rtv_desc = d3d11.D3D11_RENDER_TARGET_VIEW_DESC{
            .Format = opts.format,
            .ViewDimension = .TEXTURE2D,
        };
        hr = opts.device.CreateRenderTargetView(@ptrCast(texture.?), &rtv_desc, &rtv);
        if (d3d11.FAILED(hr)) {
            log.err("CreateRenderTargetView (texture) failed: hr=0x{x}", .{@as(u32, @bitCast(hr))});
            return error.DirectXFailed;
        }
    }

    return .{
        .texture = texture,
        .srv = srv,
        .rtv = rtv,
        .width = width,
        .height = height,
        .format = opts.format,
        .device = opts.device,
        .context = opts.context,
    };
}

pub fn deinit(self: Self) void {
    if (self.rtv) |rtv| _ = rtv.Release();
    if (self.srv) |srv| _ = srv.Release();
    if (self.texture) |tex| _ = tex.Release();
}

pub fn replaceRegion(
    self: Self,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    data: []const u8,
) Error!void {
    const tex = self.texture orelse return;

    const box = d3d11.D3D11_BOX{
        .left = @intCast(x),
        .top = @intCast(y),
        .front = 0,
        .right = @intCast(x + width),
        .bottom = @intCast(y + height),
        .back = 1,
    };

    const row_pitch: u32 = @intCast(width * formatBytesPerPixel(self.format));

    self.context.UpdateSubresource(
        @ptrCast(tex),
        0,
        &box,
        @ptrCast(data.ptr),
        row_pitch,
        0,
    );
}

fn formatBytesPerPixel(format: d3d11.DXGI_FORMAT) u32 {
    return switch (format) {
        .R8_UNORM, .R8_UINT, .R8_SINT => 1,
        .R16_UINT, .R16_SINT => 2,
        .R8G8B8A8_UNORM,
        .R8G8B8A8_UNORM_SRGB,
        .R8G8B8A8_UINT,
        .B8G8R8A8_UNORM,
        .B8G8R8A8_UNORM_SRGB,
        .R32_FLOAT,
        .R32_UINT,
        .R16G16_UINT,
        .R16G16_SINT,
        => 4,
        .R32G32_FLOAT => 8,
        .R32G32B32_FLOAT => 12,
        .R32G32B32A32_FLOAT => 16,
        else => 4, // reasonable default
    };
}
