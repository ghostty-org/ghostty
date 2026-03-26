const std = @import("std");

/// COM GUID (Globally Unique Identifier).
pub const GUID = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};

/// COM HRESULT return type.
pub const HRESULT = i32;

/// Returns true if the HRESULT indicates success (non-negative).
pub inline fn SUCCEEDED(hr: HRESULT) bool {
    return hr >= 0;
}

/// Returns true if the HRESULT indicates failure (negative).
pub inline fn FAILED(hr: HRESULT) bool {
    return hr < 0;
}

pub const S_OK: HRESULT = 0;
pub const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
pub const E_FAIL: HRESULT = @bitCast(@as(u32, 0x80004005));
pub const DXGI_ERROR_DEVICE_REMOVED: HRESULT = @bitCast(@as(u32, 0x887A0005));

/// IUnknown — base COM interface that all COM objects implement.
pub const IUnknown = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (
            self: *IUnknown,
            riid: *const GUID,
            ppvObject: *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        AddRef: *const fn (self: *IUnknown) callconv(.winapi) u32,
        Release: *const fn (self: *IUnknown) callconv(.winapi) u32,
    };

    pub inline fn Release(self: *IUnknown) u32 {
        return self.vtable.Release(self);
    }

    pub inline fn AddRef(self: *IUnknown) u32 {
        return self.vtable.AddRef(self);
    }

    pub inline fn QueryInterface(
        self: *IUnknown,
        riid: *const GUID,
        ppvObject: *?*anyopaque,
    ) HRESULT {
        return self.vtable.QueryInterface(self, riid, ppvObject);
    }
};

/// Stub vtable entry for COM methods not yet wrapped.
pub const Reserved = *const fn () callconv(.winapi) void;
