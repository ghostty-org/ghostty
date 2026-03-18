//! Win32 Surface. Each Surface corresponds to one HWND (window) and
//! owns an OpenGL (WGL) context for rendering.
const Surface = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const input = @import("../../input.zig");
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

/// Initialize a new Surface by creating a Win32 window and WGL context,
/// then initialize the core terminal surface (fonts, renderer, PTY, IO).
pub fn init(self: *Surface, app: *App) !void {
    self.* = .{
        .app = app,
    };

    // Create the window through the App
    const hwnd = try app.createWindow();
    self.hwnd = hwnd;

    // Store the Surface pointer in the window's GWLP_USERDATA so that
    // the WndProc can retrieve it.
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    // Get the device context. With CS_OWNDC, this DC is valid for
    // the lifetime of the window.
    self.hdc = w32.GetDC(hwnd);
    if (self.hdc == null) return error.Win32Error;

    // Set up the pixel format for OpenGL
    try self.setupPixelFormat();

    // Create the WGL context
    self.hglrc = w32.wglCreateContext(self.hdc.?);
    if (self.hglrc == null) return error.Win32Error;

    // Query the initial DPI and size
    self.updateDpiScale();
    self.updateClientSize();

    log.info("Win32 surface created: {}x{} scale={d:.2}", .{
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
}

pub fn deinit(self: *Surface) void {
    // Deinit the core surface first (stops renderer/IO threads, cleans up
    // terminal state, PTY, fonts, etc.).
    self.core_surface.deinit();

    // Unregister from the core app's surface list.
    self.app.core_app.deleteSurface(self);

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
    _ = process_active;
    if (self.hwnd) |hwnd| {
        _ = w32.DestroyWindow(hwnd);
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

    // Build a null-terminated version for completeClipboardRequest.
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

    // Set TERM
    try env.put("TERM", "xterm-256color");

    // COLORTERM signals 24-bit color support
    try env.put("COLORTERM", "truecolor");

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

// -----------------------------------------------------------------------
// Message handlers called from App.wndProc
// -----------------------------------------------------------------------

/// Handle WM_SIZE.
pub fn handleResize(self: *Surface, width: u32, height: u32) void {
    self.width = width;
    self.height = height;
}

/// Handle WM_DESTROY.
pub fn handleDestroy(self: *Surface) void {
    // The window is already being destroyed at this point.
    // Clear the hwnd so deinit() doesn't try to destroy it again.
    self.hwnd = null;

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
    const vk: u16 = @intCast(wparam & 0xFFFF);

    // Determine left/right for modifier keys using the extended key flag
    // (bit 24 of lparam) and specific left/right VK codes.
    const extended = (lparam & (1 << 24)) != 0;

    const key = mapVirtualKey(vk, extended);

    // Build modifier state
    const mods = getModifiers();

    // Check if the key is a repeat (bit 30 of lparam is set for KEYDOWN
    // if the key was already down).
    const actual_action = if (action == .press and (lparam & (1 << 30)) != 0)
        input.Action.repeat
    else
        action;

    // Try to get the unshifted codepoint for this key
    const unshifted_codepoint: u21 = if (key.codepoint()) |cp| cp else 0;

    const event = input.KeyEvent{
        .action = actual_action,
        .key = key,
        .mods = mods,
        .unshifted_codepoint = unshifted_codepoint,
    };

    _ = self.core_surface.keyCallback(event) catch |err| {
        log.err("key callback error: {}", .{err});
    };
}

/// Handle WM_CHAR — character input after translation.
pub fn handleCharEvent(self: *Surface, wparam: usize) void {
    const char_code: u16 = @intCast(wparam & 0xFFFF);

    // Skip control characters that are handled via WM_KEYDOWN
    if (char_code < 0x20 and char_code != '\t' and char_code != '\r' and char_code != '\n') return;

    // Convert UTF-16 code unit to UTF-8
    var utf8_buf: [4]u8 = undefined;
    const codepoint: u21 = @intCast(char_code);
    const len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch return;

    self.core_surface.textCallback(utf8_buf[0..len]) catch |err| {
        log.err("text callback error: {}", .{err});
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
    const x: f32 = @floatFromInt(@as(i16, @truncate(@as(isize, lparam & 0xFFFF))));
    const y: f32 = @floatFromInt(@as(i16, @truncate(@as(isize, (lparam >> 16) & 0xFFFF))));

    const mods = getModifiers();

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
    const x: f32 = @floatFromInt(@as(i16, @truncate(@as(isize, lparam & 0xFFFF))));
    const y: f32 = @floatFromInt(@as(i16, @truncate(@as(isize, (lparam >> 16) & 0xFFFF))));

    const mods = getModifiers();

    self.core_surface.cursorPosCallback(.{ .x = x, .y = y }, mods) catch |err| {
        log.err("cursor pos callback error: {}", .{err});
    };
}

/// Handle WM_MOUSEWHEEL.
pub fn handleMouseWheel(self: *Surface, wparam: usize) void {
    // The high word of wparam contains the wheel delta (signed).
    const raw_delta: i16 = @bitCast(@as(u16, @intCast((wparam >> 16) & 0xFFFF)));
    const delta: f64 = @as(f64, @floatFromInt(raw_delta)) / @as(f64, @floatFromInt(w32.WHEEL_DELTA));

    const scroll_mods: input.ScrollMods = .{};

    self.core_surface.scrollCallback(0, delta, scroll_mods) catch |err| {
        log.err("scroll callback error: {}", .{err});
    };
}

/// Handle WM_SETFOCUS / WM_KILLFOCUS.
pub fn handleFocus(self: *Surface, focused: bool) void {
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
