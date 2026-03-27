const com = @import("com.zig");
const GUID = com.GUID;
const HRESULT = com.HRESULT;
const IUnknown = com.IUnknown;

// --- Enums ---

pub const DXGI_FORMAT = enum(u32) {
    UNKNOWN = 0,
    R32G32B32A32_FLOAT = 2,
    R32_UINT = 42,
    R8G8B8A8_UNORM = 28,
    B8G8R8A8_UNORM = 87,
    _,
};

pub const DXGI_SWAP_EFFECT = enum(u32) {
    DISCARD = 0,
    SEQUENTIAL = 1,
    FLIP_SEQUENTIAL = 3,
    FLIP_DISCARD = 4,
};

pub const DXGI_SCALING = enum(u32) {
    STRETCH = 0,
    NONE = 1,
    ASPECT_RATIO_STRETCH = 2,
};

pub const DXGI_ALPHA_MODE = enum(u32) {
    UNSPECIFIED = 0,
    PREMULTIPLIED = 1,
    STRAIGHT = 2,
    IGNORE = 3,
};

pub const DXGI_USAGE = u32;
pub const DXGI_USAGE_RENDER_TARGET_OUTPUT: DXGI_USAGE = 0x00000020;

// --- Structs ---

pub const DXGI_SAMPLE_DESC = extern struct {
    Count: u32,
    Quality: u32,
};

pub const DXGI_SWAP_CHAIN_DESC1 = extern struct {
    Width: u32,
    Height: u32,
    Format: DXGI_FORMAT,
    Stereo: i32, // BOOL
    SampleDesc: DXGI_SAMPLE_DESC,
    BufferUsage: DXGI_USAGE,
    BufferCount: u32,
    Scaling: DXGI_SCALING,
    SwapEffect: DXGI_SWAP_EFFECT,
    AlphaMode: DXGI_ALPHA_MODE,
    Flags: u32,
};

pub const DXGI_MATRIX_3X2_F = extern struct {
    _11: f32,
    _12: f32,
    _21: f32,
    _22: f32,
    _31: f32,
    _32: f32,
};

const Reserved = com.Reserved;

// =============================================================================
// IDXGIObject — 7 methods total (3 IUnknown + 4 own)
// =============================================================================
pub const IDXGIObject = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (slots 0-2)
        QueryInterface: *const fn (*IDXGIObject, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IDXGIObject) callconv(.winapi) u32,
        Release: *const fn (*IDXGIObject) callconv(.winapi) u32,
        // IDXGIObject (slots 3-6)
        SetPrivateData: Reserved,
        SetPrivateDataInterface: Reserved,
        GetPrivateData: Reserved,
        GetParent: *const fn (*IDXGIObject, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    };
};

// =============================================================================
// IDXGIDeviceSubObject — 8 methods total (7 IDXGIObject + 1 own)
// =============================================================================
pub const IDXGIDeviceSubObject = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (slots 0-2)
        QueryInterface: Reserved,
        AddRef: Reserved,
        Release: Reserved,
        // IDXGIObject (slots 3-6)
        SetPrivateData: Reserved,
        SetPrivateDataInterface: Reserved,
        GetPrivateData: Reserved,
        GetParent: Reserved,
        // IDXGIDeviceSubObject (slot 7)
        GetDevice: Reserved,
    };
};

// =============================================================================
// IDXGISwapChain — 18 methods total (8 IDXGIDeviceSubObject + 10 own)
// Slots we call: Present (8), GetBuffer (9)
// =============================================================================
pub const IDXGISwapChain = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (slots 0-2)
        QueryInterface: *const fn (*IDXGISwapChain, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IDXGISwapChain) callconv(.winapi) u32,
        Release: *const fn (*IDXGISwapChain) callconv(.winapi) u32,
        // IDXGIObject (slots 3-6)
        SetPrivateData: Reserved,
        SetPrivateDataInterface: Reserved,
        GetPrivateData: Reserved,
        GetParent: Reserved,
        // IDXGIDeviceSubObject (slot 7)
        GetDevice: Reserved,
        // IDXGISwapChain (slots 8-17)
        Present: *const fn (*IDXGISwapChain, SyncInterval: u32, Flags: u32) callconv(.winapi) HRESULT,
        GetBuffer: *const fn (*IDXGISwapChain, Buffer: u32, riid: *const GUID, ppSurface: *?*anyopaque) callconv(.winapi) HRESULT,
        SetFullscreenState: Reserved,
        GetFullscreenState: Reserved,
        GetDesc: Reserved,
        ResizeBuffers: Reserved,
        ResizeTarget: Reserved,
        GetContainingOutput: Reserved,
        GetFrameStatistics: Reserved,
        GetLastPresentCount: Reserved,
    };

    pub inline fn Present(self: *IDXGISwapChain, sync_interval: u32, flags: u32) HRESULT {
        return self.vtable.Present(self, sync_interval, flags);
    }

    pub inline fn GetBuffer(self: *IDXGISwapChain, buffer: u32, riid: *const GUID, surface: *?*anyopaque) HRESULT {
        return self.vtable.GetBuffer(self, buffer, riid, surface);
    }

    pub inline fn Release(self: *IDXGISwapChain) u32 {
        return self.vtable.Release(self);
    }
};

// =============================================================================
// IDXGISwapChain1 — 29 methods total (18 IDXGISwapChain + 11 own)
// =============================================================================
pub const IDXGISwapChain1 = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (slots 0-2)
        QueryInterface: *const fn (*IDXGISwapChain1, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IDXGISwapChain1) callconv(.winapi) u32,
        Release: *const fn (*IDXGISwapChain1) callconv(.winapi) u32,
        // IDXGIObject (slots 3-6)
        SetPrivateData: Reserved,
        SetPrivateDataInterface: Reserved,
        GetPrivateData: Reserved,
        GetParent: Reserved,
        // IDXGIDeviceSubObject (slot 7)
        GetDevice: Reserved,
        // IDXGISwapChain (slots 8-17)
        Present: *const fn (*IDXGISwapChain1, u32, u32) callconv(.winapi) HRESULT,
        GetBuffer: *const fn (*IDXGISwapChain1, u32, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        SetFullscreenState: Reserved,
        GetFullscreenState: Reserved,
        GetDesc: Reserved,
        ResizeBuffers: *const fn (*IDXGISwapChain1, u32, u32, u32, DXGI_FORMAT, u32) callconv(.winapi) HRESULT,
        ResizeTarget: Reserved,
        GetContainingOutput: Reserved,
        GetFrameStatistics: Reserved,
        GetLastPresentCount: Reserved,
        // IDXGISwapChain1 (slots 18-28)
        GetDesc1: Reserved,
        GetFullscreenDesc: Reserved,
        GetHwnd: Reserved,
        GetCoreWindow: Reserved,
        Present1: Reserved,
        IsTemporaryMonoSupported: Reserved,
        GetRestrictToOutput: Reserved,
        SetBackgroundColor: Reserved,
        GetBackgroundColor: Reserved,
        SetRotation: Reserved,
        GetRotation: Reserved,
    };

    pub inline fn Present(self: *IDXGISwapChain1, sync_interval: u32, flags: u32) HRESULT {
        return self.vtable.Present(self, sync_interval, flags);
    }

    pub inline fn GetBuffer(self: *IDXGISwapChain1, buffer: u32, riid: *const GUID, surface: *?*anyopaque) HRESULT {
        return self.vtable.GetBuffer(self, buffer, riid, surface);
    }

    pub inline fn ResizeBuffers(self: *IDXGISwapChain1, buffer_count: u32, width: u32, height: u32, format: DXGI_FORMAT, flags: u32) HRESULT {
        return self.vtable.ResizeBuffers(self, buffer_count, width, height, format, flags);
    }

    pub inline fn Release(self: *IDXGISwapChain1) u32 {
        return self.vtable.Release(self);
    }
};

// =============================================================================
// IDXGISwapChain2 — 36 methods total (29 IDXGISwapChain1 + 7 own)
// Slot we call: SetMatrixTransform (34)
// =============================================================================
pub const IDXGISwapChain2 = extern struct {
    vtable: *const VTable,

    pub const IID = GUID{
        .data1 = 0xa8be2ac4,
        .data2 = 0x199f,
        .data3 = 0x4946,
        .data4 = .{ 0xb3, 0x31, 0x79, 0x59, 0x9f, 0xb9, 0x8d, 0xe7 },
    };

    pub const VTable = extern struct {
        // IUnknown (slots 0-2)
        QueryInterface: *const fn (*IDXGISwapChain2, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IDXGISwapChain2) callconv(.winapi) u32,
        Release: *const fn (*IDXGISwapChain2) callconv(.winapi) u32,
        // IDXGIObject (slots 3-6)
        SetPrivateData: Reserved,
        SetPrivateDataInterface: Reserved,
        GetPrivateData: Reserved,
        GetParent: Reserved,
        // IDXGIDeviceSubObject (slot 7)
        GetDevice: Reserved,
        // IDXGISwapChain (slots 8-17)
        Present: *const fn (*IDXGISwapChain2, u32, u32) callconv(.winapi) HRESULT,
        GetBuffer: *const fn (*IDXGISwapChain2, u32, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        SetFullscreenState: Reserved,
        GetFullscreenState: Reserved,
        GetDesc: Reserved,
        ResizeBuffers: Reserved,
        ResizeTarget: Reserved,
        GetContainingOutput: Reserved,
        GetFrameStatistics: Reserved,
        GetLastPresentCount: Reserved,
        // IDXGISwapChain1 (slots 18-28)
        GetDesc1: Reserved,
        GetFullscreenDesc: Reserved,
        GetHwnd: Reserved,
        GetCoreWindow: Reserved,
        Present1: Reserved,
        IsTemporaryMonoSupported: Reserved,
        GetRestrictToOutput: Reserved,
        SetBackgroundColor: Reserved,
        GetBackgroundColor: Reserved,
        SetRotation: Reserved,
        GetRotation: Reserved,
        // IDXGISwapChain2 (slots 29-35)
        SetSourceSize: Reserved,
        GetSourceSize: Reserved,
        SetMaximumFrameLatency: Reserved,
        GetMaximumFrameLatency: Reserved,
        GetFrameLatencyWaitableObject: Reserved,
        SetMatrixTransform: *const fn (*IDXGISwapChain2, *const DXGI_MATRIX_3X2_F) callconv(.winapi) HRESULT,
        GetMatrixTransform: Reserved,
    };

    pub inline fn Present(self: *IDXGISwapChain2, sync_interval: u32, flags: u32) HRESULT {
        return self.vtable.Present(self, sync_interval, flags);
    }

    pub inline fn GetBuffer(self: *IDXGISwapChain2, buffer: u32, riid: *const GUID, surface: *?*anyopaque) HRESULT {
        return self.vtable.GetBuffer(self, buffer, riid, surface);
    }

    pub inline fn SetMatrixTransform(self: *IDXGISwapChain2, matrix: *const DXGI_MATRIX_3X2_F) HRESULT {
        return self.vtable.SetMatrixTransform(self, matrix);
    }

    pub inline fn Release(self: *IDXGISwapChain2) u32 {
        return self.vtable.Release(self);
    }
};

// =============================================================================
// IDXGIDevice — 11 methods total (7 IDXGIObject + 4 own)
// Slot we call: GetAdapter (slot 7)
// =============================================================================
pub const IDXGIDevice = extern struct {
    vtable: *const VTable,

    pub const IID = GUID{
        .data1 = 0x54ec77fa,
        .data2 = 0x1377,
        .data3 = 0x44e6,
        .data4 = .{ 0x8c, 0x32, 0x88, 0xfd, 0x5f, 0x44, 0xc8, 0x4c },
    };

    pub const VTable = extern struct {
        // IUnknown (slots 0-2)
        QueryInterface: *const fn (*IDXGIDevice, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IDXGIDevice) callconv(.winapi) u32,
        Release: *const fn (*IDXGIDevice) callconv(.winapi) u32,
        // IDXGIObject (slots 3-6)
        SetPrivateData: Reserved,
        SetPrivateDataInterface: Reserved,
        GetPrivateData: Reserved,
        GetParent: Reserved,
        // IDXGIDevice (slots 7-10)
        GetAdapter: *const fn (*IDXGIDevice, ppAdapter: *?*IDXGIAdapter) callconv(.winapi) HRESULT,
        CreateSurface: Reserved,
        QueryResourceResidency: Reserved,
        SetGPUThreadPriority: Reserved,
    };

    pub inline fn GetAdapter(self: *IDXGIDevice, adapter: *?*IDXGIAdapter) HRESULT {
        return self.vtable.GetAdapter(self, adapter);
    }

    pub inline fn Release(self: *IDXGIDevice) u32 {
        return self.vtable.Release(self);
    }
};

// =============================================================================
// IDXGIAdapter — 10 methods total (7 IDXGIObject + 3 own)
// Slot we call: GetParent (slot 6, inherited from IDXGIObject)
// =============================================================================
pub const IDXGIAdapter = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (slots 0-2)
        QueryInterface: *const fn (*IDXGIAdapter, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IDXGIAdapter) callconv(.winapi) u32,
        Release: *const fn (*IDXGIAdapter) callconv(.winapi) u32,
        // IDXGIObject (slots 3-6)
        SetPrivateData: Reserved,
        SetPrivateDataInterface: Reserved,
        GetPrivateData: Reserved,
        GetParent: *const fn (*IDXGIAdapter, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        // IDXGIAdapter (slots 7-9)
        EnumOutputs: Reserved,
        GetDesc: Reserved,
        CheckInterfaceSupport: Reserved,
    };

    pub inline fn GetParent(self: *IDXGIAdapter, riid: *const GUID, parent: *?*anyopaque) HRESULT {
        return self.vtable.GetParent(self, riid, parent);
    }

    pub inline fn Release(self: *IDXGIAdapter) u32 {
        return self.vtable.Release(self);
    }
};

// =============================================================================
// IDXGIFactory — 12 methods total (7 IDXGIObject + 5 own)
// =============================================================================
pub const IDXGIFactory = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (slots 0-2)
        QueryInterface: Reserved,
        AddRef: Reserved,
        Release: Reserved,
        // IDXGIObject (slots 3-6)
        SetPrivateData: Reserved,
        SetPrivateDataInterface: Reserved,
        GetPrivateData: Reserved,
        GetParent: Reserved,
        // IDXGIFactory (slots 7-11)
        EnumAdapters: Reserved,
        MakeWindowAssociation: Reserved,
        GetWindowAssociation: Reserved,
        CreateSwapChain: Reserved,
        CreateSoftwareAdapter: Reserved,
    };
};

// =============================================================================
// IDXGIFactory1 — 14 methods total (12 IDXGIFactory + 2 own)
// =============================================================================
pub const IDXGIFactory1 = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (slots 0-2)
        QueryInterface: Reserved,
        AddRef: Reserved,
        Release: Reserved,
        // IDXGIObject (slots 3-6)
        SetPrivateData: Reserved,
        SetPrivateDataInterface: Reserved,
        GetPrivateData: Reserved,
        GetParent: Reserved,
        // IDXGIFactory (slots 7-11)
        EnumAdapters: Reserved,
        MakeWindowAssociation: Reserved,
        GetWindowAssociation: Reserved,
        CreateSwapChain: Reserved,
        CreateSoftwareAdapter: Reserved,
        // IDXGIFactory1 (slots 12-13)
        EnumAdapters1: Reserved,
        IsCurrent: Reserved,
    };
};

// =============================================================================
// IDXGIFactory2 — 25 methods total (14 IDXGIFactory1 + 11 own)
// Slot we call: CreateSwapChainForComposition (slot 24)
// =============================================================================
pub const IDXGIFactory2 = extern struct {
    vtable: *const VTable,

    pub const IID = GUID{
        .data1 = 0x50c83a1c,
        .data2 = 0xe072,
        .data3 = 0x4c48,
        .data4 = .{ 0x87, 0xb0, 0x36, 0x30, 0xfa, 0x36, 0xa6, 0xd0 },
    };

    pub const VTable = extern struct {
        // IUnknown (slots 0-2)
        QueryInterface: *const fn (*IDXGIFactory2, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IDXGIFactory2) callconv(.winapi) u32,
        Release: *const fn (*IDXGIFactory2) callconv(.winapi) u32,
        // IDXGIObject (slots 3-6)
        SetPrivateData: Reserved,
        SetPrivateDataInterface: Reserved,
        GetPrivateData: Reserved,
        GetParent: Reserved,
        // IDXGIFactory (slots 7-11)
        EnumAdapters: Reserved,
        MakeWindowAssociation: Reserved,
        GetWindowAssociation: Reserved,
        CreateSwapChain: Reserved,
        CreateSoftwareAdapter: Reserved,
        // IDXGIFactory1 (slots 12-13)
        EnumAdapters1: Reserved,
        IsCurrent: Reserved,
        // IDXGIFactory2 (slots 14-24)
        IsWindowedStereoEnabled: Reserved,
        CreateSwapChainForHwnd: Reserved,
        CreateSwapChainForCoreWindow: Reserved,
        GetSharedResourceAdapterLuid: Reserved,
        RegisterStereoStatusWindow: Reserved,
        RegisterStereoStatusEvent: Reserved,
        UnregisterStereoStatus: Reserved,
        RegisterOcclusionStatusWindow: Reserved,
        RegisterOcclusionStatusEvent: Reserved,
        UnregisterOcclusionStatus: Reserved,
        CreateSwapChainForComposition: *const fn (
            self: *IDXGIFactory2,
            pDevice: *IUnknown,
            pDesc: *const DXGI_SWAP_CHAIN_DESC1,
            pRestrictToOutput: ?*anyopaque, // IDXGIOutput, nullable
            ppSwapChain: *?*IDXGISwapChain1,
        ) callconv(.winapi) HRESULT,
    };

    pub inline fn CreateSwapChainForComposition(
        self: *IDXGIFactory2,
        device: *IUnknown,
        desc: *const DXGI_SWAP_CHAIN_DESC1,
        restrict_to_output: ?*anyopaque,
        swap_chain: *?*IDXGISwapChain1,
    ) HRESULT {
        return self.vtable.CreateSwapChainForComposition(self, device, desc, restrict_to_output, swap_chain);
    }

    pub inline fn Release(self: *IDXGIFactory2) u32 {
        return self.vtable.Release(self);
    }
};

// =============================================================================
// ISwapChainPanelNative — 4 methods total (3 IUnknown + 1 own)
// Slot we call: SetSwapChain (slot 3)
// =============================================================================
pub const ISwapChainPanelNative = extern struct {
    vtable: *const VTable,

    pub const IID = GUID{
        .data1 = 0xf92f19d2,
        .data2 = 0x3ade,
        .data3 = 0x45a6,
        .data4 = .{ 0xa2, 0x0c, 0xf6, 0xf1, 0xea, 0x90, 0x55, 0x4b },
    };

    pub const VTable = extern struct {
        // IUnknown (slots 0-2)
        QueryInterface: *const fn (*ISwapChainPanelNative, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ISwapChainPanelNative) callconv(.winapi) u32,
        Release: *const fn (*ISwapChainPanelNative) callconv(.winapi) u32,
        // ISwapChainPanelNative (slot 3)
        SetSwapChain: *const fn (*ISwapChainPanelNative, ?*IDXGISwapChain) callconv(.winapi) HRESULT,
    };

    pub inline fn SetSwapChain(self: *ISwapChainPanelNative, swap_chain: ?*IDXGISwapChain) HRESULT {
        return self.vtable.SetSwapChain(self, swap_chain);
    }

    pub inline fn Release(self: *ISwapChainPanelNative) u32 {
        return self.vtable.Release(self);
    }
};
