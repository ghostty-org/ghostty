//! Graphics API wrapper for DirectX 11.
//!
//! This module mirrors the structure of Metal.zig: it is the public surface
//! for the DX11 renderer, re-exporting sub-modules and (eventually) providing
//! the GraphicsAPI contract required by GenericRenderer.
//!
//! Current status: infrastructure only — COM bindings, device lifecycle,
//! swap chain management, and an instanced cell-grid pipeline. The
//! GenericRenderer integration (Target, Frame, RenderPass, Buffer, Texture,
//! Sampler, shaders) is planned for follow-up work.
pub const DirectX11 = @This();

// Sub-module re-exports — low-level D3D11/DXGI/COM bindings.
pub const com = @import("directx11/com.zig");
pub const d3d11 = @import("directx11/d3d11.zig");
pub const dxgi = @import("directx11/dxgi.zig");

// Renderer components.
pub const Device = @import("directx11/device.zig").Device;
pub const Pipeline = @import("directx11/pipeline.zig").Pipeline;
pub const Constants = @import("directx11/pipeline.zig").Constants;
pub const CellGrid = @import("directx11/cell_grid.zig").CellGrid;
pub const CellInstance = @import("directx11/cell_grid.zig").CellInstance;

test {
    _ = com;
    _ = d3d11;
    _ = dxgi;
}
