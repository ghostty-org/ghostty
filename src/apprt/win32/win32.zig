//! Win32 API type definitions and extern function declarations.
//! These supplement what is available in std.os.windows.

const std = @import("std");

// Re-export commonly used types from std
pub const HWND = std.os.windows.HWND;
pub const HINSTANCE = std.os.windows.HINSTANCE;
pub const HDC = *opaque {};
pub const HGLRC = *opaque {};
pub const HMENU = *opaque {};
pub const HICON = *opaque {};
pub const HCURSOR = *opaque {};
pub const HBRUSH = *opaque {};

pub const POINT = extern struct {
    x: i32,
    y: i32,
};

pub const RECT = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

pub const MSG = extern struct {
    hwnd: ?HWND,
    message: u32,
    wParam: usize,
    lParam: isize,
    time: u32,
    pt: POINT,
};

pub const WNDCLASSEXW = extern struct {
    cbSize: u32,
    style: u32,
    lpfnWndProc: *const fn (HWND, u32, usize, isize) callconv(.c) isize,
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: ?HINSTANCE,
    hIcon: ?HICON,
    hCursor: ?HCURSOR,
    hbrBackground: ?HBRUSH,
    lpszMenuName: ?[*:0]const u16,
    lpszClassName: [*:0]const u16,
    hIconSm: ?HICON,
};

pub const PIXELFORMATDESCRIPTOR = extern struct {
    nSize: u16,
    nVersion: u16,
    dwFlags: u32,
    iPixelType: u8,
    cColorBits: u8,
    cRedBits: u8,
    cRedShift: u8,
    cGreenBits: u8,
    cGreenShift: u8,
    cBlueBits: u8,
    cBlueShift: u8,
    cAlphaBits: u8,
    cAlphaShift: u8,
    cAccumBits: u8,
    cAccumRedBits: u8,
    cAccumGreenBits: u8,
    cAccumBlueBits: u8,
    cAccumAlphaBits: u8,
    cDepthBits: u8,
    cStencilBits: u8,
    cAuxBuffers: u8,
    iLayerType: u8,
    bReserved: u8,
    dwLayerMask: u32,
    dwVisibleMask: u32,
    dwDamageMask: u32,
};

// Window class styles
pub const CS_HREDRAW: u32 = 0x0002;
pub const CS_VREDRAW: u32 = 0x0001;
pub const CS_OWNDC: u32 = 0x0020;

// Window styles
pub const WS_OVERLAPPEDWINDOW: u32 = 0x00CF0000;
pub const WS_POPUP: u32 = 0x80000000;

// Window long indices
pub const GWL_STYLE: i32 = -16;

// SetWindowPos flags
pub const SWP_NOZORDER: u32 = 0x0004;
pub const SWP_FRAMECHANGED: u32 = 0x0020;

// MonitorFromWindow flags
pub const MONITOR_DEFAULTTONEAREST: u32 = 0x00000002;

pub const HMONITOR = *opaque {};

pub const MONITORINFO = extern struct {
    cbSize: u32,
    rcMonitor: RECT,
    rcWork: RECT,
    dwFlags: u32,
};

// Window messages
pub const WM_APP: u32 = 0x8000;
pub const WM_CLOSE: u32 = 0x0010;
pub const WM_DESTROY: u32 = 0x0002;
pub const WM_SIZE: u32 = 0x0005;
pub const WM_SETFOCUS: u32 = 0x0007;
pub const WM_KILLFOCUS: u32 = 0x0008;
pub const WM_ERASEBKGND: u32 = 0x0014;
pub const WM_PAINT: u32 = 0x000F;
pub const WM_TIMER: u32 = 0x0113;
pub const WM_ENTERSIZEMOVE: u32 = 0x0231;
pub const WM_EXITSIZEMOVE: u32 = 0x0232;
pub const WM_KEYDOWN: u32 = 0x0100;
pub const WM_KEYUP: u32 = 0x0101;
pub const WM_CHAR: u32 = 0x0102;
pub const WM_SYSKEYDOWN: u32 = 0x0104;
pub const WM_SYSKEYUP: u32 = 0x0105;
pub const WM_MOUSEMOVE: u32 = 0x0200;
pub const WM_LBUTTONDOWN: u32 = 0x0201;
pub const WM_LBUTTONUP: u32 = 0x0202;
pub const WM_RBUTTONDOWN: u32 = 0x0204;
pub const WM_RBUTTONUP: u32 = 0x0205;
pub const WM_MBUTTONDOWN: u32 = 0x0207;
pub const WM_MBUTTONUP: u32 = 0x0208;
pub const WM_MOUSEWHEEL: u32 = 0x020A;
pub const WM_DPICHANGED: u32 = 0x02E0;

// IME messages
pub const WM_IME_STARTCOMPOSITION: u32 = 0x010D;
pub const WM_IME_ENDCOMPOSITION: u32 = 0x010E;
pub const WM_IME_COMPOSITION: u32 = 0x010F;

// IME composition string flags
pub const GCS_COMPSTR: u32 = 0x0008;
pub const GCS_RESULTSTR: u32 = 0x0800;

// IME composition form styles
pub const CFS_POINT: u32 = 0x0002;

// Virtual key codes
pub const VK_PROCESSKEY: u16 = 0xE5;
pub const VK_PACKET: u16 = 0xE7;
pub const VK_BACK: u16 = 0x08;
pub const VK_TAB: u16 = 0x09;
pub const VK_RETURN: u16 = 0x0D;
pub const VK_SHIFT: u16 = 0x10;
pub const VK_CONTROL: u16 = 0x11;
pub const VK_MENU: u16 = 0x12; // Alt key
pub const VK_PAUSE: u16 = 0x13;
pub const VK_CAPITAL: u16 = 0x14; // Caps Lock
pub const VK_ESCAPE: u16 = 0x1B;
pub const VK_SPACE: u16 = 0x20;
pub const VK_PRIOR: u16 = 0x21; // Page Up
pub const VK_NEXT: u16 = 0x22; // Page Down
pub const VK_END: u16 = 0x23;
pub const VK_HOME: u16 = 0x24;
pub const VK_LEFT: u16 = 0x25;
pub const VK_UP: u16 = 0x26;
pub const VK_RIGHT: u16 = 0x27;
pub const VK_DOWN: u16 = 0x28;
pub const VK_INSERT: u16 = 0x2D;
pub const VK_DELETE: u16 = 0x2E;
// 0-9 keys are 0x30-0x39 (same as ASCII)
// A-Z keys are 0x41-0x5A (same as ASCII uppercase)
pub const VK_LWIN: u16 = 0x5B;
pub const VK_RWIN: u16 = 0x5C;
pub const VK_APPS: u16 = 0x5D; // Context menu key
pub const VK_NUMPAD0: u16 = 0x60;
pub const VK_NUMPAD1: u16 = 0x61;
pub const VK_NUMPAD2: u16 = 0x62;
pub const VK_NUMPAD3: u16 = 0x63;
pub const VK_NUMPAD4: u16 = 0x64;
pub const VK_NUMPAD5: u16 = 0x65;
pub const VK_NUMPAD6: u16 = 0x66;
pub const VK_NUMPAD7: u16 = 0x67;
pub const VK_NUMPAD8: u16 = 0x68;
pub const VK_NUMPAD9: u16 = 0x69;
pub const VK_MULTIPLY: u16 = 0x6A;
pub const VK_ADD: u16 = 0x6B;
pub const VK_SEPARATOR: u16 = 0x6C;
pub const VK_SUBTRACT: u16 = 0x6D;
pub const VK_DECIMAL: u16 = 0x6E;
pub const VK_DIVIDE: u16 = 0x6F;
pub const VK_F1: u16 = 0x70;
pub const VK_F2: u16 = 0x71;
pub const VK_F3: u16 = 0x72;
pub const VK_F4: u16 = 0x73;
pub const VK_F5: u16 = 0x74;
pub const VK_F6: u16 = 0x75;
pub const VK_F7: u16 = 0x76;
pub const VK_F8: u16 = 0x77;
pub const VK_F9: u16 = 0x78;
pub const VK_F10: u16 = 0x79;
pub const VK_F11: u16 = 0x7A;
pub const VK_F12: u16 = 0x7B;
pub const VK_F13: u16 = 0x7C;
pub const VK_F14: u16 = 0x7D;
pub const VK_F15: u16 = 0x7E;
pub const VK_F16: u16 = 0x7F;
pub const VK_F17: u16 = 0x80;
pub const VK_F18: u16 = 0x81;
pub const VK_F19: u16 = 0x82;
pub const VK_F20: u16 = 0x83;
pub const VK_F21: u16 = 0x84;
pub const VK_F22: u16 = 0x85;
pub const VK_F23: u16 = 0x86;
pub const VK_F24: u16 = 0x87;
pub const VK_NUMLOCK: u16 = 0x90;
pub const VK_SCROLL: u16 = 0x91;
pub const VK_LSHIFT: u16 = 0xA0;
pub const VK_RSHIFT: u16 = 0xA1;
pub const VK_LCONTROL: u16 = 0xA2;
pub const VK_RCONTROL: u16 = 0xA3;
pub const VK_LMENU: u16 = 0xA4;
pub const VK_RMENU: u16 = 0xA5;
pub const VK_OEM_1: u16 = 0xBA; // ';:' on US
pub const VK_OEM_PLUS: u16 = 0xBB; // '=+' on US
pub const VK_OEM_COMMA: u16 = 0xBC; // ',<' on US
pub const VK_OEM_MINUS: u16 = 0xBD; // '-_' on US
pub const VK_OEM_PERIOD: u16 = 0xBE; // '.>' on US
pub const VK_OEM_2: u16 = 0xBF; // '/?' on US
pub const VK_OEM_3: u16 = 0xC0; // '`~' on US
pub const VK_OEM_4: u16 = 0xDB; // '[{' on US
pub const VK_OEM_5: u16 = 0xDC; // '\|' on US
pub const VK_OEM_6: u16 = 0xDD; // ']}' on US
pub const VK_OEM_7: u16 = 0xDE; // ''"' on US

// WHEEL_DELTA for mouse wheel normalization
pub const WHEEL_DELTA: i16 = 120;

// Show window commands
pub const SW_SHOW: i32 = 5;

// Window long pointer indices
pub const GWLP_USERDATA: i32 = -21;

// HWND_MESSAGE for message-only windows
pub const HWND_MESSAGE: ?HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))));

// Pixel format descriptor flags
pub const PFD_DRAW_TO_WINDOW: u32 = 0x00000004;
pub const PFD_SUPPORT_OPENGL: u32 = 0x00000020;
pub const PFD_DOUBLEBUFFER: u32 = 0x00000001;
pub const PFD_TYPE_RGBA: u8 = 0;

// CreateWindowEx defaults
pub const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));

// IDC_ARROW cursor
pub const IDC_ARROW: ?[*:0]const u16 = @ptrFromInt(32512);

// -----------------------------------------------------------------------
// Win32 API extern declarations
// -----------------------------------------------------------------------

pub extern "user32" fn RegisterClassExW(
    *const WNDCLASSEXW,
) callconv(.c) u16;

pub extern "user32" fn CreateWindowExW(
    dwExStyle: u32,
    lpClassName: [*:0]const u16,
    lpWindowName: [*:0]const u16,
    dwStyle: u32,
    x: i32,
    y: i32,
    nWidth: i32,
    nHeight: i32,
    hWndParent: ?HWND,
    hMenu: ?HMENU,
    hInstance: ?HINSTANCE,
    lpParam: ?*anyopaque,
) callconv(.c) ?HWND;

pub extern "user32" fn ShowWindow(
    hWnd: HWND,
    nCmdShow: i32,
) callconv(.c) i32;

pub extern "user32" fn UpdateWindow(
    hWnd: HWND,
) callconv(.c) i32;

pub extern "user32" fn GetMessageW(
    lpMsg: *MSG,
    hWnd: ?HWND,
    wMsgFilterMin: u32,
    wMsgFilterMax: u32,
) callconv(.c) i32;

pub extern "user32" fn TranslateMessage(
    lpMsg: *const MSG,
) callconv(.c) i32;

pub extern "user32" fn DispatchMessageW(
    lpMsg: *const MSG,
) callconv(.c) isize;

pub extern "user32" fn PostMessageW(
    hWnd: HWND,
    Msg: u32,
    wParam: usize,
    lParam: isize,
) callconv(.c) i32;

pub extern "user32" fn DestroyWindow(
    hWnd: HWND,
) callconv(.c) i32;

pub extern "user32" fn DefWindowProcW(
    hWnd: HWND,
    Msg: u32,
    wParam: usize,
    lParam: isize,
) callconv(.c) isize;

pub extern "user32" fn PostQuitMessage(
    nExitCode: i32,
) callconv(.c) void;

pub extern "user32" fn GetClientRect(
    hWnd: HWND,
    lpRect: *RECT,
) callconv(.c) i32;

pub extern "user32" fn GetDC(
    hWnd: ?HWND,
) callconv(.c) ?HDC;

pub extern "user32" fn ReleaseDC(
    hWnd: ?HWND,
    hDC: HDC,
) callconv(.c) i32;

pub extern "user32" fn SetWindowLongPtrW(
    hWnd: HWND,
    nIndex: i32,
    dwNewLong: isize,
) callconv(.c) isize;

pub extern "user32" fn GetWindowLongPtrW(
    hWnd: HWND,
    nIndex: i32,
) callconv(.c) isize;

pub const GetCursorPos_ = struct {
    extern "user32" fn GetCursorPos(
        lpPoint: *POINT,
    ) callconv(.c) i32;
}.GetCursorPos;

pub extern "user32" fn ScreenToClient(
    hWnd: HWND,
    lpPoint: *POINT,
) callconv(.c) i32;

pub extern "user32" fn GetDpiForWindow(
    hWnd: HWND,
) callconv(.c) u32;

pub extern "user32" fn MessageBeep(
    uType: u32,
) callconv(.c) i32;

pub extern "user32" fn SetWindowTextW(
    hWnd: HWND,
    lpString: [*:0]const u16,
) callconv(.c) i32;

pub extern "user32" fn ValidateRect(
    hWnd: ?HWND,
    lpRect: ?*const RECT,
) callconv(.c) i32;

pub extern "user32" fn LoadCursorW(
    hInstance: ?HINSTANCE,
    lpCursorName: ?[*:0]const u16,
) callconv(.c) ?HCURSOR;

pub extern "user32" fn GetKeyState(
    nVirtKey: i32,
) callconv(.c) i16;

pub extern "kernel32" fn GetModuleHandleW(
    lpModuleName: ?[*:0]const u16,
) callconv(.c) ?HINSTANCE;

pub extern "user32" fn ToUnicode(
    wVirtKey: u32,
    wScanCode: u32,
    lpKeyState: *const [256]u8,
    pwszBuff: [*]u16,
    cchBuff: i32,
    wFlags: u32,
) callconv(.c) i32;

pub extern "user32" fn GetKeyboardState(
    lpKeyState: *[256]u8,
) callconv(.c) i32;

pub extern "user32" fn SetCapture(
    hWnd: HWND,
) callconv(.c) ?HWND;

pub extern "user32" fn ReleaseCapture() callconv(.c) i32;

pub extern "user32" fn GetWindowLongW(
    hWnd: HWND,
    nIndex: i32,
) callconv(.c) u32;

pub extern "user32" fn SetWindowLongW(
    hWnd: HWND,
    nIndex: i32,
    dwNewLong: u32,
) callconv(.c) u32;

pub extern "user32" fn SetWindowPos(
    hWnd: HWND,
    hWndInsertAfter: ?HWND,
    X: i32,
    Y: i32,
    cx: i32,
    cy: i32,
    uFlags: u32,
) callconv(.c) i32;

pub extern "user32" fn GetWindowRect(
    hWnd: HWND,
    lpRect: *RECT,
) callconv(.c) i32;

pub extern "user32" fn MonitorFromWindow(
    hwnd: HWND,
    dwFlags: u32,
) callconv(.c) HMONITOR;

pub extern "user32" fn GetMonitorInfoW(
    hMonitor: HMONITOR,
    lpmi: *MONITORINFO,
) callconv(.c) i32;

pub extern "user32" fn SetTimer(
    hWnd: ?HWND,
    nIDEvent: usize,
    uElapse: u32,
    lpTimerFunc: ?*const anyopaque,
) callconv(.c) usize;

pub extern "user32" fn KillTimer(
    hWnd: ?HWND,
    uIDEvent: usize,
) callconv(.c) i32;

// -----------------------------------------------------------------------
// Synchronization API
// -----------------------------------------------------------------------

pub const HANDLE = std.os.windows.HANDLE;
pub const INFINITE: u32 = 0xFFFFFFFF;
pub const WAIT_OBJECT_0: u32 = 0x00000000;
pub const WAIT_TIMEOUT: u32 = 0x00000102;

pub extern "kernel32" fn CreateEventW(
    lpEventAttributes: ?*anyopaque,
    bManualReset: i32,
    bInitialState: i32,
    lpName: ?[*:0]const u16,
) callconv(.c) ?HANDLE;

pub extern "kernel32" fn SetEvent(
    hEvent: HANDLE,
) callconv(.c) i32;

pub extern "kernel32" fn ResetEvent(
    hEvent: HANDLE,
) callconv(.c) i32;

pub extern "kernel32" fn WaitForSingleObject(
    hHandle: HANDLE,
    dwMilliseconds: u32,
) callconv(.c) u32;

pub extern "kernel32" fn CloseHandle(
    hObject: HANDLE,
) callconv(.c) i32;

// Stock object indices for GetStockObject
pub const BLACK_BRUSH: i32 = 4;

pub extern "gdi32" fn GetStockObject(
    i: i32,
) callconv(.c) ?*anyopaque;

/// COLORREF is 0x00BBGGRR (blue in high byte, red in low byte).
pub fn RGB(r: u8, g: u8, b: u8) u32 {
    return @as(u32, r) | (@as(u32, g) << 8) | (@as(u32, b) << 16);
}

pub extern "gdi32" fn CreateSolidBrush(
    color: u32,
) callconv(.c) ?HBRUSH;

pub extern "gdi32" fn DeleteObject(
    ho: *anyopaque,
) callconv(.c) i32;

pub extern "user32" fn FillRect(
    hDC: HDC,
    lprc: *const RECT,
    hbr: HBRUSH,
) callconv(.c) i32;

// -----------------------------------------------------------------------
// Clipboard API
// -----------------------------------------------------------------------

// Clipboard format: Unicode text (UTF-16LE, null-terminated)
pub const CF_UNICODETEXT: u32 = 13;

// GlobalAlloc flags
pub const GMEM_MOVEABLE: u32 = 0x0002;

pub extern "user32" fn OpenClipboard(
    hWndNewOwner: ?HWND,
) callconv(.c) i32;

pub extern "user32" fn CloseClipboard() callconv(.c) i32;

pub extern "user32" fn EmptyClipboard() callconv(.c) i32;

pub extern "user32" fn GetClipboardData(
    uFormat: u32,
) callconv(.c) ?*anyopaque;

pub extern "user32" fn SetClipboardData(
    uFormat: u32,
    hMem: *anyopaque,
) callconv(.c) ?*anyopaque;

pub extern "kernel32" fn GlobalAlloc(
    uFlags: u32,
    dwBytes: usize,
) callconv(.c) ?*anyopaque;

pub extern "kernel32" fn GlobalLock(
    hMem: *anyopaque,
) callconv(.c) ?[*]u8;

pub extern "kernel32" fn GlobalUnlock(
    hMem: *anyopaque,
) callconv(.c) i32;

pub extern "kernel32" fn GlobalFree(
    hMem: *anyopaque,
) callconv(.c) ?*anyopaque;

// -----------------------------------------------------------------------
// IMM32 (Input Method Manager) API
// -----------------------------------------------------------------------

pub const HIMC = *opaque {};

pub const COMPOSITIONFORM = extern struct {
    dwStyle: u32,
    ptCurrentPos: POINT,
    rcArea: RECT,
};

pub extern "imm32" fn ImmGetContext(
    hWnd: HWND,
) callconv(.c) ?HIMC;

pub extern "imm32" fn ImmReleaseContext(
    hWnd: HWND,
    hIMC: HIMC,
) callconv(.c) i32;

pub extern "imm32" fn ImmGetCompositionStringW(
    hIMC: HIMC,
    dwIndex: u32,
    lpBuf: ?[*]u16,
    dwBufLen: u32,
) callconv(.c) i32;

pub extern "imm32" fn ImmSetCompositionWindow(
    hIMC: HIMC,
    lpCompForm: *const COMPOSITIONFORM,
) callconv(.c) i32;

// -----------------------------------------------------------------------
// DWM (Desktop Window Manager) API
// -----------------------------------------------------------------------

/// DWMWA_USE_IMMERSIVE_DARK_MODE — tells DWM to use dark-mode window chrome.
/// Supported on Windows 10 build 18985+ (formally documented from Windows 11).
pub const DWMWA_USE_IMMERSIVE_DARK_MODE: u32 = 20;

pub extern "dwmapi" fn DwmSetWindowAttribute(
    hwnd: HWND,
    dwAttribute: u32,
    pvAttribute: *const anyopaque,
    cbAttribute: u32,
) callconv(.c) i32;

pub extern "gdi32" fn ChoosePixelFormat(
    hdc: HDC,
    ppfd: *const PIXELFORMATDESCRIPTOR,
) callconv(.c) i32;

pub extern "gdi32" fn SetPixelFormat(
    hdc: HDC,
    format: i32,
    ppfd: *const PIXELFORMATDESCRIPTOR,
) callconv(.c) i32;

pub extern "gdi32" fn SwapBuffers(
    hdc: HDC,
) callconv(.c) i32;

pub extern "opengl32" fn wglCreateContext(
    hdc: HDC,
) callconv(.c) ?HGLRC;

pub extern "opengl32" fn wglMakeCurrent(
    hdc: ?HDC,
    hglrc: ?HGLRC,
) callconv(.c) i32;

pub extern "opengl32" fn wglDeleteContext(
    hglrc: HGLRC,
) callconv(.c) i32;
