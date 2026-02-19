/// Runtime loader for the WinUI 3 shim DLL (ghostty_winui.dll).
///
/// All functions are loaded via GetProcAddress and stored as nullable
/// function pointers. If the DLL is absent or WinUI is unavailable,
/// all pointers remain null and `isAvailable()` returns false.
///
/// Callers (Window.zig, Surface.zig, App.zig) check `isAvailable()`
/// before calling any WinUI function, falling back to GDI controls.
const WinUI = @This();

const std = @import("std");
const c = @import("c.zig");

const log = std.log.scoped(.winui);

const HWND = c.HWND;
const WINAPI = c.WINAPI;

// ---------------------------------------------------------------
// Opaque handle types (match C header)
// ---------------------------------------------------------------

pub const XamlHost = ?*opaque {};
pub const TabView = ?*opaque {};
pub const SearchPanel = ?*opaque {};

// ---------------------------------------------------------------
// Callback structs (match C header layout)
// ---------------------------------------------------------------

pub const TabViewCallbacks = extern struct {
    ctx: ?*anyopaque = null,
    on_tab_selected: ?*const fn (?*anyopaque, u32) callconv(.c) void = null,
    on_tab_close_requested: ?*const fn (?*anyopaque, u32) callconv(.c) void = null,
    on_new_tab_requested: ?*const fn (?*anyopaque) callconv(.c) void = null,
    on_tab_reordered: ?*const fn (?*anyopaque, u32, u32) callconv(.c) void = null,
    on_minimize: ?*const fn (?*anyopaque) callconv(.c) void = null,
    on_maximize: ?*const fn (?*anyopaque) callconv(.c) void = null,
    on_close: ?*const fn (?*anyopaque) callconv(.c) void = null,
};

pub const SearchCallbacks = extern struct {
    ctx: ?*anyopaque = null,
    on_search_changed: ?*const fn (?*anyopaque, [*:0]const u8) callconv(.c) void = null,
    on_search_next: ?*const fn (?*anyopaque) callconv(.c) void = null,
    on_search_prev: ?*const fn (?*anyopaque) callconv(.c) void = null,
    on_search_close: ?*const fn (?*anyopaque) callconv(.c) void = null,
};

pub const TitleResultCallback = *const fn (?*anyopaque, i32, ?[*:0]const u8) callconv(.c) void;

// ---------------------------------------------------------------
// Function pointer types
// ---------------------------------------------------------------

const FnLastError = *const fn () callconv(.c) i32;
const FnInit = *const fn () callconv(.c) i32;
const FnShutdown = *const fn () callconv(.c) void;
const FnAvailable = *const fn () callconv(.c) i32;
const FnPreTranslateMessage = *const fn (*c.MSG) callconv(.c) i32;

const FnXamlHostCreate = *const fn (?HWND) callconv(.c) XamlHost;
const FnXamlHostDestroy = *const fn (XamlHost) callconv(.c) void;
const FnXamlHostGetHwnd = *const fn (XamlHost) callconv(.c) ?HWND;
const FnXamlHostResize = *const fn (XamlHost, i32, i32, i32, i32) callconv(.c) void;

const FnTabViewCreate = *const fn (XamlHost, TabViewCallbacks) callconv(.c) TabView;
const FnTabViewDestroy = *const fn (TabView) callconv(.c) void;
const FnTabViewAddTab = *const fn (TabView, [*:0]const u8) callconv(.c) u32;
const FnTabViewRemoveTab = *const fn (TabView, u32) callconv(.c) void;
const FnTabViewSelectTab = *const fn (TabView, u32) callconv(.c) void;
const FnTabViewSetTabTitle = *const fn (TabView, u32, [*:0]const u8) callconv(.c) void;
const FnTabViewMoveTab = *const fn (TabView, u32, u32) callconv(.c) void;
const FnTabViewGetHeight = *const fn (TabView) callconv(.c) i32;
const FnTabViewSetTheme = *const fn (TabView, i32) callconv(.c) void;
const FnTabViewSetBackgroundColor = *const fn (TabView, u8, u8, u8) callconv(.c) void;

const FnSearchCreate = *const fn (TabView, SearchCallbacks) callconv(.c) SearchPanel;
const FnSearchDestroy = *const fn (SearchPanel) callconv(.c) void;
const FnSearchShow = *const fn (SearchPanel, ?[*:0]const u8) callconv(.c) void;
const FnSearchHide = *const fn (SearchPanel) callconv(.c) void;
const FnSearchSetMatchCount = *const fn (SearchPanel, i32, i32) callconv(.c) void;
const FnSearchReposition = *const fn (SearchPanel, i32, i32, i32) callconv(.c) void;

const FnTabViewSetupDragRegions = *const fn (TabView, c.HWND) callconv(.c) void;
const FnTabViewUpdateDragRegions = *const fn (TabView, c.HWND) callconv(.c) void;

const FnTitleDialogShow = *const fn (TabView, [*:0]const u8, [*:0]const u8, ?*anyopaque, TitleResultCallback) callconv(.c) void;

// ---------------------------------------------------------------
// Loaded function pointers
// ---------------------------------------------------------------

module: c.HMODULE = null,

// Lifecycle
winui_last_error: ?FnLastError = null,
winui_init: ?FnInit = null,
winui_shutdown: ?FnShutdown = null,
winui_available: ?FnAvailable = null,
winui_pre_translate_message: ?FnPreTranslateMessage = null,

// XAML host
xaml_host_create: ?FnXamlHostCreate = null,
xaml_host_destroy: ?FnXamlHostDestroy = null,
xaml_host_get_hwnd: ?FnXamlHostGetHwnd = null,
xaml_host_resize: ?FnXamlHostResize = null,

// TabView
tabview_create: ?FnTabViewCreate = null,
tabview_destroy: ?FnTabViewDestroy = null,
tabview_add_tab: ?FnTabViewAddTab = null,
tabview_remove_tab: ?FnTabViewRemoveTab = null,
tabview_select_tab: ?FnTabViewSelectTab = null,
tabview_set_tab_title: ?FnTabViewSetTabTitle = null,
tabview_move_tab: ?FnTabViewMoveTab = null,
tabview_get_height: ?FnTabViewGetHeight = null,
tabview_set_theme: ?FnTabViewSetTheme = null,
tabview_set_background_color: ?FnTabViewSetBackgroundColor = null,
tabview_setup_drag_regions: ?FnTabViewSetupDragRegions = null,
tabview_update_drag_regions: ?FnTabViewUpdateDragRegions = null,

// Search panel
search_create: ?FnSearchCreate = null,
search_destroy: ?FnSearchDestroy = null,
search_show: ?FnSearchShow = null,
search_hide: ?FnSearchHide = null,
search_set_match_count: ?FnSearchSetMatchCount = null,
search_reposition: ?FnSearchReposition = null,

// Title dialog
title_dialog_show: ?FnTitleDialogShow = null,

// ---------------------------------------------------------------
// Public API
// ---------------------------------------------------------------

/// Attempt to load the WinUI shim DLL and resolve all function pointers.
/// Non-fatal: if loading fails, all pointers remain null.
pub fn load(self: *WinUI) void {
    // Build full path relative to the exe directory so that the DLL
    // is found regardless of the process's current working directory.
    var exe_path_buf: [std.os.windows.PATH_MAX_WIDE]u16 = undefined;
    const exe_path_len = c.GetModuleFileNameW(null, &exe_path_buf, exe_path_buf.len);
    if (exe_path_len > 0) {
        // Find the last backslash to get the directory.
        var dir_end: usize = exe_path_len;
        while (dir_end > 0) {
            dir_end -= 1;
            if (exe_path_buf[dir_end] == '\\') break;
        }
        // Append DLL name after the backslash.
        const dll_suffix = std.unicode.utf8ToUtf16LeStringLiteral("\\ghostty_winui.dll");
        const total_len = dir_end + dll_suffix.len;
        if (total_len < exe_path_buf.len) {
            @memcpy(exe_path_buf[dir_end .. dir_end + dll_suffix.len], dll_suffix[0..dll_suffix.len]);
            exe_path_buf[total_len] = 0;
            const dll_path: [*:0]const u16 = @ptrCast(exe_path_buf[0..total_len :0]);
            self.module = c.LoadLibraryW(dll_path);
            if (self.module == null) {
                const err = c.GetLastError();
                log.warn("LoadLibraryW failed for exe-relative path, error={}", .{err});
            }
        }
    }

    // Fallback: try bare name (searches system DLL paths).
    if (self.module == null) {
        const dll_name = std.unicode.utf8ToUtf16LeStringLiteral("ghostty_winui.dll");
        self.module = c.LoadLibraryW(dll_name);
        if (self.module == null) {
            const err = c.GetLastError();
            log.info("ghostty_winui.dll not found (error={}), using GDI fallback", .{err});
            return;
        }
    }

    log.info("Loaded ghostty_winui.dll", .{});

    // Resolve all function pointers.
    self.winui_last_error = self.getProc(FnLastError, "ghostty_winui_last_error");
    self.winui_init = self.getProc(FnInit, "ghostty_winui_init");
    self.winui_shutdown = self.getProc(FnShutdown, "ghostty_winui_shutdown");
    self.winui_available = self.getProc(FnAvailable, "ghostty_winui_available");
    self.winui_pre_translate_message = self.getProc(FnPreTranslateMessage, "ghostty_winui_pre_translate_message");

    self.xaml_host_create = self.getProc(FnXamlHostCreate, "ghostty_xaml_host_create");
    self.xaml_host_destroy = self.getProc(FnXamlHostDestroy, "ghostty_xaml_host_destroy");
    self.xaml_host_get_hwnd = self.getProc(FnXamlHostGetHwnd, "ghostty_xaml_host_get_hwnd");
    self.xaml_host_resize = self.getProc(FnXamlHostResize, "ghostty_xaml_host_resize");

    self.tabview_create = self.getProc(FnTabViewCreate, "ghostty_tabview_create");
    self.tabview_destroy = self.getProc(FnTabViewDestroy, "ghostty_tabview_destroy");
    self.tabview_add_tab = self.getProc(FnTabViewAddTab, "ghostty_tabview_add_tab");
    self.tabview_remove_tab = self.getProc(FnTabViewRemoveTab, "ghostty_tabview_remove_tab");
    self.tabview_select_tab = self.getProc(FnTabViewSelectTab, "ghostty_tabview_select_tab");
    self.tabview_set_tab_title = self.getProc(FnTabViewSetTabTitle, "ghostty_tabview_set_tab_title");
    self.tabview_move_tab = self.getProc(FnTabViewMoveTab, "ghostty_tabview_move_tab");
    self.tabview_get_height = self.getProc(FnTabViewGetHeight, "ghostty_tabview_get_height");
    self.tabview_set_theme = self.getProc(FnTabViewSetTheme, "ghostty_tabview_set_theme");
    self.tabview_set_background_color = self.getProc(FnTabViewSetBackgroundColor, "ghostty_tabview_set_background_color");
    self.tabview_setup_drag_regions = self.getProc(FnTabViewSetupDragRegions, "ghostty_tabview_setup_drag_regions");
    self.tabview_update_drag_regions = self.getProc(FnTabViewUpdateDragRegions, "ghostty_tabview_update_drag_regions");

    self.search_create = self.getProc(FnSearchCreate, "ghostty_search_create");
    self.search_destroy = self.getProc(FnSearchDestroy, "ghostty_search_destroy");
    self.search_show = self.getProc(FnSearchShow, "ghostty_search_show");
    self.search_hide = self.getProc(FnSearchHide, "ghostty_search_hide");
    self.search_set_match_count = self.getProc(FnSearchSetMatchCount, "ghostty_search_set_match_count");
    self.search_reposition = self.getProc(FnSearchReposition, "ghostty_search_reposition");

    self.title_dialog_show = self.getProc(FnTitleDialogShow, "ghostty_title_dialog_show");

    // Initialize WinUI.
    if (self.winui_init) |init_fn| {
        const result = init_fn();
        if (result != 0) {
            log.warn("ghostty_winui_init() failed ({}), falling back to GDI", .{result});
            self.unload();
            return;
        }
        log.info("WinUI 3 initialized successfully", .{});
    } else {
        log.warn("ghostty_winui_init not found in DLL", .{});
        self.unload();
    }
}

/// Returns the last HRESULT error from the WinUI DLL.
pub fn lastError(self: *const WinUI) i32 {
    if (self.winui_last_error) |err_fn| return err_fn();
    return 0;
}

/// Returns true if the WinUI shim DLL is loaded and WinUI is available.
pub fn isAvailable(self: *const WinUI) bool {
    if (self.module == null) return false;
    if (self.winui_available) |avail_fn| {
        return avail_fn() != 0;
    }
    return false;
}

/// Unload the DLL and reset all function pointers.
pub fn unload(self: *WinUI) void {
    if (self.winui_shutdown) |shutdown_fn| {
        shutdown_fn();
    }

    if (self.module) |mod| {
        _ = c.FreeLibrary(mod);
    }

    self.* = .{};
    log.info("WinUI DLL unloaded", .{});
}

// ---------------------------------------------------------------
// Theme constants
// ---------------------------------------------------------------

pub const THEME_DEFAULT: i32 = 0;
pub const THEME_LIGHT: i32 = 1;
pub const THEME_DARK: i32 = 2;

// ---------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------

fn getProc(self: *const WinUI, comptime T: type, name: [*:0]const u8) ?T {
    const raw = c.GetProcAddress(self.module, name);
    if (raw) |ptr| {
        return @ptrCast(ptr);
    }
    log.debug("GetProcAddress failed for '{s}'", .{name});
    return null;
}
