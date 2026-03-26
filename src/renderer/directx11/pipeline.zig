// Pipeline state for the DX11 cell grid renderer.
//
// Loads pre-compiled HLSL shaders via @embedFile, creates the input layout
// matching the CellInstance struct, and manages the constant buffer for
// per-frame uniforms (grid dimensions, viewport size, time).

const std = @import("std");
const log = std.log.scoped(.directx11);
const com = @import("com.zig");
const d3d11 = @import("d3d11.zig");
const dxgi = @import("dxgi.zig");

const HRESULT = com.HRESULT;

// Pre-compiled shader bytecode, embedded at comptime.
const vs_bytecode = @embedFile("../shaders/hlsl/cell_vs.cso");
const ps_bytecode = @embedFile("../shaders/hlsl/cell_ps.cso");

/// Constant buffer layout — must match the HLSL cbuffer exactly.
pub const Constants = extern struct {
    grid_size: [2]f32,
    cell_size_px: [2]f32,
    viewport_size: [2]f32,
    time: f32,
    _pad: f32 = 0,

    comptime {
        // D3D11 constant buffers must be a multiple of 16 bytes.
        std.debug.assert(@sizeOf(Constants) % 16 == 0);
    }
};

pub const Pipeline = struct {
    vertex_shader: *d3d11.ID3D11VertexShader,
    pixel_shader: *d3d11.ID3D11PixelShader,
    input_layout: *d3d11.ID3D11InputLayout,
    constant_buffer: *d3d11.ID3D11Buffer,

    pub const InitError = error{
        VertexShaderFailed,
        PixelShaderFailed,
        InputLayoutFailed,
        ConstantBufferFailed,
    };

    pub fn init(device: *d3d11.ID3D11Device) InitError!Pipeline {
        // Create vertex shader.
        var vs: ?*d3d11.ID3D11VertexShader = null;
        var hr = device.CreateVertexShader(vs_bytecode.ptr, vs_bytecode.len, null, &vs);
        if (com.FAILED(hr) or vs == null) {
            log.err("CreateVertexShader failed: hr=0x{x}", .{@as(u32, @bitCast(hr))});
            return InitError.VertexShaderFailed;
        }

        // Create pixel shader.
        var ps: ?*d3d11.ID3D11PixelShader = null;
        hr = device.CreatePixelShader(ps_bytecode.ptr, ps_bytecode.len, null, &ps);
        if (com.FAILED(hr) or ps == null) {
            log.err("CreatePixelShader failed: hr=0x{x}", .{@as(u32, @bitCast(hr))});
            _ = vs.?.vtable.Release(vs.?);
            return InitError.PixelShaderFailed;
        }

        // Create input layout matching CellInstance (all per-instance data).
        const input_elements = [_]d3d11.D3D11_INPUT_ELEMENT_DESC{
            .{
                .SemanticName = "BG_COLOR",
                .SemanticIndex = 0,
                .Format = .R32G32B32A32_FLOAT,
                .InputSlot = 0,
                .AlignedByteOffset = 0,
                .InputSlotClass = .PER_INSTANCE_DATA,
                .InstanceDataStepRate = 1,
            },
            .{
                .SemanticName = "FG_COLOR",
                .SemanticIndex = 0,
                .Format = .R32G32B32A32_FLOAT,
                .InputSlot = 0,
                .AlignedByteOffset = 16,
                .InputSlotClass = .PER_INSTANCE_DATA,
                .InstanceDataStepRate = 1,
            },
            .{
                .SemanticName = "GLYPH_INDEX",
                .SemanticIndex = 0,
                .Format = .R32_UINT,
                .InputSlot = 0,
                .AlignedByteOffset = 32,
                .InputSlotClass = .PER_INSTANCE_DATA,
                .InstanceDataStepRate = 1,
            },
        };

        var layout: ?*d3d11.ID3D11InputLayout = null;
        hr = device.CreateInputLayout(
            &input_elements,
            input_elements.len,
            vs_bytecode.ptr,
            vs_bytecode.len,
            &layout,
        );
        if (com.FAILED(hr) or layout == null) {
            log.err("CreateInputLayout failed: hr=0x{x}", .{@as(u32, @bitCast(hr))});
            _ = ps.?.vtable.Release(ps.?);
            _ = vs.?.vtable.Release(vs.?);
            return InitError.InputLayoutFailed;
        }

        // Create constant buffer for per-frame uniforms.
        const cb_desc = d3d11.D3D11_BUFFER_DESC{
            .ByteWidth = @sizeOf(Constants),
            .Usage = .DYNAMIC,
            .BindFlags = d3d11.D3D11_BIND_CONSTANT_BUFFER,
            .CPUAccessFlags = d3d11.D3D11_CPU_ACCESS_WRITE,
            .MiscFlags = 0,
            .StructureByteStride = 0,
        };

        var cb: ?*d3d11.ID3D11Buffer = null;
        hr = device.CreateBuffer(&cb_desc, null, &cb);
        if (com.FAILED(hr) or cb == null) {
            log.err("CreateBuffer (constant) failed: hr=0x{x}", .{@as(u32, @bitCast(hr))});
            _ = layout.?.vtable.Release(layout.?);
            _ = ps.?.vtable.Release(ps.?);
            _ = vs.?.vtable.Release(vs.?);
            return InitError.ConstantBufferFailed;
        }

        return Pipeline{
            .vertex_shader = vs.?,
            .pixel_shader = ps.?,
            .input_layout = layout.?,
            .constant_buffer = cb.?,
        };
    }

    pub fn deinit(self: *Pipeline) void {
        _ = self.constant_buffer.Release();
        _ = self.input_layout.Release();
        _ = self.pixel_shader.Release();
        _ = self.vertex_shader.Release();
    }

    /// Bind the pipeline state to the device context.
    pub fn bind(self: *Pipeline, ctx: *d3d11.ID3D11DeviceContext) void {
        ctx.IASetInputLayout(self.input_layout);
        ctx.IASetPrimitiveTopology(.TRIANGLELIST);
        ctx.VSSetShader(self.vertex_shader);
        ctx.PSSetShader(self.pixel_shader);
        ctx.VSSetConstantBuffers(0, &.{self.constant_buffer});
    }

    /// Update the constant buffer with new uniform values.
    pub fn updateConstants(self: *Pipeline, ctx: *d3d11.ID3D11DeviceContext, constants: Constants) void {
        var mapped: d3d11.D3D11_MAPPED_SUBRESOURCE = .{ .pData = null, .RowPitch = 0, .DepthPitch = 0 };
        const hr = ctx.Map(
            @ptrCast(self.constant_buffer),
            0,
            .WRITE_DISCARD,
            0,
            &mapped,
        );
        if (com.FAILED(hr) or mapped.pData == null) {
            log.err("Map constant buffer failed: hr=0x{x}", .{@as(u32, @bitCast(hr))});
            return;
        }

        const dest: *Constants = @ptrCast(@alignCast(mapped.pData.?));
        dest.* = constants;

        ctx.Unmap(@ptrCast(self.constant_buffer), 0);
    }
};
