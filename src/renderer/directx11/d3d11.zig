const std = @import("std");
const com = @import("com.zig");
const dxgi = @import("dxgi.zig");
const GUID = com.GUID;
const HRESULT = com.HRESULT;
const IUnknown = com.IUnknown;
const DXGI_FORMAT = dxgi.DXGI_FORMAT;

const Reserved = com.Reserved;

// --- Enums ---

pub const D3D_FEATURE_LEVEL = enum(u32) {
    @"9_1" = 0x9100,
    @"9_2" = 0x9200,
    @"9_3" = 0x9300,
    @"10_0" = 0xa000,
    @"10_1" = 0xa100,
    @"11_0" = 0xb000,
    @"11_1" = 0xb100,
    _,
};

pub const D3D_DRIVER_TYPE = enum(u32) {
    UNKNOWN = 0,
    HARDWARE = 1,
    REFERENCE = 2,
    NULL = 3,
    SOFTWARE = 4,
    WARP = 5,
};

pub const D3D11_USAGE = enum(u32) {
    DEFAULT = 0,
    IMMUTABLE = 1,
    DYNAMIC = 2,
    STAGING = 3,
};

pub const D3D11_BIND_FLAG = u32;
pub const D3D11_BIND_VERTEX_BUFFER: D3D11_BIND_FLAG = 0x1;
pub const D3D11_BIND_INDEX_BUFFER: D3D11_BIND_FLAG = 0x2;
pub const D3D11_BIND_CONSTANT_BUFFER: D3D11_BIND_FLAG = 0x4;
pub const D3D11_BIND_SHADER_RESOURCE: D3D11_BIND_FLAG = 0x8;
pub const D3D11_BIND_RENDER_TARGET: D3D11_BIND_FLAG = 0x20;

pub const D3D11_CPU_ACCESS_FLAG = u32;
pub const D3D11_CPU_ACCESS_WRITE: D3D11_CPU_ACCESS_FLAG = 0x10000;
pub const D3D11_CPU_ACCESS_READ: D3D11_CPU_ACCESS_FLAG = 0x20000;

pub const D3D11_MAP = enum(u32) {
    READ = 1,
    WRITE = 2,
    READ_WRITE = 3,
    WRITE_DISCARD = 4,
    WRITE_NO_OVERWRITE = 5,
};

pub const D3D_PRIMITIVE_TOPOLOGY = enum(u32) {
    UNDEFINED = 0,
    POINTLIST = 1,
    LINELIST = 2,
    LINESTRIP = 3,
    TRIANGLELIST = 4,
    TRIANGLESTRIP = 5,
    _,
};

pub const D3D11_CREATE_DEVICE_FLAG = u32;
pub const D3D11_CREATE_DEVICE_SINGLETHREADED: D3D11_CREATE_DEVICE_FLAG = 0x1;
pub const D3D11_CREATE_DEVICE_DEBUG: D3D11_CREATE_DEVICE_FLAG = 0x2;
pub const D3D11_CREATE_DEVICE_BGRA_SUPPORT: D3D11_CREATE_DEVICE_FLAG = 0x20;

pub const D3D11_INPUT_CLASSIFICATION = enum(u32) {
    PER_VERTEX_DATA = 0,
    PER_INSTANCE_DATA = 1,
};

// --- Structs ---

pub const D3D11_VIEWPORT = extern struct {
    TopLeftX: f32,
    TopLeftY: f32,
    Width: f32,
    Height: f32,
    MinDepth: f32,
    MaxDepth: f32,
};

pub const D3D11_BUFFER_DESC = extern struct {
    ByteWidth: u32,
    Usage: D3D11_USAGE,
    BindFlags: D3D11_BIND_FLAG,
    CPUAccessFlags: D3D11_CPU_ACCESS_FLAG,
    MiscFlags: u32,
    StructureByteStride: u32,
};

pub const D3D11_SUBRESOURCE_DATA = extern struct {
    pSysMem: *const anyopaque,
    SysMemPitch: u32,
    SysMemSlicePitch: u32,
};

pub const D3D11_INPUT_ELEMENT_DESC = extern struct {
    SemanticName: [*:0]const u8,
    SemanticIndex: u32,
    Format: DXGI_FORMAT,
    InputSlot: u32,
    AlignedByteOffset: u32,
    InputSlotClass: D3D11_INPUT_CLASSIFICATION,
    InstanceDataStepRate: u32,
};

pub const D3D11_MAPPED_SUBRESOURCE = extern struct {
    pData: ?*anyopaque,
    RowPitch: u32,
    DepthPitch: u32,
};

// =============================================================================
// ID3D11DeviceChild — 7 methods total (3 IUnknown + 4 own)
// =============================================================================
pub const ID3D11DeviceChild = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (slots 0-2)
        QueryInterface: Reserved,
        AddRef: Reserved,
        Release: Reserved,
        // ID3D11DeviceChild (slots 3-6)
        GetDevice: Reserved,
        GetPrivateData: Reserved,
        SetPrivateData: Reserved,
        SetPrivateDataInterface: Reserved,
    };
};

// =============================================================================
// ID3D11Resource — 10 methods total (7 ID3D11DeviceChild + 3 own)
// =============================================================================
pub const ID3D11Resource = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (slots 0-2)
        QueryInterface: Reserved,
        AddRef: Reserved,
        Release: Reserved,
        // ID3D11DeviceChild (slots 3-6)
        GetDevice: Reserved,
        GetPrivateData: Reserved,
        SetPrivateData: Reserved,
        SetPrivateDataInterface: Reserved,
        // ID3D11Resource (slot 7)
        GetType: Reserved,
        SetEvictionPriority: Reserved,
        GetEvictionPriority: Reserved,
    };
};

// =============================================================================
// ID3D11View — 8 methods total (7 ID3D11DeviceChild + 1 own)
// =============================================================================
pub const ID3D11View = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (slots 0-2)
        QueryInterface: Reserved,
        AddRef: Reserved,
        Release: Reserved,
        // ID3D11DeviceChild (slots 3-6)
        GetDevice: Reserved,
        GetPrivateData: Reserved,
        SetPrivateData: Reserved,
        SetPrivateDataInterface: Reserved,
        // ID3D11View (slot 7)
        GetResource: Reserved,
    };
};

// =============================================================================
// ID3D11RenderTargetView — 9 methods total (8 ID3D11View + 1 own)
// Inherits: IUnknown(3) + ID3D11DeviceChild(4) + ID3D11View(1) + own(1)
// =============================================================================
pub const ID3D11RenderTargetView = extern struct {
    vtable: *const VTable,

    pub const IID = GUID{
        .data1 = 0xdfdba067,
        .data2 = 0x0b8d,
        .data3 = 0x4865,
        .data4 = .{ 0x87, 0x5b, 0xd7, 0xb4, 0x51, 0x6c, 0xc1, 0x64 },
    };

    pub const VTable = extern struct {
        // IUnknown (slots 0-2)
        QueryInterface: *const fn (*ID3D11RenderTargetView, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ID3D11RenderTargetView) callconv(.winapi) u32,
        Release: *const fn (*ID3D11RenderTargetView) callconv(.winapi) u32,
        // ID3D11DeviceChild (slots 3-6)
        GetDevice: Reserved,
        GetPrivateData: Reserved,
        SetPrivateData: Reserved,
        SetPrivateDataInterface: Reserved,
        // ID3D11View (slot 7)
        GetResource: Reserved,
        // ID3D11RenderTargetView (slot 8)
        GetDesc: Reserved,
    };

    pub inline fn Release(self: *ID3D11RenderTargetView) u32 {
        return self.vtable.Release(self);
    }
};

// =============================================================================
// ID3D11Texture2D — 11 methods total
// Inherits: IUnknown(3) + ID3D11DeviceChild(4) + ID3D11Resource(3) + own(1)
// =============================================================================
pub const ID3D11Texture2D = extern struct {
    vtable: *const VTable,

    pub const IID = GUID{
        .data1 = 0x6f15aaf2,
        .data2 = 0xd208,
        .data3 = 0x4e89,
        .data4 = .{ 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c },
    };

    pub const VTable = extern struct {
        // IUnknown (slots 0-2)
        QueryInterface: *const fn (*ID3D11Texture2D, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ID3D11Texture2D) callconv(.winapi) u32,
        Release: *const fn (*ID3D11Texture2D) callconv(.winapi) u32,
        // ID3D11DeviceChild (slots 3-6)
        GetDevice: Reserved,
        GetPrivateData: Reserved,
        SetPrivateData: Reserved,
        SetPrivateDataInterface: Reserved,
        // ID3D11Resource (slots 7-9)
        GetType: Reserved,
        SetEvictionPriority: Reserved,
        GetEvictionPriority: Reserved,
        // ID3D11Texture2D (slot 10)
        GetDesc: Reserved,
    };

    pub inline fn Release(self: *ID3D11Texture2D) u32 {
        return self.vtable.Release(self);
    }
};

// =============================================================================
// ID3D11Buffer — 11 methods total
// Inherits: IUnknown(3) + ID3D11DeviceChild(4) + ID3D11Resource(3) + own(1)
// =============================================================================
pub const ID3D11Buffer = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (slots 0-2)
        QueryInterface: *const fn (*ID3D11Buffer, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ID3D11Buffer) callconv(.winapi) u32,
        Release: *const fn (*ID3D11Buffer) callconv(.winapi) u32,
        // ID3D11DeviceChild (slots 3-6)
        GetDevice: Reserved,
        GetPrivateData: Reserved,
        SetPrivateData: Reserved,
        SetPrivateDataInterface: Reserved,
        // ID3D11Resource (slots 7-9)
        GetType: Reserved,
        SetEvictionPriority: Reserved,
        GetEvictionPriority: Reserved,
        // ID3D11Buffer (slot 10)
        GetDesc: Reserved,
    };

    pub inline fn Release(self: *ID3D11Buffer) u32 {
        return self.vtable.Release(self);
    }
};

// =============================================================================
// Simple ID3D11DeviceChild derivatives — 7 methods each (no own methods)
// ID3D11VertexShader, ID3D11PixelShader, ID3D11InputLayout, ID3D11SamplerState
// =============================================================================
pub const ID3D11VertexShader = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*ID3D11VertexShader, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ID3D11VertexShader) callconv(.winapi) u32,
        Release: *const fn (*ID3D11VertexShader) callconv(.winapi) u32,
        GetDevice: Reserved,
        GetPrivateData: Reserved,
        SetPrivateData: Reserved,
        SetPrivateDataInterface: Reserved,
    };

    pub inline fn Release(self: *ID3D11VertexShader) u32 {
        return self.vtable.Release(self);
    }
};

pub const ID3D11PixelShader = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*ID3D11PixelShader, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ID3D11PixelShader) callconv(.winapi) u32,
        Release: *const fn (*ID3D11PixelShader) callconv(.winapi) u32,
        GetDevice: Reserved,
        GetPrivateData: Reserved,
        SetPrivateData: Reserved,
        SetPrivateDataInterface: Reserved,
    };

    pub inline fn Release(self: *ID3D11PixelShader) u32 {
        return self.vtable.Release(self);
    }
};

pub const ID3D11InputLayout = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*ID3D11InputLayout, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ID3D11InputLayout) callconv(.winapi) u32,
        Release: *const fn (*ID3D11InputLayout) callconv(.winapi) u32,
        GetDevice: Reserved,
        GetPrivateData: Reserved,
        SetPrivateData: Reserved,
        SetPrivateDataInterface: Reserved,
    };

    pub inline fn Release(self: *ID3D11InputLayout) u32 {
        return self.vtable.Release(self);
    }
};

pub const ID3D11SamplerState = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*ID3D11SamplerState, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ID3D11SamplerState) callconv(.winapi) u32,
        Release: *const fn (*ID3D11SamplerState) callconv(.winapi) u32,
        GetDevice: Reserved,
        GetPrivateData: Reserved,
        SetPrivateData: Reserved,
        SetPrivateDataInterface: Reserved,
        // ID3D11SamplerState (slot 7)
        GetDesc: Reserved,
    };

    pub inline fn Release(self: *ID3D11SamplerState) u32 {
        return self.vtable.Release(self);
    }
};

pub const ID3D11ShaderResourceView = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*ID3D11ShaderResourceView, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ID3D11ShaderResourceView) callconv(.winapi) u32,
        Release: *const fn (*ID3D11ShaderResourceView) callconv(.winapi) u32,
        GetDevice: Reserved,
        GetPrivateData: Reserved,
        SetPrivateData: Reserved,
        SetPrivateDataInterface: Reserved,
        // ID3D11View (slot 7)
        GetResource: Reserved,
        // ID3D11ShaderResourceView (slot 8)
        GetDesc: Reserved,
    };

    pub inline fn Release(self: *ID3D11ShaderResourceView) u32 {
        return self.vtable.Release(self);
    }
};

// =============================================================================
// ID3D11Device — 43 methods total (3 IUnknown + 40 own)
// Vtable order from d3d11.h:
//   0: QueryInterface
//   1: AddRef
//   2: Release
//   3: CreateBuffer
//   4: CreateTexture1D
//   5: CreateTexture2D
//   6: CreateTexture3D
//   7: CreateShaderResourceView
//   8: CreateUnorderedAccessView
//   9: CreateRenderTargetView
//  10: CreateDepthStencilView
//  11: CreateInputLayout
//  12: CreateVertexShader
//  13: CreateGeometryShader
//  14: CreateGeometryShaderWithStreamOutput
//  15: CreatePixelShader
//  16: CreateHullShader
//  17: CreateDomainShader
//  18: CreateComputeShader
//  19: CreateClassLinkage
//  20: CreateBlendState
//  21: CreateDepthStencilState
//  22: CreateRasterizerState
//  23: CreateSamplerState
//  24: CreateQuery
//  25: CreatePredicate
//  26: CreateCounter
//  27: CreateDeferredContext
//  28: OpenSharedResource
//  29: CheckFormatSupport
//  30: CheckMultisampleQualityLevels
//  31: CheckCounterInfo
//  32: CheckCounter
//  33: CheckFeatureSupport
//  34: GetPrivateData
//  35: SetPrivateData
//  36: SetPrivateDataInterface
//  37: GetFeatureLevel
//  38: GetCreationFlags
//  39: GetDeviceRemovedReason
//  40: GetImmediateContext
//  41: SetExceptionMode
//  42: GetExceptionMode
// =============================================================================
pub const ID3D11Device = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (slots 0-2)
        QueryInterface: *const fn (*ID3D11Device, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ID3D11Device) callconv(.winapi) u32,
        Release: *const fn (*ID3D11Device) callconv(.winapi) u32,
        // slot 3: CreateBuffer
        CreateBuffer: *const fn (
            *ID3D11Device,
            *const D3D11_BUFFER_DESC,
            ?*const D3D11_SUBRESOURCE_DATA,
            *?*ID3D11Buffer,
        ) callconv(.winapi) HRESULT,
        // slots 4-6
        CreateTexture1D: Reserved,
        CreateTexture2D: Reserved,
        CreateTexture3D: Reserved,
        // slot 7
        CreateShaderResourceView: Reserved,
        // slot 8
        CreateUnorderedAccessView: Reserved,
        // slot 9: CreateRenderTargetView
        CreateRenderTargetView: *const fn (
            *ID3D11Device,
            *ID3D11Resource,
            ?*const anyopaque, // D3D11_RENDER_TARGET_VIEW_DESC, nullable for default
            *?*ID3D11RenderTargetView,
        ) callconv(.winapi) HRESULT,
        // slot 10
        CreateDepthStencilView: Reserved,
        // slot 11: CreateInputLayout
        CreateInputLayout: *const fn (
            *ID3D11Device,
            [*]const D3D11_INPUT_ELEMENT_DESC,
            u32, // NumElements
            *const anyopaque, // pShaderBytecodeWithInputSignature
            usize, // BytecodeLength
            *?*ID3D11InputLayout,
        ) callconv(.winapi) HRESULT,
        // slot 12: CreateVertexShader
        CreateVertexShader: *const fn (
            *ID3D11Device,
            *const anyopaque, // pShaderBytecode
            usize, // BytecodeLength
            ?*ID3D11ClassLinkage,
            *?*ID3D11VertexShader,
        ) callconv(.winapi) HRESULT,
        // slot 13
        CreateGeometryShader: Reserved,
        // slot 14
        CreateGeometryShaderWithStreamOutput: Reserved,
        // slot 15: CreatePixelShader
        CreatePixelShader: *const fn (
            *ID3D11Device,
            *const anyopaque, // pShaderBytecode
            usize, // BytecodeLength
            ?*ID3D11ClassLinkage,
            *?*ID3D11PixelShader,
        ) callconv(.winapi) HRESULT,
        // slots 16-18
        CreateHullShader: Reserved,
        CreateDomainShader: Reserved,
        CreateComputeShader: Reserved,
        // slot 19
        CreateClassLinkage: Reserved,
        // slots 20-22
        CreateBlendState: Reserved,
        CreateDepthStencilState: Reserved,
        CreateRasterizerState: Reserved,
        // slot 23
        CreateSamplerState: Reserved,
        // slots 24-26
        CreateQuery: Reserved,
        CreatePredicate: Reserved,
        CreateCounter: Reserved,
        // slots 27-28
        CreateDeferredContext: Reserved,
        OpenSharedResource: Reserved,
        // slots 29-33
        CheckFormatSupport: Reserved,
        CheckMultisampleQualityLevels: Reserved,
        CheckCounterInfo: Reserved,
        CheckCounter: Reserved,
        CheckFeatureSupport: Reserved,
        // slots 34-36
        GetPrivateData: Reserved,
        SetPrivateData: Reserved,
        SetPrivateDataInterface: Reserved,
        // slot 37
        GetFeatureLevel: Reserved,
        // slot 38
        GetCreationFlags: Reserved,
        // slot 39
        GetDeviceRemovedReason: Reserved,
        // slot 40
        GetImmediateContext: Reserved,
        // slot 41
        SetExceptionMode: Reserved,
        // slot 42
        GetExceptionMode: Reserved,
    };

    pub inline fn CreateBuffer(
        self: *ID3D11Device,
        desc: *const D3D11_BUFFER_DESC,
        initial_data: ?*const D3D11_SUBRESOURCE_DATA,
        buffer: *?*ID3D11Buffer,
    ) HRESULT {
        return self.vtable.CreateBuffer(self, desc, initial_data, buffer);
    }

    pub inline fn CreateRenderTargetView(
        self: *ID3D11Device,
        resource: *ID3D11Resource,
        desc: ?*const anyopaque,
        rtv: *?*ID3D11RenderTargetView,
    ) HRESULT {
        return self.vtable.CreateRenderTargetView(self, resource, desc, rtv);
    }

    pub inline fn CreateInputLayout(
        self: *ID3D11Device,
        input_element_descs: [*]const D3D11_INPUT_ELEMENT_DESC,
        num_elements: u32,
        shader_bytecode: *const anyopaque,
        bytecode_length: usize,
        input_layout: *?*ID3D11InputLayout,
    ) HRESULT {
        return self.vtable.CreateInputLayout(self, input_element_descs, num_elements, shader_bytecode, bytecode_length, input_layout);
    }

    pub inline fn CreateVertexShader(
        self: *ID3D11Device,
        shader_bytecode: *const anyopaque,
        bytecode_length: usize,
        class_linkage: ?*ID3D11ClassLinkage,
        vertex_shader: *?*ID3D11VertexShader,
    ) HRESULT {
        return self.vtable.CreateVertexShader(self, shader_bytecode, bytecode_length, class_linkage, vertex_shader);
    }

    pub inline fn CreatePixelShader(
        self: *ID3D11Device,
        shader_bytecode: *const anyopaque,
        bytecode_length: usize,
        class_linkage: ?*ID3D11ClassLinkage,
        pixel_shader: *?*ID3D11PixelShader,
    ) HRESULT {
        return self.vtable.CreatePixelShader(self, shader_bytecode, bytecode_length, class_linkage, pixel_shader);
    }

    pub inline fn QueryInterface(self: *ID3D11Device, riid: *const GUID, ppvObject: *?*anyopaque) HRESULT {
        return self.vtable.QueryInterface(self, riid, ppvObject);
    }

    pub inline fn Release(self: *ID3D11Device) u32 {
        return self.vtable.Release(self);
    }
};

/// Opaque type — we never call methods on this, only pass null.
pub const ID3D11ClassLinkage = opaque {};

// =============================================================================
// ID3D11DeviceContext — 115 methods total
// Inherits: IUnknown(3) + ID3D11DeviceChild(4) = 7 inherited, 108 own
// Vtable order from d3d11.h (verified against d3d11_c.h):
//   0: QueryInterface          56: GetResourceMinLOD
//   1: AddRef                  57: ResolveSubresource
//   2: Release                 58: ExecuteCommandList
//   3: GetDevice               59: HSSetShaderResources
//   4: GetPrivateData          60: HSSetShader
//   5: SetPrivateData          61: HSSetSamplers
//   6: SetPrivateDataInterface 62: HSSetConstantBuffers
//   7: VSSetConstantBuffers    63: DSSetShaderResources
//   8: PSSetShaderResources    64: DSSetShader
//   9: PSSetShader             65: DSSetSamplers
//  10: PSSetSamplers           66: DSSetConstantBuffers
//  11: VSSetShader             67: CSSetShaderResources
//  12: DrawIndexed             68: CSSetUnorderedAccessViews
//  13: Draw                    69: CSSetShader
//  14: Map                     70: CSSetSamplers
//  15: Unmap                   71: CSSetConstantBuffers
//  16: PSSetConstantBuffers    72: VSGetConstantBuffers
//  17: IASetInputLayout        73: PSGetShaderResources
//  18: IASetVertexBuffers      74: PSGetShader
//  19: IASetIndexBuffer        75: PSGetSamplers
//  20: DrawIndexedInstanced    76: VSGetShader
//  21: DrawInstanced           77: PSGetConstantBuffers
//  22: GSSetConstantBuffers    78: IAGetInputLayout
//  23: GSSetShader             79: IAGetVertexBuffers
//  24: IASetPrimitiveTopology  80: IAGetIndexBuffer
//  25: VSSetShaderResources    81: GSGetConstantBuffers
//  26: VSSetSamplers           82: GSGetShader
//  27: Begin                   83: IAGetPrimitiveTopology
//  28: End                     84: VSGetShaderResources
//  29: GetData                 85: VSGetSamplers
//  30: SetPredication          86: GetPredication
//  31: GSSetShaderResources    87: GSGetShaderResources
//  32: GSSetSamplers           88: GSGetSamplers
//  33: OMSetRenderTargets      89: OMGetRenderTargets
//  34: OMSetRenderTargetsAndUAV 90: OMGetRenderTargetsAndUAV
//  35: OMSetBlendState         91: OMGetBlendState
//  36: OMSetDepthStencilState  92: OMGetDepthStencilState
//  37: SOSetTargets            93: SOGetTargets
//  38: DrawAuto                94: RSGetState
//  39: DrawIndexedInstIndirect 95: RSGetViewports
//  40: DrawInstancedIndirect   96: RSGetScissorRects
//  41: Dispatch                97: HSGetShaderResources
//  42: DispatchIndirect        98: HSGetShader
//  43: RSSetState              99: HSGetSamplers
//  44: RSSetViewports         100: HSGetConstantBuffers
//  45: RSSetScissorRects      101: DSGetShaderResources
//  46: CopySubresourceRegion  102: DSGetShader
//  47: CopyResource           103: DSGetSamplers
//  48: UpdateSubresource      104: DSGetConstantBuffers
//  49: CopyStructureCount     105: CSGetShaderResources
//  50: ClearRenderTargetView  106: CSGetUnorderedAccessViews
//  51: ClearUAVUint           107: CSGetShader
//  52: ClearUAVFloat          108: CSGetSamplers
//  53: ClearDepthStencilView  109: CSGetConstantBuffers
//  54: GenerateMips           110: ClearState
//  55: SetResourceMinLOD      111: Flush
//                             112: GetType
//                             113: GetContextFlags
//                             114: FinishCommandList
// =============================================================================
pub const ID3D11DeviceContext = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (slots 0-2)
        QueryInterface: *const fn (*ID3D11DeviceContext, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ID3D11DeviceContext) callconv(.winapi) u32,
        Release: *const fn (*ID3D11DeviceContext) callconv(.winapi) u32,
        // ID3D11DeviceChild (slots 3-6)
        GetDevice: Reserved,
        GetPrivateData: Reserved,
        SetPrivateData: Reserved,
        SetPrivateDataInterface: Reserved,
        // slot 7: VSSetConstantBuffers
        VSSetConstantBuffers: *const fn (
            *ID3D11DeviceContext,
            StartSlot: u32,
            NumBuffers: u32,
            ppConstantBuffers: [*]const ?*ID3D11Buffer,
        ) callconv(.winapi) void,
        // slot 8: PSSetShaderResources
        PSSetShaderResources: *const fn (
            *ID3D11DeviceContext,
            StartSlot: u32,
            NumViews: u32,
            ppShaderResourceViews: [*]const ?*ID3D11ShaderResourceView,
        ) callconv(.winapi) void,
        // slot 9: PSSetShader
        PSSetShader: *const fn (
            *ID3D11DeviceContext,
            ?*ID3D11PixelShader,
            ?[*]const ?*ID3D11ClassInstance,
            u32, // NumClassInstances
        ) callconv(.winapi) void,
        // slot 10: PSSetSamplers
        PSSetSamplers: *const fn (
            *ID3D11DeviceContext,
            StartSlot: u32,
            NumSamplers: u32,
            ppSamplers: [*]const ?*ID3D11SamplerState,
        ) callconv(.winapi) void,
        // slot 11: VSSetShader
        VSSetShader: *const fn (
            *ID3D11DeviceContext,
            ?*ID3D11VertexShader,
            ?[*]const ?*ID3D11ClassInstance,
            u32, // NumClassInstances
        ) callconv(.winapi) void,
        // slot 12: DrawIndexed
        DrawIndexed: Reserved,
        // slot 13: Draw
        Draw: Reserved,
        // slot 14: Map
        Map: *const fn (
            *ID3D11DeviceContext,
            *ID3D11Resource,
            u32, // Subresource
            D3D11_MAP,
            u32, // MapFlags
            *D3D11_MAPPED_SUBRESOURCE,
        ) callconv(.winapi) HRESULT,
        // slot 15: Unmap
        Unmap: *const fn (
            *ID3D11DeviceContext,
            *ID3D11Resource,
            u32, // Subresource
        ) callconv(.winapi) void,
        // slot 16: PSSetConstantBuffers
        _reserved16: Reserved,
        // slot 17: IASetInputLayout
        IASetInputLayout: *const fn (
            *ID3D11DeviceContext,
            ?*ID3D11InputLayout,
        ) callconv(.winapi) void,
        // slot 18: IASetVertexBuffers
        IASetVertexBuffers: *const fn (
            *ID3D11DeviceContext,
            StartSlot: u32,
            NumBuffers: u32,
            ppVertexBuffers: [*]const ?*ID3D11Buffer,
            pStrides: [*]const u32,
            pOffsets: [*]const u32,
        ) callconv(.winapi) void,
        // slot 19: IASetIndexBuffer
        _reserved19: Reserved,
        // slot 20: DrawIndexedInstanced
        _reserved20: Reserved,
        // slot 21: DrawInstanced
        DrawInstanced: *const fn (
            *ID3D11DeviceContext,
            VertexCountPerInstance: u32,
            InstanceCount: u32,
            StartVertexLocation: u32,
            StartInstanceLocation: u32,
        ) callconv(.winapi) void,
        // slot 22: GSSetConstantBuffers
        _reserved22: Reserved,
        // slot 23: GSSetShader
        _reserved23: Reserved,
        // slot 24: IASetPrimitiveTopology
        IASetPrimitiveTopology: *const fn (
            *ID3D11DeviceContext,
            D3D_PRIMITIVE_TOPOLOGY,
        ) callconv(.winapi) void,
        // slot 25: VSSetShaderResources
        _reserved25: Reserved,
        // slot 26: VSSetSamplers
        _reserved26: Reserved,
        // slot 27: Begin
        _reserved27: Reserved,
        // slot 28: End
        _reserved28: Reserved,
        // slot 29: GetData
        _reserved29: Reserved,
        // slot 30: SetPredication
        _reserved30: Reserved,
        // slot 31: GSSetShaderResources
        _reserved31: Reserved,
        // slot 32: GSSetSamplers
        _reserved32: Reserved,
        // slot 33: OMSetRenderTargets
        OMSetRenderTargets: *const fn (
            *ID3D11DeviceContext,
            NumViews: u32,
            ppRenderTargetViews: ?[*]const ?*ID3D11RenderTargetView,
            pDepthStencilView: ?*anyopaque, // ID3D11DepthStencilView
        ) callconv(.winapi) void,
        // slot 34: OMSetRenderTargetsAndUnorderedAccessViews
        _reserved34: Reserved,
        // slot 35: OMSetBlendState
        _reserved35: Reserved,
        // slot 36: OMSetDepthStencilState
        _reserved36: Reserved,
        // slot 37: SOSetTargets
        _reserved37: Reserved,
        // slot 38: DrawAuto
        _reserved38: Reserved,
        // slot 39: DrawIndexedInstancedIndirect
        _reserved39: Reserved,
        // slot 40: DrawInstancedIndirect
        _reserved40: Reserved,
        // slot 41: Dispatch
        _reserved41: Reserved,
        // slot 42: DispatchIndirect
        _reserved42: Reserved,
        // slot 43: RSSetState
        _reserved43: Reserved,
        // slot 44: RSSetViewports
        RSSetViewports: *const fn (
            *ID3D11DeviceContext,
            NumViewports: u32,
            pViewports: [*]const D3D11_VIEWPORT,
        ) callconv(.winapi) void,
        // slot 45: RSSetScissorRects
        _reserved45: Reserved,
        // slot 46: CopySubresourceRegion
        _reserved46: Reserved,
        // slot 47: CopyResource
        _reserved47: Reserved,
        // slot 48: UpdateSubresource
        _reserved48: Reserved,
        // slot 49: CopyStructureCount
        _reserved49: Reserved,
        // slot 50: ClearRenderTargetView
        ClearRenderTargetView: *const fn (
            *ID3D11DeviceContext,
            *ID3D11RenderTargetView,
            *const [4]f32,
        ) callconv(.winapi) void,
        // slot 51: ClearUnorderedAccessViewUint
        _reserved51: Reserved,
        // slot 52: ClearUnorderedAccessViewFloat
        _reserved52: Reserved,
        // slot 53: ClearDepthStencilView
        _reserved53: Reserved,
        // slot 54: GenerateMips
        _reserved54: Reserved,
        // slot 55: SetResourceMinLOD
        _reserved55: Reserved,
        // slot 56: GetResourceMinLOD
        _reserved56: Reserved,
        // slot 57: ResolveSubresource
        _reserved57: Reserved,
        // slot 58: ExecuteCommandList
        _reserved58: Reserved,
        // slot 59: HSSetShaderResources
        _reserved59: Reserved,
        // slot 60: HSSetShader
        _reserved60: Reserved,
        // slot 61: HSSetSamplers
        _reserved61: Reserved,
        // slot 62: HSSetConstantBuffers
        _reserved62: Reserved,
        // slot 63: DSSetShaderResources
        _reserved63: Reserved,
        // slot 64: DSSetShader
        _reserved64: Reserved,
        // slot 65: DSSetSamplers
        _reserved65: Reserved,
        // slot 66: DSSetConstantBuffers
        _reserved66: Reserved,
        // slot 67: CSSetShaderResources
        _reserved67: Reserved,
        // slot 68: CSSetUnorderedAccessViews
        _reserved68: Reserved,
        // slot 69: CSSetShader
        _reserved69: Reserved,
        // slot 70: CSSetSamplers
        _reserved70: Reserved,
        // slot 71: CSSetConstantBuffers
        _reserved71: Reserved,
        // slot 72: VSGetConstantBuffers
        _reserved72: Reserved,
        // slot 73: PSGetShaderResources
        _reserved73: Reserved,
        // slot 74: PSGetShader
        _reserved74: Reserved,
        // slot 75: PSGetSamplers
        _reserved75: Reserved,
        // slot 76: VSGetShader
        _reserved76: Reserved,
        // slot 77: PSGetConstantBuffers
        _reserved77: Reserved,
        // slot 78: IAGetInputLayout
        _reserved78: Reserved,
        // slot 79: IAGetVertexBuffers
        _reserved79: Reserved,
        // slot 80: IAGetIndexBuffer
        _reserved80: Reserved,
        // slot 81: GSGetConstantBuffers
        _reserved81: Reserved,
        // slot 82: GSGetShader
        _reserved82: Reserved,
        // slot 83: IAGetPrimitiveTopology
        _reserved83: Reserved,
        // slot 84: VSGetShaderResources
        _reserved84: Reserved,
        // slot 85: VSGetSamplers
        _reserved85: Reserved,
        // slot 86: GetPredication
        _reserved86: Reserved,
        // slot 87: GSGetShaderResources
        _reserved87: Reserved,
        // slot 88: GSGetSamplers
        _reserved88: Reserved,
        // slot 89: OMGetRenderTargets
        _reserved89: Reserved,
        // slot 90: OMGetRenderTargetsAndUnorderedAccessViews
        _reserved90: Reserved,
        // slot 91: OMGetBlendState
        _reserved91: Reserved,
        // slot 92: OMGetDepthStencilState
        _reserved92: Reserved,
        // slot 93: SOGetTargets
        _reserved93: Reserved,
        // slot 94: RSGetState
        _reserved94: Reserved,
        // slot 95: RSGetViewports
        _reserved95: Reserved,
        // slot 96: RSGetScissorRects
        _reserved96: Reserved,
        // slot 97: HSGetShaderResources
        _reserved97: Reserved,
        // slot 98: HSGetShader
        _reserved98: Reserved,
        // slot 99: HSGetSamplers
        _reserved99: Reserved,
        // slot 100: HSGetConstantBuffers
        _reserved100: Reserved,
        // slot 101: DSGetShaderResources
        _reserved101: Reserved,
        // slot 102: DSGetShader
        _reserved102: Reserved,
        // slot 103: DSGetSamplers
        _reserved103: Reserved,
        // slot 104: DSGetConstantBuffers
        _reserved104: Reserved,
        // slot 105: CSGetShaderResources
        _reserved105: Reserved,
        // slot 106: CSGetUnorderedAccessViews
        _reserved106: Reserved,
        // slot 107: CSGetShader
        _reserved107: Reserved,
        // slot 108: CSGetSamplers
        _reserved108: Reserved,
        // slot 109: CSGetConstantBuffers
        _reserved109: Reserved,
        // slot 110: ClearState
        _reserved110: Reserved,
        // slot 111: Flush
        _reserved111: Reserved,
        // slot 112: GetType
        _reserved112: Reserved,
        // slot 113: GetContextFlags
        _reserved113: Reserved,
        // slot 114: FinishCommandList
        _reserved114: Reserved,
    };

    pub inline fn VSSetConstantBuffers(self: *ID3D11DeviceContext, start_slot: u32, buffers: []const ?*ID3D11Buffer) void {
        self.vtable.VSSetConstantBuffers(self, start_slot, @intCast(buffers.len), buffers.ptr);
    }

    pub inline fn PSSetShaderResources(self: *ID3D11DeviceContext, start_slot: u32, views: []const ?*ID3D11ShaderResourceView) void {
        self.vtable.PSSetShaderResources(self, start_slot, @intCast(views.len), views.ptr);
    }

    pub inline fn PSSetShader(self: *ID3D11DeviceContext, shader: ?*ID3D11PixelShader) void {
        self.vtable.PSSetShader(self, shader, null, 0);
    }

    pub inline fn PSSetSamplers(self: *ID3D11DeviceContext, start_slot: u32, samplers: []const ?*ID3D11SamplerState) void {
        self.vtable.PSSetSamplers(self, start_slot, @intCast(samplers.len), samplers.ptr);
    }

    pub inline fn VSSetShader(self: *ID3D11DeviceContext, shader: ?*ID3D11VertexShader) void {
        self.vtable.VSSetShader(self, shader, null, 0);
    }

    pub inline fn Map(
        self: *ID3D11DeviceContext,
        resource: *ID3D11Resource,
        subresource: u32,
        map_type: D3D11_MAP,
        map_flags: u32,
        mapped: *D3D11_MAPPED_SUBRESOURCE,
    ) HRESULT {
        return self.vtable.Map(self, resource, subresource, map_type, map_flags, mapped);
    }

    pub inline fn Unmap(self: *ID3D11DeviceContext, resource: *ID3D11Resource, subresource: u32) void {
        self.vtable.Unmap(self, resource, subresource);
    }

    pub inline fn IASetInputLayout(self: *ID3D11DeviceContext, layout: ?*ID3D11InputLayout) void {
        self.vtable.IASetInputLayout(self, layout);
    }

    pub inline fn IASetVertexBuffers(
        self: *ID3D11DeviceContext,
        start_slot: u32,
        buffers: []const ?*ID3D11Buffer,
        strides: []const u32,
        offsets: []const u32,
    ) void {
        self.vtable.IASetVertexBuffers(self, start_slot, @intCast(buffers.len), buffers.ptr, strides.ptr, offsets.ptr);
    }

    pub inline fn IASetPrimitiveTopology(self: *ID3D11DeviceContext, topology: D3D_PRIMITIVE_TOPOLOGY) void {
        self.vtable.IASetPrimitiveTopology(self, topology);
    }

    pub inline fn DrawInstanced(
        self: *ID3D11DeviceContext,
        vertex_count: u32,
        instance_count: u32,
        start_vertex: u32,
        start_instance: u32,
    ) void {
        self.vtable.DrawInstanced(self, vertex_count, instance_count, start_vertex, start_instance);
    }

    pub inline fn OMSetRenderTargets(
        self: *ID3D11DeviceContext,
        rtvs: []const ?*ID3D11RenderTargetView,
        dsv: ?*anyopaque,
    ) void {
        self.vtable.OMSetRenderTargets(self, @intCast(rtvs.len), rtvs.ptr, dsv);
    }

    pub inline fn RSSetViewports(self: *ID3D11DeviceContext, viewports: []const D3D11_VIEWPORT) void {
        self.vtable.RSSetViewports(self, @intCast(viewports.len), viewports.ptr);
    }

    pub inline fn ClearRenderTargetView(self: *ID3D11DeviceContext, rtv: *ID3D11RenderTargetView, color: *const [4]f32) void {
        self.vtable.ClearRenderTargetView(self, rtv, color);
    }

    pub inline fn Release(self: *ID3D11DeviceContext) u32 {
        return self.vtable.Release(self);
    }
};

/// Opaque type — we never call methods on class instances directly.
pub const ID3D11ClassInstance = opaque {};

// =============================================================================
// D3D11CreateDevice — imported from d3d11.dll
// =============================================================================
pub const D3D11CreateDevice = @extern(*const fn (
    pAdapter: ?*anyopaque, // IDXGIAdapter
    DriverType: D3D_DRIVER_TYPE,
    Software: ?*anyopaque, // HMODULE
    Flags: D3D11_CREATE_DEVICE_FLAG,
    pFeatureLevels: ?[*]const D3D_FEATURE_LEVEL,
    FeatureLevels: u32,
    SDKVersion: u32,
    ppDevice: ?*?*ID3D11Device,
    pFeatureLevel: ?*D3D_FEATURE_LEVEL,
    ppImmediateContext: ?*?*ID3D11DeviceContext,
) callconv(.winapi) HRESULT, .{
    .library_name = "d3d11",
    .name = "D3D11CreateDevice",
});

pub const D3D11_SDK_VERSION: u32 = 7;
