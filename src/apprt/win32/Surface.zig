/// Win32 Surface represents a terminal rendering surface (child HWND).
/// Each Surface is a child window inside a Window's content area.
const Surface = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const build_config = @import("../../build_config.zig");
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const terminal = @import("../../terminal/main.zig");
const CoreSurface = @import("../../Surface.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");
const c = @import("c.zig");
const opengl = if (build_config.renderer == .directx) void else @import("opengl.zig");
const d3d11mod = if (build_config.renderer == .directx) @import("d3d11.zig") else void;
const inputmod = @import("input.zig");
const input = @import("../../input.zig");
const SearchBar = @import("SearchBar.zig");
const WinUI = @import("WinUI.zig");

const log = std.log.scoped(.win32_surface);

const HWND = c.HWND;
const HDC = c.HDC;
const HGLRC = if (build_config.renderer == .directx) void else c.HGLRC;
const UINT = u32;
const WPARAM = c.WPARAM;
const LPARAM = c.LPARAM;
const LRESULT = c.LRESULT;

/// Window handle (child HWND)
hwnd: HWND,

/// Parent window
window: *Window,

/// Device context for OpenGL (not used with D3D11)
hdc: if (build_config.renderer == .directx) void else HDC,

/// OpenGL rendering context (not used with D3D11)
hglrc: if (build_config.renderer == .directx) void else ?HGLRC = if (build_config.renderer == .directx) {} else null,

/// Whether the graphics context has been initialized
gl_initialized: bool = false,

/// D3D11 context (only with directx renderer)
d3d11_ctx: if (build_config.renderer == .directx) ?d3d11mod.D3D11Context else void =
    if (build_config.renderer == .directx) null else {},

/// Core Ghostty surface
core_surface: ?*CoreSurface = null,

/// Parent app
app: *App,

/// Mouse tracking state for WM_MOUSELEAVE
tracking_mouse: bool = false,

/// Current mouse cursor shape
current_cursor: c.HCURSOR = null,

/// Whether the mouse cursor is hidden
mouse_hidden: bool = false,

/// Cell dimensions in pixels
cell_width: u32 = 0,
cell_height: u32 = 0,

/// Keyboard input: deferred key event for correct WM_KEYDOWN/WM_CHAR sequencing
pending_key: ?input.KeyEvent = null,
pending_key_consumed: bool = false,

/// Reference count for SplitTree. Starts at 0; SplitTree.init refs to 1.
ref_count: u32 = 0,

/// Set to true during WM_DESTROY cascade so that destroy() skips DestroyWindow.
closing: bool = false,

/// Per-surface title (set via set_title action).
title_buf: [256]u8 = undefined,
title_len: u16 = 0,

/// Child process exit info (set when child exits, cleared on dismiss).
child_exited_info: ?ChildExitedInfo = null,

/// Search bar overlay (created on demand).
search_bar: ?*SearchBar = null,

/// WinUI search panel (created on demand, null if WinUI not available).
winui_search: WinUI.SearchPanel = null,

/// Whether the WinUI search panel is currently visible.
winui_search_visible: bool = false,

/// Cached search match counts for WinUI updates.
cached_search_total: i32 = 0,
cached_search_selected: i32 = 0,

/// Child-exited banner HWND (STATIC control, child of Window).
banner_hwnd: ?HWND = null,

/// Cached brush for the banner background color.
banner_brush: c.HBRUSH = null,

/// Whether this surface currently has keyboard focus.
focused: bool = false,

/// URL of the link under the mouse cursor (if any).
link_url_buf: [2048]u8 = undefined,
link_url_len: usize = 0,

const ChildExitedInfo = struct {
    exit_code: u32,
    runtime_ms: u64,
};

/// Height of the child-exited banner in pixels.
const BANNER_HEIGHT: i32 = 30;

pub fn create(app: *App, window: *Window) !*Surface {
    const surface = try app.core_app.alloc.create(Surface);
    errdefer app.core_app.alloc.destroy(surface);

    surface.* = .{
        .hwnd = undefined,
        .window = window,
        .hdc = if (build_config.renderer == .directx) {} else undefined,
        .app = app,
        .current_cursor = c.LoadCursorW(null, c.IDC_ARROW),
    };

    // Create the child window
    try surface.createChildWindow();

    // Initialize graphics context
    if (build_config.renderer == .directx) {
        try surface.initD3D11();
    } else {
        try surface.initOpenGL();
    }

    log.info("Created Win32 surface (child window)", .{});
    return surface;
}

/// Clean up graphics and core_surface resources without freeing the struct.
/// Called during WM_DESTROY on the child HWND.
pub fn destroyResources(self: *Surface) void {
    const alloc = self.app.core_app.alloc;

    // Clean up the child-exited banner
    self.destroyBannerWindow();

    // Clean up WinUI search panel.
    if (self.winui_search != null) {
        if (self.app.winui.search_destroy) |destroy_fn| {
            destroy_fn(self.winui_search);
        }
        self.winui_search = null;
    }

    // Clean up the search bar
    if (self.search_bar) |bar| {
        bar.deinit();
        self.search_bar = null;
    }

    // Clean up the core surface
    if (self.core_surface) |cs| {
        self.app.core_app.deleteSurface(self);
        cs.deinit();
        alloc.destroy(cs);
        self.core_surface = null;
    }

    // Clean up graphics resources
    if (build_config.renderer == .directx) {
        if (self.d3d11_ctx) |*ctx| {
            d3d11mod.destroyContext(ctx);
            self.d3d11_ctx = null;
        }
    } else {
        if (self.hglrc) |hglrc| {
            _ = c.wglMakeCurrent(null, null);
            _ = c.wglDeleteContext(hglrc);
            self.hglrc = null;
        }
        _ = c.ReleaseDC(self.hwnd, self.hdc);
    }

    log.info("Destroyed Win32 surface resources", .{});
}

pub fn deinit(self: *Surface) void {
    self.destroyResources();
    _ = c.DestroyWindow(self.hwnd);
}

// ---------------------------------------------------------------
// SplitTree View interface
// ---------------------------------------------------------------

/// Increment reference count (called by SplitTree on init/split/clone/etc).
pub fn ref(self: *Surface, _: Allocator) !*Surface {
    self.ref_count += 1;
    return self;
}

/// Decrement reference count (called by SplitTree on deinit/remove).
/// When ref_count reaches 0, the surface is destroyed.
pub fn unref(self: *Surface, alloc: Allocator) void {
    if (self.ref_count == 0) return;
    self.ref_count -= 1;
    if (self.ref_count == 0) {
        self.destroy(alloc);
    }
}

/// Pointer equality for SplitTree node lookups.
pub fn eql(self: *const Surface, other: *const Surface) bool {
    return self == other;
}

/// Final cleanup when ref_count reaches 0.
fn destroy(self: *Surface, alloc: Allocator) void {
    self.destroyResources();
    if (!self.closing) {
        // Normal close path (e.g. split removal) — destroy the child HWND.
        _ = c.DestroyWindow(self.hwnd);
    }
    // Free the struct.
    alloc.destroy(self);
}

pub fn core(self: *Surface) *CoreSurface {
    return self.core_surface orelse unreachable;
}

pub fn rtApp(self: *Surface) *App {
    return self.app;
}

pub fn close(self: *Surface, process_active: bool) void {
    _ = process_active;
    // Post WM_CLOSE to self; windowProc will forward to parent as
    // WM_GHOSTTY_CLOSE_SURFACE for deferred tree removal.
    _ = c.PostMessageW(self.hwnd, c.WM_CLOSE, 0, 0);
}

pub fn cgroup(self: *Surface) ?[]const u8 {
    _ = self;
    return null;
}

pub fn getTitle(self: *Surface) ?[:0]const u8 {
    if (self.title_len == 0) return null;
    if (self.title_len < self.title_buf.len and self.title_buf[self.title_len] == 0) {
        return self.title_buf[0..self.title_len :0];
    }
    return null;
}

/// Set the per-surface title from a UTF-8 string.
pub fn setTitle(self: *Surface, title: [:0]const u8) void {
    const len = @min(title.len, self.title_buf.len - 1);
    @memcpy(self.title_buf[0..len], title[0..len]);
    self.title_buf[len] = 0;
    self.title_len = @intCast(len);
}

// ---------------------------------------------------------------
// Search bar integration
// ---------------------------------------------------------------

/// Show the search bar, creating it if necessary.
pub fn showSearch(self: *Surface, needle: [:0]const u8) void {
    if (self.window.using_winui) {
        if (self.winui_search == null) {
            if (self.app.winui.search_create) |create_fn| {
                self.winui_search = create_fn(self.window.winui_tabview, .{
                    .ctx = @ptrCast(self),
                    .on_search_changed = &winuiOnSearchChanged,
                    .on_search_next = &winuiOnSearchNext,
                    .on_search_prev = &winuiOnSearchPrev,
                    .on_search_close = &winuiOnSearchClose,
                });
            }
        }
        if (self.winui_search != null) {
            if (self.app.winui.search_show) |show_fn| {
                show_fn(self.winui_search, if (needle.len > 0) needle.ptr else null);
            }
            self.winui_search_visible = true;
            self.window.resizeWinUIHost();
            self.repositionWinUISearch();
            return;
        }
    }

    // GDI fallback.
    if (self.search_bar == null) {
        self.search_bar = SearchBar.create(self) catch |err| {
            log.warn("Failed to create search bar: {}", .{err});
            return;
        };
        // Subclass the edit control for Enter/Escape handling.
        const bar = self.search_bar.?;
        const orig: isize = c.SetWindowLongPtrW(bar.edit_hwnd, c.GWLP_WNDPROC, @bitCast(@intFromPtr(&SearchBar.editSubclassProc)));
        if (orig != 0) {
            const orig_proc: c.WNDPROC = @ptrFromInt(@as(usize, @bitCast(orig)));
            SearchBar.setEditOrigProc(orig_proc);
        }
    }
    self.search_bar.?.show(needle);
}

/// Hide the search bar.
pub fn hideSearch(self: *Surface) void {
    if (self.winui_search != null) {
        if (self.app.winui.search_hide) |hide_fn| {
            hide_fn(self.winui_search);
        }
        self.winui_search_visible = false;
        self.window.resizeWinUIHost();
        return;
    }
    if (self.search_bar) |bar| {
        bar.hide();
    }
}

/// Update the total match count in the search bar.
pub fn updateSearchTotal(self: *Surface, total: ?usize) void {
    if (self.winui_search != null) {
        self.cached_search_total = if (total) |v| @intCast(v) else 0;
        if (self.app.winui.search_set_match_count) |set_fn| {
            set_fn(self.winui_search, self.cached_search_total, self.cached_search_selected);
        }
        return;
    }
    if (self.search_bar) |bar| {
        bar.updateTotal(total);
    }
}

/// Update the selected match index in the search bar.
pub fn updateSearchSelected(self: *Surface, selected: ?usize) void {
    if (self.winui_search != null) {
        self.cached_search_selected = if (selected) |v| @intCast(v) else 0;
        if (self.app.winui.search_set_match_count) |set_fn| {
            set_fn(self.winui_search, self.cached_search_total, self.cached_search_selected);
        }
        return;
    }
    if (self.search_bar) |bar| {
        bar.updateSelected(selected);
    }
}

// ---------------------------------------------------------------
// WinUI search callback trampolines
// ---------------------------------------------------------------

fn winuiOnSearchChanged(ctx: ?*anyopaque, text: [*:0]const u8) callconv(.c) void {
    const self: *Surface = @ptrCast(@alignCast(ctx));
    if (self.core_surface) |cs| {
        _ = cs.performBindingAction(.{ .search = std.mem.span(text) }) catch {};
    }
}

fn winuiOnSearchNext(ctx: ?*anyopaque) callconv(.c) void {
    const self: *Surface = @ptrCast(@alignCast(ctx));
    if (self.core_surface) |cs| {
        _ = cs.performBindingAction(.{ .navigate_search = .next }) catch {};
    }
}

fn winuiOnSearchPrev(ctx: ?*anyopaque) callconv(.c) void {
    const self: *Surface = @ptrCast(@alignCast(ctx));
    if (self.core_surface) |cs| {
        _ = cs.performBindingAction(.{ .navigate_search = .previous }) catch {};
    }
}

fn winuiOnSearchClose(ctx: ?*anyopaque) callconv(.c) void {
    const self: *Surface = @ptrCast(@alignCast(ctx));
    if (self.core_surface) |cs| {
        _ = cs.performBindingAction(.end_search) catch {};
    }
}

fn repositionWinUISearch(self: *Surface) void {
    if (self.winui_search == null) return;
    if (self.app.winui.search_reposition) |reposition_fn| {
        var surface_client: c.RECT = undefined;
        if (c.GetClientRect(self.hwnd, &surface_client) == 0) return;
        const surface_width = surface_client.right - surface_client.left;
        const search_width: i32 = 380;
        const margin: i32 = 8;
        const x = @max(0, surface_width - search_width - margin);
        reposition_fn(self.winui_search, x, 8, search_width);
    }
}

// ---------------------------------------------------------------
// Unfocused split overlay (rendered via DX11 in present path)
// ---------------------------------------------------------------

/// Returns the RGBA overlay color if this surface should show the
/// unfocused-split dimming effect, or null if no overlay needed.
pub fn getUnfocusedSplitOverlay(self: *Surface) ?[4]f32 {
    if (self.focused) return null;
    const tab = self.window.activeTab();
    if (!tab.tree.isSplit()) return null;

    const config = &self.app.config;
    const fill = config.@"unfocused-split-fill" orelse config.background;
    const opacity = config.@"unfocused-split-opacity";
    const alpha: f32 = @floatCast(1.0 - opacity);
    if (alpha <= 0.0) return null;

    return .{
        @as(f32, @floatFromInt(fill.r)) / 255.0 * alpha,
        @as(f32, @floatFromInt(fill.g)) / 255.0 * alpha,
        @as(f32, @floatFromInt(fill.b)) / 255.0 * alpha,
        alpha,
    };
}

pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
    const dpi = c.GetDpiForWindow(self.hwnd);
    const scale: f32 = @as(f32, @floatFromInt(dpi)) / 96.0;
    return .{ .x = scale, .y = scale };
}

pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
    var rect: c.RECT = undefined;
    if (c.GetClientRect(self.hwnd, &rect) == 0) {
        return error.GetClientRectFailed;
    }
    return .{
        .width = @intCast(rect.right - rect.left),
        .height = @intCast(rect.bottom - rect.top),
    };
}

pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
    var point: c.POINT = undefined;
    if (c.GetCursorPos(&point) == 0) {
        return error.GetCursorPosFailed;
    }
    if (c.ScreenToClient(self.hwnd, &point) == 0) {
        return error.ScreenToClientFailed;
    }
    return .{
        .x = @floatFromInt(point.x),
        .y = @floatFromInt(point.y),
    };
}

pub fn supportsClipboard(self: *const Surface, clipboard_type: apprt.Clipboard) bool {
    _ = self;
    return clipboard_type == .standard;
}

pub fn clipboardRequest(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
    state: apprt.ClipboardRequest,
) !bool {
    if (clipboard_type != .standard) return false;

    if (c.OpenClipboard(self.hwnd) == 0) {
        log.warn("Failed to open clipboard", .{});
        return false;
    }
    defer _ = c.CloseClipboard();

    const handle = c.GetClipboardData(c.CF_UNICODETEXT);
    if (handle == null) {
        log.debug("No text data in clipboard", .{});
        return false;
    }

    const locked = c.GlobalLock(handle.?) orelse {
        log.warn("Failed to lock clipboard data", .{});
        return false;
    };
    defer _ = c.GlobalUnlock(handle.?);

    const wide_ptr: [*]const u16 = @ptrCast(@alignCast(locked));
    const wide_len = std.mem.indexOfScalar(u16, wide_ptr[0..4096], 0) orelse 4096;
    const wide_slice = wide_ptr[0..wide_len];

    const alloc = self.app.core_app.alloc;
    const utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, wide_slice) catch |err| {
        log.warn("Failed to convert clipboard to UTF-8: {}", .{err});
        return false;
    };
    defer alloc.free(utf8);

    const utf8z = alloc.dupeZ(u8, utf8) catch |err| {
        log.warn("Failed to allocate clipboard string: {}", .{err});
        return false;
    };
    defer alloc.free(utf8z);

    if (self.core_surface) |cs| {
        cs.completeClipboardRequest(state, utf8z, false) catch |err| {
            log.warn("Failed to complete clipboard request: {}", .{err});
            return false;
        };
    }

    return true;
}

pub fn setClipboard(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
    contents: []const apprt.ClipboardContent,
    confirm: bool,
) !void {
    _ = confirm;

    if (clipboard_type != .standard) return;

    const text: [:0]const u8 = for (contents) |content| {
        if (std.mem.eql(u8, content.mime, "text/plain") or
            std.mem.startsWith(u8, content.mime, "text/"))
        {
            break content.data;
        }
    } else if (contents.len > 0) contents[0].data else return;

    const alloc = self.app.core_app.alloc;

    const wide = std.unicode.utf8ToUtf16LeAlloc(alloc, text) catch |err| {
        log.warn("Failed to convert text to UTF-16: {}", .{err});
        return;
    };
    defer alloc.free(wide);

    if (c.OpenClipboard(self.hwnd) == 0) {
        log.warn("Failed to open clipboard for writing", .{});
        return;
    }
    defer _ = c.CloseClipboard();

    _ = c.EmptyClipboard();

    const byte_len = (wide.len + 1) * 2;
    const gmem = c.GlobalAlloc(c.GMEM_MOVEABLE, byte_len) orelse {
        log.warn("Failed to allocate global memory for clipboard", .{});
        return;
    };

    const dest = c.GlobalLock(gmem) orelse {
        _ = c.GlobalFree(gmem);
        log.warn("Failed to lock global memory for clipboard", .{});
        return;
    };

    const dest_bytes: [*]u8 = @ptrCast(dest);
    const src_bytes = std.mem.sliceAsBytes(wide);
    @memcpy(dest_bytes[0..src_bytes.len], src_bytes);
    dest_bytes[src_bytes.len] = 0;
    dest_bytes[src_bytes.len + 1] = 0;

    _ = c.GlobalUnlock(gmem);

    if (c.SetClipboardData(c.CF_UNICODETEXT, gmem) == null) {
        _ = c.GlobalFree(gmem);
        log.warn("Failed to set clipboard data", .{});
    }
}

pub fn defaultTermioEnv(self: *Surface) !std.process.EnvMap {
    return try std.process.getEnvMap(self.app.core_app.alloc);
}

pub fn redrawInspector(self: *Surface) void {
    _ = self;
}

/// Show the child-exited banner as a STATIC control child of the Window HWND.
pub fn showChildExited(self: *Surface, info: ChildExitedInfo) void {
    self.child_exited_info = info;

    // Destroy any existing banner first.
    self.destroyBannerWindow();

    // Get surface position in Window client coordinates.
    var surface_rect: c.RECT = undefined;
    if (c.GetWindowRect(self.hwnd, &surface_rect) == 0) return;
    var pt = c.POINT{ .x = surface_rect.left, .y = surface_rect.top };
    _ = c.ScreenToClient(self.window.hwnd, &pt);

    var client_rect: c.RECT = undefined;
    if (c.GetClientRect(self.hwnd, &client_rect) == 0) return;
    const surface_width = client_rect.right - client_rect.left;

    // Format the message text.
    var msg_buf: [128]u8 = undefined;
    const msg_utf8 = std.fmt.bufPrint(&msg_buf, "Process exited with code {d}  (press any key to dismiss)", .{info.exit_code}) catch return;

    const alloc = self.app.core_app.alloc;
    const wide = std.unicode.utf8ToUtf16LeAlloc(alloc, msg_utf8) catch return;
    defer alloc.free(wide);
    const wide_z = alloc.allocSentinel(u16, wide.len, 0) catch return;
    defer alloc.free(wide_z);
    @memcpy(wide_z[0..wide.len], wide);

    const static_class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
    const banner = c.CreateWindowExW(
        0,
        static_class,
        wide_z,
        c.WS_CHILD | c.WS_VISIBLE | c.SS_CENTER | c.SS_CENTERIMAGE,
        pt.x,
        pt.y,
        surface_width,
        BANNER_HEIGHT,
        self.window.hwnd,
        null,
        self.app.hinstance,
        null,
    );
    if (banner) |h| {
        self.banner_hwnd = h;
        // Set the font to the default GUI font.
        _ = c.SendMessageW(h, c.WM_SETFONT, @bitCast(@intFromPtr(c.GetStockObject(c.DEFAULT_GUI_FONT))), 1);
        // Create and cache the background brush.
        const bg_color: c.COLORREF = if (info.exit_code != 0) c.RGB(180, 40, 40) else c.RGB(40, 140, 40);
        self.banner_brush = c.CreateSolidBrush(bg_color);
    }
}

/// Dismiss the child-exited banner.
fn dismissChildExitedBanner(self: *Surface) void {
    self.child_exited_info = null;
    self.destroyBannerWindow();
}

/// Destroy the banner HWND and free the cached brush.
fn destroyBannerWindow(self: *Surface) void {
    if (self.banner_hwnd) |h| {
        _ = c.DestroyWindow(h);
        self.banner_hwnd = null;
    }
    if (self.banner_brush) |brush| {
        _ = c.DeleteObject(@ptrCast(brush));
        self.banner_brush = null;
    }
}

// --- Private implementation ---

/// Position the IME composition window near the text cursor.
fn positionImeWindow(self: *Surface) void {
    const himc = c.ImmGetContext(self.hwnd);
    if (himc == null) return;
    defer _ = c.ImmReleaseContext(self.hwnd, himc.?);

    var cf = c.COMPOSITIONFORM{
        .dwStyle = c.CFS_POINT,
        .ptCurrentPos = .{ .x = 0, .y = 0 },
        .rcArea = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    };

    if (self.core_surface) |_| {
        const cursor_pos = self.getCursorPos() catch return;
        cf.ptCurrentPos.x = @intFromFloat(cursor_pos.x);
        cf.ptCurrentPos.y = @intFromFloat(cursor_pos.y);
    }

    _ = c.ImmSetCompositionWindow(himc.?, &cf);
}


fn createChildWindow(self: *Surface) !void {
    const class_name_w = std.unicode.utf8ToUtf16LeStringLiteral("GhosttySurface");

    // Fill the parent's content area
    const rect = self.window.getContentRect();

    const hwnd = c.CreateWindowExW(
        0, // dwExStyle
        class_name_w,
        std.unicode.utf8ToUtf16LeStringLiteral(""), // No title for child
        c.WS_CHILD | c.WS_VISIBLE | c.WS_CLIPSIBLINGS,
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        self.window.hwnd, // parent
        null, // menu
        self.app.hinstance,
        null, // lpParam
    );

    if (hwnd == null) {
        log.err("Failed to create child surface window", .{});
        return error.CreateWindowFailed;
    }

    self.hwnd = hwnd.?;

    // Store Surface pointer in window user data
    _ = c.SetWindowLongPtrW(self.hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    // Get device context (only needed for OpenGL)
    if (build_config.renderer != .directx) {
        const hdc = c.GetDC(self.hwnd);
        if (hdc == null) {
            return error.GetDCFailed;
        }
        self.hdc = hdc.?;
    }

    log.info("Created child surface window", .{});
}

/// Initializes Direct3D 11 for this surface.
fn initD3D11(self: *Surface) !void {
    const size = self.getSize() catch apprt.SurfaceSize{ .width = 800, .height = 600 };
    self.d3d11_ctx = try d3d11mod.createDeviceAndSwapChain(
        self.hwnd,
        size.width,
        size.height,
    );
    self.gl_initialized = true;
    log.info("Initialized D3D11 context", .{});
}

/// Present the D3D11 swap chain.
pub fn presentD3D11(self: *Surface) !void {
    if (self.d3d11_ctx) |*ctx| {
        try d3d11mod.present(ctx, 0);
    }
}

/// Returns the DXGI swap chain, if D3D11 is active.
pub fn getSwapChain(self: *Surface) ?@import("../../renderer/directx/d3d11.zig").IDXGISwapChain {
    if (build_config.renderer != .directx) return null;
    const ctx = self.d3d11_ctx orelse return null;
    return ctx.swap_chain;
}

/// Resize the D3D11 swap chain buffers.
pub fn resizeD3D11(self: *Surface, width: u32, height: u32) !void {
    if (self.d3d11_ctx) |*ctx| {
        try d3d11mod.resizeBuffers(ctx, width, height);
    }
}

/// Initializes the OpenGL context for this surface.
fn initOpenGL(self: *Surface) !void {
    self.hglrc = try opengl.createContext(self.hdc);
    self.gl_initialized = true;
    log.info("Initialized OpenGL context", .{});
}

/// Makes this surface's OpenGL context current.
pub fn makeContextCurrent(self: *Surface) !void {
    if (build_config.renderer == .directx) return;
    if (self.hglrc) |hglrc| {
        try opengl.makeCurrent(self.hdc, hglrc);
    }
}

/// Releases the OpenGL context from the current thread.
pub fn releaseContext(self: *Surface) void {
    _ = self;
    if (build_config.renderer == .directx) return;
    _ = c.wglMakeCurrent(null, null);
}

/// Loads the OpenGL function pointers via glad on the current thread.
pub fn prepareOpenGL(self: *Surface) !void {
    _ = self;
    if (build_config.renderer == .directx) return;
    try opengl.prepareContext();
}

/// Swaps the OpenGL buffers to present the rendered frame.
pub fn swapBuffers(self: *Surface) !void {
    if (build_config.renderer == .directx) return;
    try opengl.swapBuffers(self.hdc);
}

/// Maps a terminal mouse shape to a Win32 cursor.
pub fn mouseShapeToCursor(shape: terminal.MouseShape) c.HCURSOR {
    const cursor_id: [*:0]align(1) const u16 = switch (shape) {
        .default => c.IDC_ARROW,
        .text => c.IDC_IBEAM,
        .pointer => c.IDC_HAND,
        .crosshair => c.IDC_CROSS,
        .help => c.IDC_HELP,
        .not_allowed, .no_drop => c.IDC_NO,
        .all_scroll, .move => c.IDC_SIZEALL,
        .col_resize, .ew_resize, .e_resize, .w_resize => c.IDC_SIZEWE,
        .row_resize, .ns_resize, .n_resize, .s_resize => c.IDC_SIZENS,
        .nesw_resize, .ne_resize, .sw_resize => c.IDC_SIZENESW,
        .nwse_resize, .nw_resize, .se_resize => c.IDC_SIZENWSE,
        .wait => c.IDC_WAIT,
        .progress => c.IDC_APPSTARTING,
        else => c.IDC_ARROW,
    };
    return c.LoadCursorW(null, cursor_id);
}

/// Window procedure for the child surface window.
pub fn windowProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(c.WINAPI) LRESULT {
    const ptr = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
    const surface: ?*Surface = if (ptr != 0)
        @ptrFromInt(@as(usize, @bitCast(ptr)))
    else
        null;

    switch (msg) {
        c.WM_DESTROY => {
            log.info("WM_DESTROY received on surface", .{});
            if (surface) |s| {
                // Mark as closing so destroy() (from unref) won't call
                // DestroyWindow again during the parent's WM_DESTROY cascade.
                s.closing = true;
                s.destroyResources();
                _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
            }
            return 0;
        },

        c.WM_CLOSE => {
            // Post WM_GHOSTTY_CLOSE_SURFACE to parent Window for deferred
            // tree removal (avoids use-after-free if called from core).
            if (surface) |s| {
                _ = c.PostMessageW(
                    s.window.hwnd,
                    Window.WM_GHOSTTY_CLOSE_SURFACE,
                    @bitCast(@intFromPtr(s)),
                    0,
                );
            }
            return 0;
        },

        c.WM_SIZE => {
            if (surface) |s| {
                const width: u32 = @intCast(lparam & 0xFFFF);
                const height: u32 = @intCast((lparam >> 16) & 0xFFFF);
                log.debug("Surface WM_SIZE: {}x{}", .{ width, height });

                // Resize D3D11 swap chain buffers
                if (build_config.renderer == .directx) {
                    s.resizeD3D11(width, height) catch |err| {
                        log.warn("Failed to resize D3D11 swap chain: {}", .{err});
                    };
                }

                // Reposition the search bar if visible.
                if (s.search_bar) |bar| {
                    if (bar.is_visible) {
                        bar.reposition();
                    }
                }

                // Reposition WinUI search if visible.
                if (s.winui_search != null) {
                    s.repositionWinUISearch();
                }

                // Notify core surface of size change
                if (s.core_surface) |cs| {
                    cs.sizeCallback(.{
                        .width = @intCast(width),
                        .height = @intCast(height),
                    }) catch |err| {
                        log.warn("Failed to handle size change: {}", .{err});
                    };
                }

                _ = c.InvalidateRect(hwnd, null, 0);
            }
            return 0;
        },

        c.WM_ERASEBKGND => {
            return 1;
        },

        c.WM_PAINT => {
            if (surface) |s| {
                if (s.core_surface) |cs| {
                    cs.renderer_thread.draw_now.notify() catch {};
                }
            }
            // Validate the paint region so Windows stops sending WM_PAINT.
            var ps: c.PAINTSTRUCT = undefined;
            _ = c.BeginPaint(hwnd, &ps);
            _ = c.EndPaint(hwnd, &ps);
            return 0;
        },

        // Keyboard input
        c.WM_KEYDOWN, c.WM_KEYUP => {
            if (surface) |s| {
                // Dismiss child-exited banner on any key press
                if (msg == c.WM_KEYDOWN and s.child_exited_info != null) {
                    s.dismissChildExitedBanner();
                    return 0;
                }
                inputmod.handleKeyEvent(s, msg, wparam, lparam) catch |err| {
                    log.warn("Failed to handle key event: {}", .{err});
                };
            }
            return 0;
        },

        c.WM_SYSKEYDOWN, c.WM_SYSKEYUP => {
            if (surface) |s| {
                inputmod.handleKeyEvent(s, msg, wparam, lparam) catch |err| {
                    log.warn("Failed to handle key event: {}", .{err});
                };
            }
            // Let DefWindowProc handle system keys (Alt+F4 → SC_CLOSE etc.)
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        c.WM_CHAR => {
            if (surface) |s| {
                inputmod.handleCharEvent(s, wparam) catch |err| {
                    log.warn("Failed to handle char event: {}", .{err});
                };
            }
            return 0;
        },

        c.WM_DEADCHAR, c.WM_SYSDEADCHAR => {
            if (surface) |s| {
                inputmod.handleDeadCharEvent(s) catch |err| {
                    log.warn("Failed to handle dead char event: {}", .{err});
                };
            }
            return 0;
        },

        // Mouse input
        c.WM_LBUTTONDOWN,
        c.WM_LBUTTONUP,
        c.WM_RBUTTONDOWN,
        c.WM_RBUTTONUP,
        c.WM_MBUTTONDOWN,
        c.WM_MBUTTONUP,
        c.WM_XBUTTONDOWN,
        c.WM_XBUTTONUP,
        => {
            if (surface) |s| {
                // Claim keyboard focus on click
                if (msg == c.WM_LBUTTONDOWN or msg == c.WM_RBUTTONDOWN or msg == c.WM_MBUTTONDOWN) {
                    _ = c.SetFocus(s.hwnd);
                }
                inputmod.handleMouseButton(s, msg, wparam, lparam) catch |err| {
                    log.warn("Failed to handle mouse button: {}", .{err});
                };
            }
            return 0;
        },

        c.WM_MOUSEMOVE => {
            if (surface) |s| {
                inputmod.handleMouseMove(s, wparam, lparam) catch |err| {
                    log.warn("Failed to handle mouse move: {}", .{err});
                };
            }
            return 0;
        },

        c.WM_MOUSEWHEEL => {
            if (surface) |s| {
                inputmod.handleMouseWheel(s, wparam, lparam) catch |err| {
                    log.warn("Failed to handle mouse wheel: {}", .{err});
                };
            }
            return 0;
        },

        c.WM_MOUSEHWHEEL => {
            if (surface) |s| {
                inputmod.handleMouseHWheel(s, wparam, lparam) catch |err| {
                    log.warn("Failed to handle horizontal mouse wheel: {}", .{err});
                };
            }
            return 0;
        },

        c.WM_MOUSELEAVE => {
            if (surface) |s| {
                inputmod.handleMouseLeave(s) catch |err| {
                    log.warn("Failed to handle mouse leave: {}", .{err});
                };
            }
            return 0;
        },

        // Focus events
        c.WM_SETFOCUS => {
            if (surface) |s| {
                s.focused = true;
                if (s.core_surface) |cs| {
                    cs.focusCallback(true) catch |err| {
                        log.warn("Failed to handle focus gain: {}", .{err});
                    };
                }
            }
            return 0;
        },

        c.WM_KILLFOCUS => {
            if (surface) |s| {
                // wparam is the HWND gaining focus. If focus is moving
                // to our search bar or its edit control, don't report
                // focus loss to the core — the search bar is logically
                // part of this surface.
                const gaining_focus: ?HWND = if (wparam != 0)
                    @ptrFromInt(wparam)
                else
                    null;
                const is_search_child = if (s.search_bar) |bar|
                    (gaining_focus == bar.hwnd or gaining_focus == bar.edit_hwnd)
                else
                    false;

                const is_winui_child = if (s.winui_search_visible) blk: {
                    if (s.app.winui.xaml_host_get_hwnd) |get_fn| {
                        const island = get_fn(s.window.winui_host);
                        break :blk (gaining_focus == island);
                    }
                    break :blk false;
                } else false;

                const is_island_descendant = if (s.winui_search_visible and gaining_focus != null) blk: {
                    if (s.app.winui.xaml_host_get_hwnd) |get_fn| {
                        const island = get_fn(s.window.winui_host);
                        if (island) |ih| {
                            break :blk c.IsChild(ih, gaining_focus.?) != 0;
                        }
                    }
                    break :blk false;
                } else false;

                if (!is_search_child and !is_winui_child and !is_island_descendant) {
                    s.focused = false;
                    if (s.core_surface) |cs| {
                        cs.focusCallback(false) catch |err| {
                            log.warn("Failed to handle focus loss: {}", .{err});
                        };
                    }
                }
            }
            return 0;
        },

        // Let the parent window handle resize borders.
        // Without this, the child surface HWND covers the edges and
        // DefWindowProc returns HTCLIENT, preventing window resizing.
        c.WM_NCHITTEST => {
            if (surface) |s| {
                const parent = s.window;
                if (c.IsZoomed(parent.hwnd) == 0 and !parent.is_fullscreen) {
                    // Get cursor in screen coords.
                    const cursor: c.POINT = .{
                        .x = c.GET_X_LPARAM(lparam),
                        .y = c.GET_Y_LPARAM(lparam),
                    };
                    var win_rect: c.RECT = undefined;
                    _ = &win_rect;
                    if (c.GetWindowRect(parent.hwnd, &win_rect) != 0) {
                        const border = parent.getResizeBorderThickness();
                        if (cursor.y < win_rect.top + border or
                            cursor.y >= win_rect.bottom - border or
                            cursor.x < win_rect.left + border or
                            cursor.x >= win_rect.right - border)
                        {
                            // In the resize border — let the parent handle it.
                            return -1; // HTTRANSPARENT
                        }
                    }
                }
            }
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        // Cursor shape management
        c.WM_SETCURSOR => {
            if (surface) |s| {
                if (c.LOWORD(lparam) == c.HTCLIENT) {
                    const cursor: c.HCURSOR = if (s.mouse_hidden) null else s.current_cursor;
                    _ = c.SetCursor(cursor);
                    return 1;
                }
            }
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        // IME composition messages
        c.WM_IME_STARTCOMPOSITION => {
            if (surface) |s| {
                s.positionImeWindow();
            }
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        c.WM_IME_COMPOSITION => {
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        c.WM_IME_ENDCOMPOSITION => {
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        else => {},
    }

    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}
