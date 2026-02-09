//! Texture sampler wrapper for Direct3D 11.
const Self = @This();

const std = @import("std");
const d3d11 = @import("d3d11.zig");

const log = std.log.scoped(.directx);

pub const Options = struct {
    device: d3d11.ID3D11Device,
    filter: d3d11.D3D11_FILTER = .MIN_MAG_MIP_LINEAR,
    address_u: d3d11.D3D11_TEXTURE_ADDRESS_MODE = .CLAMP,
    address_v: d3d11.D3D11_TEXTURE_ADDRESS_MODE = .CLAMP,
};

sampler: ?d3d11.ID3D11SamplerState = null,

pub const Error = error{
    DirectXFailed,
};

pub fn init(opts: Options) Error!Self {
    const desc = d3d11.D3D11_SAMPLER_DESC{
        .Filter = opts.filter,
        .AddressU = opts.address_u,
        .AddressV = opts.address_v,
        .AddressW = .CLAMP,
    };

    var sampler: ?d3d11.ID3D11SamplerState = null;
    const hr = opts.device.CreateSamplerState(&desc, &sampler);
    if (d3d11.FAILED(hr)) {
        log.err("CreateSamplerState failed: hr=0x{x}", .{@as(u32, @bitCast(hr))});
        return error.DirectXFailed;
    }

    return .{
        .sampler = sampler,
    };
}

pub fn deinit(self: Self) void {
    if (self.sampler) |s| _ = s.Release();
}
