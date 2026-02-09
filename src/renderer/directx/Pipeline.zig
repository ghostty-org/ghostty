//! Render pipeline for Direct3D 11.
//!
//! Wraps compiled vertex/pixel shaders, input layout, and blend state.
const Self = @This();

const std = @import("std");
const d3d11 = @import("d3d11.zig");

const log = std.log.scoped(.directx);

pub const Options = struct {
    device: d3d11.ID3D11Device,
    vertex_fn: [:0]const u8,
    fragment_fn: [:0]const u8,
    step_fn: StepFunction = .per_vertex,
    blending_enabled: bool = true,
    /// Entry point name for the pixel shader. Default is "ps_main" for
    /// built-in shaders; custom (spirv-cross generated) shaders use "main".
    ps_entry: [*:0]const u8 = "ps_main",

    pub const StepFunction = enum {
        constant,
        per_vertex,
        per_instance,
    };
};

vertex_shader: ?d3d11.ID3D11VertexShader = null,
pixel_shader: ?d3d11.ID3D11PixelShader = null,
input_layout: ?d3d11.ID3D11InputLayout = null,
blend_state: ?d3d11.ID3D11BlendState = null,
stride: usize = 0,
blending_enabled: bool = true,

pub fn init(comptime VertexAttributes: ?type, opts: Options) !Self {
    var result = Self{
        .stride = if (VertexAttributes) |VA| @sizeOf(VA) else 0,
        .blending_enabled = opts.blending_enabled,
    };
    errdefer result.deinit();

    // Compile vertex shader
    var vs_blob: ?d3d11.ID3DBlob = null;
    var vs_errors: ?d3d11.ID3DBlob = null;
    var hr = d3d11.D3DCompile(
        opts.vertex_fn.ptr,
        opts.vertex_fn.len,
        "vertex",
        null,
        null,
        "vs_main",
        "vs_5_0",
        d3d11.D3DCOMPILE_ENABLE_STRICTNESS | if (std.debug.runtime_safety) d3d11.D3DCOMPILE_DEBUG else d3d11.D3DCOMPILE_OPTIMIZATION_LEVEL3,
        0,
        &vs_blob,
        &vs_errors,
    );

    if (d3d11.FAILED(hr)) {
        if (vs_errors) |errs| {
            if (errs.GetBufferPointer()) |ptr| {
                const msg_ptr: [*]const u8 = @ptrCast(ptr);
                const msg_len = errs.GetBufferSize();
                log.err("Vertex shader compile error: {s}", .{msg_ptr[0..msg_len]});
            } else {
                log.err("Vertex shader compile error: unknown", .{});
            }
            _ = errs.Release();
        }
        return error.DirectXFailed;
    }
    defer _ = vs_blob.?.Release();
    if (vs_errors) |errs| _ = errs.Release();

    // Create vertex shader
    const vs_code = vs_blob.?.GetBufferPointer() orelse return error.DirectXFailed;
    const vs_size = vs_blob.?.GetBufferSize();
    hr = opts.device.CreateVertexShader(vs_code, vs_size, null, &result.vertex_shader);
    if (d3d11.FAILED(hr)) {
        log.err("CreateVertexShader failed: hr=0x{x}", .{@as(u32, @bitCast(hr))});
        return error.DirectXFailed;
    }

    // Compile pixel shader
    var ps_blob: ?d3d11.ID3DBlob = null;
    var ps_errors: ?d3d11.ID3DBlob = null;
    hr = d3d11.D3DCompile(
        opts.fragment_fn.ptr,
        opts.fragment_fn.len,
        "pixel",
        null,
        null,
        opts.ps_entry,
        "ps_5_0",
        d3d11.D3DCOMPILE_ENABLE_STRICTNESS | if (std.debug.runtime_safety) d3d11.D3DCOMPILE_DEBUG else d3d11.D3DCOMPILE_OPTIMIZATION_LEVEL3,
        0,
        &ps_blob,
        &ps_errors,
    );

    if (d3d11.FAILED(hr)) {
        if (ps_errors) |errs| {
            if (errs.GetBufferPointer()) |ptr| {
                const msg_ptr: [*]const u8 = @ptrCast(ptr);
                const msg_len = errs.GetBufferSize();
                log.err("Pixel shader compile error: {s}", .{msg_ptr[0..msg_len]});
            } else {
                log.err("Pixel shader compile error: unknown", .{});
            }
            _ = errs.Release();
        }
        return error.DirectXFailed;
    }
    defer _ = ps_blob.?.Release();
    if (ps_errors) |errs| _ = errs.Release();

    // Create pixel shader
    const ps_code = ps_blob.?.GetBufferPointer() orelse return error.DirectXFailed;
    const ps_size = ps_blob.?.GetBufferSize();
    hr = opts.device.CreatePixelShader(ps_code, ps_size, null, &result.pixel_shader);
    if (d3d11.FAILED(hr)) {
        log.err("CreatePixelShader failed: hr=0x{x}", .{@as(u32, @bitCast(hr))});
        return error.DirectXFailed;
    }

    // Create input layout from vertex attributes (if any)
    if (VertexAttributes) |VA| {
        var descs = comptime buildInputElementDescs(VA);
        const input_class: d3d11.D3D11_INPUT_CLASSIFICATION = switch (opts.step_fn) {
            .per_instance => .PER_INSTANCE_DATA,
            else => .PER_VERTEX_DATA,
        };
        const step_rate: u32 = switch (opts.step_fn) {
            .per_instance => 1,
            else => 0,
        };
        for (&descs) |*desc| {
            desc.InputSlotClass = input_class;
            desc.InstanceDataStepRate = step_rate;
        }
        hr = opts.device.CreateInputLayout(
            &descs,
            descs.len,
            vs_code,
            vs_size,
            &result.input_layout,
        );
        if (d3d11.FAILED(hr)) {
            log.err("CreateInputLayout failed: hr=0x{x}", .{@as(u32, @bitCast(hr))});
            return error.DirectXFailed;
        }
    }

    // Create blend state
    if (opts.blending_enabled) {
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
        hr = opts.device.CreateBlendState(&blend_desc, &result.blend_state);
        if (d3d11.FAILED(hr)) {
            log.err("CreateBlendState failed: hr=0x{x}", .{@as(u32, @bitCast(hr))});
            return error.DirectXFailed;
        }
    }

    return result;
}

pub fn deinit(self: *const Self) void {
    if (self.blend_state) |bs| _ = bs.Release();
    if (self.input_layout) |il| _ = il.Release();
    if (self.pixel_shader) |ps| _ = ps.Release();
    if (self.vertex_shader) |vs| _ = vs.Release();
}

/// Build D3D11_INPUT_ELEMENT_DESC array from a Zig struct at comptime.
/// InputSlotClass and InstanceDataStepRate are set to defaults; caller patches them at runtime.
fn buildInputElementDescs(
    comptime T: type,
) [std.meta.fields(T).len]d3d11.D3D11_INPUT_ELEMENT_DESC {
    const fields = std.meta.fields(T);
    var descs: [fields.len]d3d11.D3D11_INPUT_ELEMENT_DESC = undefined;

    for (fields, 0..) |field, i| {
        descs[i] = .{
            .SemanticName = fieldToSemantic(field.name),
            .SemanticIndex = 0,
            .Format = fieldToFormat(field.type),
            .InputSlot = 0,
            .AlignedByteOffset = @intCast(@offsetOf(T, field.name)),
            .InputSlotClass = .PER_VERTEX_DATA,
            .InstanceDataStepRate = 0,
        };
    }

    return descs;
}

/// Map a Zig struct field name to an HLSL semantic name.
fn fieldToSemantic(comptime name: []const u8) d3d11.LPCSTR {
    const map = .{
        .{ "glyph_pos", "GLYPH_POS" },
        .{ "glyph_size", "GLYPH_SIZE" },
        .{ "bearings", "BEARINGS" },
        .{ "grid_pos", "GRID_POS" },
        .{ "color", "COLOR" },
        .{ "atlas", "ATLAS" },
        .{ "bools", "GLYPH_BOOLS" },
        .{ "cell_offset", "CELL_OFFSET" },
        .{ "source_rect", "SOURCE_RECT" },
        .{ "dest_size", "DEST_SIZE" },
        .{ "opacity", "OPACITY" },
        .{ "info", "INFO" },
    };

    inline for (map) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }

    @compileError("Unknown vertex attribute field: " ++ name);
}

/// Map a Zig type to a DXGI_FORMAT.
fn fieldToFormat(comptime T: type) d3d11.DXGI_FORMAT {
    if (T == [2]u32) return .R32G32_UINT;
    if (T == [2]i16) return .R16G16_SINT;
    if (T == [2]u16) return .R16G16_UINT;
    if (T == [4]u8) return .R8G8B8A8_UINT;
    if (T == [2]f32) return .R32G32_FLOAT;
    if (T == [4]f32) return .R32G32B32A32_FLOAT;
    if (T == f32) return .R32_FLOAT;
    // Enum(u8) and packed struct(u8) both have @sizeOf == 1
    if (@sizeOf(T) == 1) return .R8_UINT;
    @compileError("Unsupported vertex attribute type: " ++ @typeName(T));
}
