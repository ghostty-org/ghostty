/// Windows API bindings for Win32 GUI functionality.
/// This file defines the Windows API functions and constants needed for
/// the Win32 application runtime.
const std = @import("std");
const windows = std.os.windows;

// Re-export commonly used types
pub const BOOL = windows.BOOL;
pub const DWORD = windows.DWORD;
pub const HANDLE = windows.HANDLE;
pub const HINSTANCE = windows.HINSTANCE;
pub const LPARAM = windows.LPARAM;
pub const LRESULT = windows.LRESULT;
pub const WPARAM = windows.WPARAM;
pub const WINAPI = std.builtin.CallingConvention.winapi;

// Window types
pub const HWND = windows.HWND;
pub const HDC = *opaque {};
pub const HGLRC = *opaque {};
pub const HICON = ?*opaque {};
pub const HCURSOR = ?*opaque {};
pub const HBRUSH = ?*opaque {};
pub const HMENU = ?*opaque {};

// Structures
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
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
    lPrivate: DWORD,
};

pub const WNDCLASSEXW = extern struct {
    cbSize: u32,
    style: u32,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: HINSTANCE,
    hIcon: HICON,
    hCursor: HCURSOR,
    hbrBackground: HBRUSH,
    lpszMenuName: ?[*:0]const u16,
    lpszClassName: [*:0]const u16,
    hIconSm: HICON,
};

pub const PAINTSTRUCT = extern struct {
    hdc: HDC,
    fErase: BOOL,
    rcPaint: RECT,
    fRestore: BOOL,
    fIncUpdate: BOOL,
    rgbReserved: [32]u8,
};

pub const PIXELFORMATDESCRIPTOR = extern struct {
    nSize: u16,
    nVersion: u16,
    dwFlags: DWORD,
    iPixelType: u8,
    cColorBits: u8,
    cRedBits: u8 = 0,
    cRedShift: u8 = 0,
    cGreenBits: u8 = 0,
    cGreenShift: u8 = 0,
    cBlueBits: u8 = 0,
    cBlueShift: u8 = 0,
    cAlphaBits: u8 = 0,
    cAlphaShift: u8 = 0,
    cAccumBits: u8 = 0,
    cAccumRedBits: u8 = 0,
    cAccumGreenBits: u8 = 0,
    cAccumBlueBits: u8 = 0,
    cAccumAlphaBits: u8 = 0,
    cDepthBits: u8,
    cStencilBits: u8,
    cAuxBuffers: u8 = 0,
    iLayerType: u8,
    bReserved: u8 = 0,
    dwLayerMask: DWORD = 0,
    dwVisibleMask: DWORD = 0,
    dwDamageMask: DWORD = 0,
};

pub const WNDPROC = *const fn (hwnd: HWND, msg: u32, wParam: WPARAM, lParam: LPARAM) callconv(WINAPI) LRESULT;
pub const DPI_AWARENESS_CONTEXT = *opaque {};

// Window Messages
pub const WM_NULL = 0x0000;
pub const WM_CREATE = 0x0001;
pub const WM_DESTROY = 0x0002;
pub const WM_MOVE = 0x0003;
pub const WM_SIZE = 0x0005;
pub const WM_ACTIVATE = 0x0006;
pub const WM_SETFOCUS = 0x0007;
pub const WM_KILLFOCUS = 0x0008;
pub const WM_PAINT = 0x000F;
pub const WM_CLOSE = 0x0010;
pub const WM_QUIT = 0x0012;
pub const WM_ERASEBKGND = 0x0014;
pub const WM_SHOWWINDOW = 0x0018;
pub const WM_ACTIVATEAPP = 0x001C;
pub const WM_SETCURSOR = 0x0020;
pub const WM_GETMINMAXINFO = 0x0024;
pub const WM_WINDOWPOSCHANGING = 0x0046;
pub const WM_WINDOWPOSCHANGED = 0x0047;
pub const WM_NCCREATE = 0x0081;
pub const WM_NCDESTROY = 0x0082;
pub const WM_NCCALCSIZE = 0x0083;
pub const WM_NCHITTEST = 0x0084;
pub const WM_NCPAINT = 0x0085;
pub const WM_NCACTIVATE = 0x0086;
pub const WM_GETDLGCODE = 0x0087;
pub const WM_NCLBUTTONDOWN = 0x00A1;
pub const WM_NCLBUTTONUP = 0x00A2;
pub const WM_NCLBUTTONDBLCLK = 0x00A3;
pub const WM_NCRBUTTONDOWN = 0x00A4;
pub const WM_NCRBUTTONUP = 0x00A5;
pub const WM_NCMOUSEMOVE = 0x00A0;
pub const WM_KEYDOWN = 0x0100;
pub const WM_KEYUP = 0x0101;
pub const WM_CHAR = 0x0102;
pub const WM_DEADCHAR = 0x0103;
pub const WM_SYSKEYDOWN = 0x0104;
pub const WM_SYSKEYUP = 0x0105;
pub const WM_SYSCHAR = 0x0106;
pub const WM_SYSDEADCHAR = 0x0107;
pub const WM_IME_STARTCOMPOSITION = 0x010D;
pub const WM_IME_ENDCOMPOSITION = 0x010E;
pub const WM_IME_COMPOSITION = 0x010F;
pub const WM_INITDIALOG = 0x0110;
pub const WM_COMMAND = 0x0111;
pub const WM_SYSCOMMAND = 0x0112;
pub const WM_TIMER = 0x0113;
pub const WM_HSCROLL = 0x0114;
pub const WM_VSCROLL = 0x0115;
pub const WM_INITMENU = 0x0116;
pub const WM_MENUSELECT = 0x011F;
pub const WM_MENUCHAR = 0x0120;
pub const WM_ENTERIDLE = 0x0121;
pub const WM_CTLCOLORMSGBOX = 0x0132;
pub const WM_CTLCOLOREDIT = 0x0133;
pub const WM_CTLCOLORLISTBOX = 0x0134;
pub const WM_CTLCOLORBTN = 0x0135;
pub const WM_CTLCOLORDLG = 0x0136;
pub const WM_CTLCOLORSCROLLBAR = 0x0137;
pub const WM_CTLCOLORSTATIC = 0x0138;
pub const WM_MOUSEMOVE = 0x0200;
pub const WM_LBUTTONDOWN = 0x0201;
pub const WM_LBUTTONUP = 0x0202;
pub const WM_LBUTTONDBLCLK = 0x0203;
pub const WM_RBUTTONDOWN = 0x0204;
pub const WM_RBUTTONUP = 0x0205;
pub const WM_RBUTTONDBLCLK = 0x0206;
pub const WM_MBUTTONDOWN = 0x0207;
pub const WM_MBUTTONUP = 0x0208;
pub const WM_MBUTTONDBLCLK = 0x0209;
pub const WM_MOUSEWHEEL = 0x020A;
pub const WM_XBUTTONDOWN = 0x020B;
pub const WM_XBUTTONUP = 0x020C;
pub const WM_XBUTTONDBLCLK = 0x020D;
pub const WM_MOUSEHWHEEL = 0x020E;
pub const WM_DPICHANGED = 0x02E0;
pub const WM_USER = 0x0400;
pub const WM_APP = 0x8000;

// Window Styles
pub const WS_OVERLAPPED = 0x00000000;
pub const WS_POPUP = 0x80000000;
pub const WS_CHILD = 0x40000000;
pub const WS_MINIMIZE = 0x20000000;
pub const WS_VISIBLE = 0x10000000;
pub const WS_DISABLED = 0x08000000;
pub const WS_CLIPSIBLINGS = 0x04000000;
pub const WS_CLIPCHILDREN = 0x02000000;
pub const WS_MAXIMIZE = 0x01000000;
pub const WS_CAPTION = 0x00C00000;
pub const WS_BORDER = 0x00800000;
pub const WS_DLGFRAME = 0x00400000;
pub const WS_VSCROLL = 0x00200000;
pub const WS_HSCROLL = 0x00100000;
pub const WS_SYSMENU = 0x00080000;
pub const WS_THICKFRAME = 0x00040000;
pub const WS_GROUP = 0x00020000;
pub const WS_TABSTOP = 0x00010000;
pub const WS_MINIMIZEBOX = 0x00020000;
pub const WS_MAXIMIZEBOX = 0x00010000;
pub const WS_TILED = WS_OVERLAPPED;
pub const WS_ICONIC = WS_MINIMIZE;
pub const WS_SIZEBOX = WS_THICKFRAME;
pub const WS_TILEDWINDOW = WS_OVERLAPPEDWINDOW;
pub const WS_OVERLAPPEDWINDOW = (WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX);
pub const WS_POPUPWINDOW = (WS_POPUP | WS_BORDER | WS_SYSMENU);
pub const WS_CHILDWINDOW = (WS_CHILD);

// Window Class Styles
pub const CS_VREDRAW = 0x0001;
pub const CS_HREDRAW = 0x0002;
pub const CS_DBLCLKS = 0x0008;
pub const CS_OWNDC = 0x0020;
pub const CS_CLASSDC = 0x0040;
pub const CS_PARENTDC = 0x0080;
pub const CS_NOCLOSE = 0x0200;
pub const CS_SAVEBITS = 0x0800;
pub const CS_BYTEALIGNCLIENT = 0x1000;
pub const CS_BYTEALIGNWINDOW = 0x2000;
pub const CS_GLOBALCLASS = 0x4000;
pub const CS_IME = 0x00010000;
pub const CS_DROPSHADOW = 0x00020000;

// ShowWindow Commands
pub const SW_HIDE = 0;
pub const SW_SHOWNORMAL = 1;
pub const SW_NORMAL = 1;
pub const SW_SHOWMINIMIZED = 2;
pub const SW_SHOWMAXIMIZED = 3;
pub const SW_MAXIMIZE = 3;
pub const SW_SHOWNOACTIVATE = 4;
pub const SW_SHOW = 5;
pub const SW_MINIMIZE = 6;
pub const SW_SHOWMINNOACTIVE = 7;
pub const SW_SHOWNA = 8;
pub const SW_RESTORE = 9;
pub const SW_SHOWDEFAULT = 10;
pub const SW_FORCEMINIMIZE = 11;

// Window positioning
pub const CW_USEDEFAULT = @as(i32, @bitCast(@as(u32, 0x80000000)));

// GetWindowLongPtr indices
pub const GWL_WNDPROC = -4;
pub const GWL_HINSTANCE = -6;
pub const GWL_HWNDPARENT = -8;
pub const GWL_STYLE = -16;
pub const GWL_EXSTYLE = -20;
pub const GWL_USERDATA = -21;
pub const GWL_ID = -12;
pub const GWLP_WNDPROC = -4;
pub const GWLP_HINSTANCE = -6;
pub const GWLP_HWNDPARENT = -8;
pub const GWLP_USERDATA = -21;
pub const GWLP_ID = -12;

// PeekMessage options
pub const PM_NOREMOVE = 0x0000;
pub const PM_REMOVE = 0x0001;
pub const PM_NOYIELD = 0x0002;

// Standard Cursor IDs (MAKEINTRESOURCE values - cast integer IDs to pointers)
pub const IDC_ARROW: [*:0]align(1) const u16 = @ptrFromInt(32512);
pub const IDC_IBEAM: [*:0]align(1) const u16 = @ptrFromInt(32513);
pub const IDC_WAIT: [*:0]align(1) const u16 = @ptrFromInt(32514);
pub const IDC_CROSS: [*:0]align(1) const u16 = @ptrFromInt(32515);
pub const IDC_UPARROW: [*:0]align(1) const u16 = @ptrFromInt(32516);
pub const IDC_SIZE: [*:0]align(1) const u16 = @ptrFromInt(32640);
pub const IDC_ICON: [*:0]align(1) const u16 = @ptrFromInt(32641);
pub const IDC_SIZENWSE: [*:0]align(1) const u16 = @ptrFromInt(32642);
pub const IDC_SIZENESW: [*:0]align(1) const u16 = @ptrFromInt(32643);
pub const IDC_SIZEWE: [*:0]align(1) const u16 = @ptrFromInt(32644);
pub const IDC_SIZENS: [*:0]align(1) const u16 = @ptrFromInt(32645);
pub const IDC_SIZEALL: [*:0]align(1) const u16 = @ptrFromInt(32646);
pub const IDC_NO: [*:0]align(1) const u16 = @ptrFromInt(32648);
pub const IDC_HAND: [*:0]align(1) const u16 = @ptrFromInt(32649);
pub const IDC_APPSTARTING: [*:0]align(1) const u16 = @ptrFromInt(32650);
pub const IDC_HELP: [*:0]align(1) const u16 = @ptrFromInt(32651);

// Pixel format flags
pub const PFD_DOUBLEBUFFER = 0x00000001;
pub const PFD_STEREO = 0x00000002;
pub const PFD_DRAW_TO_WINDOW = 0x00000004;
pub const PFD_DRAW_TO_BITMAP = 0x00000008;
pub const PFD_SUPPORT_GDI = 0x00000010;
pub const PFD_SUPPORT_OPENGL = 0x00000020;
pub const PFD_GENERIC_FORMAT = 0x00000040;
pub const PFD_NEED_PALETTE = 0x00000080;
pub const PFD_NEED_SYSTEM_PALETTE = 0x00000100;
pub const PFD_SWAP_EXCHANGE = 0x00000200;
pub const PFD_SWAP_COPY = 0x00000400;
pub const PFD_SWAP_LAYER_BUFFERS = 0x00000800;
pub const PFD_GENERIC_ACCELERATED = 0x00001000;
pub const PFD_TYPE_RGBA = 0;
pub const PFD_TYPE_COLORINDEX = 1;
pub const PFD_MAIN_PLANE = 0;

// SetWindowPos flags
pub const SWP_NOSIZE = 0x0001;
pub const SWP_NOMOVE = 0x0002;
pub const SWP_NOZORDER = 0x0004;
pub const SWP_NOREDRAW = 0x0008;
pub const SWP_NOACTIVATE = 0x0010;
pub const SWP_FRAMECHANGED = 0x0020;
pub const SWP_SHOWWINDOW = 0x0040;
pub const SWP_HIDEWINDOW = 0x0080;
pub const SWP_NOCOPYBITS = 0x0100;
pub const SWP_NOOWNERZORDER = 0x0200;
pub const SWP_NOSENDCHANGING = 0x0400;

// user32.dll functions
pub extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(WINAPI) u16;
pub extern "user32" fn CreateWindowExW(dwExStyle: DWORD, lpClassName: [*:0]const u16, lpWindowName: [*:0]const u16, dwStyle: DWORD, X: i32, Y: i32, nWidth: i32, nHeight: i32, hWndParent: ?HWND, hMenu: HMENU, hInstance: HINSTANCE, lpParam: ?*anyopaque) callconv(WINAPI) ?HWND;
pub extern "user32" fn DestroyWindow(hWnd: HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: i32) callconv(WINAPI) BOOL;
pub extern "user32" fn UpdateWindow(hWnd: HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: ?HWND, wMsgFilterMin: u32, wMsgFilterMax: u32) callconv(WINAPI) BOOL;
pub extern "user32" fn PeekMessageW(lpMsg: *MSG, hWnd: ?HWND, wMsgFilterMin: u32, wMsgFilterMax: u32, wRemoveMsg: u32) callconv(WINAPI) BOOL;
pub extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(WINAPI) BOOL;
pub extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(WINAPI) LRESULT;
pub extern "user32" fn PostMessageW(hWnd: ?HWND, Msg: u32, wParam: WPARAM, lParam: LPARAM) callconv(WINAPI) BOOL;
pub extern "user32" fn PostQuitMessage(nExitCode: i32) callconv(WINAPI) void;
pub extern "user32" fn DefWindowProcW(hWnd: HWND, Msg: u32, wParam: WPARAM, lParam: LPARAM) callconv(WINAPI) LRESULT;
pub extern "user32" fn GetDC(hWnd: ?HWND) callconv(WINAPI) ?HDC;
pub extern "user32" fn ReleaseDC(hWnd: ?HWND, hDC: HDC) callconv(WINAPI) i32;
pub extern "user32" fn BeginPaint(hWnd: HWND, lpPaint: *PAINTSTRUCT) callconv(WINAPI) ?HDC;
pub extern "user32" fn EndPaint(hWnd: HWND, lpPaint: *const PAINTSTRUCT) callconv(WINAPI) BOOL;
pub extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(WINAPI) BOOL;
pub extern "user32" fn GetWindowRect(hWnd: HWND, lpRect: *RECT) callconv(WINAPI) BOOL;
pub extern "user32" fn GetCursorPos(lpPoint: *POINT) callconv(WINAPI) BOOL;
pub extern "user32" fn ScreenToClient(hWnd: HWND, lpPoint: *POINT) callconv(WINAPI) BOOL;
pub extern "user32" fn ClientToScreen(hWnd: HWND, lpPoint: *POINT) callconv(WINAPI) BOOL;
pub extern "user32" fn WindowFromPoint(Point: POINT) callconv(WINAPI) ?HWND;
pub extern "user32" fn MapWindowPoints(hWndFrom: ?HWND, hWndTo: ?HWND, lpPoints: [*]POINT, cPoints: u32) callconv(WINAPI) i32;
pub extern "user32" fn LoadCursorW(hInstance: ?HINSTANCE, lpCursorName: [*:0]align(1) const u16) callconv(WINAPI) HCURSOR;
pub extern "user32" fn SetCursor(hCursor: HCURSOR) callconv(WINAPI) HCURSOR;
pub extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: i32) callconv(WINAPI) isize;
pub extern "user32" fn SetWindowLongPtrW(hWnd: HWND, nIndex: i32, dwNewLong: isize) callconv(WINAPI) isize;
pub extern "user32" fn GetWindow(hWnd: HWND, uCmd: u32) callconv(WINAPI) ?HWND;
pub const GW_CHILD: u32 = 5;
pub const GW_HWNDNEXT: u32 = 2;
pub extern "user32" fn GetDpiForWindow(hwnd: HWND) callconv(WINAPI) u32;
pub extern "user32" fn SetProcessDpiAwarenessContext(value: DPI_AWARENESS_CONTEXT) callconv(WINAPI) BOOL;
pub extern "user32" fn SetWindowPos(hWnd: HWND, hWndInsertAfter: ?HWND, X: i32, Y: i32, cx: i32, cy: i32, uFlags: u32) callconv(WINAPI) BOOL;
pub extern "user32" fn GetKeyState(nVirtKey: i32) callconv(WINAPI) i16;

// Clipboard functions
pub extern "user32" fn OpenClipboard(hWndNewOwner: ?HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn CloseClipboard() callconv(WINAPI) BOOL;
pub extern "user32" fn EmptyClipboard() callconv(WINAPI) BOOL;
pub extern "user32" fn GetClipboardData(uFormat: u32) callconv(WINAPI) ?HANDLE;
pub extern "user32" fn SetClipboardData(uFormat: u32, hMem: HANDLE) callconv(WINAPI) ?HANDLE;

// Clipboard formats
pub const CF_UNICODETEXT: u32 = 13;

// Global memory functions
pub const GMEM_MOVEABLE: u32 = 0x0002;
pub extern "kernel32" fn GlobalAlloc(uFlags: u32, dwBytes: usize) callconv(WINAPI) ?HANDLE;
pub extern "kernel32" fn GlobalFree(hMem: HANDLE) callconv(WINAPI) ?HANDLE;
pub extern "kernel32" fn GlobalLock(hMem: HANDLE) callconv(WINAPI) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(hMem: HANDLE) callconv(WINAPI) BOOL;

// IME functions
pub const HIMC = ?*opaque {};

pub const COMPOSITIONFORM = extern struct {
    dwStyle: u32,
    ptCurrentPos: POINT,
    rcArea: RECT,
};

pub const CFS_POINT: u32 = 0x0002;

pub extern "imm32" fn ImmGetContext(hWnd: HWND) callconv(WINAPI) HIMC;
pub extern "imm32" fn ImmReleaseContext(hWnd: HWND, hIMC: HIMC) callconv(WINAPI) BOOL;
pub extern "imm32" fn ImmSetCompositionWindow(hIMC: HIMC, lpCompForm: *COMPOSITIONFORM) callconv(WINAPI) BOOL;

// kernel32.dll file/pipe functions
pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
pub const GENERIC_READ: u32 = 0x80000000;
pub const GENERIC_WRITE: u32 = 0x40000000;
pub const OPEN_EXISTING: u32 = 3;
pub const FILE_FLAG_FIRST_PIPE_INSTANCE: u32 = 0x00080000;
pub const PIPE_ACCESS_DUPLEX: u32 = 0x00000003;
pub const PIPE_TYPE_MESSAGE: u32 = 0x00000004;
pub const PIPE_READMODE_MESSAGE: u32 = 0x00000002;
pub const PIPE_WAIT: u32 = 0x00000000;

pub extern "kernel32" fn CreateFileW(lpFileName: [*:0]const u16, dwDesiredAccess: u32, dwShareMode: u32, lpSecurityAttributes: ?*anyopaque, dwCreationDisposition: u32, dwFlagsAndAttributes: u32, hTemplateFile: ?HANDLE) callconv(WINAPI) HANDLE;
pub extern "kernel32" fn WriteFile(hFile: HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: u32, lpNumberOfBytesWritten: ?*u32, lpOverlapped: ?*anyopaque) callconv(WINAPI) BOOL;
pub extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: u32, lpNumberOfBytesRead: ?*u32, lpOverlapped: ?*anyopaque) callconv(WINAPI) BOOL;
pub extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(WINAPI) BOOL;
pub extern "kernel32" fn CreateNamedPipeW(lpName: [*:0]const u16, dwOpenMode: u32, dwPipeMode: u32, nMaxInstances: u32, nOutBufferSize: u32, nInBufferSize: u32, nDefaultTimeOut: u32, lpSecurityAttributes: ?*anyopaque) callconv(WINAPI) HANDLE;
pub extern "kernel32" fn ConnectNamedPipe(hNamedPipe: HANDLE, lpOverlapped: ?*anyopaque) callconv(WINAPI) BOOL;
pub extern "kernel32" fn DisconnectNamedPipe(hNamedPipe: HANDLE) callconv(WINAPI) BOOL;
pub extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const u16) callconv(WINAPI) ?HINSTANCE;
pub extern "kernel32" fn GetLastError() callconv(WINAPI) DWORD;

// gdi32.dll functions
pub extern "gdi32" fn ChoosePixelFormat(hdc: HDC, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(WINAPI) i32;
pub extern "gdi32" fn SetPixelFormat(hdc: HDC, format: i32, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(WINAPI) BOOL;
pub extern "gdi32" fn SwapBuffers(hdc: HDC) callconv(WINAPI) BOOL;

// GDI drawing functions (for tab bar)
pub const COLORREF = u32;
pub const HGDIOBJ = ?*opaque {};
pub const HFONT = ?*opaque {};

pub inline fn RGB(r: u8, g: u8, b: u8) COLORREF {
    return @as(u32, r) | (@as(u32, g) << 8) | (@as(u32, b) << 16);
}

pub const HRGN = ?*opaque {};
pub const HPEN = ?*opaque {};

pub extern "gdi32" fn CreateSolidBrush(color: COLORREF) callconv(WINAPI) HBRUSH;
pub extern "gdi32" fn DeleteObject(ho: HGDIOBJ) callconv(WINAPI) BOOL;
pub extern "gdi32" fn SelectObject(hdc: HDC, h: HGDIOBJ) callconv(WINAPI) HGDIOBJ;
pub extern "gdi32" fn CreateRoundRectRgn(x1: i32, y1: i32, x2: i32, y2: i32, w: i32, h: i32) callconv(WINAPI) HRGN;
pub extern "gdi32" fn FillRgn(hdc: HDC, hrgn: HRGN, hbr: HBRUSH) callconv(WINAPI) BOOL;
pub extern "gdi32" fn CreatePen(iStyle: i32, cWidth: i32, color: COLORREF) callconv(WINAPI) HPEN;
pub extern "gdi32" fn RoundRect(hdc: HDC, left: i32, top: i32, right: i32, bottom: i32, width: i32, height: i32) callconv(WINAPI) BOOL;
pub extern "gdi32" fn MoveToEx(hdc: HDC, x: i32, y: i32, lppt: ?*POINT) callconv(WINAPI) BOOL;
pub extern "gdi32" fn LineTo(hdc: HDC, x: i32, y: i32) callconv(WINAPI) BOOL;
pub extern "gdi32" fn SetBkMode(hdc: HDC, mode: i32) callconv(WINAPI) i32;
pub extern "gdi32" fn SetTextColor(hdc: HDC, color: COLORREF) callconv(WINAPI) COLORREF;
pub extern "gdi32" fn GetStockObject(i: i32) callconv(WINAPI) HGDIOBJ;

pub extern "user32" fn FillRect(hDC: HDC, lprc: *const RECT, hbr: HBRUSH) callconv(WINAPI) i32;
pub extern "user32" fn DrawTextW(hdc: HDC, lpchText: [*]const u16, cchText: i32, lprc: *RECT, format: u32) callconv(WINAPI) i32;

// DrawText format flags
pub const DT_LEFT: u32 = 0x00000000;
pub const DT_CENTER: u32 = 0x00000001;
pub const DT_VCENTER: u32 = 0x00000004;
pub const DT_SINGLELINE: u32 = 0x00000020;
pub const DT_END_ELLIPSIS: u32 = 0x00008000;
pub const DT_NOPREFIX: u32 = 0x00000800;

// SetBkMode constants
pub const TRANSPARENT: i32 = 1;
pub const OPAQUE_BK: i32 = 2;

// GetStockObject constants
pub const DEFAULT_GUI_FONT: i32 = 17;
pub const NULL_BRUSH: i32 = 5;

// Pen styles
pub const PS_SOLID: i32 = 0;

// System metrics
pub extern "user32" fn GetSystemMetrics(nIndex: i32) callconv(WINAPI) i32;
pub extern "user32" fn GetSystemMetricsForDpi(nIndex: i32, dpi: u32) callconv(WINAPI) i32;

pub const SM_CXFRAME: i32 = 32;
pub const SM_CYFRAME: i32 = 33;
pub const SM_CXPADDEDBORDER: i32 = 92;

// NCCALCSIZE_PARAMS
pub const NCCALCSIZE_PARAMS = extern struct {
    rgrc: [3]RECT,
    lppos: ?*anyopaque,
};

// Mouse input
pub extern "user32" fn SetCapture(hWnd: HWND) callconv(WINAPI) ?HWND;
pub extern "user32" fn ReleaseCapture() callconv(WINAPI) BOOL;
pub extern "user32" fn TrackMouseEvent(lpEventTrack: *TRACKMOUSEEVENT) callconv(WINAPI) BOOL;

pub const TRACKMOUSEEVENT = extern struct {
    cbSize: DWORD,
    dwFlags: DWORD,
    hwndTrack: HWND,
    dwHoverTime: DWORD,
};

pub const TME_LEAVE: DWORD = 0x00000002;

// Flash window
pub const FLASHWINFO = extern struct {
    cbSize: DWORD,
    hwnd: HWND,
    dwFlags: DWORD,
    uCount: DWORD,
    dwTimeout: DWORD,
};

pub const FLASHW_ALL: DWORD = 0x00000003;

pub extern "user32" fn FlashWindowEx(pfwi: *FLASHWINFO) callconv(WINAPI) BOOL;

pub const WM_MOUSELEAVE = 0x02A3;
pub const WM_SETTINGCHANGE = 0x001A;

// XBUTTON constants
pub const XBUTTON1: DWORD = 0x0001;
pub const XBUTTON2: DWORD = 0x0002;

// Hit test values
pub const HTERROR: u32 = @bitCast(@as(i32, -2));
pub const HTTRANSPARENT: u32 = @bitCast(@as(i32, -1));
pub const HTNOWHERE: u32 = 0;
pub const HTCLIENT: u32 = 1;
pub const HTCAPTION: u32 = 2;
pub const HTSYSMENU: u32 = 3;
pub const HTMINBUTTON: u32 = 8;
pub const HTMAXBUTTON: u32 = 9;
pub const HTLEFT: u32 = 10;
pub const HTRIGHT: u32 = 11;
pub const HTTOP: u32 = 12;
pub const HTTOPLEFT: u32 = 13;
pub const HTTOPRIGHT: u32 = 14;
pub const HTBOTTOM: u32 = 15;
pub const HTBOTTOMLEFT: u32 = 16;
pub const HTBOTTOMRIGHT: u32 = 17;
pub const HTCLOSE: u32 = 20;

// Window title
pub extern "user32" fn SetWindowTextW(hWnd: HWND, lpString: [*:0]const u16) callconv(WINAPI) BOOL;

// Rendering/invalidation
pub extern "user32" fn InvalidateRect(hWnd: ?HWND, lpRect: ?*const RECT, bErase: BOOL) callconv(WINAPI) BOOL;

// Sound
pub extern "user32" fn MessageBeep(uType: u32) callconv(WINAPI) BOOL;

// MapVirtualKey
pub extern "user32" fn MapVirtualKeyW(uCode: u32, uMapType: u32) callconv(WINAPI) u32;
pub const MAPVK_VK_TO_CHAR: u32 = 2;
pub const MAPVK_VSC_TO_VK_EX: u32 = 3;

// Window sizing
pub const MINMAXINFO = extern struct {
    ptReserved: POINT,
    ptMaxSize: POINT,
    ptMaxPosition: POINT,
    ptMinTrackSize: POINT,
    ptMaxTrackSize: POINT,
};

pub extern "user32" fn AdjustWindowRectEx(lpRect: *RECT, dwStyle: DWORD, bMenu: BOOL, dwExStyle: DWORD) callconv(WINAPI) BOOL;

// Shell functions (URL opening)
pub extern "shell32" fn ShellExecuteW(hwnd: ?HWND, lpOperation: ?[*:0]const u16, lpFile: [*:0]const u16, lpParameters: ?[*:0]const u16, lpDirectory: ?[*:0]const u16, nShowCmd: i32) callconv(WINAPI) isize;

// Timer functions
pub extern "user32" fn SetTimer(hWnd: ?HWND, nIDEvent: usize, uElapse: u32, lpTimerFunc: ?*anyopaque) callconv(WINAPI) usize;
pub extern "user32" fn KillTimer(hWnd: ?HWND, uIDEvent: usize) callconv(WINAPI) BOOL;

// Fullscreen/window state
pub const WINDOWPLACEMENT = extern struct {
    length: u32,
    flags: u32,
    showCmd: u32,
    ptMinPosition: POINT,
    ptMaxPosition: POINT,
    rcNormalPosition: RECT,
};

pub extern "user32" fn GetWindowPlacement(hWnd: HWND, lpwndpl: *WINDOWPLACEMENT) callconv(WINAPI) BOOL;
pub extern "user32" fn SetWindowPlacement(hWnd: HWND, lpwndpl: *const WINDOWPLACEMENT) callconv(WINAPI) BOOL;

pub const MONITORINFO = extern struct {
    cbSize: DWORD,
    rcMonitor: RECT,
    rcWork: RECT,
    dwFlags: DWORD,
};

pub extern "user32" fn MonitorFromWindow(hwnd: HWND, dwFlags: DWORD) callconv(WINAPI) ?HANDLE;
pub extern "user32" fn GetMonitorInfoW(hMonitor: HANDLE, lpmi: *MONITORINFO) callconv(WINAPI) BOOL;
pub extern "user32" fn IsZoomed(hWnd: HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn SetForegroundWindow(hWnd: HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn SetFocus(hWnd: ?HWND) callconv(WINAPI) ?HWND;

pub extern "user32" fn SetLayeredWindowAttributes(hwnd: HWND, crKey: u32, bAlpha: u8, dwFlags: DWORD) callconv(WINAPI) BOOL;

pub const MONITOR_DEFAULTTONEAREST: DWORD = 0x00000002;

// Extended window styles
pub const WS_EX_LAYERED: DWORD = 0x00080000;
pub const WS_EX_TOPMOST: DWORD = 0x00000008;
pub const WS_EX_TRANSPARENT: DWORD = 0x00000020;
pub const WS_EX_NOREDIRECTIONBITMAP: DWORD = 0x00200000;
pub const LWA_ALPHA: DWORD = 0x00000002;

// HWND positioning constants (cast from special integer values)
pub const HWND_TOP: ?HWND = @ptrFromInt(0);
pub const HWND_TOPMOST: ?HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
pub const HWND_NOTOPMOST: ?HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));

// Registry functions (for color scheme detection)
pub const HKEY = ?*opaque {};
pub const HKEY_CURRENT_USER: HKEY = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2147483647))));
pub const KEY_READ: DWORD = 0x20019;
pub const REG_DWORD: DWORD = 4;

pub extern "advapi32" fn RegOpenKeyExW(hKey: HKEY, lpSubKey: [*:0]const u16, ulOptions: DWORD, samDesired: DWORD, phkResult: *HKEY) callconv(WINAPI) i32;
pub extern "advapi32" fn RegQueryValueExW(hKey: HKEY, lpValueName: [*:0]const u16, lpReserved: ?*DWORD, lpType: ?*DWORD, lpData: ?[*]u8, lpcbData: ?*DWORD) callconv(WINAPI) i32;
pub extern "advapi32" fn RegCloseKey(hKey: HKEY) callconv(WINAPI) i32;

// Helper inline functions for message parameter extraction
pub inline fn GET_X_LPARAM(lp: LPARAM) i16 {
    return @as(i16, @truncate(lp));
}

pub inline fn GET_Y_LPARAM(lp: LPARAM) i16 {
    return @as(i16, @truncate(lp >> 16));
}

pub inline fn GET_WHEEL_DELTA_WPARAM(wp: WPARAM) i16 {
    return @as(i16, @truncate(@as(isize, @bitCast(wp)) >> 16));
}

pub inline fn GET_XBUTTON_WPARAM(wp: WPARAM) u32 {
    return @as(u32, @truncate((@as(usize, @bitCast(wp)) >> 16) & 0xFFFF));
}

pub inline fn MAKELPARAM(low: i32, high: i32) LPARAM {
    const lo: u16 = @bitCast(@as(i16, @truncate(low)));
    const hi: u16 = @bitCast(@as(i16, @truncate(high)));
    return @as(LPARAM, @bitCast(@as(isize, @intCast(@as(u32, hi) << 16 | @as(u32, lo)))));
}

pub inline fn LOWORD(value: anytype) u16 {
    const T = @TypeOf(value);
    const v: usize = switch (@typeInfo(T)) {
        .comptime_int => @as(usize, @intCast(value)),
        .int => if (@typeInfo(T).int.signedness == .signed)
            @bitCast(@as(isize, value))
        else
            @as(usize, @intCast(value)),
        .pointer => @intFromPtr(value),
        else => @as(usize, @bitCast(value)),
    };
    return @truncate(v);
}

// Message wait function (replaces Sleep for responsive message loops)
pub extern "user32" fn MsgWaitForMultipleObjects(nCount: DWORD, pHandles: ?[*]const HANDLE, fWaitAll: BOOL, dwMilliseconds: DWORD, dwWakeMask: DWORD) callconv(WINAPI) DWORD;
pub const QS_ALLINPUT: DWORD = 0x04FF;
pub const INFINITE: DWORD = 0xFFFFFFFF;

// High-resolution waitable timer (kernel32)
pub extern "kernel32" fn CreateWaitableTimerExW(lpTimerAttributes: ?*anyopaque, lpTimerName: ?[*:0]const u16, dwFlags: DWORD, dwDesiredAccess: DWORD) callconv(WINAPI) ?HANDLE;
pub extern "kernel32" fn SetWaitableTimer(hTimer: HANDLE, lpDueTime: *const i64, lPeriod: i32, pfnCompletionRoutine: ?*anyopaque, lpArgToCompletionRoutine: ?*anyopaque, fResume: BOOL) callconv(WINAPI) BOOL;
pub const CREATE_WAITABLE_TIMER_HIGH_RESOLUTION: DWORD = 0x00000002;
pub const TIMER_ALL_ACCESS: DWORD = 0x1F0003;

// dwmapi.dll functions
pub const MARGINS = extern struct {
    cxLeftWidth: i32,
    cxRightWidth: i32,
    cyTopHeight: i32,
    cyBottomHeight: i32,
};

pub extern "dwmapi" fn DwmExtendFrameIntoClientArea(hWnd: HWND, pMarInset: *const MARGINS) callconv(WINAPI) i32;
pub extern "dwmapi" fn DwmDefWindowProc(hWnd: HWND, msg: u32, wParam: WPARAM, lParam: LPARAM, plResult: *LRESULT) callconv(WINAPI) BOOL;
pub extern "dwmapi" fn DwmFlush() callconv(WINAPI) i32;

// winmm.dll functions (multimedia timer resolution)
pub extern "winmm" fn timeBeginPeriod(uPeriod: u32) callconv(WINAPI) u32;
pub extern "winmm" fn timeEndPeriod(uPeriod: u32) callconv(WINAPI) u32;

// Shell notification (balloon tips)
pub const NOTIFYICONDATAW = extern struct {
    cbSize: DWORD,
    hWnd: ?HWND,
    uID: u32,
    uFlags: u32,
    uCallbackMessage: u32,
    hIcon: HICON,
    szTip: [128]u16,
    dwState: DWORD,
    dwStateMask: DWORD,
    szInfo: [256]u16,
    uVersion: u32,
    szInfoTitle: [64]u16,
    dwInfoFlags: DWORD,
    guidItem: [16]u8,
    hBalloonIcon: HICON,
};

pub const NIM_ADD: DWORD = 0x00000000;
pub const NIM_MODIFY: DWORD = 0x00000001;
pub const NIM_DELETE: DWORD = 0x00000002;
pub const NIM_SETVERSION: DWORD = 0x00000004;
pub const NIF_MESSAGE: u32 = 0x00000001;
pub const NIF_ICON: u32 = 0x00000002;
pub const NIF_TIP: u32 = 0x00000004;
pub const NIF_INFO: u32 = 0x00000010;
pub const NIF_SHOWTIP: u32 = 0x00000080;
pub const NIIF_INFO: DWORD = 0x00000001;
pub const NOTIFYICON_VERSION_4: u32 = 4;

pub extern "shell32" fn Shell_NotifyIconW(dwMessage: DWORD, lpData: *NOTIFYICONDATAW) callconv(WINAPI) BOOL;

pub extern "user32" fn LoadIconW(hInstance: ?HINSTANCE, lpIconName: [*:0]align(1) const u16) callconv(WINAPI) HICON;
pub const IDI_APPLICATION: [*:0]align(1) const u16 = @ptrFromInt(32512);

// Extended window styles for controls
pub const WS_EX_CLIENTEDGE: u32 = 0x00000200;

// Button styles
pub const BS_DEFPUSHBUTTON: u32 = 0x00000001;

// Static control styles
pub const SS_CENTER: u32 = 0x00000001;
pub const SS_CENTERIMAGE: u32 = 0x00000200;

// Edit control styles
pub const ES_LEFT: u32 = 0x0000;
pub const ES_AUTOHSCROLL: u32 = 0x0080;

// Edit control messages
pub const EM_SETSEL: u32 = 0x00B1;

// Edit notification codes
pub const EN_CHANGE: u16 = 0x0300;

// Window messages for controls
pub const WM_SETTEXT: u32 = 0x000C;
pub const WM_GETTEXT: u32 = 0x000D;
pub const WM_GETTEXTLENGTH: u32 = 0x000E;

// Virtual key codes
pub const VK_RETURN: u8 = 0x0D;
pub const VK_ESCAPE: u8 = 0x1B;
pub const VK_SHIFT: i32 = 0x10;

// Font message
pub const WM_SETFONT: u32 = 0x0030;

// Button notification codes
pub const BN_CLICKED: u16 = 0;

// System color constants
pub const COLOR_BTNFACE: usize = 15;

// Additional user32 functions
pub extern "user32" fn SendMessageW(hWnd: HWND, Msg: u32, wParam: WPARAM, lParam: LPARAM) callconv(WINAPI) LRESULT;
pub extern "user32" fn GetWindowTextW(hWnd: HWND, lpString: [*]u16, nMaxCount: i32) callconv(WINAPI) i32;
pub extern "user32" fn GetParent(hWnd: HWND) callconv(WINAPI) ?HWND;
pub extern "user32" fn SetParent(hWndChild: HWND, hWndNewParent: ?HWND) callconv(WINAPI) ?HWND;
pub extern "user32" fn CallWindowProcW(lpPrevWndFunc: WNDPROC, hWnd: HWND, Msg: u32, wParam: WPARAM, lParam: LPARAM) callconv(WINAPI) LRESULT;
pub extern "user32" fn EnableWindow(hWnd: HWND, bEnable: BOOL) callconv(WINAPI) BOOL;
pub extern "user32" fn IsChild(hWndParent: HWND, hWnd: HWND) callconv(WINAPI) c_int;
pub extern "user32" fn IsDialogMessageW(hDlg: HWND, lpMsg: *MSG) callconv(WINAPI) BOOL;

// GDI additional functions
pub extern "gdi32" fn SetBkColor(hdc: HDC, color: COLORREF) callconv(WINAPI) COLORREF;
pub extern "user32" fn FrameRect(hDC: HDC, lprc: *const RECT, hbr: HBRUSH) callconv(WINAPI) i32;

// opengl32.dll functions (WGL)
pub extern "opengl32" fn wglCreateContext(hdc: HDC) callconv(WINAPI) ?HGLRC;
pub extern "opengl32" fn wglDeleteContext(hglrc: HGLRC) callconv(WINAPI) BOOL;
pub extern "opengl32" fn wglMakeCurrent(hdc: ?HDC, hglrc: ?HGLRC) callconv(WINAPI) BOOL;
pub extern "opengl32" fn wglGetProcAddress(lpszProc: [*:0]const u8) callconv(WINAPI) ?*const anyopaque;

// Dynamic library loading (kernel32)
pub const HMODULE = ?*opaque {};
pub const FARPROC = ?*const anyopaque;
pub extern "kernel32" fn LoadLibraryW(lpLibFileName: [*:0]const u16) callconv(WINAPI) HMODULE;
pub extern "kernel32" fn FreeLibrary(hLibModule: HMODULE) callconv(WINAPI) BOOL;
pub extern "kernel32" fn GetProcAddress(hModule: HMODULE, lpProcName: [*:0]const u8) callconv(WINAPI) FARPROC;
pub extern "kernel32" fn GetModuleFileNameW(hModule: HMODULE, lpFilename: [*]u16, nSize: u32) callconv(WINAPI) u32;
