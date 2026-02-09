//! Direct3D 11 and DXGI COM interface bindings for Zig.
//!
//! Hand-written COM vtable definitions following the same pattern as
//! the existing Win32 API bindings in `src/apprt/win32/c.zig`.

const std = @import("std");

// ============================================================================
// Basic Win32 types (mirrored from std)
// ============================================================================

pub const BOOL = std.os.windows.BOOL;
pub const UINT = u32;
pub const INT = i32;
pub const FLOAT = f32;
pub const DWORD = u32;
pub const HRESULT = std.os.windows.HRESULT;
pub const HWND = std.os.windows.HWND;
pub const HMODULE = std.os.windows.HMODULE;
pub const HANDLE = std.os.windows.HANDLE;
pub const LPCSTR = [*:0]const u8;
pub const LPCWSTR = [*:0]const u16;
pub const SIZE_T = usize;
pub const GUID = std.os.windows.GUID;
pub const LONG = i32;
pub const BYTE = u8;
pub const LUID = extern struct { LowPart: DWORD, HighPart: LONG };
pub const RECT = extern struct { left: LONG, top: LONG, right: LONG, bottom: LONG };

pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;

pub fn SUCCEEDED(hr: HRESULT) bool {
    return @as(i32, @bitCast(hr)) >= 0;
}

pub fn FAILED(hr: HRESULT) bool {
    return @as(i32, @bitCast(hr)) < 0;
}

// ============================================================================
// GUIDs
// ============================================================================

pub const IID_IDXGIFactory1 = GUID{
    .Data1 = 0x770aae78,
    .Data2 = 0xf26f,
    .Data3 = 0x4dba,
    .Data4 = .{ 0xa8, 0x29, 0x25, 0x3c, 0x83, 0xd1, 0xb3, 0x87 },
};

pub const IID_ID3D11Texture2D = GUID{
    .Data1 = 0x6f15aaf2,
    .Data2 = 0xd208,
    .Data3 = 0x4e89,
    .Data4 = .{ 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c },
};

// ============================================================================
// Enums and constants
// ============================================================================

pub const D3D_DRIVER_TYPE = enum(UINT) {
    UNKNOWN = 0,
    HARDWARE = 1,
    REFERENCE = 2,
    NULL = 3,
    SOFTWARE = 4,
    WARP = 5,
};

pub const D3D_FEATURE_LEVEL = enum(UINT) {
    @"9_1" = 0x9100,
    @"9_2" = 0x9200,
    @"9_3" = 0x9300,
    @"10_0" = 0xa000,
    @"10_1" = 0xa100,
    @"11_0" = 0xb000,
    @"11_1" = 0xb100,
};

pub const DXGI_FORMAT = enum(UINT) {
    UNKNOWN = 0,
    R32G32B32A32_FLOAT = 2,
    R32G32B32_FLOAT = 6,
    R32G32_FLOAT = 16,
    R32G32_UINT = 17,
    R32_FLOAT = 41,
    R8G8B8A8_UNORM = 28,
    R8G8B8A8_UNORM_SRGB = 29,
    R8G8B8A8_UINT = 30,
    B8G8R8A8_UNORM = 87,
    B8G8R8A8_UNORM_SRGB = 91,
    R16G16_UINT = 36,
    R16G16_SINT = 38,
    R32_UINT = 42,
    R16_UINT = 57,
    R16_SINT = 59,
    R8_UNORM = 61,
    R8_UINT = 62,
    R8_SINT = 64,
    D24_UNORM_S8_UINT = 45,
};

pub const DXGI_MODE_SCANLINE_ORDER = enum(UINT) {
    UNSPECIFIED = 0,
    PROGRESSIVE = 1,
    UPPER_FIELD_FIRST = 2,
    LOWER_FIELD_FIRST = 3,
};

pub const DXGI_MODE_SCALING = enum(UINT) {
    UNSPECIFIED = 0,
    CENTERED = 1,
    STRETCHED = 2,
};

pub const DXGI_SWAP_EFFECT = enum(UINT) {
    DISCARD = 0,
    SEQUENTIAL = 1,
    FLIP_SEQUENTIAL = 3,
    FLIP_DISCARD = 4,
};

pub const DXGI_USAGE = UINT;
pub const DXGI_USAGE_RENDER_TARGET_OUTPUT: DXGI_USAGE = 0x00000020;
pub const DXGI_USAGE_SHADER_INPUT: DXGI_USAGE = 0x00000010;

pub const D3D11_USAGE = enum(UINT) {
    DEFAULT = 0,
    IMMUTABLE = 1,
    DYNAMIC = 2,
    STAGING = 3,
};

pub const D3D11_BIND_FLAG = UINT;
pub const D3D11_BIND_VERTEX_BUFFER: D3D11_BIND_FLAG = 0x1;
pub const D3D11_BIND_INDEX_BUFFER: D3D11_BIND_FLAG = 0x2;
pub const D3D11_BIND_CONSTANT_BUFFER: D3D11_BIND_FLAG = 0x4;
pub const D3D11_BIND_SHADER_RESOURCE: D3D11_BIND_FLAG = 0x8;
pub const D3D11_BIND_RENDER_TARGET: D3D11_BIND_FLAG = 0x20;

pub const D3D11_CPU_ACCESS_FLAG = UINT;
pub const D3D11_CPU_ACCESS_WRITE: D3D11_CPU_ACCESS_FLAG = 0x10000;
pub const D3D11_CPU_ACCESS_READ: D3D11_CPU_ACCESS_FLAG = 0x20000;

pub const D3D11_RESOURCE_MISC_FLAG = UINT;
pub const D3D11_RESOURCE_MISC_BUFFER_STRUCTURED: D3D11_RESOURCE_MISC_FLAG = 0x40;

pub const D3D11_MAP = enum(UINT) {
    READ = 1,
    WRITE = 2,
    READ_WRITE = 3,
    WRITE_DISCARD = 4,
    WRITE_NO_OVERWRITE = 5,
};

pub const D3D11_CREATE_DEVICE_FLAG = UINT;
pub const D3D11_CREATE_DEVICE_SINGLETHREADED: D3D11_CREATE_DEVICE_FLAG = 0x1;
pub const D3D11_CREATE_DEVICE_DEBUG: D3D11_CREATE_DEVICE_FLAG = 0x2;
pub const D3D11_CREATE_DEVICE_BGRA_SUPPORT: D3D11_CREATE_DEVICE_FLAG = 0x20;

pub const D3D11_FILTER = enum(UINT) {
    MIN_MAG_MIP_POINT = 0,
    MIN_MAG_MIP_LINEAR = 0x15,
    MIN_MAG_POINT_MIP_LINEAR = 0x1,
    MIN_POINT_MAG_LINEAR_MIP_POINT = 0x4,
    MIN_POINT_MAG_MIP_LINEAR = 0x5,
    MIN_LINEAR_MAG_MIP_POINT = 0x10,
    MIN_LINEAR_MAG_POINT_MIP_LINEAR = 0x11,
    MIN_MAG_LINEAR_MIP_POINT = 0x14,
};

pub const D3D11_TEXTURE_ADDRESS_MODE = enum(UINT) {
    WRAP = 1,
    MIRROR = 2,
    CLAMP = 3,
    BORDER = 4,
    MIRROR_ONCE = 5,
};

pub const D3D11_COMPARISON_FUNC = enum(UINT) {
    NEVER = 1,
    LESS = 2,
    EQUAL = 3,
    LESS_EQUAL = 4,
    GREATER = 5,
    NOT_EQUAL = 6,
    GREATER_EQUAL = 7,
    ALWAYS = 8,
};

pub const D3D11_BLEND = enum(UINT) {
    ZERO = 1,
    ONE = 2,
    SRC_COLOR = 3,
    INV_SRC_COLOR = 4,
    SRC_ALPHA = 5,
    INV_SRC_ALPHA = 6,
    DEST_ALPHA = 7,
    INV_DEST_ALPHA = 8,
    DEST_COLOR = 9,
    INV_DEST_COLOR = 10,
    SRC_ALPHA_SAT = 11,
    BLEND_FACTOR = 14,
    INV_BLEND_FACTOR = 15,
    SRC1_COLOR = 16,
    INV_SRC1_COLOR = 17,
    SRC1_ALPHA = 18,
    INV_SRC1_ALPHA = 19,
};

pub const D3D11_BLEND_OP = enum(UINT) {
    ADD = 1,
    SUBTRACT = 2,
    REV_SUBTRACT = 3,
    MIN = 4,
    MAX = 5,
};

pub const D3D11_COLOR_WRITE_ENABLE = UINT;
pub const D3D11_COLOR_WRITE_ENABLE_ALL: D3D11_COLOR_WRITE_ENABLE = 0xf;

pub const D3D11_INPUT_CLASSIFICATION = enum(UINT) {
    PER_VERTEX_DATA = 0,
    PER_INSTANCE_DATA = 1,
};

pub const D3D11_PRIMITIVE_TOPOLOGY = enum(UINT) {
    UNDEFINED = 0,
    POINTLIST = 1,
    LINELIST = 2,
    LINESTRIP = 3,
    TRIANGLELIST = 4,
    TRIANGLESTRIP = 5,
};

pub const D3D11_SRV_DIMENSION = enum(UINT) {
    UNKNOWN = 0,
    BUFFER = 1,
    TEXTURE1D = 2,
    TEXTURE1D_ARRAY = 3,
    TEXTURE2D = 4,
    TEXTURE2D_ARRAY = 5,
    TEXTURE2DMS = 6,
    TEXTURE2DMS_ARRAY = 7,
    TEXTURE3D = 8,
    TEXTURECUBE = 9,
    TEXTURECUBE_ARRAY = 10,
    BUFFEREX = 11,
};

pub const D3D11_RTV_DIMENSION = enum(UINT) {
    UNKNOWN = 0,
    BUFFER = 1,
    TEXTURE1D = 2,
    TEXTURE1D_ARRAY = 3,
    TEXTURE2D = 4,
    TEXTURE2D_ARRAY = 5,
    TEXTURE2DMS = 6,
    TEXTURE2DMS_ARRAY = 7,
    TEXTURE3D = 8,
};

pub const D3D11_CLEAR_FLAG = UINT;
pub const D3D11_CLEAR_DEPTH: D3D11_CLEAR_FLAG = 0x1;
pub const D3D11_CLEAR_STENCIL: D3D11_CLEAR_FLAG = 0x2;

pub const D3DCOMPILE_DEBUG: DWORD = 1 << 0;
pub const D3DCOMPILE_SKIP_VALIDATION: DWORD = 1 << 1;
pub const D3DCOMPILE_SKIP_OPTIMIZATION: DWORD = 1 << 2;
pub const D3DCOMPILE_ENABLE_STRICTNESS: DWORD = 1 << 11;
pub const D3DCOMPILE_OPTIMIZATION_LEVEL3: DWORD = 1 << 15;

pub const D3D11_APPEND_ALIGNED_ELEMENT: UINT = 0xffffffff;

// ============================================================================
// Descriptor / configuration structs
// ============================================================================

pub const DXGI_RATIONAL = extern struct {
    Numerator: UINT = 0,
    Denominator: UINT = 0,
};

pub const DXGI_MODE_DESC = extern struct {
    Width: UINT = 0,
    Height: UINT = 0,
    RefreshRate: DXGI_RATIONAL = .{},
    Format: DXGI_FORMAT = .UNKNOWN,
    ScanlineOrdering: DXGI_MODE_SCANLINE_ORDER = .UNSPECIFIED,
    Scaling: DXGI_MODE_SCALING = .UNSPECIFIED,
};

pub const DXGI_SAMPLE_DESC = extern struct {
    Count: UINT = 1,
    Quality: UINT = 0,
};

pub const DXGI_SWAP_CHAIN_DESC = extern struct {
    BufferDesc: DXGI_MODE_DESC = .{},
    SampleDesc: DXGI_SAMPLE_DESC = .{},
    BufferUsage: DXGI_USAGE = 0,
    BufferCount: UINT = 0,
    OutputWindow: ?HWND = null,
    Windowed: BOOL = TRUE,
    SwapEffect: DXGI_SWAP_EFFECT = .DISCARD,
    Flags: UINT = 0,
};

pub const D3D11_BUFFER_DESC = extern struct {
    ByteWidth: UINT = 0,
    Usage: D3D11_USAGE = .DEFAULT,
    BindFlags: D3D11_BIND_FLAG = 0,
    CPUAccessFlags: D3D11_CPU_ACCESS_FLAG = 0,
    MiscFlags: D3D11_RESOURCE_MISC_FLAG = 0,
    StructureByteStride: UINT = 0,
};

pub const D3D11_TEXTURE2D_DESC = extern struct {
    Width: UINT = 0,
    Height: UINT = 0,
    MipLevels: UINT = 1,
    ArraySize: UINT = 1,
    Format: DXGI_FORMAT = .UNKNOWN,
    SampleDesc: DXGI_SAMPLE_DESC = .{},
    Usage: D3D11_USAGE = .DEFAULT,
    BindFlags: D3D11_BIND_FLAG = 0,
    CPUAccessFlags: D3D11_CPU_ACCESS_FLAG = 0,
    MiscFlags: UINT = 0,
};

pub const D3D11_SUBRESOURCE_DATA = extern struct {
    pSysMem: ?*const anyopaque = null,
    SysMemPitch: UINT = 0,
    SysMemSlicePitch: UINT = 0,
};

pub const D3D11_MAPPED_SUBRESOURCE = extern struct {
    pData: ?*anyopaque = null,
    RowPitch: UINT = 0,
    DepthPitch: UINT = 0,
};

pub const D3D11_VIEWPORT = extern struct {
    TopLeftX: FLOAT = 0,
    TopLeftY: FLOAT = 0,
    Width: FLOAT = 0,
    Height: FLOAT = 0,
    MinDepth: FLOAT = 0,
    MaxDepth: FLOAT = 1,
};

pub const D3D11_BOX = extern struct {
    left: UINT = 0,
    top: UINT = 0,
    front: UINT = 0,
    right: UINT = 0,
    bottom: UINT = 0,
    back: UINT = 1,
};

pub const D3D11_INPUT_ELEMENT_DESC = extern struct {
    SemanticName: LPCSTR,
    SemanticIndex: UINT = 0,
    Format: DXGI_FORMAT = .UNKNOWN,
    InputSlot: UINT = 0,
    AlignedByteOffset: UINT = 0,
    InputSlotClass: D3D11_INPUT_CLASSIFICATION = .PER_VERTEX_DATA,
    InstanceDataStepRate: UINT = 0,
};

pub const D3D11_RENDER_TARGET_BLEND_DESC = extern struct {
    BlendEnable: BOOL = FALSE,
    SrcBlend: D3D11_BLEND = .ONE,
    DestBlend: D3D11_BLEND = .ZERO,
    BlendOp: D3D11_BLEND_OP = .ADD,
    SrcBlendAlpha: D3D11_BLEND = .ONE,
    DestBlendAlpha: D3D11_BLEND = .ZERO,
    BlendOpAlpha: D3D11_BLEND_OP = .ADD,
    RenderTargetWriteMask: BYTE = @intCast(D3D11_COLOR_WRITE_ENABLE_ALL),
};

pub const D3D11_BLEND_DESC = extern struct {
    AlphaToCoverageEnable: BOOL = FALSE,
    IndependentBlendEnable: BOOL = FALSE,
    RenderTarget: [8]D3D11_RENDER_TARGET_BLEND_DESC = [_]D3D11_RENDER_TARGET_BLEND_DESC{.{}} ** 8,
};

pub const D3D11_SAMPLER_DESC = extern struct {
    Filter: D3D11_FILTER = .MIN_MAG_MIP_LINEAR,
    AddressU: D3D11_TEXTURE_ADDRESS_MODE = .CLAMP,
    AddressV: D3D11_TEXTURE_ADDRESS_MODE = .CLAMP,
    AddressW: D3D11_TEXTURE_ADDRESS_MODE = .CLAMP,
    MipLODBias: FLOAT = 0,
    MaxAnisotropy: UINT = 1,
    ComparisonFunc: D3D11_COMPARISON_FUNC = .NEVER,
    BorderColor: [4]FLOAT = .{ 0, 0, 0, 0 },
    MinLOD: FLOAT = -std.math.floatMax(f32),
    MaxLOD: FLOAT = std.math.floatMax(f32),
};

pub const D3D11_SHADER_RESOURCE_VIEW_DESC = extern struct {
    Format: DXGI_FORMAT = .UNKNOWN,
    ViewDimension: D3D11_SRV_DIMENSION = .UNKNOWN,
    u: extern union {
        Buffer: extern struct {
            FirstElement: UINT,
            NumElements: UINT,
        },
        Texture2D: extern struct {
            MostDetailedMip: UINT,
            MipLevels: UINT,
        },
    } = undefined,
};

pub const D3D11_RENDER_TARGET_VIEW_DESC = extern struct {
    Format: DXGI_FORMAT = .UNKNOWN,
    ViewDimension: D3D11_RTV_DIMENSION = .UNKNOWN,
    u: extern union {
        Buffer: extern struct {
            FirstElement: UINT,
            NumElements: UINT,
        },
        Texture2D: extern struct {
            MipSlice: UINT,
        },
    } = undefined,
};

pub const DXGI_ADAPTER_DESC1 = extern struct {
    Description: [128]u16 = [_]u16{0} ** 128,
    VendorId: UINT = 0,
    DeviceId: UINT = 0,
    SubSysId: UINT = 0,
    Revision: UINT = 0,
    DedicatedVideoMemory: SIZE_T = 0,
    DedicatedSystemMemory: SIZE_T = 0,
    SharedSystemMemory: SIZE_T = 0,
    AdapterLuid: LUID = .{ .LowPart = 0, .HighPart = 0 },
    Flags: UINT = 0,
};

// ============================================================================
// COM Interface VTables
//
// Pattern: Each COM interface is a pointer to an opaque type that has
// a `vtable()` method returning the typed VTable. Methods are called via
// the vtable function pointers.
// ============================================================================

// ----------------------------------------------------------------------------
// IUnknown
// ----------------------------------------------------------------------------

pub const IUnknown = *extern struct {
    pub const VTable = extern struct {
        QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*anyopaque) callconv(.c) u32,
        Release: *const fn (*anyopaque) callconv(.c) u32,
    };
};

// ----------------------------------------------------------------------------
// ID3DBlob
// ----------------------------------------------------------------------------

pub const ID3DBlob = *extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        // IUnknown
        QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*anyopaque) callconv(.c) u32,
        Release: *const fn (*anyopaque) callconv(.c) u32,
        // ID3DBlob
        GetBufferPointer: *const fn (*anyopaque) callconv(.c) ?*anyopaque,
        GetBufferSize: *const fn (*anyopaque) callconv(.c) SIZE_T,
    };

    pub fn GetBufferPointer(self: ID3DBlob) ?*anyopaque {
        return self.vtable.GetBufferPointer(@ptrCast(self));
    }

    pub fn GetBufferSize(self: ID3DBlob) SIZE_T {
        return self.vtable.GetBufferSize(@ptrCast(self));
    }

    pub fn Release(self: ID3DBlob) u32 {
        return self.vtable.Release(@ptrCast(self));
    }
};

// ----------------------------------------------------------------------------
// ID3D11Device
// ----------------------------------------------------------------------------

pub const ID3D11Device = *extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        // IUnknown (3)
        QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*anyopaque) callconv(.c) u32,
        Release: *const fn (*anyopaque) callconv(.c) u32,
        // ID3D11Device methods (in SDK vtable order)
        CreateBuffer: *const fn (*anyopaque, *const D3D11_BUFFER_DESC, ?*const D3D11_SUBRESOURCE_DATA, ?*?ID3D11Buffer) callconv(.c) HRESULT,
        CreateTexture1D: *const fn (*anyopaque, *const anyopaque, ?*const anyopaque, ?*?*anyopaque) callconv(.c) HRESULT,
        CreateTexture2D: *const fn (*anyopaque, *const D3D11_TEXTURE2D_DESC, ?*const D3D11_SUBRESOURCE_DATA, ?*?ID3D11Texture2D) callconv(.c) HRESULT,
        CreateTexture3D: *const fn (*anyopaque, *const anyopaque, ?*const anyopaque, ?*?*anyopaque) callconv(.c) HRESULT,
        CreateShaderResourceView: *const fn (*anyopaque, *anyopaque, ?*const D3D11_SHADER_RESOURCE_VIEW_DESC, ?*?ID3D11ShaderResourceView) callconv(.c) HRESULT,
        CreateUnorderedAccessView: *const fn (*anyopaque, *anyopaque, ?*const anyopaque, ?*?*anyopaque) callconv(.c) HRESULT,
        CreateRenderTargetView: *const fn (*anyopaque, *anyopaque, ?*const D3D11_RENDER_TARGET_VIEW_DESC, ?*?ID3D11RenderTargetView) callconv(.c) HRESULT,
        CreateDepthStencilView: *const fn (*anyopaque, *anyopaque, ?*const anyopaque, ?*?*anyopaque) callconv(.c) HRESULT,
        CreateInputLayout: *const fn (*anyopaque, [*]const D3D11_INPUT_ELEMENT_DESC, UINT, ?*const anyopaque, SIZE_T, ?*?ID3D11InputLayout) callconv(.c) HRESULT,
        CreateVertexShader: *const fn (*anyopaque, ?*const anyopaque, SIZE_T, ?*anyopaque, ?*?ID3D11VertexShader) callconv(.c) HRESULT,
        CreateGeometryShader: *const fn (*anyopaque, ?*const anyopaque, SIZE_T, ?*anyopaque, ?*?*anyopaque) callconv(.c) HRESULT,
        CreateGeometryShaderWithStreamOutput: *const fn (*anyopaque, ?*const anyopaque, SIZE_T, ?*const anyopaque, UINT, ?*const UINT, UINT, UINT, ?*anyopaque, ?*?*anyopaque) callconv(.c) HRESULT,
        CreatePixelShader: *const fn (*anyopaque, ?*const anyopaque, SIZE_T, ?*anyopaque, ?*?ID3D11PixelShader) callconv(.c) HRESULT,
        CreateHullShader: *const fn (*anyopaque, ?*const anyopaque, SIZE_T, ?*anyopaque, ?*?*anyopaque) callconv(.c) HRESULT,
        CreateDomainShader: *const fn (*anyopaque, ?*const anyopaque, SIZE_T, ?*anyopaque, ?*?*anyopaque) callconv(.c) HRESULT,
        CreateComputeShader: *const fn (*anyopaque, ?*const anyopaque, SIZE_T, ?*anyopaque, ?*?*anyopaque) callconv(.c) HRESULT,
        CreateClassLinkage: *const fn (*anyopaque, ?*?*anyopaque) callconv(.c) HRESULT,
        CreateBlendState: *const fn (*anyopaque, *const D3D11_BLEND_DESC, ?*?ID3D11BlendState) callconv(.c) HRESULT,
        CreateDepthStencilState: *const fn (*anyopaque, *const anyopaque, ?*?*anyopaque) callconv(.c) HRESULT,
        CreateRasterizerState: *const fn (*anyopaque, *const anyopaque, ?*?*anyopaque) callconv(.c) HRESULT,
        CreateSamplerState: *const fn (*anyopaque, *const D3D11_SAMPLER_DESC, ?*?ID3D11SamplerState) callconv(.c) HRESULT,
        CreateQuery: *const fn (*anyopaque, *const anyopaque, ?*?*anyopaque) callconv(.c) HRESULT,
        CreatePredicate: *const fn (*anyopaque, *const anyopaque, ?*?*anyopaque) callconv(.c) HRESULT,
        CreateCounter: *const fn (*anyopaque, *const anyopaque, ?*?*anyopaque) callconv(.c) HRESULT,
        CreateDeferredContext: *const fn (*anyopaque, UINT, ?*?*anyopaque) callconv(.c) HRESULT,
        OpenSharedResource: *const fn (*anyopaque, ?HANDLE, *const GUID, ?*?*anyopaque) callconv(.c) HRESULT,
        CheckFormatSupport: *const fn (*anyopaque, DXGI_FORMAT, *UINT) callconv(.c) HRESULT,
        CheckMultisampleQualityLevels: *const fn (*anyopaque, DXGI_FORMAT, UINT, *UINT) callconv(.c) HRESULT,
        CheckCounterInfo: *const fn (*anyopaque, *anyopaque) callconv(.c) void,
        CheckCounter: *const fn (*anyopaque, *const anyopaque, *anyopaque, *UINT, ?LPCSTR, ?*UINT, ?LPCSTR, ?*UINT, ?LPCSTR, ?*UINT) callconv(.c) HRESULT,
        CheckFeatureSupport: *const fn (*anyopaque, UINT, *anyopaque, UINT) callconv(.c) HRESULT,
        GetPrivateData: *const fn (*anyopaque, *const GUID, *UINT, ?*anyopaque) callconv(.c) HRESULT,
        SetPrivateData: *const fn (*anyopaque, *const GUID, UINT, ?*const anyopaque) callconv(.c) HRESULT,
        SetPrivateDataInterface: *const fn (*anyopaque, *const GUID, ?*const anyopaque) callconv(.c) HRESULT,
        GetFeatureLevel: *const fn (*anyopaque) callconv(.c) D3D_FEATURE_LEVEL,
        GetCreationFlags: *const fn (*anyopaque) callconv(.c) UINT,
        GetDeviceRemovedReason: *const fn (*anyopaque) callconv(.c) HRESULT,
        GetImmediateContext: *const fn (*anyopaque, *?ID3D11DeviceContext) callconv(.c) void,
        SetExceptionMode: *const fn (*anyopaque, UINT) callconv(.c) HRESULT,
        GetExceptionMode: *const fn (*anyopaque) callconv(.c) UINT,
    };

    pub fn CreateBuffer(
        self: ID3D11Device,
        desc: *const D3D11_BUFFER_DESC,
        initial_data: ?*const D3D11_SUBRESOURCE_DATA,
        out: *?ID3D11Buffer,
    ) HRESULT {
        return self.vtable.CreateBuffer(@ptrCast(self), desc, initial_data, out);
    }

    pub fn CreateTexture2D(
        self: ID3D11Device,
        desc: *const D3D11_TEXTURE2D_DESC,
        initial_data: ?*const D3D11_SUBRESOURCE_DATA,
        out: *?ID3D11Texture2D,
    ) HRESULT {
        return self.vtable.CreateTexture2D(@ptrCast(self), desc, initial_data, out);
    }

    pub fn CreateShaderResourceView(
        self: ID3D11Device,
        resource: *anyopaque,
        desc: ?*const D3D11_SHADER_RESOURCE_VIEW_DESC,
        out: *?ID3D11ShaderResourceView,
    ) HRESULT {
        return self.vtable.CreateShaderResourceView(@ptrCast(self), resource, desc, out);
    }

    pub fn CreateRenderTargetView(
        self: ID3D11Device,
        resource: *anyopaque,
        desc: ?*const D3D11_RENDER_TARGET_VIEW_DESC,
        out: *?ID3D11RenderTargetView,
    ) HRESULT {
        return self.vtable.CreateRenderTargetView(@ptrCast(self), resource, desc, out);
    }

    pub fn CreateInputLayout(
        self: ID3D11Device,
        descs: [*]const D3D11_INPUT_ELEMENT_DESC,
        num_elements: UINT,
        bytecode: ?*const anyopaque,
        bytecode_len: SIZE_T,
        out: *?ID3D11InputLayout,
    ) HRESULT {
        return self.vtable.CreateInputLayout(@ptrCast(self), descs, num_elements, bytecode, bytecode_len, out);
    }

    pub fn CreateVertexShader(
        self: ID3D11Device,
        bytecode: ?*const anyopaque,
        bytecode_len: SIZE_T,
        class_linkage: ?*anyopaque,
        out: *?ID3D11VertexShader,
    ) HRESULT {
        return self.vtable.CreateVertexShader(@ptrCast(self), bytecode, bytecode_len, class_linkage, out);
    }

    pub fn CreatePixelShader(
        self: ID3D11Device,
        bytecode: ?*const anyopaque,
        bytecode_len: SIZE_T,
        class_linkage: ?*anyopaque,
        out: *?ID3D11PixelShader,
    ) HRESULT {
        return self.vtable.CreatePixelShader(@ptrCast(self), bytecode, bytecode_len, class_linkage, out);
    }

    pub fn CreateBlendState(
        self: ID3D11Device,
        desc: *const D3D11_BLEND_DESC,
        out: *?ID3D11BlendState,
    ) HRESULT {
        return self.vtable.CreateBlendState(@ptrCast(self), desc, out);
    }

    pub fn CreateSamplerState(
        self: ID3D11Device,
        desc: *const D3D11_SAMPLER_DESC,
        out: *?ID3D11SamplerState,
    ) HRESULT {
        return self.vtable.CreateSamplerState(@ptrCast(self), desc, out);
    }

    pub fn GetFeatureLevel(self: ID3D11Device) D3D_FEATURE_LEVEL {
        return self.vtable.GetFeatureLevel(@ptrCast(self));
    }

    pub fn GetDeviceRemovedReason(self: ID3D11Device) HRESULT {
        return self.vtable.GetDeviceRemovedReason(@ptrCast(self));
    }

    pub fn GetImmediateContext(self: ID3D11Device, out: *?ID3D11DeviceContext) void {
        self.vtable.GetImmediateContext(@ptrCast(self), out);
    }

    pub fn Release(self: ID3D11Device) u32 {
        return self.vtable.Release(@ptrCast(self));
    }
};

// ----------------------------------------------------------------------------
// ID3D11DeviceContext
// ----------------------------------------------------------------------------

pub const ID3D11DeviceContext = *extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        // IUnknown (3)
        QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*anyopaque) callconv(.c) u32,
        Release: *const fn (*anyopaque) callconv(.c) u32,
        // ID3D11DeviceChild (4)
        GetDevice: *const fn (*anyopaque, *?*anyopaque) callconv(.c) void,
        GetPrivateData: *const fn (*anyopaque, *const GUID, *UINT, ?*anyopaque) callconv(.c) HRESULT,
        SetPrivateData: *const fn (*anyopaque, *const GUID, UINT, ?*const anyopaque) callconv(.c) HRESULT,
        SetPrivateDataInterface: *const fn (*anyopaque, *const GUID, ?*const anyopaque) callconv(.c) HRESULT,
        // ID3D11DeviceContext methods (in SDK vtable order)
        VSSetConstantBuffers: *const fn (*anyopaque, UINT, UINT, ?[*]const ?ID3D11Buffer) callconv(.c) void,
        PSSetShaderResources: *const fn (*anyopaque, UINT, UINT, ?[*]const ?ID3D11ShaderResourceView) callconv(.c) void,
        PSSetShader: *const fn (*anyopaque, ?ID3D11PixelShader, ?*?*anyopaque, UINT) callconv(.c) void,
        PSSetSamplers: *const fn (*anyopaque, UINT, UINT, ?[*]const ?ID3D11SamplerState) callconv(.c) void,
        VSSetShader: *const fn (*anyopaque, ?ID3D11VertexShader, ?*?*anyopaque, UINT) callconv(.c) void,
        DrawIndexed: *const fn (*anyopaque, UINT, UINT, INT) callconv(.c) void,
        Draw: *const fn (*anyopaque, UINT, UINT) callconv(.c) void,
        Map: *const fn (*anyopaque, *anyopaque, UINT, D3D11_MAP, UINT, *D3D11_MAPPED_SUBRESOURCE) callconv(.c) HRESULT,
        Unmap: *const fn (*anyopaque, *anyopaque, UINT) callconv(.c) void,
        PSSetConstantBuffers: *const fn (*anyopaque, UINT, UINT, ?[*]const ?ID3D11Buffer) callconv(.c) void,
        IASetInputLayout: *const fn (*anyopaque, ?ID3D11InputLayout) callconv(.c) void,
        IASetVertexBuffers: *const fn (*anyopaque, UINT, UINT, ?[*]const ?ID3D11Buffer, ?[*]const UINT, ?[*]const UINT) callconv(.c) void,
        IASetIndexBuffer: *const fn (*anyopaque, ?ID3D11Buffer, DXGI_FORMAT, UINT) callconv(.c) void,
        DrawIndexedInstanced: *const fn (*anyopaque, UINT, UINT, UINT, INT, UINT) callconv(.c) void,
        DrawInstanced: *const fn (*anyopaque, UINT, UINT, UINT, UINT) callconv(.c) void,
        GSSetConstantBuffers: *const fn (*anyopaque, UINT, UINT, ?[*]const ?ID3D11Buffer) callconv(.c) void,
        GSSetShader: *const fn (*anyopaque, ?*anyopaque, ?*?*anyopaque, UINT) callconv(.c) void,
        IASetPrimitiveTopology: *const fn (*anyopaque, D3D11_PRIMITIVE_TOPOLOGY) callconv(.c) void,
        VSSetShaderResources: *const fn (*anyopaque, UINT, UINT, ?[*]const ?ID3D11ShaderResourceView) callconv(.c) void,
        VSSetSamplers: *const fn (*anyopaque, UINT, UINT, ?[*]const ?ID3D11SamplerState) callconv(.c) void,
        Begin: *const fn (*anyopaque, ?*anyopaque) callconv(.c) void,
        End: *const fn (*anyopaque, ?*anyopaque) callconv(.c) void,
        GetData: *const fn (*anyopaque, ?*anyopaque, ?*anyopaque, UINT, UINT) callconv(.c) HRESULT,
        SetPredication: *const fn (*anyopaque, ?*anyopaque, BOOL) callconv(.c) void,
        GSSetShaderResources: *const fn (*anyopaque, UINT, UINT, ?[*]const ?ID3D11ShaderResourceView) callconv(.c) void,
        GSSetSamplers: *const fn (*anyopaque, UINT, UINT, ?[*]const ?ID3D11SamplerState) callconv(.c) void,
        OMSetRenderTargets: *const fn (*anyopaque, UINT, ?[*]const ?ID3D11RenderTargetView, ?*anyopaque) callconv(.c) void,
        OMSetRenderTargetsAndUnorderedAccessViews: *const fn (*anyopaque, UINT, ?[*]const ?ID3D11RenderTargetView, ?*anyopaque, UINT, UINT, ?[*]const ?*anyopaque, ?[*]const UINT) callconv(.c) void,
        OMSetBlendState: *const fn (*anyopaque, ?ID3D11BlendState, ?*const [4]FLOAT, UINT) callconv(.c) void,
        OMSetDepthStencilState: *const fn (*anyopaque, ?*anyopaque, UINT) callconv(.c) void,
        SOSetTargets: *const fn (*anyopaque, UINT, ?[*]const ?*anyopaque, ?[*]const UINT) callconv(.c) void,
        DrawAuto: *const fn (*anyopaque) callconv(.c) void,
        DrawIndexedInstancedIndirect: *const fn (*anyopaque, ?ID3D11Buffer, UINT) callconv(.c) void,
        DrawInstancedIndirect: *const fn (*anyopaque, ?ID3D11Buffer, UINT) callconv(.c) void,
        Dispatch: *const fn (*anyopaque, UINT, UINT, UINT) callconv(.c) void,
        DispatchIndirect: *const fn (*anyopaque, ?ID3D11Buffer, UINT) callconv(.c) void,
        RSSetState: *const fn (*anyopaque, ?*anyopaque) callconv(.c) void,
        RSSetViewports: *const fn (*anyopaque, UINT, ?[*]const D3D11_VIEWPORT) callconv(.c) void,
        RSSetScissorRects: *const fn (*anyopaque, UINT, ?[*]const RECT) callconv(.c) void,
        CopySubresourceRegion: *const fn (*anyopaque, *anyopaque, UINT, UINT, UINT, UINT, *anyopaque, UINT, ?*const D3D11_BOX) callconv(.c) void,
        CopyResource: *const fn (*anyopaque, *anyopaque, *anyopaque) callconv(.c) void,
        UpdateSubresource: *const fn (*anyopaque, *anyopaque, UINT, ?*const D3D11_BOX, *const anyopaque, UINT, UINT) callconv(.c) void,
        CopyStructureCount: *const fn (*anyopaque, ?ID3D11Buffer, UINT, ?*anyopaque) callconv(.c) void,
        ClearRenderTargetView: *const fn (*anyopaque, ID3D11RenderTargetView, *const [4]FLOAT) callconv(.c) void,
        ClearUnorderedAccessViewUint: *const fn (*anyopaque, ?*anyopaque, *const [4]UINT) callconv(.c) void,
        ClearUnorderedAccessViewFloat: *const fn (*anyopaque, ?*anyopaque, *const [4]FLOAT) callconv(.c) void,
        ClearDepthStencilView: *const fn (*anyopaque, ?*anyopaque, D3D11_CLEAR_FLAG, FLOAT, BYTE) callconv(.c) void,
        GenerateMips: *const fn (*anyopaque, ?ID3D11ShaderResourceView) callconv(.c) void,
        SetResourceMinLOD: *const fn (*anyopaque, ?*anyopaque, FLOAT) callconv(.c) void,
        GetResourceMinLOD: *const fn (*anyopaque, ?*anyopaque) callconv(.c) FLOAT,
        ResolveSubresource: *const fn (*anyopaque, *anyopaque, UINT, *anyopaque, UINT, DXGI_FORMAT) callconv(.c) void,
        ExecuteCommandList: *const fn (*anyopaque, ?*anyopaque, BOOL) callconv(.c) void,
        HSSetShaderResources: *const fn (*anyopaque, UINT, UINT, ?[*]const ?ID3D11ShaderResourceView) callconv(.c) void,
        HSSetShader: *const fn (*anyopaque, ?*anyopaque, ?*?*anyopaque, UINT) callconv(.c) void,
        HSSetSamplers: *const fn (*anyopaque, UINT, UINT, ?[*]const ?ID3D11SamplerState) callconv(.c) void,
        HSSetConstantBuffers: *const fn (*anyopaque, UINT, UINT, ?[*]const ?ID3D11Buffer) callconv(.c) void,
        DSSetShaderResources: *const fn (*anyopaque, UINT, UINT, ?[*]const ?ID3D11ShaderResourceView) callconv(.c) void,
        DSSetShader: *const fn (*anyopaque, ?*anyopaque, ?*?*anyopaque, UINT) callconv(.c) void,
        DSSetSamplers: *const fn (*anyopaque, UINT, UINT, ?[*]const ?ID3D11SamplerState) callconv(.c) void,
        DSSetConstantBuffers: *const fn (*anyopaque, UINT, UINT, ?[*]const ?ID3D11Buffer) callconv(.c) void,
        CSSetShaderResources: *const fn (*anyopaque, UINT, UINT, ?[*]const ?ID3D11ShaderResourceView) callconv(.c) void,
        CSSetUnorderedAccessViews: *const fn (*anyopaque, UINT, UINT, ?[*]const ?*anyopaque, ?[*]const UINT) callconv(.c) void,
        CSSetShader: *const fn (*anyopaque, ?*anyopaque, ?*?*anyopaque, UINT) callconv(.c) void,
        CSSetSamplers: *const fn (*anyopaque, UINT, UINT, ?[*]const ?ID3D11SamplerState) callconv(.c) void,
        CSSetConstantBuffers: *const fn (*anyopaque, UINT, UINT, ?[*]const ?ID3D11Buffer) callconv(.c) void,
        VSGetConstantBuffers: *const fn (*anyopaque, UINT, UINT, ?[*]?ID3D11Buffer) callconv(.c) void,
        PSGetShaderResources: *const fn (*anyopaque, UINT, UINT, ?[*]?ID3D11ShaderResourceView) callconv(.c) void,
        PSGetShader: *const fn (*anyopaque, ?*?ID3D11PixelShader, ?*?*anyopaque, ?*UINT) callconv(.c) void,
        PSGetSamplers: *const fn (*anyopaque, UINT, UINT, ?[*]?ID3D11SamplerState) callconv(.c) void,
        VSGetShader: *const fn (*anyopaque, ?*?ID3D11VertexShader, ?*?*anyopaque, ?*UINT) callconv(.c) void,
        PSGetConstantBuffers: *const fn (*anyopaque, UINT, UINT, ?[*]?ID3D11Buffer) callconv(.c) void,
        IAGetInputLayout: *const fn (*anyopaque, ?*?ID3D11InputLayout) callconv(.c) void,
        IAGetVertexBuffers: *const fn (*anyopaque, UINT, UINT, ?[*]?ID3D11Buffer, ?[*]UINT, ?[*]UINT) callconv(.c) void,
        IAGetIndexBuffer: *const fn (*anyopaque, ?*?ID3D11Buffer, ?*DXGI_FORMAT, ?*UINT) callconv(.c) void,
        GSGetConstantBuffers: *const fn (*anyopaque, UINT, UINT, ?[*]?ID3D11Buffer) callconv(.c) void,
        GSGetShader: *const fn (*anyopaque, ?*?*anyopaque, ?*?*anyopaque, ?*UINT) callconv(.c) void,
        IAGetPrimitiveTopology: *const fn (*anyopaque, *D3D11_PRIMITIVE_TOPOLOGY) callconv(.c) void,
        VSGetShaderResources: *const fn (*anyopaque, UINT, UINT, ?[*]?ID3D11ShaderResourceView) callconv(.c) void,
        VSGetSamplers: *const fn (*anyopaque, UINT, UINT, ?[*]?ID3D11SamplerState) callconv(.c) void,
        GetPredication: *const fn (*anyopaque, ?*?*anyopaque, ?*BOOL) callconv(.c) void,
        GSGetShaderResources: *const fn (*anyopaque, UINT, UINT, ?[*]?ID3D11ShaderResourceView) callconv(.c) void,
        GSGetSamplers: *const fn (*anyopaque, UINT, UINT, ?[*]?ID3D11SamplerState) callconv(.c) void,
        OMGetRenderTargets: *const fn (*anyopaque, UINT, ?[*]?ID3D11RenderTargetView, ?*?*anyopaque) callconv(.c) void,
        OMGetRenderTargetsAndUnorderedAccessViews: *const fn (*anyopaque, UINT, ?[*]?ID3D11RenderTargetView, ?*?*anyopaque, UINT, UINT, ?[*]?*anyopaque) callconv(.c) void,
        OMGetBlendState: *const fn (*anyopaque, ?*?ID3D11BlendState, ?*[4]FLOAT, ?*UINT) callconv(.c) void,
        OMGetDepthStencilState: *const fn (*anyopaque, ?*?*anyopaque, ?*UINT) callconv(.c) void,
        SOGetTargets: *const fn (*anyopaque, UINT, ?[*]?*anyopaque) callconv(.c) void,
        RSGetState: *const fn (*anyopaque, ?*?*anyopaque) callconv(.c) void,
        RSGetViewports: *const fn (*anyopaque, *UINT, ?[*]D3D11_VIEWPORT) callconv(.c) void,
        RSGetScissorRects: *const fn (*anyopaque, *UINT, ?[*]RECT) callconv(.c) void,
        HSGetShaderResources: *const fn (*anyopaque, UINT, UINT, ?[*]?ID3D11ShaderResourceView) callconv(.c) void,
        HSGetShader: *const fn (*anyopaque, ?*?*anyopaque, ?*?*anyopaque, ?*UINT) callconv(.c) void,
        HSGetSamplers: *const fn (*anyopaque, UINT, UINT, ?[*]?ID3D11SamplerState) callconv(.c) void,
        HSGetConstantBuffers: *const fn (*anyopaque, UINT, UINT, ?[*]?ID3D11Buffer) callconv(.c) void,
        DSGetShaderResources: *const fn (*anyopaque, UINT, UINT, ?[*]?ID3D11ShaderResourceView) callconv(.c) void,
        DSGetShader: *const fn (*anyopaque, ?*?*anyopaque, ?*?*anyopaque, ?*UINT) callconv(.c) void,
        DSGetSamplers: *const fn (*anyopaque, UINT, UINT, ?[*]?ID3D11SamplerState) callconv(.c) void,
        DSGetConstantBuffers: *const fn (*anyopaque, UINT, UINT, ?[*]?ID3D11Buffer) callconv(.c) void,
        CSGetShaderResources: *const fn (*anyopaque, UINT, UINT, ?[*]?ID3D11ShaderResourceView) callconv(.c) void,
        CSGetUnorderedAccessViews: *const fn (*anyopaque, UINT, UINT, ?[*]?*anyopaque) callconv(.c) void,
        CSGetShader: *const fn (*anyopaque, ?*?*anyopaque, ?*?*anyopaque, ?*UINT) callconv(.c) void,
        CSGetSamplers: *const fn (*anyopaque, UINT, UINT, ?[*]?ID3D11SamplerState) callconv(.c) void,
        CSGetConstantBuffers: *const fn (*anyopaque, UINT, UINT, ?[*]?ID3D11Buffer) callconv(.c) void,
        ClearState: *const fn (*anyopaque) callconv(.c) void,
        Flush: *const fn (*anyopaque) callconv(.c) void,
        GetType: *const fn (*anyopaque) callconv(.c) UINT,
        GetContextFlags: *const fn (*anyopaque) callconv(.c) UINT,
        FinishCommandList: *const fn (*anyopaque, BOOL, ?*?*anyopaque) callconv(.c) HRESULT,
    };

    pub fn VSSetConstantBuffers(self: ID3D11DeviceContext, start: UINT, num: UINT, buffers: ?[*]const ?ID3D11Buffer) void {
        self.vtable.VSSetConstantBuffers(@ptrCast(self), start, num, buffers);
    }

    pub fn PSSetShaderResources(self: ID3D11DeviceContext, start: UINT, num: UINT, views: ?[*]const ?ID3D11ShaderResourceView) void {
        self.vtable.PSSetShaderResources(@ptrCast(self), start, num, views);
    }

    pub fn PSSetShader(self: ID3D11DeviceContext, shader: ?ID3D11PixelShader) void {
        self.vtable.PSSetShader(@ptrCast(self), shader, null, 0);
    }

    pub fn PSSetSamplers(self: ID3D11DeviceContext, start: UINT, num: UINT, samplers: ?[*]const ?ID3D11SamplerState) void {
        self.vtable.PSSetSamplers(@ptrCast(self), start, num, samplers);
    }

    pub fn VSSetShader(self: ID3D11DeviceContext, shader: ?ID3D11VertexShader) void {
        self.vtable.VSSetShader(@ptrCast(self), shader, null, 0);
    }

    pub fn Draw(self: ID3D11DeviceContext, vertex_count: UINT, start: UINT) void {
        self.vtable.Draw(@ptrCast(self), vertex_count, start);
    }

    pub fn Map(self: ID3D11DeviceContext, resource: *anyopaque, subresource: UINT, map_type: D3D11_MAP, flags: UINT, mapped: *D3D11_MAPPED_SUBRESOURCE) HRESULT {
        return self.vtable.Map(@ptrCast(self), resource, subresource, map_type, flags, mapped);
    }

    pub fn Unmap(self: ID3D11DeviceContext, resource: *anyopaque, subresource: UINT) void {
        self.vtable.Unmap(@ptrCast(self), resource, subresource);
    }

    pub fn PSSetConstantBuffers(self: ID3D11DeviceContext, start: UINT, num: UINT, buffers: ?[*]const ?ID3D11Buffer) void {
        self.vtable.PSSetConstantBuffers(@ptrCast(self), start, num, buffers);
    }

    pub fn IASetInputLayout(self: ID3D11DeviceContext, layout: ?ID3D11InputLayout) void {
        self.vtable.IASetInputLayout(@ptrCast(self), layout);
    }

    pub fn IASetVertexBuffers(self: ID3D11DeviceContext, start: UINT, num: UINT, buffers: ?[*]const ?ID3D11Buffer, strides: ?[*]const UINT, offsets: ?[*]const UINT) void {
        self.vtable.IASetVertexBuffers(@ptrCast(self), start, num, buffers, strides, offsets);
    }

    pub fn DrawInstanced(self: ID3D11DeviceContext, vertex_count: UINT, instance_count: UINT, start_vertex: UINT, start_instance: UINT) void {
        self.vtable.DrawInstanced(@ptrCast(self), vertex_count, instance_count, start_vertex, start_instance);
    }

    pub fn IASetPrimitiveTopology(self: ID3D11DeviceContext, topology: D3D11_PRIMITIVE_TOPOLOGY) void {
        self.vtable.IASetPrimitiveTopology(@ptrCast(self), topology);
    }

    pub fn VSSetShaderResources(self: ID3D11DeviceContext, start: UINT, num: UINT, views: ?[*]const ?ID3D11ShaderResourceView) void {
        self.vtable.VSSetShaderResources(@ptrCast(self), start, num, views);
    }

    pub fn VSSetSamplers(self: ID3D11DeviceContext, start: UINT, num: UINT, samplers: ?[*]const ?ID3D11SamplerState) void {
        self.vtable.VSSetSamplers(@ptrCast(self), start, num, samplers);
    }

    pub fn OMSetRenderTargets(self: ID3D11DeviceContext, num: UINT, targets: ?[*]const ?ID3D11RenderTargetView, dsv: ?*anyopaque) void {
        self.vtable.OMSetRenderTargets(@ptrCast(self), num, targets, dsv);
    }

    pub fn OMSetBlendState(self: ID3D11DeviceContext, state: ?ID3D11BlendState, factor: ?*const [4]FLOAT, mask: UINT) void {
        self.vtable.OMSetBlendState(@ptrCast(self), state, factor, mask);
    }

    pub fn RSSetViewports(self: ID3D11DeviceContext, num: UINT, viewports: ?[*]const D3D11_VIEWPORT) void {
        self.vtable.RSSetViewports(@ptrCast(self), num, viewports);
    }

    pub fn CopyResource(self: ID3D11DeviceContext, dst: *anyopaque, src: *anyopaque) void {
        self.vtable.CopyResource(@ptrCast(self), dst, src);
    }

    pub fn UpdateSubresource(self: ID3D11DeviceContext, resource: *anyopaque, subresource: UINT, box: ?*const D3D11_BOX, data: *const anyopaque, row_pitch: UINT, depth_pitch: UINT) void {
        self.vtable.UpdateSubresource(@ptrCast(self), resource, subresource, box, data, row_pitch, depth_pitch);
    }

    pub fn ClearRenderTargetView(self: ID3D11DeviceContext, view: ID3D11RenderTargetView, color: *const [4]FLOAT) void {
        self.vtable.ClearRenderTargetView(@ptrCast(self), view, color);
    }

    pub fn ClearState(self: ID3D11DeviceContext) void {
        self.vtable.ClearState(@ptrCast(self));
    }

    pub fn Flush(self: ID3D11DeviceContext) void {
        self.vtable.Flush(@ptrCast(self));
    }

    pub fn Release(self: ID3D11DeviceContext) u32 {
        return self.vtable.Release(@ptrCast(self));
    }
};

// ----------------------------------------------------------------------------
// ID3D11 Resource types (thin opaque wrappers with Release)
// ----------------------------------------------------------------------------

pub const ID3D11Buffer = *extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        // IUnknown
        QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*anyopaque) callconv(.c) u32,
        Release: *const fn (*anyopaque) callconv(.c) u32,
        // ID3D11DeviceChild
        GetDevice: *const fn (*anyopaque, *?*anyopaque) callconv(.c) void,
        GetPrivateData: *const fn (*anyopaque, *const GUID, *UINT, ?*anyopaque) callconv(.c) HRESULT,
        SetPrivateData: *const fn (*anyopaque, *const GUID, UINT, ?*const anyopaque) callconv(.c) HRESULT,
        SetPrivateDataInterface: *const fn (*anyopaque, *const GUID, ?*const anyopaque) callconv(.c) HRESULT,
        // ID3D11Resource
        GetType: *const fn (*anyopaque, *UINT) callconv(.c) void,
        SetEvictionPriority: *const fn (*anyopaque, UINT) callconv(.c) void,
        GetEvictionPriority: *const fn (*anyopaque) callconv(.c) UINT,
        // ID3D11Buffer
        GetDesc: *const fn (*anyopaque, *D3D11_BUFFER_DESC) callconv(.c) void,
    };

    pub fn Release(self: ID3D11Buffer) u32 {
        return self.vtable.Release(@ptrCast(self));
    }
};

pub const ID3D11Texture2D = *extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        // IUnknown
        QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*anyopaque) callconv(.c) u32,
        Release: *const fn (*anyopaque) callconv(.c) u32,
        // ID3D11DeviceChild
        GetDevice: *const fn (*anyopaque, *?*anyopaque) callconv(.c) void,
        GetPrivateData: *const fn (*anyopaque, *const GUID, *UINT, ?*anyopaque) callconv(.c) HRESULT,
        SetPrivateData: *const fn (*anyopaque, *const GUID, UINT, ?*const anyopaque) callconv(.c) HRESULT,
        SetPrivateDataInterface: *const fn (*anyopaque, *const GUID, ?*const anyopaque) callconv(.c) HRESULT,
        // ID3D11Resource
        GetType: *const fn (*anyopaque, *UINT) callconv(.c) void,
        SetEvictionPriority: *const fn (*anyopaque, UINT) callconv(.c) void,
        GetEvictionPriority: *const fn (*anyopaque) callconv(.c) UINT,
        // ID3D11Texture2D
        GetDesc: *const fn (*anyopaque, *D3D11_TEXTURE2D_DESC) callconv(.c) void,
    };

    pub fn Release(self: ID3D11Texture2D) u32 {
        return self.vtable.Release(@ptrCast(self));
    }
};

pub const ID3D11RenderTargetView = *extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*anyopaque) callconv(.c) u32,
        Release: *const fn (*anyopaque) callconv(.c) u32,
        // ID3D11DeviceChild
        GetDevice: *const fn (*anyopaque, *?*anyopaque) callconv(.c) void,
        GetPrivateData: *const fn (*anyopaque, *const GUID, *UINT, ?*anyopaque) callconv(.c) HRESULT,
        SetPrivateData: *const fn (*anyopaque, *const GUID, UINT, ?*const anyopaque) callconv(.c) HRESULT,
        SetPrivateDataInterface: *const fn (*anyopaque, *const GUID, ?*const anyopaque) callconv(.c) HRESULT,
        // ID3D11View
        GetResource: *const fn (*anyopaque, *?*anyopaque) callconv(.c) void,
        // ID3D11RenderTargetView
        GetDesc: *const fn (*anyopaque, *D3D11_RENDER_TARGET_VIEW_DESC) callconv(.c) void,
    };

    pub fn Release(self: ID3D11RenderTargetView) u32 {
        return self.vtable.Release(@ptrCast(self));
    }
};

pub const ID3D11ShaderResourceView = *extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*anyopaque) callconv(.c) u32,
        Release: *const fn (*anyopaque) callconv(.c) u32,
        // ID3D11DeviceChild
        GetDevice: *const fn (*anyopaque, *?*anyopaque) callconv(.c) void,
        GetPrivateData: *const fn (*anyopaque, *const GUID, *UINT, ?*anyopaque) callconv(.c) HRESULT,
        SetPrivateData: *const fn (*anyopaque, *const GUID, UINT, ?*const anyopaque) callconv(.c) HRESULT,
        SetPrivateDataInterface: *const fn (*anyopaque, *const GUID, ?*const anyopaque) callconv(.c) HRESULT,
        // ID3D11View
        GetResource: *const fn (*anyopaque, *?*anyopaque) callconv(.c) void,
        // ID3D11ShaderResourceView
        GetDesc: *const fn (*anyopaque, *D3D11_SHADER_RESOURCE_VIEW_DESC) callconv(.c) void,
    };

    pub fn Release(self: ID3D11ShaderResourceView) u32 {
        return self.vtable.Release(@ptrCast(self));
    }
};

pub const ID3D11VertexShader = *extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*anyopaque) callconv(.c) u32,
        Release: *const fn (*anyopaque) callconv(.c) u32,
        GetDevice: *const fn (*anyopaque, *?*anyopaque) callconv(.c) void,
        GetPrivateData: *const fn (*anyopaque, *const GUID, *UINT, ?*anyopaque) callconv(.c) HRESULT,
        SetPrivateData: *const fn (*anyopaque, *const GUID, UINT, ?*const anyopaque) callconv(.c) HRESULT,
        SetPrivateDataInterface: *const fn (*anyopaque, *const GUID, ?*const anyopaque) callconv(.c) HRESULT,
    };
    pub fn Release(self: ID3D11VertexShader) u32 {
        return self.vtable.Release(@ptrCast(self));
    }
};

pub const ID3D11PixelShader = *extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*anyopaque) callconv(.c) u32,
        Release: *const fn (*anyopaque) callconv(.c) u32,
        GetDevice: *const fn (*anyopaque, *?*anyopaque) callconv(.c) void,
        GetPrivateData: *const fn (*anyopaque, *const GUID, *UINT, ?*anyopaque) callconv(.c) HRESULT,
        SetPrivateData: *const fn (*anyopaque, *const GUID, UINT, ?*const anyopaque) callconv(.c) HRESULT,
        SetPrivateDataInterface: *const fn (*anyopaque, *const GUID, ?*const anyopaque) callconv(.c) HRESULT,
    };
    pub fn Release(self: ID3D11PixelShader) u32 {
        return self.vtable.Release(@ptrCast(self));
    }
};

pub const ID3D11InputLayout = *extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*anyopaque) callconv(.c) u32,
        Release: *const fn (*anyopaque) callconv(.c) u32,
        GetDevice: *const fn (*anyopaque, *?*anyopaque) callconv(.c) void,
        GetPrivateData: *const fn (*anyopaque, *const GUID, *UINT, ?*anyopaque) callconv(.c) HRESULT,
        SetPrivateData: *const fn (*anyopaque, *const GUID, UINT, ?*const anyopaque) callconv(.c) HRESULT,
        SetPrivateDataInterface: *const fn (*anyopaque, *const GUID, ?*const anyopaque) callconv(.c) HRESULT,
    };
    pub fn Release(self: ID3D11InputLayout) u32 {
        return self.vtable.Release(@ptrCast(self));
    }
};

pub const ID3D11BlendState = *extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*anyopaque) callconv(.c) u32,
        Release: *const fn (*anyopaque) callconv(.c) u32,
        GetDevice: *const fn (*anyopaque, *?*anyopaque) callconv(.c) void,
        GetPrivateData: *const fn (*anyopaque, *const GUID, *UINT, ?*anyopaque) callconv(.c) HRESULT,
        SetPrivateData: *const fn (*anyopaque, *const GUID, UINT, ?*const anyopaque) callconv(.c) HRESULT,
        SetPrivateDataInterface: *const fn (*anyopaque, *const GUID, ?*const anyopaque) callconv(.c) HRESULT,
        GetDesc: *const fn (*anyopaque, *D3D11_BLEND_DESC) callconv(.c) void,
    };
    pub fn Release(self: ID3D11BlendState) u32 {
        return self.vtable.Release(@ptrCast(self));
    }
};

pub const ID3D11SamplerState = *extern struct {
    vtable: *const VTable,
    const VTable = extern struct {
        QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*anyopaque) callconv(.c) u32,
        Release: *const fn (*anyopaque) callconv(.c) u32,
        GetDevice: *const fn (*anyopaque, *?*anyopaque) callconv(.c) void,
        GetPrivateData: *const fn (*anyopaque, *const GUID, *UINT, ?*anyopaque) callconv(.c) HRESULT,
        SetPrivateData: *const fn (*anyopaque, *const GUID, UINT, ?*const anyopaque) callconv(.c) HRESULT,
        SetPrivateDataInterface: *const fn (*anyopaque, *const GUID, ?*const anyopaque) callconv(.c) HRESULT,
        GetDesc: *const fn (*anyopaque, *D3D11_SAMPLER_DESC) callconv(.c) void,
    };
    pub fn Release(self: ID3D11SamplerState) u32 {
        return self.vtable.Release(@ptrCast(self));
    }
};

// ----------------------------------------------------------------------------
// IDXGISwapChain
// ----------------------------------------------------------------------------

pub const IDXGISwapChain = *extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        // IUnknown (3)
        QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*anyopaque) callconv(.c) u32,
        Release: *const fn (*anyopaque) callconv(.c) u32,
        // IDXGIObject (4)
        SetPrivateData: *const fn (*anyopaque, *const GUID, UINT, ?*const anyopaque) callconv(.c) HRESULT,
        SetPrivateDataInterface: *const fn (*anyopaque, *const GUID, ?*const anyopaque) callconv(.c) HRESULT,
        GetPrivateData: *const fn (*anyopaque, *const GUID, *UINT, ?*anyopaque) callconv(.c) HRESULT,
        GetParent: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        // IDXGIDeviceSubObject (1)
        GetDevice: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        // IDXGISwapChain
        Present: *const fn (*anyopaque, UINT, UINT) callconv(.c) HRESULT,
        GetBuffer: *const fn (*anyopaque, UINT, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        SetFullscreenState: *const fn (*anyopaque, BOOL, ?*anyopaque) callconv(.c) HRESULT,
        GetFullscreenState: *const fn (*anyopaque, ?*BOOL, ?*?*anyopaque) callconv(.c) HRESULT,
        GetDesc: *const fn (*anyopaque, *DXGI_SWAP_CHAIN_DESC) callconv(.c) HRESULT,
        ResizeBuffers: *const fn (*anyopaque, UINT, UINT, UINT, DXGI_FORMAT, UINT) callconv(.c) HRESULT,
        ResizeTarget: *const fn (*anyopaque, *const DXGI_MODE_DESC) callconv(.c) HRESULT,
        GetContainingOutput: *const fn (*anyopaque, *?*anyopaque) callconv(.c) HRESULT,
        GetFrameStatistics: *const fn (*anyopaque, *anyopaque) callconv(.c) HRESULT,
        GetLastPresentCount: *const fn (*anyopaque, *UINT) callconv(.c) HRESULT,
    };

    pub fn Present(self: IDXGISwapChain, sync_interval: UINT, flags: UINT) HRESULT {
        return self.vtable.Present(@ptrCast(self), sync_interval, flags);
    }

    pub fn GetBuffer(self: IDXGISwapChain, buffer_index: UINT, riid: *const GUID, surface: *?*anyopaque) HRESULT {
        return self.vtable.GetBuffer(@ptrCast(self), buffer_index, riid, surface);
    }

    pub fn ResizeBuffers(self: IDXGISwapChain, count: UINT, width: UINT, height: UINT, format: DXGI_FORMAT, flags: UINT) HRESULT {
        return self.vtable.ResizeBuffers(@ptrCast(self), count, width, height, format, flags);
    }

    pub fn Release(self: IDXGISwapChain) u32 {
        return self.vtable.Release(@ptrCast(self));
    }
};

// ============================================================================
// Extern function declarations
// ============================================================================

pub extern "d3d11" fn D3D11CreateDeviceAndSwapChain(
    pAdapter: ?*anyopaque,
    DriverType: D3D_DRIVER_TYPE,
    Software: ?HMODULE,
    Flags: D3D11_CREATE_DEVICE_FLAG,
    pFeatureLevels: ?[*]const D3D_FEATURE_LEVEL,
    FeatureLevels: UINT,
    SDKVersion: UINT,
    pSwapChainDesc: ?*const DXGI_SWAP_CHAIN_DESC,
    ppSwapChain: ?*?IDXGISwapChain,
    ppDevice: ?*?ID3D11Device,
    pFeatureLevel: ?*D3D_FEATURE_LEVEL,
    ppImmediateContext: ?*?ID3D11DeviceContext,
) callconv(.c) HRESULT;

pub extern "d3dcompiler_47" fn D3DCompile(
    pSrcData: [*]const u8,
    SrcDataSize: SIZE_T,
    pSourceName: ?LPCSTR,
    pDefines: ?*const anyopaque,
    pInclude: ?*anyopaque,
    pEntrypoint: LPCSTR,
    pTarget: LPCSTR,
    Flags1: DWORD,
    Flags2: DWORD,
    ppCode: *?ID3DBlob,
    ppErrorMsgs: *?ID3DBlob,
) callconv(.c) HRESULT;

/// D3D11 SDK version constant.
pub const D3D11_SDK_VERSION: UINT = 7;
