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

// Window messages
pub const WM_APP: u32 = 0x8000;
pub const WM_CLOSE: u32 = 0x0010;
pub const WM_DESTROY: u32 = 0x0002;
pub const WM_SIZE: u32 = 0x0005;
pub const WM_PAINT: u32 = 0x000F;
pub const WM_DPICHANGED: u32 = 0x02E0;

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

pub extern "kernel32" fn GetModuleHandleW(
    lpModuleName: ?[*:0]const u16,
) callconv(.c) ?HINSTANCE;

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
