/// DirectWrite COM interface definitions for font discovery on Windows.
///
/// Each COM interface is an `extern struct` with a vtable pointer. The vtable
/// method order matches the Windows SDK `dwrite.h` exactly: each interface
/// inherits IUnknown's 3 methods (QueryInterface, AddRef, Release) at indices
/// 0-2, then its parent interface methods (if any), then its own methods.
///
/// Methods we don't need are represented as padding entries in the vtable.
const std = @import("std");
const windows = std.os.windows;

pub const HRESULT = windows.HRESULT;
pub const S_OK: HRESULT = 0;
pub const BOOL = windows.BOOL;
pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;
pub const GUID = windows.GUID;

const PadFn = *const fn () callconv(.c) void;

// ─── Enums ──────────────────────────────────────────────────────────────

pub const DWRITE_FONT_WEIGHT = enum(u32) {
    thin = 100,
    extra_light = 200,
    light = 300,
    semi_light = 350,
    normal = 400,
    medium = 500,
    semi_bold = 600,
    bold = 700,
    extra_bold = 800,
    black = 900,
    _,
};

pub const DWRITE_FONT_STYLE = enum(u32) {
    normal = 0,
    oblique = 1,
    italic = 2,
};

pub const DWRITE_FONT_STRETCH = enum(u32) {
    undefined = 0,
    ultra_condensed = 1,
    extra_condensed = 2,
    condensed = 3,
    semi_condensed = 4,
    normal = 5,
    semi_expanded = 6,
    expanded = 7,
    extra_expanded = 8,
    ultra_expanded = 9,
};

pub const DWRITE_FACTORY_TYPE = enum(u32) {
    shared = 0,
    isolated = 1,
};

// ─── GUIDs ──────────────────────────────────────────────────────────────

pub const IID_IDWriteFactory = GUID{
    .Data1 = 0xb859ee5a,
    .Data2 = 0xd838,
    .Data3 = 0x4b5b,
    .Data4 = .{ 0xa2, 0xe8, 0x1a, 0xdc, 0x7d, 0x93, 0xdb, 0x48 },
};

pub const IID_IDWriteLocalFontFileLoader = GUID{
    .Data1 = 0xb2d9f3ec,
    .Data2 = 0xc9fe,
    .Data3 = 0x4a11,
    .Data4 = .{ 0xa2, 0xec, 0xd8, 0x62, 0x08, 0xf7, 0xc0, 0xa2 },
};

// ─── IUnknown ───────────────────────────────────────────────────────────

pub const IUnknown = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // Index 0
        QueryInterface: *const fn (*const IUnknown, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        // Index 1
        AddRef: *const fn (*const IUnknown) callconv(.c) u32,
        // Index 2
        Release: *const fn (*const IUnknown) callconv(.c) u32,
    };
};

// ─── IDWriteFactory ─────────────────────────────────────────────────────
// Inherits IUnknown. We only need index 3: GetSystemFontCollection.

pub const IDWriteFactory = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const IDWriteFactory, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*const IDWriteFactory) callconv(.c) u32,
        Release: *const fn (*const IDWriteFactory) callconv(.c) u32,
        // Index 3: GetSystemFontCollection
        GetSystemFontCollection: *const fn (*const IDWriteFactory, *?*IDWriteFontCollection, BOOL) callconv(.c) HRESULT,
        // Indices 4-17: padding
        _pad4: PadFn,
        _pad5: PadFn,
        _pad6: PadFn,
        _pad7: PadFn,
        _pad8: PadFn,
        _pad9: PadFn,
        _pad10: PadFn,
        _pad11: PadFn,
        _pad12: PadFn,
        _pad13: PadFn,
        _pad14: PadFn,
        _pad15: PadFn,
        _pad16: PadFn,
        _pad17: PadFn,
    };

    pub fn release(self: *IDWriteFactory) void {
        _ = self.vtable.Release(self);
    }

    pub fn getSystemFontCollection(self: *IDWriteFactory) !*IDWriteFontCollection {
        var collection: ?*IDWriteFontCollection = null;
        const hr = self.vtable.GetSystemFontCollection(self, &collection, FALSE);
        if (hr != S_OK) return error.DirectWriteError;
        return collection orelse error.DirectWriteError;
    }
};

// ─── IDWriteFontCollection ──────────────────────────────────────────────
// Inherits IUnknown.

pub const IDWriteFontCollection = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const IDWriteFontCollection, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*const IDWriteFontCollection) callconv(.c) u32,
        Release: *const fn (*const IDWriteFontCollection) callconv(.c) u32,
        // Index 3
        GetFontFamilyCount: *const fn (*const IDWriteFontCollection) callconv(.c) u32,
        // Index 4
        GetFontFamily: *const fn (*const IDWriteFontCollection, u32, *?*IDWriteFontFamily) callconv(.c) HRESULT,
        // Index 5
        FindFamilyName: *const fn (*const IDWriteFontCollection, [*:0]const u16, *u32, *BOOL) callconv(.c) HRESULT,
        // Index 6: GetFontFromFontFace (padding)
        _pad6: PadFn,
    };

    pub fn release(self: *IDWriteFontCollection) void {
        _ = self.vtable.Release(self);
    }

    pub fn getFontFamilyCount(self: *const IDWriteFontCollection) u32 {
        return self.vtable.GetFontFamilyCount(self);
    }

    pub fn getFontFamily(self: *const IDWriteFontCollection, index: u32) !*IDWriteFontFamily {
        var family: ?*IDWriteFontFamily = null;
        const hr = self.vtable.GetFontFamily(self, index, &family);
        if (hr != S_OK) return error.DirectWriteError;
        return family orelse error.DirectWriteError;
    }

    pub fn findFamilyName(self: *const IDWriteFontCollection, name: [*:0]const u16) !?u32 {
        var index: u32 = 0;
        var exists: BOOL = FALSE;
        const hr = self.vtable.FindFamilyName(self, name, &index, &exists);
        if (hr != S_OK) return error.DirectWriteError;
        if (exists == FALSE) return null;
        return index;
    }
};

// ─── IDWriteFontFamily ──────────────────────────────────────────────────
// Inherits IDWriteFontList which inherits IUnknown.
// IDWriteFontList adds (3): GetFontCollection, (4): GetFontCount, (5): GetFont
// IDWriteFontFamily adds (6): GetFamilyNames

pub const IDWriteFontFamily = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const IDWriteFontFamily, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*const IDWriteFontFamily) callconv(.c) u32,
        Release: *const fn (*const IDWriteFontFamily) callconv(.c) u32,
        // Index 3: GetFontCollection (from IDWriteFontList, padding)
        _pad3: PadFn,
        // Index 4: GetFontCount (from IDWriteFontList)
        GetFontCount: *const fn (*const IDWriteFontFamily) callconv(.c) u32,
        // Index 5: GetFont (from IDWriteFontList)
        GetFont: *const fn (*const IDWriteFontFamily, u32, *?*IDWriteFont) callconv(.c) HRESULT,
        // Index 6: GetFamilyNames (IDWriteFontFamily's own)
        GetFamilyNames: *const fn (*const IDWriteFontFamily, *?*IDWriteLocalizedStrings) callconv(.c) HRESULT,
    };

    pub fn release(self: *IDWriteFontFamily) void {
        _ = self.vtable.Release(self);
    }

    pub fn getFontCount(self: *const IDWriteFontFamily) u32 {
        return self.vtable.GetFontCount(self);
    }

    pub fn getFont(self: *const IDWriteFontFamily, index: u32) !*IDWriteFont {
        var font_obj: ?*IDWriteFont = null;
        const hr = self.vtable.GetFont(self, index, &font_obj);
        if (hr != S_OK) return error.DirectWriteError;
        return font_obj orelse error.DirectWriteError;
    }

    pub fn getFamilyNames(self: *const IDWriteFontFamily) !*IDWriteLocalizedStrings {
        var names: ?*IDWriteLocalizedStrings = null;
        const hr = self.vtable.GetFamilyNames(self, &names);
        if (hr != S_OK) return error.DirectWriteError;
        return names orelse error.DirectWriteError;
    }
};

// ─── IDWriteFont ────────────────────────────────────────────────────────
// Inherits IUnknown.

pub const IDWriteFont = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const IDWriteFont, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*const IDWriteFont) callconv(.c) u32,
        Release: *const fn (*const IDWriteFont) callconv(.c) u32,
        // Index 3: GetFontFamily (padding)
        _pad3: PadFn,
        // Index 4: GetWeight
        GetWeight: *const fn (*const IDWriteFont) callconv(.c) DWRITE_FONT_WEIGHT,
        // Index 5: GetStyle
        GetStyle: *const fn (*const IDWriteFont) callconv(.c) DWRITE_FONT_STYLE,
        // Index 6: GetStretch
        GetStretch: *const fn (*const IDWriteFont) callconv(.c) DWRITE_FONT_STRETCH,
        // Index 7: IsSymbolFont (padding)
        _pad7: PadFn,
        // Index 8: GetFaceNames (padding)
        _pad8: PadFn,
        // Index 9: GetInformationalStrings (padding)
        _pad9: PadFn,
        // Index 10: GetSimulations (padding)
        _pad10: PadFn,
        // Index 11: GetMetrics (padding)
        _pad11: PadFn,
        // Index 12: HasCharacter
        HasCharacter: *const fn (*const IDWriteFont, u32, *BOOL) callconv(.c) HRESULT,
        // Index 13: CreateFontFace
        CreateFontFace: *const fn (*const IDWriteFont, *?*IDWriteFontFace) callconv(.c) HRESULT,
    };

    pub fn release(self: *IDWriteFont) void {
        _ = self.vtable.Release(self);
    }

    pub fn getWeight(self: *const IDWriteFont) DWRITE_FONT_WEIGHT {
        return self.vtable.GetWeight(self);
    }

    pub fn getStyle(self: *const IDWriteFont) DWRITE_FONT_STYLE {
        return self.vtable.GetStyle(self);
    }

    pub fn getStretch(self: *const IDWriteFont) DWRITE_FONT_STRETCH {
        return self.vtable.GetStretch(self);
    }

    pub fn hasCharacter(self: *const IDWriteFont, codepoint: u32) !bool {
        var exists: BOOL = FALSE;
        const hr = self.vtable.HasCharacter(self, codepoint, &exists);
        if (hr != S_OK) return error.DirectWriteError;
        return exists != FALSE;
    }

    pub fn createFontFace(self: *const IDWriteFont) !*IDWriteFontFace {
        var face: ?*IDWriteFontFace = null;
        const hr = self.vtable.CreateFontFace(self, &face);
        if (hr != S_OK) return error.DirectWriteError;
        return face orelse error.DirectWriteError;
    }
};

// ─── IDWriteFontFace ────────────────────────────────────────────────────
// Inherits IUnknown.

pub const IDWriteFontFace = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const IDWriteFontFace, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*const IDWriteFontFace) callconv(.c) u32,
        Release: *const fn (*const IDWriteFontFace) callconv(.c) u32,
        // Index 3: GetType (padding)
        _pad3: PadFn,
        // Index 4: GetFiles
        GetFiles: *const fn (*const IDWriteFontFace, *u32, ?[*]?*IDWriteFontFile) callconv(.c) HRESULT,
        // Index 5: GetIndex
        GetIndex: *const fn (*const IDWriteFontFace) callconv(.c) u32,
    };

    pub fn release(self: *IDWriteFontFace) void {
        _ = self.vtable.Release(self);
    }

    /// Get the font files for this face. Returns the first file and the face index.
    pub fn getFile(self: *const IDWriteFontFace) !*IDWriteFontFile {
        // First call to get count
        var count: u32 = 0;
        var hr = self.vtable.GetFiles(self, &count, null);
        if (hr != S_OK or count == 0) return error.DirectWriteError;

        // We only need the first file
        var file: ?*IDWriteFontFile = null;
        var one: u32 = 1;
        hr = self.vtable.GetFiles(self, &one, @ptrCast(&file));
        if (hr != S_OK) return error.DirectWriteError;
        return file orelse error.DirectWriteError;
    }

    pub fn getIndex(self: *const IDWriteFontFace) u32 {
        return self.vtable.GetIndex(self);
    }
};

// ─── IDWriteFontFile ────────────────────────────────────────────────────
// Inherits IUnknown.

pub const IDWriteFontFile = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const IDWriteFontFile, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*const IDWriteFontFile) callconv(.c) u32,
        Release: *const fn (*const IDWriteFontFile) callconv(.c) u32,
        // Index 3: GetReferenceKey
        GetReferenceKey: *const fn (*const IDWriteFontFile, *?*const anyopaque, *u32) callconv(.c) HRESULT,
        // Index 4: GetLoader
        GetLoader: *const fn (*const IDWriteFontFile, *?*IDWriteFontFileLoader) callconv(.c) HRESULT,
        // Index 5: Analyze (padding)
        _pad5: PadFn,
    };

    pub fn release(self: *IDWriteFontFile) void {
        _ = self.vtable.Release(self);
    }

    pub fn getReferenceKey(self: *const IDWriteFontFile) !struct { key: *const anyopaque, size: u32 } {
        var key: ?*const anyopaque = null;
        var size: u32 = 0;
        const hr = self.vtable.GetReferenceKey(self, &key, &size);
        if (hr != S_OK) return error.DirectWriteError;
        return .{ .key = key orelse return error.DirectWriteError, .size = size };
    }

    pub fn getLoader(self: *const IDWriteFontFile) !*IDWriteFontFileLoader {
        var loader: ?*IDWriteFontFileLoader = null;
        const hr = self.vtable.GetLoader(self, &loader);
        if (hr != S_OK) return error.DirectWriteError;
        return loader orelse error.DirectWriteError;
    }
};

// ─── IDWriteFontFileLoader ──────────────────────────────────────────────
// Inherits IUnknown.

pub const IDWriteFontFileLoader = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const IDWriteFontFileLoader, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*const IDWriteFontFileLoader) callconv(.c) u32,
        Release: *const fn (*const IDWriteFontFileLoader) callconv(.c) u32,
        // Index 3: CreateStreamFromKey (padding)
        _pad3: PadFn,
    };

    pub fn release(self: *IDWriteFontFileLoader) void {
        _ = self.vtable.Release(self);
    }
};

// ─── IDWriteLocalFontFileLoader ─────────────────────────────────────────
// Inherits IDWriteFontFileLoader which inherits IUnknown.

pub const IDWriteLocalFontFileLoader = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const IDWriteLocalFontFileLoader, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*const IDWriteLocalFontFileLoader) callconv(.c) u32,
        Release: *const fn (*const IDWriteLocalFontFileLoader) callconv(.c) u32,
        // Index 3: CreateStreamFromKey (from IDWriteFontFileLoader, padding)
        _pad3: PadFn,
        // Index 4: GetFilePathLengthFromKey
        GetFilePathLengthFromKey: *const fn (*const IDWriteLocalFontFileLoader, *const anyopaque, u32, *u32) callconv(.c) HRESULT,
        // Index 5: GetFilePathFromKey
        GetFilePathFromKey: *const fn (*const IDWriteLocalFontFileLoader, *const anyopaque, u32, [*]u16, u32) callconv(.c) HRESULT,
        // Index 6: GetLastWriteTimeFromKey (padding)
        _pad6: PadFn,
    };

    pub fn release(self: *IDWriteLocalFontFileLoader) void {
        _ = self.vtable.Release(self);
    }

    pub fn getFilePathLengthFromKey(self: *const IDWriteLocalFontFileLoader, key: *const anyopaque, key_size: u32) !u32 {
        var len: u32 = 0;
        const hr = self.vtable.GetFilePathLengthFromKey(self, key, key_size, &len);
        if (hr != S_OK) return error.DirectWriteError;
        return len;
    }

    pub fn getFilePathFromKey(self: *const IDWriteLocalFontFileLoader, key: *const anyopaque, key_size: u32, buf: [*]u16, buf_size: u32) !void {
        const hr = self.vtable.GetFilePathFromKey(self, key, key_size, buf, buf_size);
        if (hr != S_OK) return error.DirectWriteError;
    }
};

// ─── IDWriteLocalizedStrings ────────────────────────────────────────────
// Inherits IUnknown.

pub const IDWriteLocalizedStrings = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (indices 0-2)
        QueryInterface: *const fn (*const IDWriteLocalizedStrings, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*const IDWriteLocalizedStrings) callconv(.c) u32,
        Release: *const fn (*const IDWriteLocalizedStrings) callconv(.c) u32,
        // Index 3: GetCount
        GetCount: *const fn (*const IDWriteLocalizedStrings) callconv(.c) u32,
        // Index 4: FindLocaleName
        FindLocaleName: *const fn (*const IDWriteLocalizedStrings, [*:0]const u16, *u32, *BOOL) callconv(.c) HRESULT,
        // Index 5: GetLocaleNameLength (padding)
        _pad5: PadFn,
        // Index 6: GetLocaleName (padding)
        _pad6: PadFn,
        // Index 7: GetStringLength
        GetStringLength: *const fn (*const IDWriteLocalizedStrings, u32, *u32) callconv(.c) HRESULT,
        // Index 8: GetString
        GetString: *const fn (*const IDWriteLocalizedStrings, u32, [*]u16, u32) callconv(.c) HRESULT,
    };

    pub fn release(self: *IDWriteLocalizedStrings) void {
        _ = self.vtable.Release(self);
    }

    pub fn getCount(self: *const IDWriteLocalizedStrings) u32 {
        return self.vtable.GetCount(self);
    }

    pub fn findLocaleName(self: *const IDWriteLocalizedStrings, locale: [*:0]const u16) !?u32 {
        var index: u32 = 0;
        var exists: BOOL = FALSE;
        const hr = self.vtable.FindLocaleName(self, locale, &index, &exists);
        if (hr != S_OK) return error.DirectWriteError;
        if (exists == FALSE) return null;
        return index;
    }

    pub fn getStringLength(self: *const IDWriteLocalizedStrings, index: u32) !u32 {
        var len: u32 = 0;
        const hr = self.vtable.GetStringLength(self, index, &len);
        if (hr != S_OK) return error.DirectWriteError;
        return len;
    }

    pub fn getString(self: *const IDWriteLocalizedStrings, index: u32, buf: [*]u16, buf_size: u32) !void {
        const hr = self.vtable.GetString(self, index, buf, buf_size);
        if (hr != S_OK) return error.DirectWriteError;
    }

    /// Get the string at the given index, allocating memory via the provided allocator.
    /// Returns a UTF-8 encoded, null-terminated string.
    pub fn toUtf8Alloc(self: *const IDWriteLocalizedStrings, alloc: std.mem.Allocator, index: u32) ![:0]const u8 {
        const len = try self.getStringLength(index);
        // +1 for null terminator
        const buf = try alloc.alloc(u16, len + 1);
        defer alloc.free(buf);
        try self.getString(index, buf.ptr, len + 1);

        // Convert UTF-16 to UTF-8
        return utf16ToUtf8Alloc(alloc, buf[0..len]);
    }

    /// Get the best localized name (prefer "en-us", fall back to index 0).
    pub fn getLocalizedName(self: *const IDWriteLocalizedStrings, alloc: std.mem.Allocator) ![:0]const u8 {
        // Try "en-us" first
        const en_us: [*:0]const u16 = &[_:0]u16{ 'e', 'n', '-', 'u', 's' };
        const locale_index = try self.findLocaleName(en_us) orelse 0;
        return self.toUtf8Alloc(alloc, locale_index);
    }
};

// ─── QueryInterface helper ──────────────────────────────────────────────

/// Query a COM object for a different interface via its IID.
pub fn queryInterface(comptime T: type, obj: anytype, iid: *const GUID) ?*T {
    // All COM objects start with a pointer to a vtable where the first
    // 3 entries are QueryInterface, AddRef, Release (IUnknown).
    const vt_ptr: *const *const IUnknown.VTable = @ptrCast(@alignCast(obj));
    var result: ?*anyopaque = null;
    const hr = vt_ptr.*.QueryInterface(@ptrCast(obj), iid, &result);
    if (hr != S_OK or result == null) return null;
    return @ptrCast(@alignCast(result.?));
}

// ─── DWriteCreateFactory ────────────────────────────────────────────────

pub extern "dwrite" fn DWriteCreateFactory(
    factoryType: DWRITE_FACTORY_TYPE,
    iid: *const GUID,
    factory: *?*anyopaque,
) callconv(.c) HRESULT;

// ─── UTF-16 helpers ─────────────────────────────────────────────────────

/// Convert a runtime UTF-8 string to a null-terminated UTF-16 buffer.
/// Uses the provided allocator. Caller must free the returned slice.
pub fn utf8ToUtf16Alloc(alloc: std.mem.Allocator, utf8: []const u8) ![:0]u16 {
    var result: std.ArrayList(u16) = .empty;
    errdefer result.deinit(alloc);

    var i: usize = 0;
    while (i < utf8.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(utf8[i]) catch return error.DirectWriteError;
        if (i + cp_len > utf8.len) return error.DirectWriteError;
        const cp = std.unicode.utf8Decode(utf8[i..][0..cp_len]) catch return error.DirectWriteError;
        i += cp_len;

        // Encode as UTF-16
        if (cp < 0x10000) {
            try result.append(alloc, @intCast(cp));
        } else {
            // Surrogate pair
            const v = cp - 0x10000;
            try result.append(alloc, @intCast((v >> 10) + 0xD800));
            try result.append(alloc, @intCast((v & 0x3FF) + 0xDC00));
        }
    }
    return try result.toOwnedSliceSentinel(alloc, 0);
}

/// Calculate the UTF-8 length of a UTF-16 buffer (without surrogates decoding).
fn calcUtf8Len(utf16: []const u16) !usize {
    var len: usize = 0;
    var i: usize = 0;
    while (i < utf16.len) {
        const c = utf16[i];
        if (c < 0x80) {
            len += 1;
        } else if (c < 0x800) {
            len += 2;
        } else if (c >= 0xD800 and c <= 0xDBFF) {
            // High surrogate — expect low surrogate
            len += 4;
            i += 1; // skip low surrogate
        } else {
            len += 3;
        }
        i += 1;
    }
    return len;
}

/// Convert a UTF-16 buffer to a UTF-8, null-terminated string.
pub fn utf16ToUtf8Alloc(alloc: std.mem.Allocator, utf16: []const u16) ![:0]const u8 {
    const utf8_len = try calcUtf8Len(utf16);
    const utf8_buf = try alloc.allocSentinel(u8, utf8_len, 0);
    errdefer alloc.free(utf8_buf);

    var dest: usize = 0;
    var i: usize = 0;
    while (i < utf16.len) {
        const c = utf16[i];
        var cp: u21 = undefined;
        if (c >= 0xD800 and c <= 0xDBFF) {
            // Surrogate pair
            if (i + 1 >= utf16.len) return error.DirectWriteError;
            const low = utf16[i + 1];
            if (low < 0xDC00 or low > 0xDFFF) return error.DirectWriteError;
            cp = @intCast((@as(u32, c - 0xD800) << 10) + @as(u32, low - 0xDC00) + 0x10000);
            i += 2;
        } else {
            cp = @intCast(c);
            i += 1;
        }
        dest += std.unicode.utf8Encode(cp, utf8_buf[dest..]) catch return error.DirectWriteError;
    }

    return utf8_buf;
}
