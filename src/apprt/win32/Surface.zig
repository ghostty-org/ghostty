//! Win32 Surface. Each Surface corresponds to one HWND (window) and
//! owns an OpenGL (WGL) context for rendering.
const Surface = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const input = @import("../../input.zig");
const terminal = @import("../../terminal/main.zig");
const termio = @import("../../termio.zig");
const CoreSurface = @import("../../Surface.zig");
const internal_os = @import("../../os/main.zig");

const App = @import("App.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32);

/// The Win32 window handle.
hwnd: ?w32.HWND = null,

/// Device context for the window (with CS_OWNDC, this persists for the
/// lifetime of the window).
hdc: ?w32.HDC = null,

/// WGL OpenGL rendering context.
hglrc: ?w32.HGLRC = null,

/// Current client area dimensions in pixels.
width: u32 = 800,
height: u32 = 600,

/// DPI scale factor (DPI / 96.0).
scale: f32 = 1.0,

/// The parent App.
app: *App,

/// The core terminal surface. Initialized by init() after creating
/// the window and WGL context. Manages fonts, renderer, PTY, and IO.
core_surface: CoreSurface = undefined,

/// Whether core_surface has been fully initialized. Win32 messages
/// (WM_SETFOCUS, WM_SIZE, etc.) can arrive during init before
/// core_surface is ready — handlers must check this flag.
core_surface_ready: bool = false,

/// Whether core_surface.init() completed successfully (ever).
/// Different from core_surface_ready which is cleared during shutdown.
core_surface_initialized: bool = false,

/// Buffered high surrogate from WM_CHAR for supplementary plane characters.
/// Win32 delivers codepoints > U+FFFF as two WM_CHAR messages (surrogate pair).
high_surrogate: u16 = 0,

/// Whether an IME composition session is active. When true, handleKeyEvent
/// skips VK_PROCESSKEY events (the IME is intercepting keys), and composed
/// text is extracted from WM_IME_COMPOSITION instead.
ime_composing: bool = false,

/// Set to true when handleKeyEvent produced text via ToUnicode. The
/// subsequent WM_CHAR from TranslateMessage is then suppressed to avoid
/// double input. Reset to false when WM_CHAR arrives (whether suppressed
/// or processed). This allows WM_CHAR through for cases where
/// handleKeyEvent did NOT produce text: IME (VK_PROCESSKEY), SendInput
/// Unicode (VK_PACKET), or direct PostMessage.
key_event_produced_text: bool = false,

/// Whether the user is actively dragging a window border/titlebar.
/// During live resize, handleResize blocks until the renderer draws
/// one frame at the new size (or a timeout expires), eliminating the
/// visual flicker from the DWM stretching stale content.
in_live_resize: bool = false,

/// Manual-reset event signaled by the renderer thread after presenting
/// a frame. The main thread waits on this during live resize to
/// synchronize rendering with the DWM compositor.
frame_event: ?w32.HANDLE = null,

/// Cached scrollbar state for updating the Win32 scrollbar.
/// Updated by the core via performAction(.scrollbar).
scrollbar_total: usize = 0,
scrollbar_offset: usize = 0,
scrollbar_len: usize = 0,

/// The current mouse cursor. Cached so WM_SETCURSOR can restore it
/// (DefWindowProc resets the cursor to the class cursor on every
/// WM_SETCURSOR, so we must override it ourselves).
current_cursor: ?w32.HCURSOR = null,

/// Search popup HWND (a small top-level window containing an Edit
/// control). Uses a popup instead of a child window because the
/// OpenGL viewport covers the entire client area and would paint
/// over a child control.
search_hwnd: ?w32.HWND = null,

/// The Edit control inside the search popup.
search_edit: ?w32.HWND = null,

/// Whether the search bar is currently visible.
search_active: bool = false,

/// Whether the window is currently in fullscreen mode.
is_fullscreen: bool = false,

/// Saved window style and placement for restoring from fullscreen.
saved_style: u32 = 0,
saved_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

/// Initialize a new Surface by creating a Win32 window and WGL context,
/// then initialize the core terminal surface (fonts, renderer, PTY, IO).
pub fn init(self: *Surface, app: *App) !void {
    self.* = .{
        .app = app,
    };

    // Create a manual-reset event for synchronizing resize with the
    // renderer thread. Manual-reset so we control exactly when it's reset.
    self.frame_event = w32.CreateEventW(null, 1, 0, null);

    // Create the window through the App
    const hwnd = try app.createWindow();
    self.hwnd = hwnd;
    errdefer {
        _ = w32.DestroyWindow(hwnd);
        self.hwnd = null;
    }

    // Store the Surface pointer in the window's GWLP_USERDATA so that
    // the WndProc can retrieve it.
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    // Get the device context. With CS_OWNDC, this DC is valid for
    // the lifetime of the window.
    self.hdc = w32.GetDC(hwnd);
    if (self.hdc == null) return error.Win32Error;
    errdefer {
        _ = w32.ReleaseDC(hwnd, self.hdc.?);
        self.hdc = null;
    }

    // Set up the pixel format for OpenGL
    try self.setupPixelFormat();

    // Create the WGL context
    self.hglrc = w32.wglCreateContext(self.hdc.?);
    if (self.hglrc == null) return error.Win32Error;
    errdefer {
        _ = w32.wglMakeCurrent(null, null);
        _ = w32.wglDeleteContext(self.hglrc.?);
        self.hglrc = null;
    }

    // Query the initial DPI and size
    self.updateDpiScale();
    self.updateClientSize();

    log.debug("Win32 surface created: {}x{} scale={d:.2}", .{
        self.width,
        self.height,
        self.scale,
    });

    // --- Core terminal surface initialization ---
    const alloc = app.core_app.alloc;

    // Register this surface with the core app.
    try app.core_app.addSurface(self);
    errdefer app.core_app.deleteSurface(self);

    // Create a config copy for this surface.
    var config = try apprt.surface.newConfig(app.core_app, &app.config, .window);
    defer config.deinit();

    // Initialize the core surface. This sets up fonts, the renderer, PTY,
    // and spawns the renderer + IO threads.
    try self.core_surface.init(
        alloc,
        &config,
        app.core_app,
        app,
        self,
    );

    // Mark the surface as ready. Before this point, Win32 messages
    // (triggered by ShowWindow, wglCreateContext, etc.) must be ignored.
    self.core_surface_ready = true;
    self.core_surface_initialized = true;
}

pub fn deinit(self: *Surface) void {
    if (self.core_surface_initialized) {
        // Deinit the core surface first (stops renderer/IO threads, cleans up
        // terminal state, PTY, fonts, etc.).
        self.core_surface.deinit();

        // Unregister from the core app's surface list.
        self.app.core_app.deleteSurface(self);
    }

    if (self.frame_event) |event| {
        _ = w32.CloseHandle(event);
        self.frame_event = null;
    }

    if (self.hglrc) |hglrc| {
        // Ensure the context is not current before deleting
        _ = w32.wglMakeCurrent(null, null);
        _ = w32.wglDeleteContext(hglrc);
        self.hglrc = null;
    }

    if (self.hdc) |hdc| {
        if (self.hwnd) |hwnd| {
            _ = w32.ReleaseDC(hwnd, hdc);
        }
        self.hdc = null;
    }

    if (self.hwnd) |hwnd| {
        _ = w32.DestroyWindow(hwnd);
        self.hwnd = null;
    }
}

/// Set up a pixel format suitable for OpenGL rendering.
fn setupPixelFormat(self: *Surface) !void {
    const pfd = w32.PIXELFORMATDESCRIPTOR{
        .nSize = @sizeOf(w32.PIXELFORMATDESCRIPTOR),
        .nVersion = 1,
        .dwFlags = w32.PFD_DRAW_TO_WINDOW | w32.PFD_SUPPORT_OPENGL | w32.PFD_DOUBLEBUFFER,
        .iPixelType = w32.PFD_TYPE_RGBA,
        .cColorBits = 32,
        .cRedBits = 0,
        .cRedShift = 0,
        .cGreenBits = 0,
        .cGreenShift = 0,
        .cBlueBits = 0,
        .cBlueShift = 0,
        .cAlphaBits = 8,
        .cAlphaShift = 0,
        .cAccumBits = 0,
        .cAccumRedBits = 0,
        .cAccumGreenBits = 0,
        .cAccumBlueBits = 0,
        .cAccumAlphaBits = 0,
        .cDepthBits = 24,
        .cStencilBits = 8,
        .cAuxBuffers = 0,
        .iLayerType = 0, // PFD_MAIN_PLANE
        .bReserved = 0,
        .dwLayerMask = 0,
        .dwVisibleMask = 0,
        .dwDamageMask = 0,
    };

    const format = w32.ChoosePixelFormat(self.hdc.?, &pfd);
    if (format == 0) return error.Win32Error;

    if (w32.SetPixelFormat(self.hdc.?, format, &pfd) == 0)
        return error.Win32Error;
}

/// Update the DPI scale factor from the window's DPI.
fn updateDpiScale(self: *Surface) void {
    if (self.hwnd) |hwnd| {
        const dpi = w32.GetDpiForWindow(hwnd);
        if (dpi != 0) {
            self.scale = @as(f32, @floatFromInt(dpi)) / 96.0;
        }
    }
}

/// Update the cached client area size.
fn updateClientSize(self: *Surface) void {
    if (self.hwnd) |hwnd| {
        var rect: w32.RECT = undefined;
        if (w32.GetClientRect(hwnd, &rect) != 0) {
            self.width = @intCast(rect.right - rect.left);
            self.height = @intCast(rect.bottom - rect.top);
        }
    }
}

// -----------------------------------------------------------------------
// Methods called by the core Surface.zig (rt_surface.*)
// -----------------------------------------------------------------------

pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
    return .{ .x = self.scale, .y = self.scale };
}

pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
    return .{ .width = self.width, .height = self.height };
}

pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
    if (self.hwnd) |hwnd| {
        var point: w32.POINT = undefined;
        if (w32.GetCursorPos_(&point) != 0) {
            _ = w32.ScreenToClient(hwnd, &point);
            return .{
                .x = @floatFromInt(point.x),
                .y = @floatFromInt(point.y),
            };
        }
    }
    return .{ .x = 0, .y = 0 };
}

pub fn getTitle(self: *const Surface) ?[:0]const u8 {
    _ = self;
    // TODO: Store and return the title set via setTitle.
    return null;
}

pub fn close(self: *Surface, process_active: bool) void {
    // Post WM_CLOSE instead of calling DestroyWindow directly.
    // close() is often called from within core_surface callbacks
    // (e.g., keyCallback when child_exited is true). If we called
    // DestroyWindow here, it would synchronously send WM_DESTROY,
    // which triggers handleDestroy → deinit → free(self). Then
    // when DestroyWindow returns, the caller is still running on
    // freed memory (use-after-free → alignment panic).
    //
    // PostMessage defers destruction to after the current message
    // dispatch completes, so all code holding references to self
    // has finished executing by the time WM_CLOSE is processed.
    //
    // If a child process is still running, wparam=1 tells the
    // WM_CLOSE handler to show a confirmation dialog.
    if (self.hwnd) |hwnd| {
        const confirm: usize = if (process_active) 1 else 0;
        _ = w32.PostMessageW(hwnd, w32.WM_CLOSE, confirm, 0);
    }
}

pub fn supportsClipboard(
    self: *const Surface,
    clipboard_type: apprt.Clipboard,
) bool {
    _ = self;
    return switch (clipboard_type) {
        .standard => true,
        .selection, .primary => false,
    };
}

pub fn clipboardRequest(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
    state: apprt.ClipboardRequest,
) !bool {
    // Only the standard clipboard is supported on Win32.
    if (clipboard_type != .standard) return false;

    const alloc = self.app.core_app.alloc;

    if (w32.OpenClipboard(self.hwnd) == 0) {
        log.warn("OpenClipboard failed", .{});
        return false;
    }
    defer _ = w32.CloseClipboard();

    // Retrieve CF_UNICODETEXT (UTF-16LE, null-terminated).
    const hglobal = w32.GetClipboardData(w32.CF_UNICODETEXT) orelse {
        // No text on the clipboard.
        return false;
    };

    const ptr16 = w32.GlobalLock(hglobal) orelse {
        log.warn("GlobalLock failed", .{});
        return false;
    };
    defer _ = w32.GlobalUnlock(hglobal);

    // Reinterpret the byte pointer as a u16 pointer for UTF-16LE data.
    const wptr: [*]const u16 = @ptrCast(@alignCast(ptr16));

    // Find the null terminator to get the length in u16 code units.
    var wlen: usize = 0;
    while (wptr[wlen] != 0) wlen += 1;

    // Convert UTF-16LE to a UTF-8 slice owned by the allocator.
    const utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, wptr[0..wlen]) catch |err| {
        log.warn("utf16LeToUtf8Alloc failed: {}", .{err});
        return false;
    };
    defer alloc.free(utf8);

    // Null-terminate for completeClipboardRequest.
    const utf8z = try alloc.dupeZ(u8, utf8);
    defer alloc.free(utf8z);

    // Complete the request synchronously. confirmed=true avoids the
    // unsafe-paste prompt (matches behaviour of other synchronous runtimes).
    self.core_surface.completeClipboardRequest(state, utf8z, true) catch |err| switch (err) {
        error.UnsafePaste,
        error.UnauthorizedPaste,
        => {
            // Re-complete with confirmed=false so the core surface can
            // handle the prompt; for now just log and skip.
            log.warn("clipboard paste was flagged as unsafe/unauthorized", .{});
        },
        else => {
            log.err("completeClipboardRequest error: {}", .{err});
        },
    };

    return true;
}

pub fn setClipboard(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
    contents: []const apprt.ClipboardContent,
    confirm: bool,
) !void {
    _ = confirm;

    // Only the standard clipboard is supported on Win32.
    if (clipboard_type != .standard) return;

    // Find the text/plain content.
    const text = blk: {
        for (contents) |c| {
            if (std.mem.eql(u8, c.mime, "text/plain")) break :blk c.data;
        }
        // No text/plain content; nothing to write.
        return;
    };

    const alloc = self.app.core_app.alloc;

    // Convert UTF-8 to UTF-16LE.  Add 1 for the null terminator.
    const utf16 = try std.unicode.utf8ToUtf16LeAlloc(alloc, text);
    defer alloc.free(utf16);

    // Size in bytes including the null terminator (u16 → 2 bytes each).
    const byte_size = (utf16.len + 1) * @sizeOf(u16);

    // Allocate a moveable global memory block.
    const hglobal = w32.GlobalAlloc(w32.GMEM_MOVEABLE, byte_size) orelse {
        log.warn("GlobalAlloc failed for clipboard write", .{});
        return;
    };

    const dst_bytes = w32.GlobalLock(hglobal) orelse {
        log.warn("GlobalLock failed for clipboard write", .{});
        _ = w32.GlobalFree(hglobal);
        return;
    };

    // Copy the UTF-16LE data (including null terminator) into the block.
    const dst16: [*]u16 = @ptrCast(@alignCast(dst_bytes));
    @memcpy(dst16[0..utf16.len], utf16);
    dst16[utf16.len] = 0; // null terminator

    _ = w32.GlobalUnlock(hglobal);

    if (w32.OpenClipboard(self.hwnd) == 0) {
        log.warn("OpenClipboard failed for clipboard write", .{});
        _ = w32.GlobalFree(hglobal);
        return;
    }
    defer _ = w32.CloseClipboard();

    _ = w32.EmptyClipboard();

    // SetClipboardData takes ownership of hglobal on success.
    if (w32.SetClipboardData(w32.CF_UNICODETEXT, hglobal) == null) {
        log.warn("SetClipboardData failed", .{});
        _ = w32.GlobalFree(hglobal);
    }
}

pub fn defaultTermioEnv(self: *const Surface) !std.process.EnvMap {
    const alloc = self.app.core_app.alloc;
    var env = try internal_os.getEnvMap(alloc);
    errdefer env.deinit();

    // TERM and COLORTERM are set by termio/Exec.zig with platform-aware
    // logic (checking for terminfo, resources_dir, etc.). Do not set them here.

    return env;
}

/// Set the window title. Called from performAction(.set_title).
pub fn setTitle(self: *Surface, title: [:0]const u8) void {
    if (self.hwnd) |hwnd| {
        // Convert UTF-8 title to UTF-16 for Win32
        var buf: [512]u16 = undefined;
        const len = std.unicode.utf8ToUtf16Le(&buf, title) catch return;
        if (len < buf.len) {
            buf[len] = 0;
            _ = w32.SetWindowTextW(hwnd, @ptrCast(&buf));
        }
    }
}

/// Toggle fullscreen mode. Saves/restores window style and placement.
pub fn toggleFullscreen(self: *Surface) void {
    const hwnd = self.hwnd orelse return;

    if (!self.is_fullscreen) {
        // Save current style and window rect for restore.
        self.saved_style = w32.GetWindowLongW(hwnd, w32.GWL_STYLE);
        _ = w32.GetWindowRect(hwnd, &self.saved_rect);

        // Remove decorations: keep only WS_POPUP | WS_VISIBLE.
        const new_style = self.saved_style & ~@as(u32, w32.WS_OVERLAPPEDWINDOW) | w32.WS_POPUP;
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, new_style);

        // Get the monitor that contains this window and go fullscreen on it.
        const monitor = w32.MonitorFromWindow(hwnd, w32.MONITOR_DEFAULTTONEAREST);
        var mi: w32.MONITORINFO = undefined;
        mi.cbSize = @sizeOf(w32.MONITORINFO);
        if (w32.GetMonitorInfoW(monitor, &mi) != 0) {
            _ = w32.SetWindowPos(
                hwnd,
                null, // HWND_TOP
                mi.rcMonitor.left,
                mi.rcMonitor.top,
                mi.rcMonitor.right - mi.rcMonitor.left,
                mi.rcMonitor.bottom - mi.rcMonitor.top,
                w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED,
            );
        }

        self.is_fullscreen = true;
    } else {
        // Restore decorations.
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, self.saved_style);

        // Restore position and size.
        _ = w32.SetWindowPos(
            hwnd,
            null,
            self.saved_rect.left,
            self.saved_rect.top,
            self.saved_rect.right - self.saved_rect.left,
            self.saved_rect.bottom - self.saved_rect.top,
            w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED,
        );

        self.is_fullscreen = false;
    }
}

/// Set the mouse cursor shape. Caches the handle so WM_SETCURSOR can
/// restore it (Windows resets the cursor on every mouse move otherwise).
pub fn setMouseShape(self: *Surface, shape: terminal.MouseShape) void {
    const cursor = switch (shape) {
        .text => w32.LoadCursorW(null, w32.IDC_IBEAM),
        .pointer => w32.LoadCursorW(null, w32.IDC_HAND),
        .crosshair => w32.LoadCursorW(null, w32.IDC_CROSS),
        .e_resize, .w_resize, .ew_resize => w32.LoadCursorW(null, w32.IDC_SIZEWE),
        .n_resize, .s_resize, .ns_resize => w32.LoadCursorW(null, w32.IDC_SIZENS),
        .nwse_resize, .nw_resize, .se_resize => w32.LoadCursorW(null, w32.IDC_SIZENWSE),
        .nesw_resize, .ne_resize, .sw_resize => w32.LoadCursorW(null, w32.IDC_SIZENESW),
        .not_allowed => w32.LoadCursorW(null, w32.IDC_NO),
        .progress => w32.LoadCursorW(null, w32.IDC_APPSTARTING),
        .wait => w32.LoadCursorW(null, w32.IDC_WAIT),
        else => w32.LoadCursorW(null, w32.IDC_ARROW),
    };
    self.current_cursor = cursor;
    if (cursor) |c| _ = w32.SetCursor(c);
}

/// Handle WM_SETCURSOR — restore our cached cursor so Windows doesn't
/// reset it to the class cursor (IDC_ARROW) on every mouse move.
/// Returns true if we handled it (caller should return TRUE).
pub fn handleSetCursor(self: *Surface) bool {
    if (self.current_cursor) |c| {
        _ = w32.SetCursor(c);
        return true;
    }
    return false;
}

/// Child window ID for the search edit control.
pub const SEARCH_EDIT_ID: u16 = 100;

/// Show or hide the search bar.
pub fn setSearchActive(self: *Surface, active: bool, needle: [:0]const u8) void {
    if (active) {
        self.search_active = true;
        self.ensureSearchBar();
        if (self.search_hwnd) |popup| {
            self.positionSearchBar();
            _ = w32.ShowWindow(popup, w32.SW_SHOW);

            // Set the search text if provided
            if (needle.len > 0) {
                if (self.search_edit) |edit| {
                    var wbuf: [512]u16 = undefined;
                    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, needle) catch 0;
                    if (wlen < wbuf.len) {
                        wbuf[wlen] = 0;
                        _ = w32.SetWindowTextW(edit, @ptrCast(&wbuf));
                    }
                }
            }

            // Focus the edit control
            if (self.search_edit) |edit| {
                _ = w32.SetFocus(edit);
            }
        }
    } else {
        self.search_active = false;
        if (self.search_hwnd) |popup| {
            _ = w32.ShowWindow(popup, 0); // SW_HIDE
        }
        // Return focus to the main window
        if (self.hwnd) |hwnd| {
            _ = w32.SetFocus(hwnd);
        }
    }
}

/// Create the search popup window if it doesn't exist. The popup is a
/// small top-level window (WS_POPUP) that floats over the main window.
/// A child Edit control inside it handles the actual text input.
/// We can't use a child window of the main HWND because OpenGL covers
/// the entire client area and paints over child controls.
fn ensureSearchBar(self: *Surface) void {
    if (self.search_hwnd != null) return;

    // Create the popup container (no title bar, tool window so it
    // doesn't appear in the taskbar).
    const popup = w32.CreateWindowExW(
        w32.WS_EX_TOOLWINDOW,
        App.WINDOW_CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_POPUP | w32.WS_BORDER,
        0, 0, 310, 32,
        self.hwnd,
        null,
        self.app.hinstance,
        null,
    ) orelse return;

    // Apply dark theme
    const dark_mode: u32 = 1;
    _ = w32.DwmSetWindowAttribute(
        popup,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(u32),
    );
    _ = w32.SetWindowTheme(
        popup,
        std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"),
        null,
    );

    // Create the Edit control inside the popup
    const edit = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.ES_AUTOHSCROLL,
        4, 4, 300, 22,
        popup,
        @ptrFromInt(@as(usize, SEARCH_EDIT_ID)),
        self.app.hinstance,
        null,
    ) orelse {
        _ = w32.DestroyWindow(popup);
        return;
    };

    // Set a readable font
    const font_handle = w32.CreateFontW(
        -16, 0, 0, 0, 400,
        0, 0, 0,
        0, 0, 0, 0, 0,
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
    );
    if (font_handle) |f| {
        _ = w32.SendMessageW(edit, w32.WM_SETFONT, @intFromPtr(f), 1);
    }

    // Store the popup HWND in GWLP_USERDATA so the message loop
    // can route WM_COMMAND from the edit to our surface. We use the
    // parent window's userdata (already set to *Surface).

    // Set GWLP_USERDATA on the popup so the wndProc can route
    // WM_COMMAND (EN_CHANGE) and WM_CTLCOLOREDIT to this Surface.
    _ = w32.SetWindowLongPtrW(popup, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    self.search_hwnd = popup;
    self.search_edit = edit;
}

/// Position the search popup at the top-right corner of the main window.
fn positionSearchBar(self: *Surface) void {
    const popup = self.search_hwnd orelse return;
    const hwnd = self.hwnd orelse return;
    var rect: w32.RECT = undefined;
    if (w32.GetWindowRect(hwnd, &rect) != 0) {
        const bar_width: i32 = 310;
        const bar_height: i32 = 32;
        const padding: i32 = 8;
        // Position at top-right of the window, below the title bar
        _ = w32.MoveWindow(
            popup,
            rect.right - bar_width - padding,
            rect.top + 32 + padding, // 32px for title bar
            bar_width,
            bar_height,
            1,
        );
    }
}

/// Handle text changes in the search edit control (EN_CHANGE).
pub fn handleSearchChange(self: *Surface) void {
    if (!self.core_surface_ready) return;
    const search = self.search_edit orelse return;

    // Get the current search text
    var wbuf: [512]u16 = undefined;
    const wlen: usize = @intCast(w32.GetWindowTextW(search, &wbuf, @intCast(wbuf.len)));

    var utf8_buf: [1024]u8 = undefined;
    const utf8_len = std.unicode.utf16LeToUtf8(&utf8_buf, wbuf[0..wlen]) catch 0;

    // Need a null-terminated slice for performBindingAction
    var needle_buf: [1025]u8 = undefined;
    @memcpy(needle_buf[0..utf8_len], utf8_buf[0..utf8_len]);
    needle_buf[utf8_len] = 0;
    const needle: [:0]const u8 = needle_buf[0..utf8_len :0];

    _ = self.core_surface.performBindingAction(.{ .search = needle }) catch |err| {
        log.err("search error: {}", .{err});
    };
}

/// Handle key events in the search bar. Returns true if handled.
pub fn handleSearchKey(self: *Surface, vk: u16) bool {
    if (!self.core_surface_ready) return false;

    switch (vk) {
        w32.VK_RETURN => {
            // Enter = next match, Shift+Enter = previous match
            const shift = w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0;
            const nav: input.Binding.Action = if (shift)
                .{ .navigate_search = .previous }
            else
                .{ .navigate_search = .next };
            _ = self.core_surface.performBindingAction(nav) catch |err| {
                log.err("navigate_search error: {}", .{err});
            };
            return true;
        },
        w32.VK_ESCAPE => {
            _ = self.core_surface.performBindingAction(.end_search) catch |err| {
                log.err("end_search error: {}", .{err});
            };
            return true;
        },
        else => return false,
    }
}

/// Toggle window decorations (title bar + borders) on/off.
pub fn toggleWindowDecorations(self: *Surface) void {
    const hwnd = self.hwnd orelse return;
    const style = w32.GetWindowLongW(hwnd, w32.GWL_STYLE);
    const has_decorations = (style & w32.WS_CAPTION) != 0;

    if (has_decorations) {
        // Remove decorations: strip caption and thick frame
        const new_style = style & ~@as(u32, w32.WS_CAPTION | w32.WS_THICKFRAME);
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, new_style);
    } else {
        // Restore decorations
        const new_style = style | w32.WS_CAPTION | w32.WS_THICKFRAME;
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, new_style);
    }
    // Force frame recalculation
    _ = w32.SetWindowPos(hwnd, null, 0, 0, 0, 0,
        w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED | 0x0001 | 0x0002); // NOMOVE|NOSIZE
}

/// Update the Win32 scrollbar to reflect the terminal's scroll state.
/// Called from performAction(.scrollbar) when the viewport changes.
pub fn setScrollbar(self: *Surface, scrollbar: terminal.Scrollbar) void {
    const hwnd = self.hwnd orelse return;

    // Cache the values for handleVScroll.
    self.scrollbar_total = scrollbar.total;
    self.scrollbar_offset = scrollbar.offset;
    self.scrollbar_len = scrollbar.len;

    // If total <= visible rows, there's nothing to scroll — hide the
    // scrollbar entirely.
    if (scrollbar.total <= scrollbar.len) {
        _ = w32.ShowScrollBar(hwnd, w32.SB_VERT, 0);
        return;
    }

    // Show the scrollbar (adds WS_VSCROLL dynamically) and set the range.
    // ShowScrollBar is more reliable than adding WS_VSCROLL via
    // SetWindowLongW because OpenGL drivers can strip style bits.
    _ = w32.ShowScrollBar(hwnd, w32.SB_VERT, 1);

    const si = w32.SCROLLINFO{
        .cbSize = @sizeOf(w32.SCROLLINFO),
        .fMask = w32.SIF_ALL,
        .nMin = 0,
        .nMax = @intCast(scrollbar.total -| 1),
        .nPage = @intCast(scrollbar.len),
        .nPos = @intCast(scrollbar.offset),
        .nTrackPos = 0,
    };
    _ = w32.SetScrollInfo(hwnd, w32.SB_VERT, &si, 1);
}

/// Handle WM_VSCROLL — user is interacting with the scrollbar.
pub fn handleVScroll(self: *Surface, wparam: usize) void {
    if (!self.core_surface_ready) return;

    const request: u16 = @intCast(wparam & 0xFFFF);

    const row: ?usize = switch (request) {
        w32.SB_LINEUP => if (self.scrollbar_offset > 0)
            self.scrollbar_offset - 1
        else
            null,
        w32.SB_LINEDOWN => if (self.scrollbar_offset + self.scrollbar_len < self.scrollbar_total)
            self.scrollbar_offset + 1
        else
            null,
        w32.SB_PAGEUP => self.scrollbar_offset -| self.scrollbar_len,
        w32.SB_PAGEDOWN => blk: {
            const max = self.scrollbar_total -| self.scrollbar_len;
            break :blk @min(self.scrollbar_offset + self.scrollbar_len, max);
        },
        w32.SB_THUMBTRACK, w32.SB_THUMBPOSITION => blk: {
            // Get the 32-bit track position from SCROLLINFO (wparam
            // high word is only 16 bits and overflows for large scrollback).
            var si = w32.SCROLLINFO{
                .cbSize = @sizeOf(w32.SCROLLINFO),
                .fMask = w32.SIF_ALL,
                .nMin = 0,
                .nMax = 0,
                .nPage = 0,
                .nPos = 0,
                .nTrackPos = 0,
            };
            _ = w32.GetScrollInfo(self.hwnd.?, w32.SB_VERT, &si);
            break :blk @intCast(si.nTrackPos);
        },
        w32.SB_TOP => @as(usize, 0),
        w32.SB_BOTTOM => self.scrollbar_total -| self.scrollbar_len,
        else => null,
    };

    if (row) |r| {
        _ = self.core_surface.performBindingAction(.{ .scroll_to_row = r }) catch |err| {
            log.err("scroll_to_row error: {}", .{err});
        };
    }
}

// -----------------------------------------------------------------------
// Message handlers called from App.wndProc
// -----------------------------------------------------------------------

/// Handle WM_SIZE.
pub fn handleResize(self: *Surface, width: u32, height: u32) void {
    // Skip zero-size events (minimized windows).
    if (width == 0 or height == 0) return;

    self.width = width;
    self.height = height;

    // Reposition the search bar if it's visible
    if (self.search_active) self.positionSearchBar();

    if (!self.core_surface_ready) return;

    // Notify the core surface so it recalculates the terminal grid,
    // updates the renderer viewport, and sends SIGWINCH to the PTY.
    self.core_surface.sizeCallback(.{ .width = width, .height = height }) catch |err| {
        log.err("sizeCallback error: {}", .{err});
        return;
    };

    // During live resize (user dragging the border), block until the
    // renderer has presented one frame at the new size. This prevents
    // the DWM from stretching stale framebuffer content to fill the
    // new window area, which causes visible flicker.
    if (self.in_live_resize) {
        if (self.frame_event) |event| {
            // Reset the event before waking the renderer, so we
            // wait for a NEW frame, not a previously drawn one.
            _ = w32.ResetEvent(event);
        }

        // Wake the renderer to redraw at the new size.
        self.core_surface.renderer_thread.wakeup.notify() catch {};

        if (self.frame_event) |event| {
            // Wait for the renderer to present. Use a short timeout
            // so we never stall the UI if the renderer is slow.
            _ = w32.WaitForSingleObject(event, 16);
        }
    } else {
        // Outside live resize (programmatic resize, initial layout),
        // just wake the renderer asynchronously.
        self.core_surface.renderer_thread.wakeup.notify() catch {};
    }
}

/// Handle WM_DESTROY.
pub fn handleDestroy(self: *Surface) void {
    // The window is already being destroyed at this point.
    // Clear the hwnd so deinit() doesn't try to destroy it again.
    const hwnd = self.hwnd;
    self.hwnd = null;

    // Prevent any further message handlers from touching core_surface
    // during teardown. Messages can arrive during DestroyWindow and
    // deinit (e.g. WM_SETFOCUS, WM_SIZE from style changes).
    self.core_surface_ready = false;

    // Clear GWLP_USERDATA BEFORE freeing, so any subsequent messages
    // (WM_NCDESTROY etc.) see userdata=0 and go to DefWindowProc.
    if (hwnd) |h| {
        _ = w32.SetWindowLongPtrW(h, w32.GWLP_USERDATA, 0);
    }

    // Grab the allocator and app pointer before deinit clears them.
    const alloc = self.app.core_app.alloc;

    // Deinit the surface (core surface, WGL, etc.)
    self.deinit();

    // Free the heap-allocated Surface.
    alloc.destroy(self);
}

/// Handle WM_DPICHANGED.
pub fn handleDpiChange(self: *Surface) void {
    self.updateDpiScale();
}

/// Handle WM_KEYDOWN / WM_SYSKEYDOWN / WM_KEYUP / WM_SYSKEYUP.
pub fn handleKeyEvent(self: *Surface, wparam: usize, lparam: isize, action: input.Action) void {
    if (!self.core_surface_ready) return;
    const vk: u16 = @intCast(wparam & 0xFFFF);

    // When the IME is active, physical key presses arrive as VK_PROCESSKEY.
    // The IME will produce the composed text via WM_IME_COMPOSITION — skip
    // the key event so we don't feed garbage to the terminal.
    if (vk == w32.VK_PROCESSKEY) return;

    // VK_PACKET is sent by SendInput with KEYEVENTF_UNICODE (used by
    // accessibility tools, on-screen keyboards, and Unicode injection).
    // The actual character follows as WM_CHAR — don't set the
    // key_event_produced_text flag so WM_CHAR is allowed through.
    if (vk == w32.VK_PACKET) return;

    // Determine left/right for modifier keys using the extended key flag
    // (bit 24 of lparam) and specific left/right VK codes.
    const extended = (lparam & (1 << 24)) != 0;

    const key = mapVirtualKey(vk, extended);

    // Build modifier state
    const mods = getModifiers();

    // Win32 Input Mode (mode 9001): encode key events as
    // \x1b[Vk;Sc;Uc;Kd;Cs;Rc_ sequences that ConPTY reconstructs
    // into INPUT_RECORD structs. This provides full Unicode support
    // and bypasses ConPTY codepage issues.
    //
    // We still need to check keybindings first (e.g., Ctrl+Shift+C
    // for copy) so they work in this mode. Only fall through to
    // Win32 input encoding if no binding matched.
    if (self.isWin32InputMode()) {
        // Check keybindings for non-modifier keys (Ctrl+Shift+C, etc.).
        // Modifier-only keys never have bindings, and sending them
        // through keyCallback would clear the selection.
        if (!key.modifier()) {
            const actual_action_w32 = if (action == .press and (lparam & (1 << 30)) != 0)
                input.Action.repeat
            else
                action;
            const unshifted_cp: u21 = if (key.codepoint()) |cp| cp else 0;
            const effect = self.core_surface.keyCallback(.{
                .action = actual_action_w32,
                .key = key,
                .mods = mods,
                .consumed_mods = .{},
                .utf8 = "", // no text — let Win32 input handle it
                .unshifted_codepoint = unshifted_cp,
            }) catch |err| {
                log.err("key callback error: {}", .{err});
                return;
            };
            // If a keybinding consumed the event, don't send Win32 input.
            if (effect == .consumed or effect == .closed) return;
        }

        // No binding matched — send as Win32 input sequence.
        self.sendWin32InputEvent(vk, lparam, action);
        return;
    }

    // Check if the key is a repeat (bit 30 of lparam is set for KEYDOWN
    // if the key was already down).
    const actual_action = if (action == .press and (lparam & (1 << 30)) != 0)
        input.Action.repeat
    else
        action;

    // Try to get the unshifted codepoint for this key
    const unshifted_codepoint: u21 = if (key.codepoint()) |cp| cp else 0;

    // Use ToUnicode to translate the key press into UTF-16 text,
    // then convert to UTF-8 for the key event. Only for press/repeat.
    var utf8_buf: [16]u8 = undefined;
    var utf8_text: []const u8 = "";
    var consumed_mods: input.Mods = .{};

    // Reset the flag — WM_CHAR should be allowed through unless
    // ToUnicode produces text below.
    self.key_event_produced_text = false;

    if (actual_action == .press or actual_action == .repeat) {
        var keyboard_state: [256]u8 = undefined;
        if (w32.GetKeyboardState(&keyboard_state) != 0) {
            const scancode: u32 = @intCast((lparam >> 16) & 0x1FF);
            var utf16_buf: [4]u16 = undefined;
            const result = w32.ToUnicode(
                @intCast(vk),
                scancode,
                &keyboard_state,
                &utf16_buf,
                utf16_buf.len,
                0,
            );
            if (result > 0) {
                const utf16_slice = utf16_buf[0..@intCast(result)];
                // Only use the text if it's a printable character.
                // When Ctrl is held, ToUnicode returns control chars
                // (0x01-0x1A) which would interfere with the core's
                // Ctrl+key binding/encoding. Let the core handle
                // modifier combos via key + mods fields instead.
                const is_printable = utf16_slice[0] >= 0x20;
                if (is_printable) {
                    const len = std.unicode.utf16LeToUtf8(&utf8_buf, utf16_slice) catch 0;
                    if (len > 0) {
                        utf8_text = utf8_buf[0..len];
                        // Shift was consumed to produce the text (e.g., Shift+a = 'A')
                        if (mods.shift) consumed_mods.shift = true;
                        // Flag that we produced text — the subsequent
                        // WM_CHAR from TranslateMessage should be suppressed.
                        self.key_event_produced_text = true;
                    }
                }
            }
        }
    }

    const event = input.KeyEvent{
        .action = actual_action,
        .key = key,
        .mods = mods,
        .consumed_mods = consumed_mods,
        .utf8 = utf8_text,
        .unshifted_codepoint = unshifted_codepoint,
    };

    _ = self.core_surface.keyCallback(event) catch |err| {
        log.err("key callback error: {}", .{err});
    };
}

/// Handle WM_CHAR — character input after translation.
/// Win32 delivers codepoints > U+FFFF as two WM_CHAR messages
/// containing a UTF-16 surrogate pair (high then low).
///
/// Text is routed through keyCallback (not textCallback!) with
/// key=.unidentified, mirroring how GTK handles IME commits.
/// textCallback is for clipboard paste; keyCallback is for keyboard/IME text.
pub fn handleCharEvent(self: *Surface, wparam: usize) void {
    if (!self.core_surface_ready) return;
    const char_code: u16 = @intCast(wparam & 0xFFFF);

    // Skip control characters that are handled via WM_KEYDOWN
    if (char_code < 0x20 and char_code != '\t' and char_code != '\r' and char_code != '\n') return;

    // Handle UTF-16 surrogate pairs for codepoints > U+FFFF (e.g. emoji).
    const codepoint: u21 = if (char_code >= 0xD800 and char_code <= 0xDBFF) {
        // High surrogate — buffer it and wait for the low surrogate.
        self.high_surrogate = char_code;
        return;
    } else if (char_code >= 0xDC00 and char_code <= 0xDFFF) blk: {
        // Low surrogate — combine with buffered high surrogate.
        if (self.high_surrogate != 0) {
            const hi: u21 = self.high_surrogate;
            self.high_surrogate = 0;
            break :blk @intCast((@as(u21, hi - 0xD800) << 10) + (@as(u21, char_code) - 0xDC00) + 0x10000);
        }
        // Low surrogate without preceding high — invalid, skip.
        return;
    } else blk: {
        self.high_surrogate = 0; // Reset any stale high surrogate.
        break :blk @intCast(char_code);
    };

    // Convert codepoint to UTF-8
    var utf8_buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch return;

    // Send through keyCallback with .unidentified key — this is the
    // standard path for IME/text input (same as GTK's imCommit).
    // keyCallback will encode the utf8 text and write it to the PTY.
    _ = self.core_surface.keyCallback(.{
        .action = .press,
        .key = .unidentified,
        .mods = .{},
        .consumed_mods = .{},
        .composing = false,
        .utf8 = utf8_buf[0..len],
    }) catch |err| {
        log.err("text input callback error: {}", .{err});
    };
}

/// Handle WM_LBUTTONDOWN / WM_RBUTTONDOWN / WM_MBUTTONDOWN /
/// WM_LBUTTONUP / WM_RBUTTONUP / WM_MBUTTONUP.
pub fn handleMouseButton(
    self: *Surface,
    button: input.MouseButton,
    action: input.MouseButtonState,
    lparam: isize,
) void {
    if (!self.core_surface_ready) return;
    const x: f32 = @floatFromInt(@as(i16, @truncate(@as(isize, lparam & 0xFFFF))));
    const y: f32 = @floatFromInt(@as(i16, @truncate(@as(isize, (lparam >> 16) & 0xFFFF))));

    const mods = getModifiers();

    // Capture mouse on press so drag selection continues outside the window.
    if (action == .press) {
        if (self.hwnd) |hwnd| _ = w32.SetCapture(hwnd);
    } else {
        _ = w32.ReleaseCapture();
    }

    // Update cursor position first
    self.core_surface.cursorPosCallback(.{ .x = x, .y = y }, mods) catch |err| {
        log.err("cursor pos callback error: {}", .{err});
    };

    _ = self.core_surface.mouseButtonCallback(action, button, mods) catch |err| {
        log.err("mouse button callback error: {}", .{err});
    };
}

/// Handle WM_MOUSEMOVE.
pub fn handleMouseMove(self: *Surface, lparam: isize) void {
    if (!self.core_surface_ready) return;
    const x: f32 = @floatFromInt(@as(i16, @truncate(@as(isize, lparam & 0xFFFF))));
    const y: f32 = @floatFromInt(@as(i16, @truncate(@as(isize, (lparam >> 16) & 0xFFFF))));

    // Pass modifiers so the core can detect Ctrl+hover for link highlighting.
    const mods = getModifiers();

    self.core_surface.cursorPosCallback(.{ .x = x, .y = y }, mods) catch |err| {
        log.err("cursor pos callback error: {}", .{err});
    };
}

/// Handle WM_MOUSEWHEEL.
pub fn handleMouseWheel(self: *Surface, wparam: usize) void {
    if (!self.core_surface_ready) return;
    // The high word of wparam contains the wheel delta (signed).
    const raw_delta: i16 = @bitCast(@as(u16, @intCast((wparam >> 16) & 0xFFFF)));
    const delta: f64 = @as(f64, @floatFromInt(raw_delta)) / @as(f64, @floatFromInt(w32.WHEEL_DELTA));

    const scroll_mods: input.ScrollMods = .{};

    self.core_surface.scrollCallback(0, delta, scroll_mods) catch |err| {
        log.err("scroll callback error: {}", .{err});
    };
}

/// Handle WM_IME_STARTCOMPOSITION — an IME composition session has begun.
/// Position the candidate window near the terminal cursor and let Windows
/// show its default composition UI.
pub fn handleImeStartComposition(self: *Surface) void {
    self.ime_composing = true;
    self.positionImeWindow();
}

/// Handle WM_IME_ENDCOMPOSITION — the IME composition session has ended.
pub fn handleImeEndComposition(self: *Surface) void {
    self.ime_composing = false;
}

/// Handle WM_IME_COMPOSITION — intermediate or final text from the IME.
/// When the result string is available (GCS_RESULTSTR), extract it and
/// send it to the terminal. Returns true if we handled the result string.
pub fn handleImeComposition(self: *Surface, lparam: isize) bool {
    if (!self.core_surface_ready) return false;

    const flags: u32 = @intCast(lparam & 0xFFFFFFFF);
    if (flags & w32.GCS_RESULTSTR == 0) return false;

    const hwnd = self.hwnd orelse return false;
    const himc = w32.ImmGetContext(hwnd) orelse return false;
    defer _ = w32.ImmReleaseContext(hwnd, himc);

    // Query the length of the result string (in bytes).
    const byte_len = w32.ImmGetCompositionStringW(himc, w32.GCS_RESULTSTR, null, 0);
    if (byte_len <= 0) return false;

    const u16_len: usize = @intCast(@divExact(byte_len, 2));

    // Stack buffer for typical IME results (up to 64 UTF-16 code units).
    var stack_buf: [64]u16 = undefined;

    if (u16_len <= stack_buf.len) {
        const got = w32.ImmGetCompositionStringW(himc, w32.GCS_RESULTSTR, &stack_buf, @intCast(byte_len));
        if (got <= 0) return false;
        const actual_len: usize = @intCast(@divExact(got, 2));
        self.sendImeText(stack_buf[0..actual_len]);
    } else {
        // Unusual: very long composition. Allocate on the heap.
        const alloc = self.app.core_app.alloc;
        const buf = alloc.alloc(u16, u16_len) catch return false;
        defer alloc.free(buf);
        const got = w32.ImmGetCompositionStringW(himc, w32.GCS_RESULTSTR, buf.ptr, @intCast(byte_len));
        if (got <= 0) return false;
        const actual_len: usize = @intCast(@divExact(got, 2));
        self.sendImeText(buf[0..actual_len]);
    }

    // Reposition the IME window for the next composition
    self.positionImeWindow();
    return true;
}

/// Convert a UTF-16 IME result to UTF-8 and send it to the terminal.
fn sendImeText(self: *Surface, utf16: []const u16) void {
    // In Win32 Input Mode, send each character as a Win32 input event
    // so ConPTY can reconstruct the full Unicode codepoints.
    if (self.isWin32InputMode()) {
        for (utf16) |code_unit| {
            self.sendWin32CharEvent(code_unit);
        }
        return;
    }

    // Convert UTF-16LE to UTF-8 in a stack buffer (256 bytes covers
    // even long CJK phrases — each CJK char is 3 bytes in UTF-8).
    var utf8_buf: [256]u8 = undefined;
    const len = std.unicode.utf16LeToUtf8(&utf8_buf, utf16) catch |err| {
        log.warn("IME utf16→utf8 error: {}", .{err});
        return;
    };
    if (len == 0) return;

    // Send through keyCallback with .unidentified key — this is the
    // standard path for IME/text input (same as GTK's imCommit).
    _ = self.core_surface.keyCallback(.{
        .action = .press,
        .key = .unidentified,
        .mods = .{},
        .consumed_mods = .{},
        .composing = false,
        .utf8 = utf8_buf[0..len],
    }) catch |err| {
        log.err("IME text callback error: {}", .{err});
    };
}

/// Position the IME candidate/composition window near the terminal cursor.
fn positionImeWindow(self: *Surface) void {
    const hwnd = self.hwnd orelse return;
    const himc = w32.ImmGetContext(hwnd) orelse return;
    defer _ = w32.ImmReleaseContext(hwnd, himc);

    // Use the core surface's imePoint() which calculates the cursor
    // position in pixels from the terminal grid, accounting for padding
    // and content scale.
    var pos = w32.POINT{ .x = 0, .y = 0 };
    if (self.core_surface_ready) {
        const ime_pos = self.core_surface.imePoint();
        pos.x = @intFromFloat(ime_pos.x);
        pos.y = @intFromFloat(ime_pos.y);
    }

    const cf = w32.COMPOSITIONFORM{
        .dwStyle = w32.CFS_POINT,
        .ptCurrentPos = pos,
        .rcArea = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    };
    _ = w32.ImmSetCompositionWindow(himc, &cf);
}

// -----------------------------------------------------------------------
// Win32 Input Mode (mode 9001)
// -----------------------------------------------------------------------

/// Check if Win32 Input Mode is active. This mode is requested by ConPTY
/// via \x1b[?9001h and causes key events to be sent as
/// \x1b[Vk;Sc;Uc;Kd;Cs;Rc_ sequences.
pub fn isWin32InputMode(self: *Surface) bool {
    self.core_surface.renderer_state.mutex.lock();
    defer self.core_surface.renderer_state.mutex.unlock();
    return self.core_surface.io.terminal.modes.get(.win32_input);
}

/// Encode and send a key event in Win32 Input Mode format.
/// Format: \x1b[Vk;Sc;Uc;Kd;Cs;Rc_
fn sendWin32InputEvent(self: *Surface, vk: u16, lparam: isize, action: input.Action) void {
    const scancode: u16 = @intCast((lparam >> 16) & 0xFF);
    const extended = (lparam & (1 << 24)) != 0;
    const repeat_count: u16 = @intCast(lparam & 0xFFFF);
    const key_down: u1 = if (action == .press or action == .repeat) 1 else 0;

    // Get the Unicode character for this key via ToUnicode.
    var unicode_char: u16 = 0;
    if (key_down == 1) {
        var keyboard_state: [256]u8 = undefined;
        if (w32.GetKeyboardState(&keyboard_state) != 0) {
            var utf16_buf: [4]u16 = undefined;
            const result = w32.ToUnicode(
                @intCast(vk),
                @intCast(scancode),
                &keyboard_state,
                &utf16_buf,
                utf16_buf.len,
                0,
            );
            if (result > 0) {
                unicode_char = utf16_buf[0];
            }
        }
    }

    // Build the Win32 dwControlKeyState bitmask.
    var ctrl_state: u32 = 0;
    if (w32.GetKeyState(@as(i32, w32.VK_RSHIFT)) < 0 or
        w32.GetKeyState(@as(i32, w32.VK_LSHIFT)) < 0 or
        w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0)
        ctrl_state |= 0x0010; // SHIFT_PRESSED
    if (w32.GetKeyState(@as(i32, w32.VK_LCONTROL)) < 0)
        ctrl_state |= 0x0008; // LEFT_CTRL_PRESSED
    if (w32.GetKeyState(@as(i32, w32.VK_RCONTROL)) < 0)
        ctrl_state |= 0x0004; // RIGHT_CTRL_PRESSED
    if (w32.GetKeyState(@as(i32, w32.VK_LMENU)) < 0)
        ctrl_state |= 0x0002; // LEFT_ALT_PRESSED
    if (w32.GetKeyState(@as(i32, w32.VK_RMENU)) < 0)
        ctrl_state |= 0x0001; // RIGHT_ALT_PRESSED
    if (w32.GetKeyState(@as(i32, w32.VK_CAPITAL)) & 1 != 0)
        ctrl_state |= 0x0080; // CAPSLOCK_ON
    if (w32.GetKeyState(@as(i32, w32.VK_NUMLOCK)) & 1 != 0)
        ctrl_state |= 0x0020; // NUMLOCK_ON
    if (w32.GetKeyState(@as(i32, w32.VK_SCROLL)) & 1 != 0)
        ctrl_state |= 0x0040; // SCROLLLOCK_ON
    if (extended)
        ctrl_state |= 0x0100; // ENHANCED_KEY

    self.writeWin32InputSequence(vk, scancode, unicode_char, key_down, ctrl_state, repeat_count);
}

/// Send a Win32 Input Mode event for a WM_CHAR character (IME, PostMessage, etc.)
/// These are characters without a corresponding WM_KEYDOWN, so we send a
/// synthetic key event with vk=0, sc=0.
pub fn sendWin32CharEvent(self: *Surface, char_code: u16) void {
    // Key-down event with the Unicode character
    self.writeWin32InputSequence(0, 0, char_code, 1, 0, 1);
    // Key-up event
    self.writeWin32InputSequence(0, 0, char_code, 0, 0, 1);
}

/// Format and write a Win32 input sequence directly to the PTY,
/// bypassing keyCallback to avoid side effects (selection clearing,
/// modifier tracking, cursor hiding, etc.).
/// Format: \x1b[Vk;Sc;Uc;Kd;Cs;Rc_
fn writeWin32InputSequence(
    self: *Surface,
    vk: u16,
    sc: u16,
    uc: u16,
    kd: u1,
    cs: u32,
    rc: u16,
) void {
    var buf: [64]u8 = undefined;
    const seq = std.fmt.bufPrint(&buf, "\x1b[{};{};{};{};{};{}_", .{
        vk, sc, uc, kd, cs, rc,
    }) catch return;

    // Write directly to the PTY via the IO queue.
    const msg = termio.Message.writeReq(
        self.app.core_app.alloc,
        seq,
    ) catch return;
    self.core_surface.io.queueMessage(msg, .unlocked);
}

/// Called by the renderer thread after SwapBuffers to signal that a
/// frame has been presented. Wakes the main thread if it's blocking
/// in handleResize during live resize.
pub fn signalFrameDrawn(self: *Surface) void {
    if (self.frame_event) |event| {
        _ = w32.SetEvent(event);
    }
}

/// Handle WM_SETFOCUS / WM_KILLFOCUS.
pub fn handleFocus(self: *Surface, focused: bool) void {
    if (!self.core_surface_ready) return;
    self.core_surface.focusCallback(focused) catch |err| {
        log.err("focus callback error: {}", .{err});
    };
}

/// Get the current keyboard modifier state from Win32.
fn getModifiers() input.Mods {
    var mods: input.Mods = .{};

    // GetKeyState returns a value where the high bit indicates the key
    // is currently down.
    if (w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0) {
        mods.shift = true;
        // Determine which shift key is pressed
        if (w32.GetKeyState(@as(i32, w32.VK_RSHIFT)) < 0) {
            mods.sides.shift = .right;
        }
    }
    if (w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0) {
        mods.ctrl = true;
        if (w32.GetKeyState(@as(i32, w32.VK_RCONTROL)) < 0) {
            mods.sides.ctrl = .right;
        }
    }
    if (w32.GetKeyState(@as(i32, w32.VK_MENU)) < 0) {
        mods.alt = true;
        if (w32.GetKeyState(@as(i32, w32.VK_RMENU)) < 0) {
            mods.sides.alt = .right;
        }
    }

    // Check super (Windows key)
    if (w32.GetKeyState(@as(i32, w32.VK_LWIN)) < 0 or
        w32.GetKeyState(@as(i32, w32.VK_RWIN)) < 0)
    {
        mods.super = true;
        if (w32.GetKeyState(@as(i32, w32.VK_RWIN)) < 0) {
            mods.sides.super = .right;
        }
    }

    // Lock keys (low bit indicates toggle state)
    if (w32.GetKeyState(@as(i32, w32.VK_CAPITAL)) & 1 != 0) {
        mods.caps_lock = true;
    }
    if (w32.GetKeyState(@as(i32, w32.VK_NUMLOCK)) & 1 != 0) {
        mods.num_lock = true;
    }

    return mods;
}

/// Map a Win32 virtual key code to a Ghostty input.Key.
fn mapVirtualKey(vk: u16, extended: bool) input.Key {
    return switch (vk) {
        // Letter keys (A-Z: 0x41-0x5A)
        0x41 => .key_a,
        0x42 => .key_b,
        0x43 => .key_c,
        0x44 => .key_d,
        0x45 => .key_e,
        0x46 => .key_f,
        0x47 => .key_g,
        0x48 => .key_h,
        0x49 => .key_i,
        0x4A => .key_j,
        0x4B => .key_k,
        0x4C => .key_l,
        0x4D => .key_m,
        0x4E => .key_n,
        0x4F => .key_o,
        0x50 => .key_p,
        0x51 => .key_q,
        0x52 => .key_r,
        0x53 => .key_s,
        0x54 => .key_t,
        0x55 => .key_u,
        0x56 => .key_v,
        0x57 => .key_w,
        0x58 => .key_x,
        0x59 => .key_y,
        0x5A => .key_z,

        // Number keys (0-9: 0x30-0x39)
        0x30 => .digit_0,
        0x31 => .digit_1,
        0x32 => .digit_2,
        0x33 => .digit_3,
        0x34 => .digit_4,
        0x35 => .digit_5,
        0x36 => .digit_6,
        0x37 => .digit_7,
        0x38 => .digit_8,
        0x39 => .digit_9,

        // Function keys
        w32.VK_F1 => .f1,
        w32.VK_F2 => .f2,
        w32.VK_F3 => .f3,
        w32.VK_F4 => .f4,
        w32.VK_F5 => .f5,
        w32.VK_F6 => .f6,
        w32.VK_F7 => .f7,
        w32.VK_F8 => .f8,
        w32.VK_F9 => .f9,
        w32.VK_F10 => .f10,
        w32.VK_F11 => .f11,
        w32.VK_F12 => .f12,
        w32.VK_F13 => .f13,
        w32.VK_F14 => .f14,
        w32.VK_F15 => .f15,
        w32.VK_F16 => .f16,
        w32.VK_F17 => .f17,
        w32.VK_F18 => .f18,
        w32.VK_F19 => .f19,
        w32.VK_F20 => .f20,
        w32.VK_F21 => .f21,
        w32.VK_F22 => .f22,
        w32.VK_F23 => .f23,
        w32.VK_F24 => .f24,

        // Navigation / editing keys
        w32.VK_RETURN => if (extended) .numpad_enter else .enter,
        w32.VK_BACK => .backspace,
        w32.VK_TAB => .tab,
        w32.VK_ESCAPE => .escape,
        w32.VK_SPACE => .space,
        w32.VK_PRIOR => .page_up,
        w32.VK_NEXT => .page_down,
        w32.VK_END => .end,
        w32.VK_HOME => .home,
        w32.VK_LEFT => .arrow_left,
        w32.VK_UP => .arrow_up,
        w32.VK_RIGHT => .arrow_right,
        w32.VK_DOWN => .arrow_down,
        w32.VK_INSERT => .insert,
        w32.VK_DELETE => .delete,

        // Modifier keys
        w32.VK_LSHIFT => .shift_left,
        w32.VK_RSHIFT => .shift_right,
        w32.VK_LCONTROL => .control_left,
        w32.VK_RCONTROL => .control_right,
        w32.VK_LMENU => .alt_left,
        w32.VK_RMENU => .alt_right,
        w32.VK_LWIN => .meta_left,
        w32.VK_RWIN => .meta_right,
        w32.VK_SHIFT => if (extended) .shift_right else .shift_left,
        w32.VK_CONTROL => if (extended) .control_right else .control_left,
        w32.VK_MENU => if (extended) .alt_right else .alt_left,

        // Lock keys
        w32.VK_CAPITAL => .caps_lock,
        w32.VK_NUMLOCK => .num_lock,
        w32.VK_SCROLL => .scroll_lock,

        // OEM keys (US keyboard layout)
        w32.VK_OEM_1 => .semicolon,
        w32.VK_OEM_PLUS => .equal,
        w32.VK_OEM_COMMA => .comma,
        w32.VK_OEM_MINUS => .minus,
        w32.VK_OEM_PERIOD => .period,
        w32.VK_OEM_2 => .slash,
        w32.VK_OEM_3 => .backquote,
        w32.VK_OEM_4 => .bracket_left,
        w32.VK_OEM_5 => .backslash,
        w32.VK_OEM_6 => .bracket_right,
        w32.VK_OEM_7 => .quote,

        // Numpad keys
        w32.VK_NUMPAD0 => .numpad_0,
        w32.VK_NUMPAD1 => .numpad_1,
        w32.VK_NUMPAD2 => .numpad_2,
        w32.VK_NUMPAD3 => .numpad_3,
        w32.VK_NUMPAD4 => .numpad_4,
        w32.VK_NUMPAD5 => .numpad_5,
        w32.VK_NUMPAD6 => .numpad_6,
        w32.VK_NUMPAD7 => .numpad_7,
        w32.VK_NUMPAD8 => .numpad_8,
        w32.VK_NUMPAD9 => .numpad_9,
        w32.VK_MULTIPLY => .numpad_multiply,
        w32.VK_ADD => .numpad_add,
        w32.VK_SEPARATOR => .numpad_separator,
        w32.VK_SUBTRACT => .numpad_subtract,
        w32.VK_DECIMAL => .numpad_decimal,
        w32.VK_DIVIDE => .numpad_divide,

        // Misc
        w32.VK_APPS => .context_menu,
        w32.VK_PAUSE => .pause,

        else => .unidentified,
    };
}

/// Return a pointer to the core terminal surface.
pub fn core(self: *Surface) *CoreSurface {
    return &self.core_surface;
}

/// Return a reference to the App for use by core code.
pub fn rtApp(self: *Surface) *App {
    return self.app;
}
