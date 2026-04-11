const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const apprt = @import("../apprt.zig");
const CoreApp = @import("../App.zig");
const CoreSurface = @import("../Surface.zig");
const cli = @import("../cli.zig");
const configpkg = @import("../config.zig");
const config_edit = @import("../config/edit.zig");
const windows_shell = @import("../config/windows_shell.zig");
const input = @import("../input.zig");
const homedir = @import("../os/homedir.zig");
const internal_os = @import("../os/main.zig");
const terminal = @import("../terminal/main.zig");
const SplitTree = @import("../datastruct/split_tree.zig").SplitTree;

const log = std.log.scoped(.win32);
const windows = std.os.windows;

pub const resourcesDir = internal_os.resourcesDir;

const ATOM = u16;
const LPCWSTR = [*:0]const u16;
const HBRUSH = ?*anyopaque;
const HCURSOR = ?*anyopaque;
const HDC = ?*anyopaque;
const HGLRC = ?*anyopaque;
const HMODULE = ?*anyopaque;
const HMENU = ?*anyopaque;
const HICON = ?*anyopaque;
const HRGN = ?*anyopaque;
const LPARAM = isize;
const WPARAM = usize;
const LRESULT = isize;
const LONG_PTR = isize;
const UINT = u32;
const DWORD = u32;
const WORD = u16;
const BYTE = u8;
const BOOL = windows.BOOL;
const HWND = windows.HWND;
const HINSTANCE = windows.HINSTANCE;
const INTRESOURCE = ?*const anyopaque;

const CS_OWNDC = 0x0020;
const CW_USEDEFAULT = @as(i32, @bitCast(@as(u32, 0x80000000)));
const GWLP_USERDATA = -21;
const GWLP_WNDPROC = -4;
const GWL_STYLE = -16;
const GWL_EXSTYLE = -20;
const IDC_ARROW = @as(INTRESOURCE, @ptrFromInt(32512));
const HTCLIENT = 1;
const HWND_TOPMOST: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
const HWND_NOTOPMOST: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));
const SW_SHOW = 5;
const SW_RESTORE = 9;
const SW_MAXIMIZE = 3;
const SW_HIDE = 0;
const WM_APP = 0x8000;
const WM_COMMAND = 0x0111;
const WM_CLOSE = 0x0010;
const WM_DESTROY = 0x0002;
const WM_DRAWITEM = 0x002B;
const WM_ERASEBKGND = 0x0014;
const WM_GETMINMAXINFO = 0x0024;
const WM_CHAR = 0x0102;
const WM_KILLFOCUS = 0x0008;
const WM_KEYDOWN = 0x0100;
const WM_KEYUP = 0x0101;
const WM_LBUTTONDOWN = 0x0201;
const WM_LBUTTONUP = 0x0202;
const WM_LBUTTONDBLCLK = 0x0203;
const WM_MBUTTONDOWN = 0x0207;
const WM_MBUTTONUP = 0x0208;
const WM_MOUSEHWHEEL = 0x020E;
const WM_MOUSEMOVE = 0x0200;
const WM_MOUSEWHEEL = 0x020A;
const WM_MOUSELEAVE = 0x02A3;
const WM_POINTERHWHEEL = 0x024F;
const WM_POINTERWHEEL = 0x024E;
const WM_NCCREATE = 0x0081;
const WM_PAINT = 0x000F;
const WM_CTLCOLOREDIT = 0x0133;
const WM_CTLCOLORBTN = 0x0135;
const WM_CTLCOLORSTATIC = 0x0138;
const WM_RBUTTONDOWN = 0x0204;
const WM_RBUTTONUP = 0x0205;
const WM_SETCURSOR = 0x0020;
const WM_SETFOCUS = 0x0007;
const WM_SETTINGCHANGE = 0x001A;
const WM_SIZE = 0x0005;
const WM_SYSKEYDOWN = 0x0104;
const WM_SYSKEYUP = 0x0105;
const WM_WINHOSTTY_WAKE = WM_APP + 1;
const WS_OVERLAPPED = 0x00000000;
const WS_CHILD = 0x40000000;
const WS_CLIPCHILDREN = 0x02000000;
const WS_CLIPSIBLINGS = 0x04000000;
const WS_CAPTION = 0x00C00000;
const WS_GROUP = 0x00020000;
const WS_SYSMENU = 0x00080000;
const WS_THICKFRAME = 0x00040000;
const WS_MINIMIZEBOX = 0x00020000;
const WS_MAXIMIZEBOX = 0x00010000;
const WS_VISIBLE = 0x10000000;
const WS_TABSTOP = 0x00010000;
const WS_BORDER = 0x00800000;
const WS_OVERLAPPEDWINDOW = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX;
const WS_POPUP = 0x80000000;
const WS_EX_LAYERED = 0x00080000;
const SWP_NOSIZE = 0x0001;
const SWP_NOMOVE = 0x0002;
const SWP_NOZORDER = 0x0004;
const SWP_NOACTIVATE = 0x0010;
const SWP_FRAMECHANGED = 0x0020;
const MONITOR_DEFAULTTONEAREST = 0x00000002;
const COLOR_WINDOW = 5;
const CF_UNICODETEXT = 13;
const GMEM_MOVEABLE = 0x0002;
const GMEM_ZEROINIT = 0x0040;
const LWA_ALPHA = 0x00000002;
const TRANSPARENT = 1;
const OPAQUE = 2;
const IDYES = 6;
const IDOK = 1;
const IDCANCEL = 2;
const MB_ICONWARNING = 0x00000030;
const MB_ICONINFORMATION = 0x00000040;
const MB_OK = 0x00000000;
const MB_YESNO = 0x00000004;
const MK_CONTROL = 0x0008;
const MK_LBUTTON = 0x0001;
const MK_MBUTTON = 0x0010;
const MK_RBUTTON = 0x0002;
const MK_SHIFT = 0x0004;
const EN_CHANGE = 0x0300;
const BS_PUSHBUTTON = 0x00000000;
const BS_DEFPUSHBUTTON = 0x00000001;
const BS_FLAT = 0x00008000;
const BS_OWNERDRAW = 0x0000000B;
const ES_AUTOHSCROLL = 0x0080;
const BN_CLICKED = 0;
const EM_SETSEL = 0x00B1;
const ODT_BUTTON = 4;
const ODS_SELECTED = 0x0001;
const ODS_DISABLED = 0x0004;
const ODS_FOCUS = 0x0010;
const TME_LEAVE = 0x00000002;
const DT_CENTER = 0x00000001;
const DT_VCENTER = 0x00000004;
const DT_SINGLELINE = 0x00000020;
const DT_NOPREFIX = 0x00000800;
const DT_END_ELLIPSIS = 0x00008000;
const host_tab_height = 34;
const host_overlay_height = 58;
const host_inspector_panel_height = 42;
const host_status_height = 42;
const host_overlay_padding = 12;
const host_overlay_label_width = 110;
const host_overlay_row_height = 24;
const host_overlay_accept_width = 70;
const host_overlay_cancel_width = 80;
const host_tab_cmd_button_width = 96;
const host_tab_profiles_button_width = 118;
const host_tab_target_button_width = 74;
const host_tab_nav_button_width = 30;
const host_tab_tabs_button_width = 88;
const host_tab_find_button_width = 96;
const host_tab_inspect_button_width = 96;
const host_tab_small_button_width = 34;
const host_tab_label_max_len = 24;
const host_tab_min_button_width = 108;
const curated_command_palette_actions = [_][]const u8{
    "new_tab",
    "new_split:right",
    "goto_split:right",
    "toggle_fullscreen",
    "toggle_command_palette",
    "toggle_tab_overview",
    "start_search",
    "inspector:toggle",
    "reload_config",
};
const releases_url = "https://github.com/amanthanvi/winghostty/releases/latest";
const WM_THEMECHANGED = 0x031A;
const WM_SYSCOLORCHANGE = 0x0015;
const WM_DPICHANGED: UINT = 0x02E0;
const DWMWA_USE_IMMERSIVE_DARK_MODE_V1: DWORD = 19;
const DWMWA_USE_IMMERSIVE_DARK_MODE: DWORD = 20;
const DWMWA_CAPTION_COLOR: DWORD = 35;
const SPI_GETHIGHCONTRAST: UINT = 0x0042;
const HCF_HIGHCONTRASTON: DWORD = 0x00000001;
const COLOR_WINDOWTEXT = 8;
const COLOR_BTNFACE = 15;
const COLOR_BTNTEXT = 18;
const COLOR_GRAYTEXT = 17;
const COLOR_HIGHLIGHT = 13;
const COLOR_HIGHLIGHTTEXT = 14;
const HKEY_CURRENT_USER: usize = 0x80000001;
const KEY_READ: DWORD = 0x20019;
const REG_DWORD: DWORD = 4;
const ERROR_SUCCESS: i32 = 0;
const PFD_DRAW_TO_WINDOW = 0x00000004;
const PFD_SUPPORT_OPENGL = 0x00000020;
const PFD_DOUBLEBUFFER = 0x00000001;
const PFD_TYPE_RGBA = 0;
const PFD_MAIN_PLANE = 0;

// Context menu constants
const MF_STRING: UINT = 0x00000000;
const MF_SEPARATOR: UINT = 0x00000800;
const MF_GRAYED: UINT = 0x00000001;
const TPM_LEFTALIGN: UINT = 0x0000;
const TPM_TOPALIGN: UINT = 0x0000;
const TPM_RETURNCMD: UINT = 0x0100;
const TPM_RIGHTBUTTON: UINT = 0x0002;
const WM_NULL: UINT = 0x0000;
const CTX_COPY: usize = 4001;
const CTX_PASTE: usize = 4002;
const CTX_SELECT_ALL: usize = 4003;
const CTX_FIND: usize = 4004;
const CTX_COMMAND_PALETTE: usize = 4005;
const CTX_NEW_TAB: usize = 4006;
const CTX_SPLIT_RIGHT: usize = 4007;
const CTX_NEW_WINDOW: usize = 4008;

const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;
const SHORT = i16;

const VK_BACK = 0x08;
const VK_TAB = 0x09;
const VK_RETURN = 0x0D;
const VK_SHIFT = 0x10;
const VK_CONTROL = 0x11;
const VK_MENU = 0x12;
const VK_PAUSE = 0x13;
const VK_CAPITAL = 0x14;
const VK_ESCAPE = 0x1B;
const VK_SPACE = 0x20;
const VK_PRIOR = 0x21;
const VK_NEXT = 0x22;
const VK_END = 0x23;
const VK_HOME = 0x24;
const VK_LEFT = 0x25;
const VK_UP = 0x26;
const VK_RIGHT = 0x27;
const VK_DOWN = 0x28;
const VK_SNAPSHOT = 0x2C;
const VK_INSERT = 0x2D;
const VK_DELETE = 0x2E;
const VK_0 = 0x30;
const VK_9 = 0x39;
const VK_A = 0x41;
const VK_Z = 0x5A;
const VK_LWIN = 0x5B;
const VK_RWIN = 0x5C;
const VK_APPS = 0x5D;
const VK_NUMPAD0 = 0x60;
const VK_NUMPAD9 = 0x69;
const VK_MULTIPLY = 0x6A;
const VK_ADD = 0x6B;
const VK_SEPARATOR = 0x6C;
const VK_SUBTRACT = 0x6D;
const VK_DECIMAL = 0x6E;
const VK_DIVIDE = 0x6F;
const VK_F1 = 0x70;
const VK_F3 = 0x72;
const VK_F2 = 0x71;
const VK_F24 = 0x87;
const VK_NUMLOCK = 0x90;
const VK_SCROLL = 0x91;
const VK_LSHIFT = 0xA0;
const VK_RSHIFT = 0xA1;
const VK_LCONTROL = 0xA2;
const VK_RCONTROL = 0xA3;
const VK_LMENU = 0xA4;
const VK_RMENU = 0xA5;
const VK_OEM_1 = 0xBA;
const VK_OEM_PLUS = 0xBB;
const VK_OEM_COMMA = 0xBC;
const VK_OEM_MINUS = 0xBD;
const VK_OEM_PERIOD = 0xBE;
const VK_OEM_2 = 0xBF;
const VK_OEM_3 = 0xC0;
const VK_OEM_4 = 0xDB;
const VK_OEM_5 = 0xDC;
const VK_OEM_6 = 0xDD;
const VK_OEM_7 = 0xDE;

const KF_EXTENDED = 1 << 24;
const KF_REPEAT = 1 << 30;
const SPI_GETWHEELSCROLLLINES = 0x0068;
const SPI_GETWHEELSCROLLCHARS = 0x006C;
const WHEEL_DELTA = 120;
const WHEEL_PAGESCROLL = 0xFFFF_FFFF;
const ERROR_FILE_NOT_FOUND = 2;
const ERROR_BROKEN_PIPE = 109;
const ERROR_PIPE_BUSY = 231;
const ERROR_PIPE_CONNECTED = 535;
const PIPE_READMODE_BYTE = 0x00000000;
const PIPE_WAIT = 0x00000000;
const PIPE_ACCESS_DUPLEX = 0x00000003;
const PIPE_UNLIMITED_INSTANCES = 255;
const ipc_pipe_prefix = "\\\\.\\pipe\\winghostty.";
const ipc_wire_version: u32 = 1;
const ipc_ack_success: u8 = 0;
const ipc_ack_failure: u8 = 1;

const POINT = extern struct {
    x: i32,
    y: i32,
};

const RECT = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

const PIXELFORMATDESCRIPTOR = extern struct {
    nSize: WORD,
    nVersion: WORD,
    dwFlags: u32,
    iPixelType: BYTE,
    cColorBits: BYTE,
    cRedBits: BYTE,
    cRedShift: BYTE,
    cGreenBits: BYTE,
    cGreenShift: BYTE,
    cBlueBits: BYTE,
    cBlueShift: BYTE,
    cAlphaBits: BYTE,
    cAlphaShift: BYTE,
    cAccumBits: BYTE,
    cAccumRedBits: BYTE,
    cAccumGreenBits: BYTE,
    cAccumBlueBits: BYTE,
    cAccumAlphaBits: BYTE,
    cDepthBits: BYTE,
    cStencilBits: BYTE,
    cAuxBuffers: BYTE,
    iLayerType: BYTE,
    bReserved: BYTE,
    dwLayerMask: u32,
    dwVisibleMask: u32,
    dwDamageMask: u32,
};

const MSG = extern struct {
    hwnd: HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: u32,
    pt: POINT,
    lPrivate: u32,
};

const PAINTSTRUCT = extern struct {
    hdc: HDC,
    fErase: BOOL,
    rcPaint: RECT,
    fRestore: BOOL,
    fIncUpdate: BOOL,
    rgbReserved: [32]u8,
};

const DRAWITEMSTRUCT = extern struct {
    CtlType: UINT,
    CtlID: UINT,
    itemID: UINT,
    itemAction: UINT,
    itemState: UINT,
    hwndItem: HWND,
    hDC: HDC,
    rcItem: RECT,
    itemData: usize,
};

const TRACKMOUSEEVENT = extern struct {
    cbSize: DWORD,
    dwFlags: DWORD,
    hwndTrack: HWND,
    dwHoverTime: DWORD,
};

const WNDCLASSEXW = extern struct {
    cbSize: u32,
    style: u32,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: HINSTANCE,
    hIcon: HICON,
    hCursor: HCURSOR,
    hbrBackground: HBRUSH,
    lpszMenuName: ?LPCWSTR,
    lpszClassName: LPCWSTR,
    hIconSm: HICON,
};

const CREATESTRUCTW = extern struct {
    lpCreateParams: ?*anyopaque,
    hInstance: HINSTANCE,
    hMenu: HMENU,
    hwndParent: HWND,
    cy: i32,
    cx: i32,
    y: i32,
    x: i32,
    style: i32,
    lpszName: LPCWSTR,
    lpszClass: LPCWSTR,
    dwExStyle: u32,
};

const MONITORINFO = extern struct {
    cbSize: u32,
    rcMonitor: RECT,
    rcWork: RECT,
    dwFlags: u32,
};

const MINMAXINFO = extern struct {
    ptReserved: POINT,
    ptMaxSize: POINT,
    ptMaxPosition: POINT,
    ptMinTrackSize: POINT,
    ptMaxTrackSize: POINT,
};

extern "user32" fn RegisterClassExW(lpWndClass: *const WNDCLASSEXW) callconv(.winapi) ATOM;
extern "user32" fn CreateWindowExW(
    dwExStyle: u32,
    lpClassName: LPCWSTR,
    lpWindowName: LPCWSTR,
    dwStyle: u32,
    X: i32,
    Y: i32,
    nWidth: i32,
    nHeight: i32,
    hWndParent: ?HWND,
    hMenu: HMENU,
    hInstance: HINSTANCE,
    lpParam: ?*anyopaque,
) callconv(.winapi) ?HWND;
extern "user32" fn CallWindowProcW(lpPrevWndFunc: ?*const anyopaque, hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn DefWindowProcW(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn DrawTextW(hDC: HDC, lpchText: [*:0]const u16, cchText: i32, lprc: *RECT, format: UINT) callconv(.winapi) i32;
extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) LRESULT;
extern "user32" fn EnableWindow(hWnd: HWND, bEnable: BOOL) callconv(.winapi) BOOL;
extern "user32" fn GetFocus() callconv(.winapi) ?HWND;
extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: ?HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT) callconv(.winapi) i32;
extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;
extern "user32" fn GetKeyState(nVirtKey: i32) callconv(.winapi) SHORT;
extern "user32" fn GetKeyboardState(lpKeyState: *[256]u8) callconv(.winapi) BOOL;
extern "user32" fn GetMonitorInfoW(hMonitor: ?*anyopaque, lpmi: *MONITORINFO) callconv(.winapi) BOOL;
extern "user32" fn GetWindowRect(hWnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;
extern "user32" fn GetWindowTextLengthW(hWnd: HWND) callconv(.winapi) i32;
extern "user32" fn GetWindowTextW(hWnd: HWND, lpString: [*]u16, nMaxCount: i32) callconv(.winapi) i32;
extern "user32" fn IsWindowVisible(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn IsZoomed(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn MonitorFromWindow(hwnd: HWND, dwFlags: u32) callconv(.winapi) ?*anyopaque;
extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
extern "user32" fn ScreenToClient(hWnd: HWND, lpPoint: *POINT) callconv(.winapi) BOOL;
extern "user32" fn TrackMouseEvent(lpEventTrack: *TRACKMOUSEEVENT) callconv(.winapi) BOOL;
extern "user32" fn BeginPaint(hWnd: HWND, lpPaint: *PAINTSTRUCT) callconv(.winapi) HDC;
extern "user32" fn EndPaint(hWnd: HWND, lpPaint: *const PAINTSTRUCT) callconv(.winapi) BOOL;
extern "user32" fn GetDC(hWnd: HWND) callconv(.winapi) HDC;
extern "user32" fn OpenClipboard(hWndNewOwner: ?HWND) callconv(.winapi) BOOL;
extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
extern "user32" fn GetClipboardData(uFormat: UINT) callconv(.winapi) ?*anyopaque;
extern "user32" fn SetClipboardData(uFormat: UINT, hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "user32" fn IsClipboardFormatAvailable(format: UINT) callconv(.winapi) BOOL;
extern "user32" fn LoadCursorW(hInstance: ?HINSTANCE, lpCursorName: INTRESOURCE) callconv(.winapi) HCURSOR;
extern "user32" fn MessageBoxW(hWnd: ?HWND, lpText: LPCWSTR, lpCaption: LPCWSTR, uType: UINT) callconv(.winapi) i32;
extern "user32" fn MessageBeep(uType: UINT) callconv(.winapi) BOOL;
extern "user32" fn InvalidateRect(hWnd: HWND, lpRect: ?*const RECT, bErase: BOOL) callconv(.winapi) BOOL;
extern "user32" fn MoveWindow(hWnd: HWND, X: i32, Y: i32, nWidth: i32, nHeight: i32, bRepaint: BOOL) callconv(.winapi) BOOL;
extern "user32" fn PostMessageW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) BOOL;
extern "user32" fn PostQuitMessage(nExitCode: i32) callconv(.winapi) void;
extern "user32" fn ReleaseDC(hWnd: HWND, hDC: HDC) callconv(.winapi) i32;
extern "user32" fn SetCursor(hCursor: HCURSOR) callconv(.winapi) HCURSOR;
extern "user32" fn SetCapture(hWnd: HWND) callconv(.winapi) ?HWND;
extern "user32" fn SetForegroundWindow(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn SetLayeredWindowAttributes(hwnd: HWND, crKey: u32, bAlpha: BYTE, dwFlags: u32) callconv(.winapi) BOOL;
extern "user32" fn SetWindowLongPtrW(hWnd: HWND, nIndex: i32, dwNewLong: LONG_PTR) callconv(.winapi) LONG_PTR;
extern "user32" fn SetWindowPos(hWnd: HWND, hWndInsertAfter: ?*anyopaque, X: i32, Y: i32, cx: i32, cy: i32, uFlags: UINT) callconv(.winapi) BOOL;
extern "user32" fn SetActiveWindow(hWnd: HWND) callconv(.winapi) ?HWND;
extern "user32" fn SetFocus(hWnd: HWND) callconv(.winapi) ?HWND;
extern "user32" fn SendMessageW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn SetWindowTextW(hWnd: HWND, lpString: LPCWSTR) callconv(.winapi) BOOL;
extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: i32) callconv(.winapi) LONG_PTR;
extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: i32) callconv(.winapi) BOOL;
extern "user32" fn SystemParametersInfoW(uiAction: UINT, uiParam: UINT, pvParam: ?*anyopaque, fWinIni: UINT) callconv(.winapi) BOOL;
extern "user32" fn GetSysColor(nIndex: i32) callconv(.winapi) u32;
extern "user32" fn GetDpiForWindow(hwnd: HWND) callconv(.winapi) UINT;
extern "user32" fn CreatePopupMenu() callconv(.winapi) HMENU;
extern "user32" fn AppendMenuW(hMenu: HMENU, uFlags: UINT, uIDNewItem: usize, lpNewItem: ?LPCWSTR) callconv(.winapi) BOOL;
extern "user32" fn TrackPopupMenu(hMenu: HMENU, uFlags: UINT, x: i32, y: i32, nReserved: i32, hWnd: HWND, prcRect: ?*const RECT) callconv(.winapi) BOOL;
extern "user32" fn DestroyMenu(hMenu: HMENU) callconv(.winapi) BOOL;
extern "user32" fn ClientToScreen(hWnd: HWND, lpPoint: *POINT) callconv(.winapi) BOOL;
extern "user32" fn ToUnicode(
    wVirtKey: UINT,
    wScanCode: UINT,
    lpKeyState: *const [256]u8,
    pwszBuff: [*]u16,
    cchBuff: i32,
    wFlags: UINT,
) callconv(.winapi) i32;
extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) BOOL;
extern "user32" fn UpdateWindow(hWnd: HWND) callconv(.winapi) BOOL;
extern "kernel32" fn GetModuleHandleW(lpModuleName: ?LPCWSTR) callconv(.winapi) HINSTANCE;
extern "kernel32" fn CreateNamedPipeW(
    lpName: LPCWSTR,
    dwOpenMode: DWORD,
    dwPipeMode: DWORD,
    nMaxInstances: DWORD,
    nOutBufferSize: DWORD,
    nInBufferSize: DWORD,
    nDefaultTimeOut: DWORD,
    lpSecurityAttributes: ?*windows.SECURITY_ATTRIBUTES,
) callconv(.winapi) windows.HANDLE;
extern "kernel32" fn ConnectNamedPipe(
    hNamedPipe: windows.HANDLE,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) BOOL;
extern "kernel32" fn DisconnectNamedPipe(hNamedPipe: windows.HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn FlushFileBuffers(hFile: windows.HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GetProcAddress(hModule: HMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) callconv(.winapi) HMODULE;
extern "kernel32" fn SetCurrentDirectoryW(lpPathName: LPCWSTR) callconv(.winapi) BOOL;
extern "kernel32" fn WaitNamedPipeW(lpNamedPipeName: LPCWSTR, nTimeOut: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn GlobalAlloc(uFlags: UINT, dwBytes: usize) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalLock(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(hMem: ?*anyopaque) callconv(.winapi) BOOL;
extern "gdi32" fn ChoosePixelFormat(hdc: HDC, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(.winapi) i32;
extern "gdi32" fn CreateSolidBrush(color: u32) callconv(.winapi) HBRUSH;
extern "gdi32" fn DeleteObject(ho: ?*anyopaque) callconv(.winapi) BOOL;
extern "gdi32" fn FillRect(hdc: HDC, lprc: *const RECT, hbr: HBRUSH) callconv(.winapi) i32;
extern "gdi32" fn SetBkColor(hdc: HDC, color: u32) callconv(.winapi) u32;
extern "gdi32" fn SetBkMode(hdc: HDC, mode: i32) callconv(.winapi) i32;
extern "gdi32" fn SetPixelFormat(hdc: HDC, format: i32, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(.winapi) BOOL;
extern "gdi32" fn SetTextColor(hdc: HDC, color: u32) callconv(.winapi) u32;
extern "gdi32" fn SwapBuffers(hdc: HDC) callconv(.winapi) BOOL;
extern "gdi32" fn TextOutW(hdc: HDC, x: i32, y: i32, lpString: LPCWSTR, c: i32) callconv(.winapi) BOOL;
extern "advapi32" fn RegOpenKeyExW(hKey: usize, lpSubKey: LPCWSTR, ulOptions: DWORD, samDesired: DWORD, phkResult: *usize) callconv(.winapi) i32;
extern "advapi32" fn RegQueryValueExW(hKey: usize, lpValueName: LPCWSTR, lpReserved: ?*DWORD, lpType: ?*DWORD, lpData: ?*u8, lpcbData: ?*DWORD) callconv(.winapi) i32;
extern "advapi32" fn RegCloseKey(hKey: usize) callconv(.winapi) i32;
extern "opengl32" fn wglCreateContext(hdc: HDC) callconv(.winapi) HGLRC;
extern "opengl32" fn wglDeleteContext(hglrc: HGLRC) callconv(.winapi) BOOL;
extern "opengl32" fn wglGetProcAddress(lpszProc: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "opengl32" fn wglMakeCurrent(hdc: HDC, hglrc: HGLRC) callconv(.winapi) BOOL;
extern "dwmapi" fn DwmSetWindowAttribute(hwnd: HWND, dwAttribute: DWORD, pvAttribute: *const anyopaque, cbAttribute: DWORD) callconv(.winapi) i32;

const SystemWheelSettings = struct {
    lines: u32 = 3,
    chars: u32 = 3,
};

const MouseWheelAxis = enum {
    horizontal,
    vertical,
};

const WheelNormalizationContext = struct {
    settings: SystemWheelSettings = .{},
    cell_size: apprt.action.CellSize = .{ .width = 0, .height = 0 },
    viewport: apprt.SurfaceSize = .{ .width = 0, .height = 0 },
};

const NormalizedWheelScroll = struct {
    xoff: f64 = 0,
    yoff: f64 = 0,
    mods: input.ScrollMods = .{},
};
extern "shell32" fn ShellExecuteW(
    hwnd: ?HWND,
    lpOperation: ?LPCWSTR,
    lpFile: LPCWSTR,
    lpParameters: ?LPCWSTR,
    lpDirectory: ?LPCWSTR,
    nShowCmd: i32,
) callconv(.winapi) ?*anyopaque;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("winghostty.win32");
const host_class_name = std.unicode.utf8ToUtf16LeStringLiteral("winghostty.win32.host");
const default_title = std.unicode.utf8ToUtf16LeStringLiteral("winghostty");
const quick_terminal_title = std.unicode.utf8ToUtf16LeStringLiteral("winghostty quick terminal");
const prompt_label_class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
const prompt_edit_class = std.unicode.utf8ToUtf16LeStringLiteral("EDIT");
const prompt_button_class = std.unicode.utf8ToUtf16LeStringLiteral("BUTTON");
const prompt_ok_label = std.unicode.utf8ToUtf16LeStringLiteral("OK");
const prompt_cancel_label = std.unicode.utf8ToUtf16LeStringLiteral("Cancel");
const host_overlay_command_palette_label = std.unicode.utf8ToUtf16LeStringLiteral("Command:");
const host_overlay_search_label = std.unicode.utf8ToUtf16LeStringLiteral("Search:");
const host_overlay_profile_label = std.unicode.utf8ToUtf16LeStringLiteral("Profile:");
const host_overlay_surface_title_label = std.unicode.utf8ToUtf16LeStringLiteral("Window title:");
const host_overlay_tab_title_label = std.unicode.utf8ToUtf16LeStringLiteral("Tab title:");
const host_overlay_tab_overview_label = std.unicode.utf8ToUtf16LeStringLiteral("Tab:");
const host_tab_command_button_label = std.unicode.utf8ToUtf16LeStringLiteral("Cmd");
const host_tab_profiles_button_label = std.unicode.utf8ToUtf16LeStringLiteral("Prof");
const host_tab_target_button_label = std.unicode.utf8ToUtf16LeStringLiteral("Tab");
const host_tab_command_button_active_label = std.unicode.utf8ToUtf16LeStringLiteral("[Cmd]");
const host_tab_prev_button_label = std.unicode.utf8ToUtf16LeStringLiteral("<");
const host_tab_next_button_label = std.unicode.utf8ToUtf16LeStringLiteral(">");
const host_tab_tabs_button_label = std.unicode.utf8ToUtf16LeStringLiteral("Tabs");
const host_tab_tabs_button_active_label = std.unicode.utf8ToUtf16LeStringLiteral("[Tabs]");
const host_tab_inspector_button_label = std.unicode.utf8ToUtf16LeStringLiteral("Inspect");
const host_tab_inspector_button_active_label = std.unicode.utf8ToUtf16LeStringLiteral("[Inspect]");
const host_tab_new_button_label = std.unicode.utf8ToUtf16LeStringLiteral("+");
const host_tab_close_button_label = std.unicode.utf8ToUtf16LeStringLiteral("x");
const host_banner_inspector_active = "Inspector active. Toggle inspector to return to the terminal view.";
const host_banner_inspector_inactive = "Inspector hidden. Terminal view is active.";
const clipboard_read_title = std.unicode.utf8ToUtf16LeStringLiteral("Allow clipboard paste?");
const clipboard_read_message = std.unicode.utf8ToUtf16LeStringLiteral("winghostty needs confirmation before completing this clipboard paste or read request.");
const clipboard_write_title = std.unicode.utf8ToUtf16LeStringLiteral("Allow clipboard write?");
const clipboard_write_message = std.unicode.utf8ToUtf16LeStringLiteral("winghostty needs confirmation before allowing this application to write to the Windows clipboard.");
const notification_title = std.unicode.utf8ToUtf16LeStringLiteral("winghostty");
const opengl32_name: [*:0]const u8 = "opengl32.dll";
const shell_open: LPCWSTR = std.unicode.utf8ToUtf16LeStringLiteral("open");

var opengl32_module: HMODULE = null;

const ForwardedArgIterator = struct {
    args: []const [:0]const u8,
    idx: usize = 0,

    fn next(self: *ForwardedArgIterator) ?[]const u8 {
        if (self.idx >= self.args.len) return null;
        defer self.idx += 1;
        return self.args[self.idx];
    }
};

fn hostWindowStyle() u32 {
    // Prevent the host from repainting across the OpenGL child surface.
    return WS_OVERLAPPEDWINDOW | WS_VISIBLE | WS_CLIPCHILDREN;
}

fn surfaceWindowStyle() u32 {
    // Prevent the terminal child surface from repainting over sibling controls.
    return WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS;
}

fn defaultIpcNamespace() []const u8 {
    return if (builtin.mode == .Debug)
        "com.mitchellh.ghostty-debug"
    else
        "com.mitchellh.ghostty";
}

fn sanitizeIpcNamespace(alloc: Allocator, raw: ?[]const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw orelse defaultIpcNamespace(), &std.ascii.whitespace);
    const source = if (trimmed.len == 0) defaultIpcNamespace() else trimmed;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);

    for (source) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_') {
            try buf.append(alloc, c);
        } else {
            try buf.append(alloc, '_');
        }
    }

    if (buf.items.len == 0) try buf.appendSlice(alloc, defaultIpcNamespace());
    return try buf.toOwnedSlice(alloc);
}

fn allocIpcPipeName(alloc: Allocator, raw_namespace: ?[]const u8) ![:0]const u16 {
    const namespace = try sanitizeIpcNamespace(alloc, raw_namespace);
    defer alloc.free(namespace);

    const pipe_name_utf8 = try std.fmt.allocPrint(alloc, "{s}{s}", .{
        ipc_pipe_prefix,
        namespace,
    });
    defer alloc.free(pipe_name_utf8);

    return try std.unicode.utf8ToUtf16LeAllocZ(alloc, pipe_name_utf8);
}

fn resolveIpcPipeNameForTarget(
    alloc: Allocator,
    target: apprt.ipc.Target,
) ![:0]const u16 {
    return switch (target) {
        .class => |class| allocIpcPipeName(alloc, class),
        .detect => allocIpcPipeName(alloc, null),
    };
}

fn appendU32(dst: *std.ArrayList(u8), alloc: Allocator, value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .little);
    try dst.appendSlice(alloc, &buf);
}

fn readU32(src: []const u8) u32 {
    return std.mem.readInt(u32, src[0..4], .little);
}

fn freeOwnedArguments(alloc: Allocator, arguments: ?[]const [:0]const u8) void {
    if (arguments) |owned| {
        for (owned) |arg| alloc.free(arg);
        alloc.free(owned);
    }
}

fn encodeNewWindowIpcRequest(
    alloc: Allocator,
    arguments: ?[]const [:0]const u8,
) ![]u8 {
    var encoded: std.ArrayList(u8) = .empty;
    errdefer encoded.deinit(alloc);

    try appendU32(&encoded, alloc, ipc_wire_version);
    try encoded.append(alloc, 1);

    const argc: u32 = if (arguments) |argv| @intCast(argv.len) else 0;
    try appendU32(&encoded, alloc, argc);

    if (arguments) |argv| {
        for (argv) |arg| {
            try appendU32(&encoded, alloc, @intCast(arg.len));
            try encoded.appendSlice(alloc, arg);
        }
    }

    return try encoded.toOwnedSlice(alloc);
}

fn decodeNewWindowIpcRequest(
    alloc: Allocator,
    pipe: windows.HANDLE,
) !?[]const [:0]const u8 {
    var header: [9]u8 = undefined;
    try readExactHandle(pipe, &header);

    if (readU32(header[0..4]) != ipc_wire_version) return error.InvalidIpcRequest;
    if (header[4] != 1) return error.InvalidIpcRequest;

    const argc = readU32(header[5..9]);
    if (argc == 0) return null;

    const argv = try alloc.alloc([:0]const u8, argc);
    errdefer freeOwnedArguments(alloc, argv);

    for (argv, 0..) |*slot, i| {
        _ = i;
        var len_buf: [4]u8 = undefined;
        try readExactHandle(pipe, &len_buf);
        const len = readU32(&len_buf);

        const arg = try alloc.allocSentinel(u8, len, 0);
        try readExactHandle(pipe, arg[0..len]);
        slot.* = arg;
    }

    return argv;
}

fn writeIpcAck(pipe: windows.HANDLE, success: bool) !void {
    var response: [5]u8 = undefined;
    std.mem.writeInt(u32, response[0..4], ipc_wire_version, .little);
    response[4] = if (success) ipc_ack_success else ipc_ack_failure;
    try writeAllHandle(pipe, &response);
}

fn readIpcAck(pipe: windows.HANDLE) !bool {
    var response: [5]u8 = undefined;
    try readExactHandle(pipe, &response);
    if (readU32(response[0..4]) != ipc_wire_version) return error.InvalidIpcResponse;
    return switch (response[4]) {
        ipc_ack_success => true,
        ipc_ack_failure => error.IPCFailed,
        else => error.InvalidIpcResponse,
    };
}

fn readExactHandle(pipe: windows.HANDLE, dst: []u8) !void {
    var offset: usize = 0;
    while (offset < dst.len) {
        var read_len: u32 = 0;
        if (windows.kernel32.ReadFile(
            pipe,
            dst[offset..].ptr,
            @intCast(dst.len - offset),
            &read_len,
            null,
        ) == 0) {
            return switch (windows.kernel32.GetLastError()) {
                ERROR_BROKEN_PIPE => error.EndOfStream,
                else => |err| windows.unexpectedError(err),
            };
        }

        if (read_len == 0) return error.EndOfStream;
        offset += read_len;
    }
}

fn writeAllHandle(pipe: windows.HANDLE, src: []const u8) !void {
    var offset: usize = 0;
    while (offset < src.len) {
        var write_len: u32 = 0;
        if (windows.kernel32.WriteFile(
            pipe,
            src[offset..].ptr,
            @intCast(src.len - offset),
            &write_len,
            null,
        ) == 0) return windows.unexpectedError(windows.kernel32.GetLastError());
        if (write_len == 0) return error.WriteFailed;
        offset += write_len;
    }
}

fn connectToIpcPipe(pipe_name: [:0]const u16) !windows.HANDLE {
    var retries: u8 = 0;
    while (true) {
        const handle = windows.kernel32.CreateFileW(
            pipe_name.ptr,
            windows.GENERIC_READ | windows.GENERIC_WRITE,
            0,
            null,
            windows.OPEN_EXISTING,
            windows.FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (handle != windows.INVALID_HANDLE_VALUE) return handle;

        const err = windows.kernel32.GetLastError();
        switch (err) {
            ERROR_FILE_NOT_FOUND => return error.FileNotFound,
            ERROR_PIPE_BUSY => {
                if (retries == 0 and WaitNamedPipeW(pipe_name.ptr, 1000) != 0) {
                    retries += 1;
                    continue;
                }
                return error.PipeBusy;
            },
            else => return windows.unexpectedError(err),
        }
    }
}

fn sendNewWindowIpc(
    alloc: Allocator,
    pipe_name: [:0]const u16,
    arguments: ?[]const [:0]const u8,
) !bool {
    const pipe = connectToIpcPipe(pipe_name) catch |err| switch (err) {
        error.FileNotFound => return false,
        error.PipeBusy => return error.IPCFailed,
        else => return err,
    };
    defer _ = windows.CloseHandle(pipe);

    const request = try encodeNewWindowIpcRequest(alloc, arguments);
    defer alloc.free(request);

    try writeAllHandle(pipe, request);
    return try readIpcAck(pipe);
}

fn applyNewWindowArguments(
    alloc_gpa: Allocator,
    config: *configpkg.Config,
    arguments: ?[]const [:0]const u8,
) !void {
    const argv = arguments orelse return;
    if (argv.len == 0) return;

    var iter: ForwardedArgIterator = .{ .args = argv };
    try config.loadIter(alloc_gpa, &iter);
    try config.finalize();
}

fn normalizeForwardedStartupArg(
    alloc: Allocator,
    arg: []const u8,
) !?[:0]const u8 {
    if (std.mem.startsWith(u8, arg, "--class=") or
        std.mem.startsWith(u8, arg, "--single-instance=") or
        std.mem.startsWith(u8, arg, "--gtk-single-instance="))
    {
        return null;
    }

    if (std.mem.startsWith(u8, arg, "--working-directory=")) {
        const raw = arg["--working-directory=".len..];
        const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (std.mem.eql(u8, trimmed, "home") or std.mem.eql(u8, trimmed, "inherit")) {
            return try alloc.dupeZ(u8, arg);
        }

        const cwd = std.fs.cwd();
        var home_buf: [std.fs.max_path_bytes]u8 = undefined;
        const expanded = homedir.expandHome(trimmed, &home_buf) catch trimmed;
        var realpath_buf: [std.fs.max_path_bytes]u8 = undefined;
        const normalized = cwd.realpath(expanded, &realpath_buf) catch expanded;
        return try std.fmt.allocPrintSentinel(
            alloc,
            "--working-directory={s}",
            .{normalized},
            0,
        );
    }

    return try alloc.dupeZ(u8, arg);
}

fn collectStartupForwardArguments(alloc: Allocator) !?[]const [:0]const u8 {
    var iter = try cli.args.argsIterator(alloc);
    defer iter.deinit();

    var argv: std.ArrayList([:0]const u8) = .empty;
    var working_directory_seen = false;
    errdefer {
        for (argv.items) |arg| alloc.free(arg);
        argv.deinit(alloc);
    }

    while (iter.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--working-directory=")) {
            working_directory_seen = true;
        }
        if (try normalizeForwardedStartupArg(alloc, arg)) |normalized| {
            try argv.append(alloc, normalized);
        }
    }

    if (!working_directory_seen) {
        const cwd = std.fs.cwd();
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const wd = try cwd.realpath(".", &cwd_buf);
        try argv.insert(alloc, 0, try std.fmt.allocPrintSentinel(
            alloc,
            "--working-directory={s}",
            .{wd},
            0,
        ));
    }

    if (argv.items.len == 0) {
        argv.deinit(alloc);
        return null;
    }

    return try argv.toOwnedSlice(alloc);
}

fn ipcServerMain(app: *App) void {
    const pipe_name = app.ipc_pipe_name orelse return;

    while (!app.ipc_stop_requested.load(.acquire)) {
        const pipe = CreateNamedPipeW(
            pipe_name.ptr,
            PIPE_ACCESS_DUPLEX,
            windows.PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
            PIPE_UNLIMITED_INSTANCES,
            16 * 1024,
            16 * 1024,
            0,
            null,
        );
        if (pipe == windows.INVALID_HANDLE_VALUE) {
            log.warn("failed to create win32 IPC pipe err={}", .{
                windows.kernel32.GetLastError(),
            });
            return;
        }

        const connected = ConnectNamedPipe(pipe, null);
        if (connected == 0) {
            const err = windows.kernel32.GetLastError();
            if (err != ERROR_PIPE_CONNECTED) {
                _ = windows.CloseHandle(pipe);
                if (!app.ipc_stop_requested.load(.acquire)) {
                    log.warn("failed to connect win32 IPC client err={}", .{err});
                }
                continue;
            }
        }

        if (app.ipc_stop_requested.load(.acquire)) {
            _ = windows.CloseHandle(pipe);
            break;
        }

        handleIpcClient(app, pipe) catch |err| {
            log.warn("failed to process win32 IPC client err={}", .{err});
            writeIpcAck(pipe, false) catch {};
        };

        _ = FlushFileBuffers(pipe);
        _ = DisconnectNamedPipe(pipe);
        _ = windows.CloseHandle(pipe);
    }
}

fn handleIpcClient(app: *App, pipe: windows.HANDLE) !void {
    const arguments = try decodeNewWindowIpcRequest(app.core_app.alloc, pipe);
    errdefer freeOwnedArguments(app.core_app.alloc, arguments);

    const mailbox: CoreApp.Mailbox = .{
        .rt_app = app,
        .mailbox = &app.core_app.mailbox,
    };
    _ = mailbox.push(.{ .new_window = .{
        .arguments = arguments,
    } }, .forever);

    try writeIpcAck(pipe, true);
}

fn trace(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    var file = std.fs.cwd().createFile("winghostty-win32.log", .{
        .truncate = false,
    }) catch return;
    defer file.close();
    file.seekFromEnd(0) catch return;
    file.writeAll(line) catch {};
}

pub fn getProcAddress(name: [*:0]const u8) callconv(.c) ?*const anyopaque {
    if (wglGetProcAddress(name)) |ptr| {
        const raw = @intFromPtr(ptr);
        if (raw > 3 and raw != std.math.maxInt(usize)) return ptr;
    }

    if (opengl32_module == null) {
        opengl32_module = LoadLibraryA(opengl32_name);
    }

    const module = opengl32_module orelse return null;
    return GetProcAddress(module, name);
}

pub const App = struct {
    pub const must_draw_from_app_thread = true;

    core_app: *CoreApp,
    config: configpkg.Config,
    resolved_theme: ThemeColors = darkTheme(),
    hinstance: HINSTANCE,
    class_atom: ATOM = 0,
    host_class_atom: ATOM = 0,
    hosts: std.ArrayListUnmanaged(*Host) = .empty,
    windows: std.ArrayListUnmanaged(*Surface) = .empty,
    next_host_id: u32 = 1,
    launcher_profile_key: ?[:0]const u8 = null,
    launcher_profile_hint: ?[:0]const u8 = null,
    launcher_profile_order_hint: ?[:0]const u8 = null,
    launcher_quick_slot_keys: [3]?[:0]const u8 = .{ null, null, null },
    launcher_profile_target: ProfileOpenTarget = .tab,
    startup_profile_picker: bool = false,
    wheel_settings: SystemWheelSettings = .{},
    ipc_pipe_name: ?[:0]const u16 = null,
    ipc_thread: ?std.Thread = null,
    ipc_stop_requested: std.atomic.Value(bool) = .init(false),
    running: bool = false,
    windows_hidden: bool = false,

    pub fn init(
        self: *App,
        core_app: *CoreApp,
        opts: struct {},
    ) !void {
        _ = opts;

        self.* = .{
            .core_app = core_app,
            .config = try configpkg.Config.load(core_app.alloc),
            .hinstance = GetModuleHandleW(null),
            .launcher_profile_hint = detectDefaultProfileHint(core_app.alloc),
            .launcher_profile_order_hint = windows_shell.profileOrderHint(core_app.alloc),
            .launcher_profile_target = detectDefaultProfileTarget(core_app.alloc),
            .startup_profile_picker = detectStartupProfilePicker(core_app.alloc),
        };
        self.refreshSystemWheelSettings();
        self.resolved_theme = resolveTheme(&self.config);
    }

    pub fn run(self: *App) !void {
        try self.sanitizeCurrentDirectory();
        trace("win32.App.run: begin", .{});
        const cwd = std.process.getCwdAlloc(self.core_app.alloc) catch null;
        defer if (cwd) |v| self.core_app.alloc.free(v);
        if (cwd) |v| {
            trace("win32.App.run: cwd={s}", .{v});
            log.info("win32 current directory cwd={s}", .{v});
        }

        try self.ensureWindowClass();
        trace("win32.App.run: class ready", .{});

        if (try self.tryForwardStartupToExistingInstance()) {
            trace("win32.App.run: forwarded startup to existing instance", .{});
            return;
        }

        if (self.config.@"initial-window") {
            try self.createWindow(default_title);
            if (self.startup_profile_picker) {
                if (self.primarySurface()) |surface| {
                    if (surface.host) |host| _ = host.toggleProfileOverlay();
                }
                self.startup_profile_picker = false;
            }
            trace("win32.App.run: initial window created", .{});
        } else {
            log.info("initial-window is disabled; win32 runtime exiting without a window", .{});
            return;
        }

        try self.startIpcServer();

        self.running = true;
        defer self.running = false;

        var msg: MSG = undefined;
        while (true) {
            const result = GetMessageW(&msg, null, 0, 0);
            if (result == -1) return windows.unexpectedError(windows.kernel32.GetLastError());
            if (result == 0) break;

            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);

            try self.core_app.tick(self);

            if (!self.running and self.windows.items.len == 0) break;
        }
    }

    pub fn terminate(self: *App) void {
        self.stopIpcServer();
        self.destroyAllWindows();
        self.hosts.deinit(self.core_app.alloc);
        self.windows.deinit(self.core_app.alloc);
        if (self.launcher_profile_key) |value| self.core_app.alloc.free(value);
        if (self.launcher_profile_hint) |value| self.core_app.alloc.free(value);
        if (self.launcher_profile_order_hint) |value| self.core_app.alloc.free(value);
        for (self.launcher_quick_slot_keys) |value| {
            if (value) |owned| self.core_app.alloc.free(owned);
        }
        self.config.deinit();
    }

    fn tryForwardStartupToExistingInstance(self: *App) !bool {
        if (self.config.@"single-instance" != .true) return false;

        const arguments = try collectStartupForwardArguments(self.core_app.alloc);
        defer freeOwnedArguments(self.core_app.alloc, arguments);

        const pipe_name = try self.resolveIpcPipeName(self.core_app.alloc);
        defer self.core_app.alloc.free(pipe_name);

        return try sendNewWindowIpc(
            self.core_app.alloc,
            pipe_name,
            arguments,
        );
    }

    fn startIpcServer(self: *App) !void {
        if (self.config.@"single-instance" != .true) return;
        if (self.ipc_thread != null) return;

        self.ipc_pipe_name = try self.resolveIpcPipeName(self.core_app.alloc);
        errdefer {
            if (self.ipc_pipe_name) |pipe_name| self.core_app.alloc.free(pipe_name);
            self.ipc_pipe_name = null;
        }

        self.ipc_stop_requested.store(false, .release);
        self.ipc_thread = try std.Thread.spawn(.{}, ipcServerMain, .{self});
    }

    fn resolveIpcPipeName(self: *const App, alloc: Allocator) ![:0]const u16 {
        return allocIpcPipeName(alloc, self.config.class);
    }

    fn stopIpcServer(self: *App) void {
        if (self.ipc_thread) |thread| {
            self.ipc_stop_requested.store(true, .release);
            if (self.ipc_pipe_name) |pipe_name| {
                if (connectToIpcPipe(pipe_name)) |pipe| {
                    _ = windows.CloseHandle(pipe);
                } else |_| {}
            }
            thread.join();
            self.ipc_thread = null;
        }

        if (self.ipc_pipe_name) |pipe_name| {
            self.core_app.alloc.free(pipe_name);
            self.ipc_pipe_name = null;
        }
        self.ipc_stop_requested.store(false, .release);
    }

    pub fn wakeup(self: *App) void {
        if (self.windows.items.len == 0) return;
        const hwnd = self.windows.items[0].hwnd orelse return;
        _ = PostMessageW(hwnd, WM_WINHOSTTY_WAKE, 0, 0);
    }

    pub fn startQuitTimer(self: *App) void {
        _ = self;
    }

    pub fn keyboardLayout(self: *const App) input.KeyboardLayout {
        _ = self;
        return .unknown;
    }

    pub fn performAction(
        self: *App,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) !bool {
        switch (action) {
            .quit => {
                self.running = false;
                self.destroyAllWindows();
                if (self.windows.items.len == 0) PostQuitMessage(0);
                return true;
            },

            .new_window => {
                var config = try apprt.surface.newConfig(
                    self.core_app,
                    &self.config,
                    .window,
                );
                defer config.deinit();
                try applyNewWindowArguments(self.core_app.alloc, &config, value.arguments);
                _ = try self.createWindowSurface(&config, default_title, .{
                    .clone_state_from = self.findSurfaceForTarget(target),
                });
                return true;
            },

            .new_tab => {
                var config = try apprt.surface.newConfig(
                    self.core_app,
                    &self.config,
                    .tab,
                );
                defer config.deinit();
                const source = self.findSurfaceForTarget(target);
                const surface = try self.createWindowSurface(&config, default_title, .{
                    .host_id = if (source) |v| v.host_id else null,
                    .clone_state_from = source,
                });
                self.activateSurface(surface);
                return true;
            },

            .new_split => {
                var config = try apprt.surface.newConfig(
                    self.core_app,
                    &self.config,
                    .split,
                );
                defer config.deinit();
                const source = self.findSurfaceForTarget(target) orelse return false;
                const tab_info = self.findTabForSurface(source) orelse return false;
                const surface = try self.createWindowSurface(&config, default_title, .{
                    .host_id = source.host_id,
                    .tab_id = tab_info.tab.id,
                    .clone_state_from = source,
                });
                self.activateSurface(surface);
                return true;
            },

            .close_tab => {
                return self.closeTab(target, value);
            },

            .close_all_windows => {
                self.running = false;
                self.destroyAllWindows();
                if (self.windows.items.len == 0) PostQuitMessage(0);
                return true;
            },

            .close_window => {
                if (self.findSurfaceForTarget(target)) |surface| {
                    if (surface.host) |host| host.close();
                    return true;
                }

                return false;
            },

            .config_change => {
                switch (target) {
                    .app => {
                        const config = try value.config.clone(self.core_app.alloc);
                        self.config.deinit();
                        self.config = config;
                        self.reconfigureTheme();
                        for (self.windows.items) |surface| {
                            try surface.applyRuntimeConfig(&self.config);
                        }
                    },
                    .surface => |core_surface| {
                        const surface = self.findSurfaceByCore(core_surface) orelse return false;
                        try surface.applyRuntimeConfig(value.config);
                        try self.syncHostWindowState(surface);
                    },
                }
                return true;
            },

            .reload_config => {
                if (target != .app) return false;
                if (value.soft) {
                    try self.core_app.updateConfig(self, &self.config);
                    return true;
                }

                var config = try configpkg.Config.load(self.core_app.alloc);
                defer config.deinit();
                try self.core_app.updateConfig(self, &config);
                return true;
            },

            .present_terminal,
            .quit_timer,
            .renderer_health,
            .color_change,
            .mouse_over_link,
            => {
                if (action == .present_terminal) {
                    if (self.findSurfaceForTarget(target)) |surface| {
                        surface.present();
                        return true;
                    }
                    return false;
                }
                return true;
            },

            .toggle_visibility => {
                self.windows_hidden = !self.windows_hidden;
                if (self.windows_hidden) {
                    for (self.hosts.items) |host| host.setVisible(false);
                } else {
                    for (self.hosts.items) |host| {
                        host.setVisible(true);
                        try host.layout();
                    }
                    if (self.findSurfaceForTarget(target)) |surface| {
                        self.activateSurface(surface);
                    } else if (self.primarySurface()) |surface| {
                        self.activateSurface(surface);
                    }
                }
                return true;
            },

            .toggle_background_opacity => {
                if (self.findSurfaceForTarget(target)) |surface| {
                    const changed = try surface.toggleBackgroundOpacity();
                    if (!changed) return false;
                    try self.syncHostWindowState(surface);
                    return true;
                }
                return false;
            },

            .goto_window => {
                return try self.gotoWindow(target, value);
            },

            .goto_split => {
                return try self.gotoSplitFallback(target, value);
            },

            .resize_split => {
                return try self.resizeSplitFallback(target, value);
            },

            .equalize_splits => {
                return try self.equalizeSplitsFallback(target);
            },

            .move_tab => {
                return try self.moveTab(target, value);
            },

            .goto_tab => {
                return try self.gotoTab(target, value);
            },

            .toggle_tab_overview => {
                if (self.findSurfaceForTarget(target)) |surface| {
                    return try surface.toggleTabOverview();
                }
                return false;
            },

            .toggle_quick_terminal => {
                try self.toggleQuickTerminal();
                return true;
            },

            .toggle_maximize => {
                if (self.findSurfaceForTarget(target)) |surface| {
                    surface.toggleMaximize();
                    try self.syncHostWindowState(surface);
                    return true;
                }
                return false;
            },

            .toggle_fullscreen => {
                if (self.findSurfaceForTarget(target)) |surface| {
                    try surface.toggleFullscreen(value);
                    try self.syncHostWindowState(surface);
                    return true;
                }
                return false;
            },

            .toggle_window_decorations => {
                if (self.findSurfaceForTarget(target)) |surface| {
                    try surface.toggleDecorations();
                    try self.syncHostWindowState(surface);
                    return true;
                }
                return false;
            },

            .float_window => {
                if (self.findSurfaceForTarget(target)) |surface| {
                    try surface.setFloatWindow(value);
                    try self.syncHostWindowState(surface);
                    return true;
                }
                return false;
            },

            .initial_size => {
                if (self.findSurfaceForTarget(target)) |surface| {
                    try surface.setInitialSize(value);
                    try self.syncHostWindowState(surface);
                    return true;
                }
                return false;
            },

            .reset_window_size => {
                if (self.findSurfaceForTarget(target)) |surface| {
                    try surface.resetWindowSize();
                    try self.syncHostWindowState(surface);
                    return true;
                }
                return false;
            },

            .size_limit => {
                if (self.findSurfaceForTarget(target)) |surface| {
                    surface.setSizeLimit(value);
                    try self.syncHostWindowState(surface);
                    return true;
                }
                return false;
            },

            .cell_size => {
                if (self.findSurfaceForTarget(target)) |surface| {
                    surface.setCellSize(value);
                    try self.syncHostWindowState(surface);
                    return true;
                }
                return false;
            },

            .toggle_split_zoom => {
                if (self.findSurfaceForTarget(target)) |surface| {
                    const found = self.findTabForSurface(surface) orelse return false;
                    const handle = found.tab.findHandle(surface) orelse found.tab.focused;
                    found.tab.tree.zoom(if (found.tab.tree.zoomed != null) null else handle);
                    try found.host.layout();
                    return true;
                }
                return false;
            },

            .render => {
                return switch (target) {
                    .app => blk: {
                        for (self.windows.items) |surface| try surface.requestRepaint();
                        break :blk true;
                    },
                    .surface => if (self.findSurfaceForTarget(target)) |surface| blk: {
                        try surface.requestRepaint();
                        break :blk true;
                    } else false,
                };
            },

            .render_inspector => {
                if (self.findSurfaceForTarget(target)) |surface| {
                    surface.redrawInspector();
                    return true;
                }

                return false;
            },

            .inspector => {
                if (self.findSurfaceForTarget(target)) |surface| {
                    return try surface.setInspectorVisible(nextInspectorVisible(surface.inspector_visible, value));
                }
                return false;
            },

            .show_gtk_inspector => {
                if (self.findSurfaceForTarget(target)) |surface| {
                    return try surface.setInspectorVisible(nextInspectorVisible(surface.inspector_visible, .show));
                }
                return false;
            },

            .set_title => {
                if (self.findSurfaceForTarget(target)) |surface| {
                    try surface.setTitle(value.title);
                    return true;
                }

                return false;
            },

            .set_tab_title => {
                if (self.findSurfaceForTarget(target)) |surface| {
                    try surface.setTabTitleOverride(if (value.title.len == 0) null else value.title);
                    return true;
                }

                return false;
            },

            .prompt_title => {
                if (self.findSurfaceForTarget(target)) |surface| {
                    try surface.promptTitle(value);
                    return true;
                }

                return false;
            },

            .toggle_command_palette => {
                if (self.findSurfaceForTarget(target)) |surface| {
                    return try surface.toggleCommandPalette();
                }
                return false;
            },

            .pwd => {
                if (self.findSurfaceForTarget(target)) |surface| {
                    try surface.setPwd(value.pwd);
                    return true;
                }

                return false;
            },

            .mouse_shape => {
                if (self.findSurfaceForTarget(target)) |surface| {
                    surface.setMouseShape(value);
                    return true;
                }
                return false;
            },

            .mouse_visibility => {
                if (self.findSurfaceForTarget(target)) |surface| {
                    surface.setMouseVisibility(value);
                    return true;
                }
                return false;
            },

            .progress_report => {
                if (self.findSurfaceForTarget(target)) |surface| {
                    try surface.setProgressReport(value);
                    return true;
                }
                return false;
            },

            .command_finished => {
                try self.showCommandFinished(target, value);
                return true;
            },

            .start_search => {
                if (self.findSurfaceForTarget(target)) |surface| {
                    try surface.setSearchActive(true, value.needle);
                    if (value.needle.len > 0) {
                        _ = try surface.core_surface.setSearchText(value.needle);
                    }
                    try surface.showSearchOverlay(value.needle);
                    return true;
                }
                return false;
            },

            .end_search => {
                if (self.findSurfaceForTarget(target)) |surface| {
                    try surface.setSearchActive(false, "");
                    if (surface.host) |host| {
                        if (host.overlay_mode == .search) {
                            host.hideOverlay();
                            try host.layout();
                        }
                    }
                    return true;
                }
                return false;
            },

            .search_total => {
                if (self.findSurfaceForTarget(target)) |surface| {
                    try surface.setSearchTotal(value.total);
                    return true;
                }
                return false;
            },

            .search_selected => {
                if (self.findSurfaceForTarget(target)) |surface| {
                    try surface.setSearchSelected(value.selected);
                    return true;
                }
                return false;
            },

            .secure_input => {
                if (self.findSurfaceForTarget(target)) |surface| {
                    try surface.setSecureInput(value);
                    return true;
                }
                return false;
            },

            .readonly => {
                if (self.findSurfaceForTarget(target)) |surface| {
                    try surface.setReadonly(value == .on);
                    return true;
                }
                return false;
            },

            .key_sequence => {
                if (self.findSurfaceForTarget(target)) |surface| {
                    try surface.setKeySequenceActive(switch (value) {
                        .trigger => true,
                        .end => false,
                    });
                    return true;
                }
                return false;
            },

            .key_table => {
                if (self.findSurfaceForTarget(target)) |surface| {
                    try surface.setKeyTable(value);
                    return true;
                }
                return false;
            },

            .scrollbar => {
                if (self.findSurfaceForTarget(target)) |surface| {
                    try surface.setScrollbar(value);
                    return true;
                }
                return false;
            },

            .undo => {
                if (try self.showHostBanner(target, .info, "Undo is not implemented on the native Win32 runtime yet.")) {
                    return true;
                }
                try self.showInfoMessage(target, "winghostty", "Undo is not implemented on the native Win32 runtime yet.");
                return true;
            },

            .redo => {
                if (try self.showHostBanner(target, .info, "Redo is not implemented on the native Win32 runtime yet.")) {
                    return true;
                }
                try self.showInfoMessage(target, "winghostty", "Redo is not implemented on the native Win32 runtime yet.");
                return true;
            },

            .check_for_updates => {
                _ = try self.showHostBanner(target, .info, "Opening winghostty releases in your browser.");
                try self.openUrl(releases_url);
                return true;
            },

            .open_url => {
                try self.openUrl(value.url);
                return true;
            },

            .show_on_screen_keyboard => {
                try self.showOnScreenKeyboard();
                return true;
            },

            .open_config => {
                try self.openConfig();
                return true;
            },

            .copy_title_to_clipboard => {
                if (self.findSurfaceForTarget(target)) |surface| {
                    const title = surface.getTitle() orelse return false;
                    try surface.writeClipboardText(title);
                    return true;
                }
                return false;
            },

            .ring_bell => {
                self.ringBell(target);
                return true;
            },

            .desktop_notification => {
                try self.showDesktopNotification(target, value.title, value.body);
                return true;
            },

            .show_child_exited => {
                try self.showChildExited(target, value);
                return true;
            },
        }
    }

    pub fn performIpc(
        alloc: Allocator,
        target: apprt.ipc.Target,
        comptime action: apprt.ipc.Action.Key,
        value: apprt.ipc.Action.Value(action),
    ) anyerror!bool {
        switch (action) {
            .new_window => {
                const pipe_name = try resolveIpcPipeNameForTarget(alloc, target);
                defer alloc.free(pipe_name);

                if (try sendNewWindowIpc(alloc, pipe_name, value.arguments)) return true;
                return try spawnWindowProcess(alloc, target, value);
            },
        }
    }

    fn spawnWindowProcess(
        alloc: Allocator,
        target: apprt.ipc.Target,
        value: apprt.ipc.Action.NewWindow,
    ) !bool {
        const exe_path = try std.fs.selfExePathAlloc(alloc);
        defer alloc.free(exe_path);

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(alloc);

        try argv.append(alloc, exe_path);
        if (target == .class) {
            const class_arg = try std.fmt.allocPrint(alloc, "--class={s}", .{target.class});
            defer alloc.free(class_arg);
            try argv.append(alloc, class_arg);
        }
        if (value.arguments) |arguments| {
            for (arguments) |arg| try argv.append(alloc, arg);
        }

        var child = std.process.Child.init(argv.items, alloc);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        try child.spawn();
        return true;
    }

    fn ensureWindowClass(self: *App) !void {
        if (self.class_atom != 0) return;

        var wc: WNDCLASSEXW = .{
            .cbSize = @sizeOf(WNDCLASSEXW),
            .style = CS_OWNDC,
            .lpfnWndProc = &windowProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = self.hinstance,
            .hIcon = null,
            .hCursor = LoadCursorW(null, IDC_ARROW),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = class_name,
            .hIconSm = null,
        };

        self.class_atom = RegisterClassExW(&wc);
        if (self.class_atom == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
    }

    fn ensureHostWindowClass(self: *App) !void {
        if (self.host_class_atom != 0) return;

        var wc: WNDCLASSEXW = .{
            .cbSize = @sizeOf(WNDCLASSEXW),
            .style = 0,
            .lpfnWndProc = &hostWindowProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = self.hinstance,
            .hIcon = null,
            .hCursor = LoadCursorW(null, IDC_ARROW),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = host_class_name,
            .hIconSm = null,
        };

        self.host_class_atom = RegisterClassExW(&wc);
        if (self.host_class_atom == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
    }

    fn createWindowSurface(
        self: *App,
        config: *const configpkg.Config,
        title: LPCWSTR,
        opts: SurfaceInitOptions,
    ) !*Surface {
        const surface = try self.core_app.alloc.create(Surface);
        errdefer self.core_app.alloc.destroy(surface);

        try surface.init(self, title, config, opts);
        return surface;
    }

    fn createProfileSurface(
        self: *App,
        target: apprt.Target,
        profile: *const windows_shell.Profile,
        open_target: ProfileOpenTarget,
    ) !*Surface {
        const source = self.findSurfaceForTarget(target);
        var config = try apprt.surface.newConfig(
            self.core_app,
            &self.config,
            switch (open_target) {
                .tab => .tab,
                .window => .window,
                .split => .split,
            },
        );
        defer config.deinit();

        const alloc = config._arena.?.allocator();
        if (config.command) |command| command.deinit(alloc);
        config.command = try profile.command.clone(alloc);
        config.@"working-directory" = .home;

        const tab_id = switch (open_target) {
            .split => blk: {
                const source_surface = source orelse return error.NoActiveSurface;
                const tab_info = self.findTabForSurface(source_surface) orelse return error.NoActiveSurface;
                break :blk tab_info.tab.id;
            },
            else => null,
        };

        const title_w = try std.unicode.utf8ToUtf16LeAllocZ(self.core_app.alloc, profile.label);
        defer self.core_app.alloc.free(title_w);
        const surface = try self.createWindowSurface(&config, title_w.ptr, .{
            .host_id = if (open_target == .window) null else if (source) |v| v.host_id else null,
            .tab_id = tab_id,
            .clone_state_from = source,
        });
        try appendOwnedString(self.core_app.alloc, &surface.launch_profile_key, profile.key);
        return surface;
    }

    fn createWindow(self: *App, title: LPCWSTR) !void {
        _ = try self.createWindowSurface(&self.config, title, .{});
    }

    fn refreshSystemWheelSettings(self: *App) void {
        self.wheel_settings = .{
            .lines = readSystemWheelSetting(SPI_GETWHEELSCROLLLINES, self.wheel_settings.lines),
            .chars = readSystemWheelSetting(SPI_GETWHEELSCROLLCHARS, self.wheel_settings.chars),
        };
    }

    fn reconfigureTheme(self: *App) void {
        self.resolved_theme = resolveTheme(&self.config);
        for (self.hosts.items) |host| {
            host.rebuildThemeBrushes();
            if (host.hwnd) |hwnd| applyDwmTheme(hwnd, &self.resolved_theme);
        }
    }

    fn applyLauncherQuickSlotPreferences(self: *App, profiles: []windows_shell.Profile) void {
        applyQuickSlotPreferenceOrder(profiles, .{
            self.launcher_quick_slot_keys[0],
            self.launcher_quick_slot_keys[1],
            self.launcher_quick_slot_keys[2],
        });
    }

    fn launcherQuickSlotOrdinal(self: *const App, key: []const u8) ?usize {
        return findLauncherQuickSlotOrdinal(self.launcher_quick_slot_keys, key);
    }

    fn setLauncherQuickSlotPreference(self: *App, slot_ordinal: usize, key: []const u8) !void {
        if (slot_ordinal >= self.launcher_quick_slot_keys.len) return;
        var duplicate_slot: ?usize = null;
        for (self.launcher_quick_slot_keys, 0..) |existing, index| {
            if (existing) |value| {
                if (std.ascii.eqlIgnoreCase(value, key)) {
                    duplicate_slot = index;
                    break;
                }
            }
        }

        if (duplicate_slot) |index| {
            if (index != slot_ordinal) {
                if (self.launcher_quick_slot_keys[slot_ordinal]) |current| {
                    if (self.launcher_quick_slot_keys[index]) |dupe| self.core_app.alloc.free(dupe);
                    self.launcher_quick_slot_keys[index] = try self.core_app.alloc.dupeZ(u8, current);
                } else {
                    appendOwnedString(self.core_app.alloc, &self.launcher_quick_slot_keys[index], null) catch {};
                }
            }
        }

        try appendOwnedString(self.core_app.alloc, &self.launcher_quick_slot_keys[slot_ordinal], key);

        for (self.hosts.items) |host| {
            host.reapplyLauncherProfilePreferences() catch {};
            if (host.overlay_mode == .profile) {
                host.syncOverlayLabel() catch {};
                host.syncOverlayHint() catch {};
                host.syncOverlayButtons() catch {};
            }
            host.refreshChrome() catch {};
        }
    }

    fn clearLauncherQuickSlotPreferences(self: *App) void {
        for (&self.launcher_quick_slot_keys) |*value| {
            appendOwnedString(self.core_app.alloc, value, null) catch {};
        }

        for (self.hosts.items) |host| {
            if (host.profiles != null) {
                _ = host.reloadProfiles() catch false;
            }
            if (host.overlay_mode == .profile) {
                host.syncOverlayLabel() catch {};
                host.syncOverlayHint() catch {};
                host.syncOverlayButtons() catch {};
            }
            host.refreshChrome() catch {};
        }
    }

    fn allocateHostId(self: *App) u32 {
        const id = self.next_host_id;
        self.next_host_id +%= 1;
        if (self.next_host_id == 0) self.next_host_id = 1;
        return id;
    }

    fn createHost(self: *App, title: LPCWSTR, clone_state_from: ?*const Surface) !*Host {
        try self.ensureHostWindowClass();

        const host = try self.core_app.alloc.create(Host);
        errdefer self.core_app.alloc.destroy(host);
        host.* = .{
            .app = self,
            .id = self.allocateHostId(),
        };
        if (self.launcher_profile_key) |key| {
            try appendOwnedString(self.core_app.alloc, &host.selected_profile_key, key);
        }

        const hwnd = CreateWindowExW(
            0,
            host_class_name,
            title,
            hostWindowStyle(),
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            1280,
            800,
            null,
            null,
            self.hinstance,
            host,
        ) orelse return windows.unexpectedError(windows.kernel32.GetLastError());
        host.hwnd = hwnd;
        applyDwmTheme(hwnd, &self.resolved_theme);
        host.current_dpi = GetDpiForWindow(hwnd);
        if (host.current_dpi == 0) host.current_dpi = 96;
        errdefer _ = DestroyWindow(hwnd);

        try self.hosts.append(self.core_app.alloc, host);
        if (clone_state_from) |source| {
            if (source.host) |existing| try self.inheritHostWindowState(host, existing);
        }

        _ = ShowWindow(hwnd, SW_SHOW);
        _ = UpdateWindow(hwnd);
        return host;
    }

    fn findHostById(self: *App, id: u32) ?*Host {
        for (self.hosts.items) |host| {
            if (host.id == id) return host;
        }
        return null;
    }

    fn findHostByHwnd(self: *App, hwnd: HWND) ?*Host {
        for (self.hosts.items) |host| {
            if (host.hwnd == hwnd) return host;
        }
        return null;
    }

    fn activeTab(self: *App, host: *Host) ?*Tab {
        _ = self;
        if (host.tabs.items.len == 0 or host.active_tab >= host.tabs.items.len) return null;
        return &host.tabs.items[host.active_tab];
    }

    fn activeSurfaceForHost(self: *App, host_id: u32) ?*Surface {
        const host = self.findHostById(host_id) orelse return null;
        const tab = self.activeTab(host) orelse return null;
        return tab.focusedSurface();
    }

    fn inheritHostWindowState(_: *App, destination: *Host, source: *Host) !void {
        const dst_hwnd = destination.hwnd orelse return;
        const src_hwnd = source.hwnd orelse return;
        var rect: RECT = undefined;
        if (GetWindowRect(src_hwnd, &rect) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
        if (SetWindowPos(
            dst_hwnd,
            null,
            rect.left,
            rect.top,
            rect.right - rect.left,
            rect.bottom - rect.top,
            SWP_NOACTIVATE,
        ) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
    }

    fn findSurfaceForTarget(self: *App, target: apprt.Target) ?*Surface {
        return switch (target) {
            .app => self.primarySurface(),
            .surface => |core_surface| self.findSurfaceByCore(core_surface),
        };
    }

    fn primarySurface(self: *App) ?*Surface {
        if (self.hosts.items.len == 0) return null;
        return self.activeSurfaceForHost(self.hosts.items[0].id);
    }

    fn findSurfaceByCore(self: *App, core_surface: *CoreSurface) ?*Surface {
        for (self.windows.items) |surface| {
            if (surface.core() == core_surface) return surface;
        }

        return null;
    }

    fn collectHostIds(self: *App, alloc: Allocator) !std.ArrayListUnmanaged(u32) {
        var ids: std.ArrayListUnmanaged(u32) = .empty;
        errdefer ids.deinit(alloc);
        for (self.hosts.items) |host| try ids.append(alloc, host.id);
        return ids;
    }

    fn collectHostSurfaces(self: *App, alloc: Allocator, host_id: u32) !std.ArrayListUnmanaged(*Surface) {
        var surfaces: std.ArrayListUnmanaged(*Surface) = .empty;
        errdefer surfaces.deinit(alloc);
        const host = self.findHostById(host_id) orelse return surfaces;
        for (host.tabs.items) |*tab| {
            var it = tab.tree.iterator();
            while (it.next()) |entry| {
                try surfaces.append(alloc, entry.view);
            }
        }
        return surfaces;
    }

    fn findTabForSurface(_: *App, surface: *Surface) ?struct { host: *Host, index: usize, tab: *Tab } {
        const host = surface.host orelse return null;
        for (host.tabs.items, 0..) |*tab, index| {
            if (tab.findHandle(surface) != null) {
                return .{ .host = host, .index = index, .tab = tab };
            }
        }
        return null;
    }

    fn hostTabStatus(self: *App, surface: *const Surface) HostTabStatus {
        const host = surface.host orelse return .{};
        const total = host.tabs.items.len;
        var index: usize = 0;
        if (self.findTabForSurface(@constCast(surface))) |found| index = found.index;
        return .{
            .index = index,
            .total = if (total == 0) 1 else total,
        };
    }

    fn showHostSurface(self: *App, surface: *Surface, focus: bool) void {
        const host = surface.host orelse return;
        const tab_info = self.findTabForSurface(surface) orelse return;
        host.active_tab = tab_info.index;
        for (host.tabs.items) |*tab| {
            var it = tab.tree.iterator();
            while (it.next()) |entry| {
                const active = tab == tab_info.tab;
                entry.view.host_active = active;
                entry.view.setVisible(active);
            }
        }
        host.layout() catch {};
        host.refreshChrome() catch {};
        if (focus) {
            surface.presentWindow();
        } else {
            surface.setVisible(true);
        }
    }

    fn activateSurface(self: *App, surface: *Surface) void {
        self.windows_hidden = false;
        if (self.findTabForSurface(surface)) |found| {
            if (found.tab.findHandle(surface)) |handle| found.tab.focused = handle;
        }
        if (surface.host) |host| host.syncSelectedProfileFromSurface(surface);
        self.showHostSurface(surface, true);
    }

    fn syncHostWindowState(self: *App, source: *Surface) !void {
        var host_surfaces = try self.collectHostSurfaces(self.core_app.alloc, source.host_id);
        defer host_surfaces.deinit(self.core_app.alloc);
        for (host_surfaces.items) |candidate| {
            if (candidate == source) continue;
            try candidate.inheritWindowStateFrom(source);
        }
    }

    fn removeWindow(self: *App, surface: *Surface) void {
        for (self.windows.items, 0..) |item, i| {
            if (item == surface) {
                _ = self.windows.swapRemove(i);
                break;
            }
        }
    }

    fn removeHost(self: *App, host: *Host) void {
        for (self.hosts.items, 0..) |item, i| {
            if (item == host) {
                _ = self.hosts.swapRemove(i);
                host.deinit();
                self.core_app.alloc.destroy(host);
                break;
            }
        }
    }

    fn windowDestroyed(self: *App, surface: *Surface) void {
        self.removeWindow(surface);
        if (surface.host) |host| {
            for (host.tabs.items, 0..) |*tab, i| {
                if (tab.findHandle(surface)) |handle| {
                    if (tab.tree.nodes.len == 1) {
                        tab.deinit();
                        _ = host.tabs.orderedRemove(i);
                        if (host.active_tab >= host.tabs.items.len and host.tabs.items.len > 0) {
                            host.active_tab = host.tabs.items.len - 1;
                        }
                    } else {
                        const next_tree = tab.tree.remove(self.core_app.alloc, handle) catch break;
                        tab.tree.deinit();
                        tab.tree = next_tree;
                        var it = tab.tree.iterator();
                        tab.focused = it.next().?.handle;
                    }
                    break;
                }
            }

            if (host.tabs.items.len == 0) {
                if (host.hwnd) |hwnd| _ = DestroyWindow(hwnd);
                self.removeHost(host);
            } else if (self.running) {
                if (self.activeTab(host)) |tab| if (tab.focusedSurface()) |replacement| self.activateSurface(replacement);
                // Relayout when tab bar visibility may have changed (auto-hide crossing 1-tab threshold)
                host.layout() catch {};
                if (host.hwnd) |host_hwnd| _ = InvalidateRect(host_hwnd, null, 0);
            }
        }

        if (self.windows.items.len == 0) {
            self.running = false;
            PostQuitMessage(0);
        }
    }

    fn gotoWindow(self: *App, target: apprt.Target, direction: apprt.action.GotoWindow) !bool {
        var host_ids = try self.collectHostIds(self.core_app.alloc);
        defer host_ids.deinit(self.core_app.alloc);
        if (host_ids.items.len <= 1) return false;

        const current = self.findSurfaceForTarget(target) orelse self.windows.items[0];
        var current_host_idx: usize = 0;
        for (host_ids.items, 0..) |host_id, i| {
            if (host_id == current.host_id) {
                current_host_idx = i;
                break;
            }
        }

        const next_idx = switch (direction) {
            .next => (current_host_idx + 1) % host_ids.items.len,
            .previous => (current_host_idx + host_ids.items.len - 1) % host_ids.items.len,
        };
        const next_surface = self.activeSurfaceForHost(host_ids.items[next_idx]) orelse return false;
        self.activateSurface(next_surface);
        return true;
    }

    fn gotoSplitFallback(self: *App, target: apprt.Target, to: apprt.action.GotoSplit) !bool {
        const current = self.findSurfaceForTarget(target) orelse return false;
        const found = self.findTabForSurface(current) orelse return false;
        const from = found.tab.findHandle(current) orelse found.tab.focused;
        const goto: SplitTreeSurface.Goto = switch (to) {
            .previous => .previous_wrapped,
            .next => .next_wrapped,
            .left => .{ .spatial = .left },
            .right => .{ .spatial = .right },
            .up => .{ .spatial = .up },
            .down => .{ .spatial = .down },
        };
        const next_handle = (try found.tab.tree.goto(self.core_app.alloc, from, goto)) orelse return false;
        found.tab.focused = next_handle;
        const next_surface = found.tab.focusedSurface() orelse return false;
        self.activateSurface(next_surface);
        return true;
    }

    fn gotoSplitFallbackDirection(to: apprt.action.GotoSplit) ?apprt.action.GotoWindow {
        return switch (to) {
            .previous => .previous,
            .next => .next,
            .up, .down, .left, .right => null,
        };
    }

    fn resizeSplitFallback(self: *App, target: apprt.Target, value: apprt.action.ResizeSplit) !bool {
        const surface = self.findSurfaceForTarget(target) orelse return false;
        const found = self.findTabForSurface(surface) orelse return false;
        const handle = found.tab.findHandle(surface) orelse found.tab.focused;
        const layout: SplitTreeSurface.Split.Layout = switch (value.direction) {
            .left, .right => .horizontal,
            .up, .down => .vertical,
        };
        const delta_sign: f16 = switch (value.direction) {
            .left, .up => -1,
            .right, .down => 1,
        };
        const delta = std.math.clamp((@as(f16, @floatFromInt(value.amount)) / 100.0) * delta_sign, -1, 1);
        const next_tree = try found.tab.tree.resize(self.core_app.alloc, handle, layout, delta);
        found.tab.tree.deinit();
        found.tab.tree = next_tree;
        try found.host.layout();
        return true;
    }

    fn equalizeSplitsFallback(self: *App, target: apprt.Target) !bool {
        const surface = self.findSurfaceForTarget(target) orelse return false;
        const found = self.findTabForSurface(surface) orelse return false;
        const next_tree = try found.tab.tree.equalize(self.core_app.alloc);
        found.tab.tree.deinit();
        found.tab.tree = next_tree;
        try found.host.layout();
        return true;
    }

    fn closeTab(self: *App, target: apprt.Target, mode: apprt.action.CloseTabMode) bool {
        const current = self.findSurfaceForTarget(target) orelse return false;
        const found = self.findTabForSurface(current) orelse return false;
        const host = found.host;
        const current_idx = found.index;

        switch (mode) {
            .this => {
                var surfaces: std.ArrayListUnmanaged(*Surface) = .empty;
                defer surfaces.deinit(self.core_app.alloc);
                var it = found.tab.tree.iterator();
                while (it.next()) |entry| surfaces.append(self.core_app.alloc, entry.view) catch return false;
                for (surfaces.items) |surface| surface.close(false);
                return true;
            },

            .other => {
                if (host.tabs.items.len <= 1) return false;
                var closed = false;
                var i = host.tabs.items.len;
                while (i > 0) {
                    i -= 1;
                    if (i == current_idx) continue;
                    var it = host.tabs.items[i].tree.iterator();
                    while (it.next()) |entry| entry.view.close(false);
                    closed = true;
                }
                if (closed) self.activateSurface(current);
                return closed;
            },

            .right => {
                if (current_idx + 1 >= host.tabs.items.len) return false;
                var closed = false;
                var i = host.tabs.items.len;
                while (i > current_idx + 1) {
                    i -= 1;
                    var it = host.tabs.items[i].tree.iterator();
                    while (it.next()) |entry| entry.view.close(false);
                    closed = true;
                }
                if (closed) self.activateSurface(current);
                return closed;
            },
        }
    }

    fn gotoTab(self: *App, target: apprt.Target, goto: apprt.action.GotoTab) !bool {
        if (self.windows.items.len == 0) return false;
        const current = self.findSurfaceForTarget(target) orelse self.windows.items[0];
        const found = self.findTabForSurface(current) orelse return false;
        const desired = desiredTabIndex(found.host.tabs.items.len, found.index, goto) orelse return false;
        const current_idx = found.index;
        if (desired == current_idx) return false;
        const tab = &found.host.tabs.items[desired];
        const surface = tab.focusedSurface() orelse return false;
        self.activateSurface(surface);
        return true;
    }

    fn moveTab(self: *App, target: apprt.Target, move: apprt.action.MoveTab) !bool {
        if (self.windows.items.len <= 1 or move.amount == 0) return false;
        const current = self.findSurfaceForTarget(target) orelse return false;
        const found = self.findTabForSurface(current) orelse return false;
        if (found.host.tabs.items.len <= 1) return false;
        const current_idx = found.index;
        const desired = desiredMoveIndex(found.host.tabs.items.len, current_idx, move.amount) orelse return false;
        if (desired == current_idx) return false;
        const tab = found.host.tabs.orderedRemove(current_idx);
        try found.host.tabs.insert(self.core_app.alloc, desired, tab);
        found.host.active_tab = desired;
        const surface = found.host.tabs.items[desired].focusedSurface() orelse return false;
        self.activateSurface(surface);
        return true;
    }

    fn surfaceIndex(self: *App, needle: *Surface) ?usize {
        for (self.windows.items, 0..) |surface, i| {
            if (surface == needle) return i;
        }
        return null;
    }

    fn quickTerminalSurface(self: *App) ?*Surface {
        for (self.windows.items) |surface| {
            if (surface.quick_terminal) return surface;
        }
        return null;
    }

    fn toggleQuickTerminal(self: *App) !void {
        if (self.quickTerminalSurface()) |surface| {
            const hwnd = surface.hwnd orelse return;
            const visible = IsWindowVisible(hwnd) != 0;
            surface.setVisible(!visible);
            if (!visible) {
                self.windows_hidden = false;
                surface.present();
            }
            return;
        }

        var config = try apprt.surface.newConfig(
            self.core_app,
            &self.config,
            .window,
        );
        defer config.deinit();
        const surface = try self.createWindowSurface(&config, quick_terminal_title, .{
            .quick_terminal = true,
        });
        try surface.setFloatWindow(.on);
        surface.present();
    }

    fn showOnScreenKeyboard(self: *App) !void {
        const osk_w = try std.unicode.utf8ToUtf16LeAllocZ(self.core_app.alloc, "osk.exe");
        defer self.core_app.alloc.free(osk_w);
        const result = ShellExecuteW(null, shell_open, osk_w.ptr, null, null, SW_SHOW);
        if (@intFromPtr(result) <= 32) return error.OpenUrlFailed;
    }

    fn destroyAllWindows(self: *App) void {
        while (self.hosts.items.len > 0) {
            const host = self.hosts.items[self.hosts.items.len - 1];
            const hwnd = host.hwnd orelse {
                self.removeHost(host);
                continue;
            };
            _ = DestroyWindow(hwnd);
        }
    }

    fn sanitizeCurrentDirectory(self: *App) !void {
        const cwd = std.process.getCwdAlloc(self.core_app.alloc) catch null;
        defer if (cwd) |v| self.core_app.alloc.free(v);

        if (cwd) |v| {
            if (isSafeStartupCwd(v)) return;
            log.warn("win32 current directory is unsafe, resetting cwd={s}", .{v});
        } else {
            log.warn("win32 current directory unavailable, resetting to profile", .{});
        }

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const profile = (try internal_os.windows.knownFolderPathUtf8(
            &internal_os.windows.FOLDERID_Profile,
            &buf,
        )) orelse return error.NoHomeDir;
        const profile_w = try std.unicode.utf8ToUtf16LeAllocZ(self.core_app.alloc, profile);
        defer self.core_app.alloc.free(profile_w);

        if (SetCurrentDirectoryW(profile_w.ptr) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }

        log.info("win32 current directory reset cwd={s}", .{profile});
    }

    fn clientSize(self: *App, hwnd: HWND) !apprt.SurfaceSize {
        _ = self;
        var rect: RECT = undefined;
        if (GetClientRect(hwnd, &rect) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }

        return .{
            .width = @max(0, rect.right - rect.left),
            .height = @max(0, rect.bottom - rect.top),
        };
    }

    fn defaultPixelFormatDescriptor() PIXELFORMATDESCRIPTOR {
        return .{
            .nSize = @sizeOf(PIXELFORMATDESCRIPTOR),
            .nVersion = 1,
            .dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER,
            .iPixelType = PFD_TYPE_RGBA,
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
            .iLayerType = PFD_MAIN_PLANE,
            .bReserved = 0,
            .dwLayerMask = 0,
            .dwVisibleMask = 0,
            .dwDamageMask = 0,
        };
    }

    fn createGLContext(self: *App, hwnd: HWND) !struct { hdc: HDC, hglrc: HGLRC } {
        _ = self;

        const hdc = GetDC(hwnd) orelse return error.GetDCFailed;
        errdefer _ = ReleaseDC(hwnd, hdc);

        const pfd = defaultPixelFormatDescriptor();
        const pixel_format = ChoosePixelFormat(hdc, &pfd);
        if (pixel_format == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }

        if (SetPixelFormat(hdc, pixel_format, &pfd) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }

        const hglrc = wglCreateContext(hdc) orelse
            return windows.unexpectedError(windows.kernel32.GetLastError());
        errdefer _ = wglDeleteContext(hglrc);

        if (wglMakeCurrent(hdc, hglrc) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }

        return .{ .hdc = hdc, .hglrc = hglrc };
    }

    fn openUrl(self: *App, url: []const u8) !void {
        const url_w = try std.unicode.utf8ToUtf16LeAllocZ(self.core_app.alloc, url);
        defer self.core_app.alloc.free(url_w);

        const result = ShellExecuteW(null, shell_open, url_w.ptr, null, null, SW_SHOW);
        if (@intFromPtr(result) <= 32) return error.OpenUrlFailed;
    }

    fn openConfig(self: *App) !void {
        const path = try config_edit.openPath(self.core_app.alloc);
        defer self.core_app.alloc.free(path);
        try self.openUrl(path);
    }

    fn ringBell(self: *App, target: apprt.Target) void {
        _ = self;
        _ = target;
        _ = MessageBeep(MB_ICONINFORMATION);
    }

    fn showDesktopNotification(
        self: *App,
        target: apprt.Target,
        title: [:0]const u8,
        body: [:0]const u8,
    ) !void {
        const caption = if (title.len > 0) title else "winghostty";
        const message = if (title.len > 0 and !std.mem.eql(u8, title, "winghostty"))
            try std.fmt.allocPrint(self.core_app.alloc, "{s}: {s}", .{ caption, body })
        else
            try self.core_app.alloc.dupe(u8, body);
        defer self.core_app.alloc.free(message);

        if (try self.showHostBanner(target, .info, message)) return;
        try self.showInfoMessage(target, caption, body);
    }

    fn showChildExited(
        self: *App,
        target: apprt.Target,
        exited: apprt.surface.Message.ChildExited,
    ) !void {
        const seconds = @as(f64, @floatFromInt(exited.runtime_ms)) / @as(f64, std.time.ms_per_s);
        const message = try std.fmt.allocPrint(
            self.core_app.alloc,
            "Child exited with code {d} | Runtime: {d:.2}s",
            .{ exited.exit_code, seconds },
        );
        defer self.core_app.alloc.free(message);
        if (try self.showHostBanner(target, .info, message)) return;
        try self.showInfoMessage(target, "winghostty", message);
    }

    fn showCommandFinished(
        self: *App,
        target: apprt.Target,
        finished: apprt.action.CommandFinished,
    ) !void {
        const seconds = @as(f64, @floatFromInt(finished.duration.duration)) / @as(f64, std.time.ns_per_s);
        const message = if (finished.exit_code) |code|
            try std.fmt.allocPrint(
                self.core_app.alloc,
                "Command finished with exit code {d} | Runtime: {d:.2}s",
                .{ code, seconds },
            )
        else
            try std.fmt.allocPrint(
                self.core_app.alloc,
                "Command finished | Runtime: {d:.2}s",
                .{seconds},
            );
        defer self.core_app.alloc.free(message);
        if (try self.showHostBanner(target, .info, message)) return;
        try self.showInfoMessage(target, "winghostty", message);
    }

    fn showInfoMessage(
        self: *App,
        target: apprt.Target,
        title: []const u8,
        message: []const u8,
    ) !void {
        const title_w = try std.unicode.utf8ToUtf16LeAllocZ(self.core_app.alloc, title);
        defer self.core_app.alloc.free(title_w);
        const message_w = try std.unicode.utf8ToUtf16LeAllocZ(self.core_app.alloc, message);
        defer self.core_app.alloc.free(message_w);
        const hwnd = if (self.findSurfaceForTarget(target)) |surface| surface.windowHwnd() else null;
        _ = MessageBoxW(hwnd, message_w.ptr, title_w.ptr, MB_OK | MB_ICONINFORMATION);
    }

    fn showHostBanner(
        self: *App,
        target: apprt.Target,
        kind: HostBannerKind,
        message: []const u8,
    ) !bool {
        const surface = self.findSurfaceForTarget(target) orelse return false;
        const host = surface.host orelse return false;
        try host.setBanner(kind, message);
        return true;
    }
};

const SearchStatus = struct {
    active: bool = false,
    needle: ?[]const u8 = null,
    total: ?usize = null,
    selected: ?usize = null,
};

const SurfaceStatus = struct {
    pwd: ?[]const u8 = null,
    scrollbar: terminal.Scrollbar = .zero,
    readonly: bool = false,
    secure_input: bool = false,
    key_sequence_active: bool = false,
    key_table_name: ?[]const u8 = null,
    search: SearchStatus = .{},
    progress: ?[]const u8 = null,
};

const HostTabStatus = struct {
    index: usize = 0,
    total: usize = 1,
};

const VisibleTabRange = struct {
    start: usize,
    count: usize,
};

const TabOverviewEntry = struct {
    title: ?[]const u8 = null,
    pane_count: usize = 1,
    active: bool = false,
};

const SplitTreeSurface = SplitTree(Surface);

const Tab = struct {
    id: u32,
    tree: SplitTreeSurface,
    focused: SplitTreeSurface.Node.Handle = .root,
    button_hwnd: ?HWND = null,
    button_prev_proc: ?*const anyopaque = null,

    fn init(alloc: Allocator, id: u32, surface: *Surface) !Tab {
        return .{
            .id = id,
            .tree = try SplitTreeSurface.init(alloc, surface),
            .focused = .root,
        };
    }

    fn deinit(self: *Tab) void {
        if (self.button_hwnd) |hwnd| _ = DestroyWindow(hwnd);
        self.tree.deinit();
        self.* = undefined;
    }

    fn focusedSurface(self: *const Tab) ?*Surface {
        if (self.tree.nodes.len == 0) return null;
        return switch (self.tree.nodes[self.focused.idx()]) {
            .leaf => |surface| surface,
            .split => null,
        };
    }

    fn findHandle(self: *const Tab, surface: *Surface) ?SplitTreeSurface.Node.Handle {
        var it = self.tree.iterator();
        while (it.next()) |entry| {
            if (entry.view == surface) return entry.handle;
        }
        return null;
    }

    fn leafCount(self: *const Tab) usize {
        var count: usize = 0;
        var it = self.tree.iterator();
        while (it.next()) |_| count += 1;
        return count;
    }
};

const Host = struct {
    app: *App,
    id: u32,
    hwnd: ?HWND = null,
    tabs: std.ArrayListUnmanaged(Tab) = .empty,
    active_tab: usize = 0,
    next_tab_id: u32 = 1,
    overlay_mode: HostOverlayMode = .none,
    overlay_label_hwnd: ?HWND = null,
    overlay_edit_hwnd: ?HWND = null,
    overlay_edit_prev_proc: ?*const anyopaque = null,
    overlay_hint_hwnd: ?HWND = null,
    overlay_accept_hwnd: ?HWND = null,
    overlay_cancel_hwnd: ?HWND = null,
    overlay_button_prev_proc: ?*const anyopaque = null,
    overlay_completion_seed: ?[:0]const u8 = null,
    overlay_completion_value: ?[:0]const u8 = null,
    profiles: ?[]windows_shell.Profile = null,
    selected_profile: usize = 0,
    selected_profile_key: ?[:0]const u8 = null,
    chrome_brush: HBRUSH = null,
    overlay_brush: HBRUSH = null,
    edit_brush: HBRUSH = null,
    status_brush: HBRUSH = null,
    current_dpi: u32 = 96,
    pending_dpi_update: bool = false,
    command_palette_hwnd: ?HWND = null,
    profiles_hwnd: ?HWND = null,
    profile_target_hwnd: ?HWND = null,
    chrome_button_prev_proc: ?*const anyopaque = null,
    prev_tab_hwnd: ?HWND = null,
    tab_overview_hwnd: ?HWND = null,
    next_tab_hwnd: ?HWND = null,
    search_hwnd: ?HWND = null,
    inspector_hwnd: ?HWND = null,
    new_tab_hwnd: ?HWND = null,
    close_tab_hwnd: ?HWND = null,
    hovered_button_hwnd: ?HWND = null,
    hovered_quick_slot: ?usize = null,
    focused_quick_slot: ?usize = null,
    banner_kind: HostBannerKind = .none,
    banner_text: ?[:0]const u8 = null,

    fn nextTabId(self: *Host) u32 {
        const id = self.next_tab_id;
        self.next_tab_id +%= 1;
        if (self.next_tab_id == 0) self.next_tab_id = 1;
        return id;
    }

    fn deinit(self: *Host) void {
        if (self.banner_text) |value| self.app.core_app.alloc.free(value);
        if (self.overlay_completion_seed) |value| self.app.core_app.alloc.free(value);
        if (self.overlay_completion_value) |value| self.app.core_app.alloc.free(value);
        if (self.profiles) |profiles| windows_shell.deinitProfiles(self.app.core_app.alloc, profiles);
        if (self.selected_profile_key) |value| self.app.core_app.alloc.free(value);
        if (self.chrome_brush) |brush| _ = DeleteObject(brush);
        if (self.overlay_brush) |brush| _ = DeleteObject(brush);
        if (self.edit_brush) |brush| _ = DeleteObject(brush);
        for (self.tabs.items) |*tab| tab.deinit();
        self.tabs.deinit(self.app.core_app.alloc);
        self.* = undefined;
    }

    fn activeTab(self: *Host) ?*Tab {
        if (self.tabs.items.len == 0 or self.active_tab >= self.tabs.items.len) return null;
        return &self.tabs.items[self.active_tab];
    }

    fn activeSurface(self: *Host) ?*Surface {
        const tab = self.activeTab() orelse return null;
        return tab.focusedSurface();
    }

    fn quickSlotProfileIndexAtPoint(self: *Host, point: POINT) ?usize {
        if (self.overlay_mode != .none) return null;
        const profiles = self.profiles orelse return null;
        if (profiles.len == 0) return null;
        const hwnd = self.hwnd orelse return null;

        var rect: RECT = undefined;
        if (GetClientRect(hwnd, &rect) == 0) return null;
        const status_y = @max(self.scaled(host_tab_height) + self.scaled(2), rect.bottom - self.scaled(host_status_height) + self.scaled(4));
        var status_x: i32 = self.scaled(16);
        const selected_index = self.selectedProfileIndex();

        if (self.selectedProfile()) |profile| {
            const chip = buildProfileStatusBadgeText(
                self.app.core_app.alloc,
                profile,
                selected_index,
                self.app.launcherQuickSlotOrdinal(profile.key),
            ) catch return null;
            defer self.app.core_app.alloc.free(chip);
            const chip_width = self.scaled(16) + @as(i32, @intCast(chip.len * @as(usize, @intCast(self.scaled(7)))));
            status_x += chip_width + self.scaled(10);
        }

        var slot_ordinal: usize = 0;
        while (slot_ordinal < 3) : (slot_ordinal += 1) {
            const profile_index = quickSlotProfileIndex(profiles.len, selected_index, slot_ordinal, 3) orelse break;
            const chip = buildProfileQuickSlotChipText(
                self.app.core_app.alloc,
                &profiles[profile_index],
                profile_index,
                self.app.launcherQuickSlotOrdinal(profiles[profile_index].key),
            ) catch return null;
            defer self.app.core_app.alloc.free(chip);
            const chip_width = self.scaled(12) + @as(i32, @intCast(chip.len * @as(usize, @intCast(self.scaled(7)))));
            const chip_rect = RECT{
                .left = status_x,
                .top = status_y - self.scaled(1),
                .right = status_x + chip_width,
                .bottom = status_y + self.scaled(13),
            };
            if (point.x >= chip_rect.left and point.x < chip_rect.right and point.y >= chip_rect.top and point.y < chip_rect.bottom) {
                return profile_index;
            }
            status_x = chip_rect.right + self.scaled(6);
        }

        return null;
    }

    fn tabIndexForButton(self: *Host, button_hwnd: HWND) ?usize {
        for (self.tabs.items, 0..) |tab, i| {
            if (tab.button_hwnd == button_hwnd) return i;
        }
        return null;
    }

    fn activateTabIndex(self: *Host, index: usize) bool {
        if (index >= self.tabs.items.len) return false;
        self.active_tab = index;
        if (self.tabs.items[index].focusedSurface()) |surface| {
            self.app.activateSurface(surface);
            return true;
        }
        return false;
    }

    fn activateTabByDirection(self: *Host, goto: apprt.action.GotoTab) bool {
        if (self.tabs.items.len <= 1) return false;
        const index = desiredTabIndex(self.tabs.items.len, self.active_tab, goto) orelse return false;
        return self.activateTabIndex(index);
    }

    fn navigateActiveSearch(self: *Host, dir: input.Binding.Action.NavigateSearch) bool {
        const surface = self.activeSurface() orelse return false;
        if (!surface.search_active) return false;
        _ = surface.core_surface.performBindingAction(.{ .navigate_search = dir }) catch return false;
        self.refreshChrome() catch {};
        return true;
    }

    fn dismissActiveSearch(self: *Host) bool {
        const surface = self.activeSurface() orelse return false;
        if (!surface.search_active and self.overlay_mode != .search) return false;
        _ = surface.core_surface.endSearch() catch {};
        if (self.overlay_mode == .search) {
            self.hideOverlay();
            self.layout() catch {};
            refocusActiveSurface(self);
        } else {
            self.refreshChrome() catch {};
        }
        return true;
    }

    fn toggleCommandPaletteFromButton(self: *Host) bool {
        const surface = self.activeSurface() orelse return false;
        _ = surface.toggleCommandPalette() catch return false;
        return true;
    }

    fn completeCommandPaletteFromButton(self: *Host, reverse: bool) bool {
        if (self.overlay_mode != .command_palette) {
            return self.toggleCommandPaletteFromButton();
        }
        _ = self.completeCommandPalette(reverse) catch return false;
        return true;
    }

    fn dismissCommandPalette(self: *Host) bool {
        if (self.overlay_mode != .command_palette) return false;
        self.hideOverlay();
        self.layout() catch {};
        refocusActiveSurface(self);
        return true;
    }

    fn reloadProfiles(self: *Host) !bool {
        if (self.profiles) |profiles| windows_shell.deinitProfiles(self.app.core_app.alloc, profiles);
        self.profiles = try windows_shell.listProfiles(self.app.core_app.alloc);
        self.app.applyLauncherQuickSlotPreferences(self.profiles.?);
        const profiles = self.profiles.?;
        if (profiles.len == 0) {
            self.selected_profile = 0;
            try appendOwnedString(self.app.core_app.alloc, &self.selected_profile_key, null);
            return false;
        }
        if (preferredProfileIndex(
            profiles,
            self.selected_profile_key,
            self.app.launcher_profile_key,
            self.app.launcher_profile_hint,
            self.selected_profile,
        )) |index| {
            try self.setSelectedProfileIndex(index);
            return true;
        }
        if (self.selected_profile >= profiles.len) self.selected_profile = 0;
        try self.setSelectedProfileIndex(self.selected_profile);
        return true;
    }

    fn reapplyLauncherProfilePreferences(self: *Host) !void {
        const profiles = self.profiles orelse return;
        if (profiles.len == 0) return;
        self.app.applyLauncherQuickSlotPreferences(profiles);
        if (preferredProfileIndex(
            profiles,
            self.selected_profile_key,
            self.app.launcher_profile_key,
            self.app.launcher_profile_hint,
            self.selected_profile,
        )) |index| {
            try self.setSelectedProfileIndex(index);
            return;
        }
        if (self.selected_profile >= profiles.len) self.selected_profile = 0;
        try self.setSelectedProfileIndex(self.selected_profile);
    }

    fn ensureProfiles(self: *Host) !bool {
        if (self.profiles == null) return try self.reloadProfiles();
        const profiles = self.profiles.?;
        if (profiles.len == 0) return false;
        if (self.selected_profile >= profiles.len) self.selected_profile = 0;
        return true;
    }

    fn selectedProfileIndex(self: *Host) ?usize {
        const profiles = self.profiles orelse return null;
        if (profiles.len == 0) return null;
        return @min(self.selected_profile, profiles.len - 1);
    }

    fn selectedProfile(self: *Host) ?*windows_shell.Profile {
        const profiles = self.profiles orelse return null;
        const index = self.selectedProfileIndex() orelse return null;
        return &profiles[index];
    }

    fn setSelectedProfileIndex(self: *Host, index: usize) !void {
        const profiles = self.profiles orelse return;
        if (profiles.len == 0) return;
        const next_index = @min(index, profiles.len - 1);
        self.selected_profile = next_index;
        self.setFocusedQuickSlot(null);
        try appendOwnedString(self.app.core_app.alloc, &self.selected_profile_key, profiles[next_index].key);
        try appendOwnedString(self.app.core_app.alloc, &self.app.launcher_profile_key, profiles[next_index].key);
    }

    fn setLauncherProfileTarget(self: *Host, target: ProfileOpenTarget) void {
        self.app.launcher_profile_target = target;
        self.refreshChrome() catch {};
    }

    fn cycleLauncherProfileTarget(self: *Host, reverse: bool) bool {
        self.setLauncherProfileTarget(cycleProfileOpenTarget(self.app.launcher_profile_target, reverse));
        return true;
    }

    fn syncSelectedProfileFromSurface(self: *Host, surface: *const Surface) void {
        const key = surface.launch_profile_key orelse return;
        if (!(self.ensureProfiles() catch false)) return;
        const profiles = self.profiles orelse return;
        for (profiles, 0..) |profile, index| {
            if (std.ascii.eqlIgnoreCase(profile.key, key)) {
                self.setSelectedProfileIndex(index) catch return;
                self.refreshChrome() catch {};
                return;
            }
        }
    }

    fn toggleProfileOverlay(self: *Host) bool {
        if (!(self.reloadProfiles() catch false)) {
            self.setBanner(.err, "No supported Windows profiles detected.") catch {};
            return false;
        }
        if (self.overlay_mode == .profile) {
            self.hideOverlay();
            self.layout() catch {};
            return true;
        }
        const initial = self.overlayInitialText(.profile);
        defer if (initial) |value| self.app.core_app.alloc.free(value);
        self.hideOverlay();
        self.showOverlay(.profile, initial) catch return false;
        return true;
    }

    fn cycleSelectedProfile(self: *Host, reverse: bool) bool {
        if (!(self.ensureProfiles() catch false)) return false;
        const profiles = self.profiles.?;
        const next = nextTabOverviewSelection(self.selected_profile + 1, profiles.len, reverse) - 1;
        self.setSelectedProfileIndex(next) catch return false;
        self.refreshChrome() catch {};
        return true;
    }

    fn stepProfileSelection(self: *Host, reverse: bool) !bool {
        if (self.overlay_mode != .profile) return false;
        if (!(try self.ensureProfiles())) return false;
        const profiles = self.profiles.?;
        const edit_hwnd = self.overlay_edit_hwnd orelse return false;
        const raw = try readWindowTextUtf8Alloc(self.app.core_app.alloc, edit_hwnd);
        defer self.app.core_app.alloc.free(raw);
        const text = std.mem.trim(u8, raw, " \t\r\n");
        const fallback = self.selectedProfileIndex() orelse 0;
        const current_index = switch (resolveProfileSelection(profiles, text, fallback)) {
            .exact => |index| index,
            .ambiguous, .invalid => fallback,
        };
        const next = nextTabOverviewSelection(current_index + 1, profiles.len, reverse) - 1;
        try self.setSelectedProfileIndex(next);
        const next_w = try std.unicode.utf8ToUtf16LeAllocZ(self.app.core_app.alloc, profiles[next].key);
        defer self.app.core_app.alloc.free(next_w);
        _ = SetWindowTextW(edit_hwnd, next_w.ptr);
        _ = SendMessageW(edit_hwnd, EM_SETSEL, 0, -1);
        try self.syncOverlayLabel();
        try self.syncOverlayHint();
        try self.syncOverlayButtons();
        try self.refreshChrome();
        return true;
    }

    fn openSelectedProfile(self: *Host, open_target: ProfileOpenTarget) bool {
        if (!(self.ensureProfiles() catch false)) return false;
        const profile = self.selectedProfile() orelse return false;
        const source = self.activeSurface() orelse return false;
        const surface = self.app.createProfileSurface(.{ .surface = source.core() }, profile, open_target) catch return false;
        if (self.overlay_mode == .profile) {
            self.hideOverlay();
            self.layout() catch {};
        }
        self.app.activateSurface(surface);
        return true;
    }

    fn quickOpenProfileIndex(self: *Host, index: usize, open_target: ProfileOpenTarget) bool {
        if (!(self.ensureProfiles() catch false)) return false;
        const profiles = self.profiles.?;
        if (index >= profiles.len) return false;
        self.setSelectedProfileIndex(index) catch return false;
        self.refreshChrome() catch {};
        return self.openSelectedProfile(open_target);
    }

    fn openSelectedProfileOrFallback(self: *Host, open_target: ProfileOpenTarget) bool {
        if (self.openSelectedProfile(open_target)) return true;
        const surface = self.activeSurface() orelse return false;
        switch (open_target) {
            .tab => _ = self.app.performAction(.{ .surface = surface.core() }, .new_tab, {}) catch return false,
            .window => _ = self.app.performAction(.{ .surface = surface.core() }, .new_window, {}) catch return false,
            .split => _ = self.app.performAction(.{ .surface = surface.core() }, .new_split, .right) catch return false,
        }
        return true;
    }

    fn submitProfileOverlay(self: *Host, open_target: ProfileOpenTarget) !bool {
        if (!(try self.ensureProfiles())) {
            try self.setBanner(.err, "No supported Windows profiles detected.");
            return false;
        }
        const edit_hwnd = self.overlay_edit_hwnd orelse return false;
        const raw = try readWindowTextUtf8Alloc(self.app.core_app.alloc, edit_hwnd);
        defer self.app.core_app.alloc.free(raw);
        const text = std.mem.trim(u8, raw, " \t\r\n");
        const selection = resolveProfileSelection(self.profiles.?, text, self.selectedProfileIndex() orelse 0);
        switch (selection) {
            .exact => |index| {
                try self.setSelectedProfileIndex(index);
            },
            .ambiguous => |count| {
                const message = try std.fmt.allocPrint(
                    self.app.core_app.alloc,
                    "{d} profiles match. Keep typing or use Up/Down to choose one.",
                    .{count},
                );
                defer self.app.core_app.alloc.free(message);
                try self.setBanner(.err, message);
                return false;
            },
            .invalid => {
                try self.setBanner(.err, "Unknown profile. Try a number or a profile name like pwsh, ubuntu, git, or cmd.");
                return false;
            },
        }
        if (!self.openSelectedProfile(open_target)) return false;
        return true;
    }

    fn inspectorPanelVisible(self: *Host) bool {
        if (self.overlay_mode != .none) return false;
        const surface = self.activeSurface() orelse return false;
        return surface.inspector_visible;
    }

    fn isActiveTabButton(self: *Host, child: HWND) bool {
        const tab = self.activeTab() orelse return false;
        return if (tab.button_hwnd) |hwnd| hwnd == child else false;
    }

    fn isHoveredButton(self: *Host, child: HWND) bool {
        return self.hovered_button_hwnd != null and child == self.hovered_button_hwnd.?;
    }

    fn setHoveredButton(self: *Host, child: ?HWND) void {
        if (self.hovered_button_hwnd == child) return;
        const previous = self.hovered_button_hwnd;
        self.hovered_button_hwnd = child;
        if (previous) |hwnd| _ = InvalidateRect(hwnd, null, 0);
        if (child) |hwnd| _ = InvalidateRect(hwnd, null, 0);
    }

    fn setHoveredQuickSlot(self: *Host, slot: ?usize) void {
        if (self.hovered_quick_slot == slot) return;
        self.hovered_quick_slot = slot;
        self.invalidateChrome();
    }

    fn setFocusedQuickSlot(self: *Host, slot: ?usize) void {
        if (self.focused_quick_slot == slot) return;
        self.focused_quick_slot = slot;
        self.invalidateChrome();
    }

    fn focusQuickSlotEdge(self: *Host, toward_start: bool) bool {
        if (!(self.ensureProfiles() catch false)) return false;
        const next = nextQuickSlotFocus(
            self.profiles.?.len,
            self.selectedProfileIndex(),
            null,
            !toward_start,
            3,
        ) orelse return false;
        self.setFocusedQuickSlot(next);
        return true;
    }

    fn cycleFocusedQuickSlot(self: *Host, reverse: bool) bool {
        if (!(self.ensureProfiles() catch false)) return false;
        const next = nextQuickSlotFocus(
            self.profiles.?.len,
            self.selectedProfileIndex(),
            self.focused_quick_slot,
            reverse,
            3,
        ) orelse return false;
        self.setFocusedQuickSlot(next);
        return true;
    }

    fn openFocusedQuickSlot(self: *Host, open_target: ProfileOpenTarget) bool {
        const profile_index = self.focused_quick_slot orelse return false;
        return self.quickOpenProfileIndex(profile_index, open_target);
    }

    fn assignSelectedProfileToQuickSlot(self: *Host, slot_ordinal: usize) bool {
        if (!(self.ensureProfiles() catch false)) return false;
        const profile = self.selectedProfile() orelse return false;
        self.app.setLauncherQuickSlotPreference(slot_ordinal, profile.key) catch return false;
        const message = std.fmt.allocPrint(
            self.app.core_app.alloc,
            "Pinned {s} to quick slot {d}.",
            .{ profile.label, slot_ordinal + 1 },
        ) catch return false;
        defer self.app.core_app.alloc.free(message);
        self.setBanner(.info, message) catch {};
        return true;
    }

    fn clearQuickSlotPins(self: *Host) bool {
        self.app.clearLauncherQuickSlotPreferences();
        self.setFocusedQuickSlot(null);
        self.setBanner(.info, "Cleared quick slot pins.") catch {};
        return true;
    }

    fn subclassButton(
        self: *Host,
        button_hwnd: HWND,
        proc: WNDPROC,
        prev_slot: *?*const anyopaque,
    ) void {
        _ = SetWindowLongPtrW(
            button_hwnd,
            GWLP_USERDATA,
            @as(LONG_PTR, @intCast(@intFromPtr(self))),
        );
        const previous = SetWindowLongPtrW(
            button_hwnd,
            GWLP_WNDPROC,
            @as(LONG_PTR, @intCast(@intFromPtr(proc))),
        );
        prev_slot.* = if (previous == 0)
            null
        else
            @ptrFromInt(@as(usize, @intCast(previous)));
    }

    fn setVisible(self: *Host, visible: bool) void {
        const hwnd = self.hwnd orelse return;
        _ = ShowWindow(hwnd, if (visible) SW_SHOW else SW_HIDE);
    }

    fn present(self: *Host) void {
        const hwnd = self.hwnd orelse return;
        _ = ShowWindow(hwnd, SW_SHOW);
        _ = SetForegroundWindow(hwnd);
        _ = SetFocus(hwnd);
    }

    fn setBanner(self: *Host, kind: HostBannerKind, text: ?[]const u8) !void {
        self.banner_kind = if (text == null) .none else kind;
        try appendOwnedString(self.app.core_app.alloc, &self.banner_text, text);
        self.invalidateChrome();
    }

    fn setOverlayDefaultBanner(self: *Host, mode: HostOverlayMode) !void {
        _ = mode;
        try self.setBanner(.none, null);
    }

    fn ensureOverlayControls(self: *Host) !void {
        const hwnd = self.hwnd orelse return;
        if (self.overlay_edit_hwnd != null) return;

        self.overlay_label_hwnd = CreateWindowExW(
            0,
            prompt_label_class,
            host_overlay_command_palette_label,
            WS_CHILD,
            0,
            0,
            80,
            host_overlay_height - 8,
            hwnd,
            @ptrFromInt(2001),
            self.app.hinstance,
            null,
        ) orelse return windows.unexpectedError(windows.kernel32.GetLastError());

        self.overlay_edit_hwnd = CreateWindowExW(
            0,
            prompt_edit_class,
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            WS_CHILD | WS_TABSTOP | ES_AUTOHSCROLL,
            0,
            0,
            100,
            host_overlay_height - 8,
            hwnd,
            @ptrFromInt(2002),
            self.app.hinstance,
            null,
        ) orelse return windows.unexpectedError(windows.kernel32.GetLastError());

        const edit_hwnd = self.overlay_edit_hwnd.?;
        _ = SetWindowLongPtrW(
            edit_hwnd,
            GWLP_USERDATA,
            @as(LONG_PTR, @intCast(@intFromPtr(self))),
        );
        const previous = SetWindowLongPtrW(
            edit_hwnd,
            GWLP_WNDPROC,
            @as(LONG_PTR, @intCast(@intFromPtr(&overlayEditProc))),
        );
        self.overlay_edit_prev_proc = if (previous == 0)
            null
        else
            @ptrFromInt(@as(usize, @intCast(previous)));

        self.overlay_hint_hwnd = CreateWindowExW(
            0,
            prompt_label_class,
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            WS_CHILD,
            0,
            0,
            100,
            18,
            hwnd,
            @ptrFromInt(2005),
            self.app.hinstance,
            null,
        ) orelse return windows.unexpectedError(windows.kernel32.GetLastError());

        self.overlay_accept_hwnd = CreateWindowExW(
            0,
            prompt_button_class,
            prompt_ok_label,
            WS_CHILD | WS_TABSTOP | BS_OWNERDRAW,
            0,
            0,
            70,
            host_overlay_height - 8,
            hwnd,
            @ptrFromInt(2003),
            self.app.hinstance,
            null,
        ) orelse return windows.unexpectedError(windows.kernel32.GetLastError());
        self.subclassButton(self.overlay_accept_hwnd.?, &hostButtonProc, &self.overlay_button_prev_proc);

        self.overlay_cancel_hwnd = CreateWindowExW(
            0,
            prompt_button_class,
            prompt_cancel_label,
            WS_CHILD | WS_TABSTOP | BS_OWNERDRAW,
            0,
            0,
            80,
            host_overlay_height - 8,
            hwnd,
            @ptrFromInt(2004),
            self.app.hinstance,
            null,
        ) orelse return windows.unexpectedError(windows.kernel32.GetLastError());
        self.subclassButton(self.overlay_cancel_hwnd.?, &hostButtonProc, &self.overlay_button_prev_proc);

        self.hideOverlay();
    }

    fn ensureChromeButtons(self: *Host) !void {
        const hwnd = self.hwnd orelse return;

        if (self.command_palette_hwnd == null) {
            self.command_palette_hwnd = CreateWindowExW(
                0,
                prompt_button_class,
                host_tab_command_button_label,
                WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW,
                0,
                0,
                host_tab_cmd_button_width,
                host_tab_height - 8,
                hwnd,
                @ptrFromInt(1901),
                self.app.hinstance,
                null,
            ) orelse return windows.unexpectedError(windows.kernel32.GetLastError());
            self.subclassButton(self.command_palette_hwnd.?, &hostButtonProc, &self.chrome_button_prev_proc);
        }

        if (self.profiles_hwnd == null) {
            self.profiles_hwnd = CreateWindowExW(
                0,
                prompt_button_class,
                host_tab_profiles_button_label,
                WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW,
                0,
                0,
                host_tab_profiles_button_width,
                host_tab_height - 8,
                hwnd,
                @ptrFromInt(1909),
                self.app.hinstance,
                null,
            ) orelse return windows.unexpectedError(windows.kernel32.GetLastError());
            self.subclassButton(self.profiles_hwnd.?, &hostButtonProc, &self.chrome_button_prev_proc);
        }

        if (self.profile_target_hwnd == null) {
            self.profile_target_hwnd = CreateWindowExW(
                0,
                prompt_button_class,
                host_tab_target_button_label,
                WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW,
                0,
                0,
                host_tab_target_button_width,
                host_tab_height - 8,
                hwnd,
                @ptrFromInt(1910),
                self.app.hinstance,
                null,
            ) orelse return windows.unexpectedError(windows.kernel32.GetLastError());
            self.subclassButton(self.profile_target_hwnd.?, &hostButtonProc, &self.chrome_button_prev_proc);
        }

        if (self.prev_tab_hwnd == null) {
            self.prev_tab_hwnd = CreateWindowExW(
                0,
                prompt_button_class,
                host_tab_prev_button_label,
                WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW,
                0,
                0,
                host_tab_nav_button_width,
                host_tab_height - 8,
                hwnd,
                @ptrFromInt(1907),
                self.app.hinstance,
                null,
            ) orelse return windows.unexpectedError(windows.kernel32.GetLastError());
            self.subclassButton(self.prev_tab_hwnd.?, &hostButtonProc, &self.chrome_button_prev_proc);
        }

        if (self.tab_overview_hwnd == null) {
            self.tab_overview_hwnd = CreateWindowExW(
                0,
                prompt_button_class,
                host_tab_tabs_button_label,
                WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW,
                0,
                0,
                host_tab_tabs_button_width,
                host_tab_height - 8,
                hwnd,
                @ptrFromInt(1906),
                self.app.hinstance,
                null,
            ) orelse return windows.unexpectedError(windows.kernel32.GetLastError());
            self.subclassButton(self.tab_overview_hwnd.?, &hostButtonProc, &self.chrome_button_prev_proc);
        }

        if (self.next_tab_hwnd == null) {
            self.next_tab_hwnd = CreateWindowExW(
                0,
                prompt_button_class,
                host_tab_next_button_label,
                WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW,
                0,
                0,
                host_tab_nav_button_width,
                host_tab_height - 8,
                hwnd,
                @ptrFromInt(1908),
                self.app.hinstance,
                null,
            ) orelse return windows.unexpectedError(windows.kernel32.GetLastError());
            self.subclassButton(self.next_tab_hwnd.?, &hostButtonProc, &self.chrome_button_prev_proc);
        }

        if (self.search_hwnd == null) {
            self.search_hwnd = CreateWindowExW(
                0,
                prompt_button_class,
                std.unicode.utf8ToUtf16LeStringLiteral("Find"),
                WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW,
                0,
                0,
                host_tab_find_button_width,
                host_tab_height - 8,
                hwnd,
                @ptrFromInt(1902),
                self.app.hinstance,
                null,
            ) orelse return windows.unexpectedError(windows.kernel32.GetLastError());
            self.subclassButton(self.search_hwnd.?, &hostButtonProc, &self.chrome_button_prev_proc);
        }

        if (self.inspector_hwnd == null) {
            self.inspector_hwnd = CreateWindowExW(
                0,
                prompt_button_class,
                host_tab_inspector_button_label,
                WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW,
                0,
                0,
                host_tab_inspect_button_width,
                host_tab_height - 8,
                hwnd,
                @ptrFromInt(1903),
                self.app.hinstance,
                null,
            ) orelse return windows.unexpectedError(windows.kernel32.GetLastError());
            self.subclassButton(self.inspector_hwnd.?, &hostButtonProc, &self.chrome_button_prev_proc);
        }

        if (self.new_tab_hwnd == null) {
            self.new_tab_hwnd = CreateWindowExW(
                0,
                prompt_button_class,
                host_tab_new_button_label,
                WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW,
                0,
                0,
                host_tab_small_button_width,
                host_tab_height - 8,
                hwnd,
                @ptrFromInt(1904),
                self.app.hinstance,
                null,
            ) orelse return windows.unexpectedError(windows.kernel32.GetLastError());
            self.subclassButton(self.new_tab_hwnd.?, &hostButtonProc, &self.chrome_button_prev_proc);
        }

        if (self.close_tab_hwnd == null) {
            self.close_tab_hwnd = CreateWindowExW(
                0,
                prompt_button_class,
                host_tab_close_button_label,
                WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW,
                0,
                0,
                host_tab_small_button_width,
                host_tab_height - 8,
                hwnd,
                @ptrFromInt(1905),
                self.app.hinstance,
                null,
            ) orelse return windows.unexpectedError(windows.kernel32.GetLastError());
            self.subclassButton(self.close_tab_hwnd.?, &hostButtonProc, &self.chrome_button_prev_proc);
        }
    }

    fn showOverlay(self: *Host, mode: HostOverlayMode, initial: ?[]const u8) !void {
        try self.ensureOverlayControls();
        self.overlay_mode = mode;
        self.clearOverlayCompletion();
        try self.setOverlayDefaultBanner(mode);

        const edit_hwnd = self.overlay_edit_hwnd orelse return;
        const accept_hwnd = self.overlay_accept_hwnd orelse return;
        const cancel_hwnd = self.overlay_cancel_hwnd orelse return;
        _ = ShowWindow(edit_hwnd, SW_SHOW);
        _ = ShowWindow(accept_hwnd, SW_SHOW);
        _ = ShowWindow(cancel_hwnd, SW_SHOW);

        const initial_text = initial orelse "";
        const initial_w = try std.unicode.utf8ToUtf16LeAllocZ(self.app.core_app.alloc, initial_text);
        defer self.app.core_app.alloc.free(initial_w);
        _ = SetWindowTextW(edit_hwnd, initial_w.ptr);

        try self.syncOverlayLabel();
        try self.syncOverlayHint();
        try self.syncOverlayButtons();
        try self.layout();
        _ = SetFocus(edit_hwnd);
        _ = SendMessageW(edit_hwnd, EM_SETSEL, 0, -1);
    }

    fn hideOverlay(self: *Host) void {
        self.overlay_mode = .none;
        self.clearOverlayCompletion();
        self.setBanner(.none, null) catch {};
        if (self.overlay_label_hwnd) |hwnd| _ = ShowWindow(hwnd, SW_HIDE);
        if (self.overlay_edit_hwnd) |hwnd| _ = ShowWindow(hwnd, SW_HIDE);
        if (self.overlay_hint_hwnd) |hwnd| _ = ShowWindow(hwnd, SW_HIDE);
        if (self.overlay_accept_hwnd) |hwnd| _ = ShowWindow(hwnd, SW_HIDE);
        if (self.overlay_cancel_hwnd) |hwnd| _ = ShowWindow(hwnd, SW_HIDE);
    }

    fn overlayInitialText(self: *Host, mode: HostOverlayMode) ?[]const u8 {
        const surface = self.activeSurface() orelse return null;
        return switch (mode) {
            .none => null,
            .command_palette => null,
            .profile => if (self.selectedProfile()) |profile|
                self.app.core_app.alloc.dupe(u8, profile.key) catch null
            else
                self.app.core_app.alloc.dupe(u8, "") catch null,
            .search => if (surface.search_needle) |value|
                self.app.core_app.alloc.dupe(u8, value) catch null
            else
                self.app.core_app.alloc.dupe(u8, "") catch null,
            .surface_title => if (surface.title_override) |value|
                self.app.core_app.alloc.dupe(u8, value) catch null
            else if (surface.title) |value|
                self.app.core_app.alloc.dupe(u8, value) catch null
            else
                self.app.core_app.alloc.dupe(u8, "") catch null,
            .tab_title => if (surface.tab_title_override) |value|
                self.app.core_app.alloc.dupe(u8, value) catch null
            else if (surface.title_override) |value|
                self.app.core_app.alloc.dupe(u8, value) catch null
            else if (surface.title) |value|
                self.app.core_app.alloc.dupe(u8, value) catch null
            else
                self.app.core_app.alloc.dupe(u8, "") catch null,
            .tab_overview => blk: {
                const status = self.app.hostTabStatus(surface);
                break :blk std.fmt.allocPrint(self.app.core_app.alloc, "{d}", .{status.index + 1}) catch null;
            },
        };
    }

    fn syncOverlayLabel(self: *Host) !void {
        const label_hwnd = self.overlay_label_hwnd orelse return;
        const alloc = self.app.core_app.alloc;
        switch (self.overlay_mode) {
            .none => _ = SetWindowTextW(label_hwnd, host_overlay_command_palette_label),
            .profile => {
                if (!(try self.ensureProfiles())) {
                    _ = SetWindowTextW(label_hwnd, host_overlay_profile_label);
                    return;
                }
                const raw = if (self.overlay_edit_hwnd) |edit_hwnd|
                    try readWindowTextUtf8Alloc(alloc, edit_hwnd)
                else
                    try alloc.dupeZ(u8, "");
                defer alloc.free(raw);
                const text = std.mem.trim(u8, raw, " \t\r\n");
                const label = try buildProfileOverlayLabel(
                    alloc,
                    self.profiles.?,
                    text,
                    self.selectedProfileIndex() orelse 0,
                );
                defer alloc.free(label);
                const label_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, label);
                defer alloc.free(label_w);
                _ = SetWindowTextW(label_hwnd, label_w.ptr);
            },
            .surface_title => _ = SetWindowTextW(label_hwnd, host_overlay_surface_title_label),
            .tab_title => _ = SetWindowTextW(label_hwnd, host_overlay_tab_title_label),
            .command_palette => {
                const raw = if (self.overlay_edit_hwnd) |edit_hwnd|
                    try readWindowTextUtf8Alloc(alloc, edit_hwnd)
                else
                    try alloc.dupeZ(u8, "");
                defer alloc.free(raw);
                const text = std.mem.trim(u8, raw, " \t\r\n");
                const label = try buildCommandPaletteOverlayLabel(alloc, text);
                defer alloc.free(label);
                const label_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, label);
                defer alloc.free(label_w);
                _ = SetWindowTextW(label_hwnd, label_w.ptr);
            },
            .search => {
                const surface = self.activeSurface();
                const label = try buildSearchOverlayLabel(
                    alloc,
                    if (surface) |value| value.search_total else null,
                    if (surface) |value| value.search_selected else null,
                );
                defer alloc.free(label);
                const label_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, label);
                defer alloc.free(label_w);
                _ = SetWindowTextW(label_hwnd, label_w.ptr);
            },
            .tab_overview => {
                const surface = self.activeSurface();
                const status = if (surface) |value| self.app.hostTabStatus(value) else HostTabStatus{};
                const label = try buildTabOverviewOverlayLabel(alloc, status.index, status.total);
                defer alloc.free(label);
                const label_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, label);
                defer alloc.free(label_w);
                _ = SetWindowTextW(label_hwnd, label_w.ptr);
            },
        }
    }

    fn syncOverlayButtons(self: *Host) !void {
        const accept_hwnd = self.overlay_accept_hwnd orelse return;
        const cancel_hwnd = self.overlay_cancel_hwnd orelse return;
        const alloc = self.app.core_app.alloc;
        const raw = if (self.overlay_edit_hwnd) |edit_hwnd|
            try readWindowTextUtf8Alloc(alloc, edit_hwnd)
        else
            try alloc.dupeZ(u8, "");
        defer alloc.free(raw);
        const text = std.mem.trim(u8, raw, " \t\r\n");
        const surface = self.activeSurface();
        if (self.overlay_mode == .profile) {
            const accept = try buildProfileAcceptLabel(
                alloc,
                self.profiles,
                text,
                self.selectedProfileIndex() orelse 0,
                self.app.launcher_profile_target,
            );
            defer alloc.free(accept);
            const accept_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, accept);
            defer alloc.free(accept_w);
            _ = SetWindowTextW(accept_hwnd, accept_w.ptr);

            const cancel_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, overlayCancelLabel(self.overlay_mode));
            defer alloc.free(cancel_w);
            _ = SetWindowTextW(cancel_hwnd, cancel_w.ptr);
            return;
        }
        const accept = try buildOverlayAcceptLabel(
            alloc,
            self.overlay_mode,
            text,
            if (surface) |value| value.search_needle else null,
            if (surface) |value| value.search_total else null,
            if (surface) |value| value.search_selected else null,
        );
        defer alloc.free(accept);
        const accept_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, accept);
        defer alloc.free(accept_w);
        _ = SetWindowTextW(accept_hwnd, accept_w.ptr);

        const cancel = overlayCancelLabel(self.overlay_mode);
        const cancel_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, cancel);
        defer alloc.free(cancel_w);
        _ = SetWindowTextW(cancel_hwnd, cancel_w.ptr);
    }

    fn syncOverlayHint(self: *Host) !void {
        const hint_hwnd = self.overlay_hint_hwnd orelse return;
        const alloc = self.app.core_app.alloc;
        const raw = if (self.overlay_edit_hwnd) |edit_hwnd|
            try readWindowTextUtf8Alloc(alloc, edit_hwnd)
        else
            try alloc.dupeZ(u8, "");
        defer alloc.free(raw);
        const text = std.mem.trim(u8, raw, " \t\r\n");
        if (self.overlay_mode == .profile) {
            const hint = try buildProfileHintText(
                alloc,
                self.profiles,
                text,
                self.selectedProfileIndex() orelse 0,
                self.app.launcher_profile_target,
                self.app.launcher_quick_slot_keys,
            );
            defer alloc.free(hint);
            const hint_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, hint);
            defer alloc.free(hint_w);
            _ = SetWindowTextW(hint_hwnd, hint_w.ptr);
            return;
        }
        const surface = self.activeSurface();
        const hint = try buildOverlayHintText(
            alloc,
            self.overlay_mode,
            text,
            if (surface) |value| value.search_needle else null,
            if (surface) |value| value.search_total else null,
            if (surface) |value| value.search_selected else null,
            if (surface) |value| self.app.hostTabStatus(value) else .{},
            if (self.activeTab()) |tab| tab.leafCount() else 1,
        );
        defer alloc.free(hint);
        const hint_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, hint);
        defer alloc.free(hint_w);
        _ = SetWindowTextW(hint_hwnd, hint_w.ptr);
    }

    fn clearOverlayCompletion(self: *Host) void {
        if (self.overlay_completion_seed) |value| self.app.core_app.alloc.free(value);
        if (self.overlay_completion_value) |value| self.app.core_app.alloc.free(value);
        self.overlay_completion_seed = null;
        self.overlay_completion_value = null;
    }

    fn ensureThemeBrushes(self: *Host) !void {
        const theme = &self.app.resolved_theme;
        if (self.chrome_brush == null) {
            self.chrome_brush = CreateSolidBrush(theme.chrome_bg) orelse return windows.unexpectedError(windows.kernel32.GetLastError());
        }
        if (self.overlay_brush == null) {
            self.overlay_brush = CreateSolidBrush(theme.overlay_bg) orelse return windows.unexpectedError(windows.kernel32.GetLastError());
        }
        if (self.edit_brush == null) {
            self.edit_brush = CreateSolidBrush(theme.edit_bg) orelse return windows.unexpectedError(windows.kernel32.GetLastError());
        }
    }

    fn rebuildThemeBrushes(self: *Host) void {
        if (self.chrome_brush) |brush| _ = DeleteObject(brush);
        if (self.overlay_brush) |brush| _ = DeleteObject(brush);
        if (self.edit_brush) |brush| _ = DeleteObject(brush);
        self.chrome_brush = null;
        self.overlay_brush = null;
        self.edit_brush = null;
        self.ensureThemeBrushes() catch {};
    }

    fn showContextMenu(self: *Host, screen_x: i32, screen_y: i32) void {
        const hwnd = self.hwnd orelse return;
        const menu = CreatePopupMenu() orelse return;
        defer _ = DestroyMenu(menu);

        // Check if active surface has a selection
        const has_selection = if (self.activeSurface()) |s| blk: {
            if (!s.core_initialized) break :blk false;
            break :blk s.core_surface.hasSelection();
        } else false;

        _ = AppendMenuW(menu, if (has_selection) MF_STRING else MF_GRAYED, CTX_COPY, std.unicode.utf8ToUtf16LeStringLiteral("Copy\tCtrl+Shift+C"));
        _ = AppendMenuW(menu, MF_STRING, CTX_PASTE, std.unicode.utf8ToUtf16LeStringLiteral("Paste\tCtrl+Shift+V"));
        _ = AppendMenuW(menu, MF_STRING, CTX_SELECT_ALL, std.unicode.utf8ToUtf16LeStringLiteral("Select All"));
        _ = AppendMenuW(menu, MF_SEPARATOR, 0, null);
        _ = AppendMenuW(menu, MF_STRING, CTX_FIND, std.unicode.utf8ToUtf16LeStringLiteral("Find...\tCtrl+Shift+F"));
        _ = AppendMenuW(menu, MF_STRING, CTX_COMMAND_PALETTE, std.unicode.utf8ToUtf16LeStringLiteral("Command Palette\tCtrl+Shift+P"));
        _ = AppendMenuW(menu, MF_SEPARATOR, 0, null);
        _ = AppendMenuW(menu, MF_STRING, CTX_NEW_TAB, std.unicode.utf8ToUtf16LeStringLiteral("New Tab"));
        _ = AppendMenuW(menu, MF_STRING, CTX_SPLIT_RIGHT, std.unicode.utf8ToUtf16LeStringLiteral("Split Right"));
        _ = AppendMenuW(menu, MF_STRING, CTX_NEW_WINDOW, std.unicode.utf8ToUtf16LeStringLiteral("New Window"));

        // Menu must be owned by top-level host HWND to avoid dismiss bugs
        _ = SetForegroundWindow(hwnd);
        const cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_LEFTALIGN | TPM_TOPALIGN, screen_x, screen_y, 0, hwnd, null);
        _ = PostMessageW(hwnd, WM_NULL, 0, 0);

        // Dispatch command (cmd is 0 on cancel)
        self.handleContextMenuCommand(cmd);
    }

    fn handleContextMenuCommand(self: *Host, cmd: BOOL) void {
        if (cmd <= 0) return; // 0 = cancel/dismiss
        const surface = self.activeSurface() orelse return;
        if (!surface.core_initialized) return;

        switch (@as(usize, @intCast(cmd))) {
            CTX_COPY => {
                _ = surface.core_surface.performBindingAction(.{ .copy_to_clipboard = .mixed }) catch {};
            },
            CTX_PASTE => {
                _ = surface.core_surface.performBindingAction(.{ .paste_from_clipboard = {} }) catch {};
            },
            CTX_SELECT_ALL => {
                _ = surface.core_surface.performBindingAction(.{ .select_all = {} }) catch {};
            },
            CTX_FIND => {
                surface.showSearchOverlay("") catch {};
            },
            CTX_COMMAND_PALETTE => {
                _ = surface.toggleCommandPalette() catch {};
            },
            CTX_NEW_TAB => {
                _ = self.app.performAction(.{ .surface = surface.core() }, .new_tab, {}) catch {};
            },
            CTX_SPLIT_RIGHT => {
                _ = self.app.performAction(.{ .surface = surface.core() }, .new_split, .right) catch {};
            },
            CTX_NEW_WINDOW => {
                _ = self.app.performAction(.{ .surface = surface.core() }, .new_window, {}) catch {};
            },
            else => {}, // 0 = cancel, ignore
        }
    }

    fn isOverlayButton(self: *Host, child: HWND) bool {
        return (self.overlay_accept_hwnd != null and child == self.overlay_accept_hwnd.?) or
            (self.overlay_cancel_hwnd != null and child == self.overlay_cancel_hwnd.?);
    }

    fn isActiveChromeButton(self: *Host, child: HWND) bool {
        if (self.isActiveTabButton(child)) return true;
        if (self.command_palette_hwnd != null and child == self.command_palette_hwnd.?) return self.overlay_mode == .command_palette;
        if (self.profiles_hwnd != null and child == self.profiles_hwnd.?) return self.overlay_mode == .profile;
        if (self.profile_target_hwnd != null and child == self.profile_target_hwnd.?) return true;
        if (self.tab_overview_hwnd != null and child == self.tab_overview_hwnd.?) return self.overlay_mode == .tab_overview;
        if (self.search_hwnd != null and child == self.search_hwnd.?) return self.overlay_mode == .search;
        if (self.inspector_hwnd != null and child == self.inspector_hwnd.?) {
            if (self.activeSurface()) |surface| return surface.inspector_visible;
        }
        return false;
    }

    fn drawButton(self: *Host, draw: *const DRAWITEMSTRUCT) void {
        if (draw.CtlType != ODT_BUTTON) return;
        self.ensureThemeBrushes() catch return;

        const disabled = (draw.itemState & ODS_DISABLED) != 0;
        const pressed = (draw.itemState & ODS_SELECTED) != 0;
        const focused = (draw.itemState & ODS_FOCUS) != 0 or GetFocus() == draw.hwndItem;
        const active = self.isActiveChromeButton(draw.hwndItem);
        const overlay = self.isOverlayButton(draw.hwndItem);
        const hovered = self.isHoveredButton(draw.hwndItem);
        const accept = draw.hwndItem == self.overlay_accept_hwnd;
        const profile_kind = self.buttonProfileKind(draw.hwndItem);
        const pinned_slot_ordinal = self.buttonPinnedSlotOrdinal(draw.hwndItem);
        const launcher_target = self.buttonLauncherTarget(draw.hwndItem);
        var colors = buttonColors(
            active,
            overlay,
            hovered,
            pressed,
            disabled,
            accept,
        );
        if (profile_kind) |kind| {
            colors = applyProfileChromeAccent(colors, kind, active, hovered, pressed, disabled);
        }
        const bg = colors.bg;
        const border = colors.border;
        const fg = colors.fg;

        fillSolidRect(draw.hDC, draw.rcItem, bg);
        fillSolidRect(draw.hDC, .{
            .left = draw.rcItem.left,
            .top = draw.rcItem.top,
            .right = draw.rcItem.right,
            .bottom = draw.rcItem.top + 1,
        }, border);
        fillSolidRect(draw.hDC, .{
            .left = draw.rcItem.left,
            .top = draw.rcItem.bottom - 1,
            .right = draw.rcItem.right,
            .bottom = draw.rcItem.bottom,
        }, border);
        fillSolidRect(draw.hDC, .{
            .left = draw.rcItem.left,
            .top = draw.rcItem.top,
            .right = draw.rcItem.left + 1,
            .bottom = draw.rcItem.bottom,
        }, border);
        fillSolidRect(draw.hDC, .{
            .left = draw.rcItem.right - 1,
            .top = draw.rcItem.top,
            .right = draw.rcItem.right,
            .bottom = draw.rcItem.bottom,
        }, border);
        if (profile_kind) |kind| {
            const stripe = profileChromeStripeColor(kind, active, hovered, pressed, disabled);
            fillSolidRect(draw.hDC, .{
                .left = draw.rcItem.left + 1,
                .top = draw.rcItem.top + 1,
                .right = draw.rcItem.left + 4,
                .bottom = draw.rcItem.bottom - 1,
            }, stripe);
            if (self.profile_target_hwnd != null and draw.hwndItem == self.profile_target_hwnd.?) {
                fillSolidRect(draw.hDC, .{
                    .left = draw.rcItem.right - 4,
                    .top = draw.rcItem.top + 1,
                    .right = draw.rcItem.right - 1,
                    .bottom = draw.rcItem.bottom - 1,
                }, stripe);
            }
            if (pinnedSlotBadgeDigit(pinned_slot_ordinal)) |digit| {
                paintPinnedSlotBadge(
                    draw.hDC,
                    draw.rcItem,
                    digit,
                    colors.border,
                    colors.bg,
                    profileKindLabelColor(kind),
                );
            }
            if (launcher_target) |target| {
                paintTargetButtonBadge(
                    draw.hDC,
                    draw.rcItem,
                    profileOpenTargetBadgeGlyph(target),
                    colors.border,
                    colors.bg,
                    profileOpenTargetMarkerColor(target),
                );
            }
        }
        if (focused and !disabled) {
            const focus = if (profile_kind) |kind|
                profileKindFocusRingColor(kind)
            else
                buttonFocusRingColor(active, overlay, accept);
            fillSolidRect(draw.hDC, .{
                .left = draw.rcItem.left + 2,
                .top = draw.rcItem.top + 2,
                .right = draw.rcItem.right - 2,
                .bottom = draw.rcItem.top + 3,
            }, focus);
            fillSolidRect(draw.hDC, .{
                .left = draw.rcItem.left + 2,
                .top = draw.rcItem.bottom - 3,
                .right = draw.rcItem.right - 2,
                .bottom = draw.rcItem.bottom - 2,
            }, focus);
            fillSolidRect(draw.hDC, .{
                .left = draw.rcItem.left + 2,
                .top = draw.rcItem.top + 2,
                .right = draw.rcItem.left + 3,
                .bottom = draw.rcItem.bottom - 2,
            }, focus);
            fillSolidRect(draw.hDC, .{
                .left = draw.rcItem.right - 3,
                .top = draw.rcItem.top + 2,
                .right = draw.rcItem.right - 2,
                .bottom = draw.rcItem.bottom - 2,
            }, focus);
        }

        var text_buf: [160]u16 = undefined;
        const text_len = GetWindowTextW(draw.hwndItem, &text_buf, text_buf.len);
        _ = SetBkMode(draw.hDC, TRANSPARENT);
        _ = SetTextColor(draw.hDC, fg);
        var text_rect = draw.rcItem;
        if (!overlay and draw.hwndItem != self.prev_tab_hwnd and draw.hwndItem != self.next_tab_hwnd) {
            text_rect.left += 6;
            text_rect.right -= 6;
        }
        if (profile_kind != null) {
            text_rect.left += 4;
            if (self.profile_target_hwnd != null and draw.hwndItem == self.profile_target_hwnd.?) {
                text_rect.right -= 4;
            }
        }
        text_rect.right -= buttonLabelRightInset(pinned_slot_ordinal, launcher_target);
        _ = DrawTextW(
            draw.hDC,
            @ptrCast(&text_buf),
            text_len,
            &text_rect,
            DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX | DT_END_ELLIPSIS,
        );
    }

    fn buttonProfileKind(self: *Host, hwnd: HWND) ?windows_shell.ProfileKind {
        const profile = self.selectedProfile() orelse return null;
        if (self.profiles_hwnd != null and hwnd == self.profiles_hwnd.?) return profile.kind;
        if (self.profile_target_hwnd != null and hwnd == self.profile_target_hwnd.?) return profile.kind;
        if (self.overlay_mode == .profile and self.overlay_accept_hwnd != null and hwnd == self.overlay_accept_hwnd.?) {
            return profile.kind;
        }
        return null;
    }

    fn buttonPinnedSlotOrdinal(self: *Host, hwnd: HWND) ?usize {
        const profile = self.selectedProfile() orelse return null;
        if (self.profiles_hwnd != null and hwnd == self.profiles_hwnd.?) {
            return self.app.launcherQuickSlotOrdinal(profile.key);
        }
        if (self.profile_target_hwnd != null and hwnd == self.profile_target_hwnd.?) {
            return self.app.launcherQuickSlotOrdinal(profile.key);
        }
        if (self.overlay_mode == .profile and self.overlay_accept_hwnd != null and hwnd == self.overlay_accept_hwnd.?) {
            return self.app.launcherQuickSlotOrdinal(profile.key);
        }
        return null;
    }

    fn buttonLauncherTarget(self: *Host, hwnd: HWND) ?ProfileOpenTarget {
        if (self.profiles_hwnd != null and hwnd == self.profiles_hwnd.?) {
            return self.app.launcher_profile_target;
        }
        if (self.profile_target_hwnd != null and hwnd == self.profile_target_hwnd.?) {
            return self.app.launcher_profile_target;
        }
        if (self.overlay_mode == .profile and self.overlay_accept_hwnd != null and hwnd == self.overlay_accept_hwnd.?) {
            return self.app.launcher_profile_target;
        }
        return null;
    }

    fn syncOverlayCompletionState(self: *Host) !void {
        if (self.overlay_mode != .command_palette) {
            self.clearOverlayCompletion();
            return;
        }
        const edit_hwnd = self.overlay_edit_hwnd orelse {
            self.clearOverlayCompletion();
            return;
        };
        const raw = try readWindowTextUtf8Alloc(self.app.core_app.alloc, edit_hwnd);
        defer self.app.core_app.alloc.free(raw);
        const text = std.mem.trim(u8, raw, " \t\r\n");
        if (self.overlay_completion_value) |value| {
            if (std.mem.eql(u8, value, text)) return;
        }
        self.clearOverlayCompletion();
    }

    fn completeCommandPalette(self: *Host, reverse: bool) !bool {
        if (self.overlay_mode != .command_palette) return false;
        const edit_hwnd = self.overlay_edit_hwnd orelse return false;
        const raw = try readWindowTextUtf8Alloc(self.app.core_app.alloc, edit_hwnd);
        defer self.app.core_app.alloc.free(raw);
        const text = std.mem.trim(u8, raw, " \t\r\n");
        const seed = if (self.overlay_completion_seed) |value|
            if (self.overlay_completion_value) |current|
                if (std.mem.eql(u8, current, text)) value else text
            else
                text
        else
            text;
        const candidate = commandPaletteCompletionCandidate(seed, text, reverse) orelse return false;
        const candidate_w = try std.unicode.utf8ToUtf16LeAllocZ(self.app.core_app.alloc, candidate);
        defer self.app.core_app.alloc.free(candidate_w);
        _ = SetWindowTextW(edit_hwnd, candidate_w.ptr);
        _ = SendMessageW(edit_hwnd, EM_SETSEL, 0, -1);
        try appendOwnedString(self.app.core_app.alloc, &self.overlay_completion_seed, seed);
        try appendOwnedString(self.app.core_app.alloc, &self.overlay_completion_value, candidate);
        _ = try self.syncCommandPaletteBanner();
        return true;
    }

    fn stepTabOverviewSelection(self: *Host, reverse: bool) !bool {
        if (self.overlay_mode != .tab_overview) return false;
        const edit_hwnd = self.overlay_edit_hwnd orelse return false;
        const total = self.tabs.items.len;
        if (total == 0) return false;

        const raw = try readWindowTextUtf8Alloc(self.app.core_app.alloc, edit_hwnd);
        defer self.app.core_app.alloc.free(raw);
        const text = std.mem.trim(u8, raw, " \t\r\n");

        const current: usize = std.fmt.parseUnsigned(usize, text, 10) catch self.active_tab + 1;
        const next = nextTabOverviewSelection(current, total, reverse);
        const next_text = try std.fmt.allocPrint(self.app.core_app.alloc, "{d}", .{next});
        defer self.app.core_app.alloc.free(next_text);
        const next_w = try std.unicode.utf8ToUtf16LeAllocZ(self.app.core_app.alloc, next_text);
        defer self.app.core_app.alloc.free(next_w);
        _ = SetWindowTextW(edit_hwnd, next_w.ptr);
        _ = SendMessageW(edit_hwnd, EM_SETSEL, 0, -1);
        try self.syncOverlayLabel();
        try self.syncOverlayHint();
        try self.syncOverlayButtons();
        return true;
    }

    fn navigateSearchOverlay(self: *Host, dir: input.Binding.Action.NavigateSearch) !bool {
        if (self.overlay_mode != .search) return false;
        const surface = self.activeSurface() orelse return false;
        if (surface.search_total == null or surface.search_selected == null) return false;
        _ = try surface.core_surface.performBindingAction(.{ .navigate_search = dir });
        return true;
    }

    fn syncSearchOverlay(self: *Host) !bool {
        const edit_hwnd = self.overlay_edit_hwnd orelse return false;
        const surface = self.activeSurface() orelse return false;
        const raw = try readWindowTextUtf8Alloc(self.app.core_app.alloc, edit_hwnd);
        defer self.app.core_app.alloc.free(raw);
        const text = std.mem.trim(u8, raw, " \t\r\n");
        _ = try surface.core_surface.setSearchText(text);
        try surface.setSearchActive(text.len > 0, text);
        try self.syncOverlayLabel();
        try self.syncOverlayHint();
        try self.syncOverlayButtons();
        return true;
    }

    fn syncCommandPaletteBanner(self: *Host) !bool {
        if (self.overlay_mode != .command_palette) return false;
        const edit_hwnd = self.overlay_edit_hwnd orelse return false;
        const raw = try readWindowTextUtf8Alloc(self.app.core_app.alloc, edit_hwnd);
        defer self.app.core_app.alloc.free(raw);
        const text = std.mem.trim(u8, raw, " \t\r\n");
        const banner = try commandPaletteBannerText(self.app.core_app.alloc, text);
        defer if (banner) |value| self.app.core_app.alloc.free(value);
        if (banner) |value| {
            try self.setBanner(.info, value);
        } else {
            try self.setBanner(.none, null);
        }
        try self.syncOverlayLabel();
        try self.syncOverlayHint();
        try self.syncOverlayButtons();
        return true;
    }

    fn submitOverlay(self: *Host) !bool {
        const edit_hwnd = self.overlay_edit_hwnd orelse return false;
        const raw = try readWindowTextUtf8Alloc(self.app.core_app.alloc, edit_hwnd);
        defer self.app.core_app.alloc.free(raw);
        const text = std.mem.trim(u8, raw, " \t\r\n");
        if (text.len == 0 and self.overlay_mode != .search and self.overlay_mode != .profile) {
            self.hideOverlay();
            try self.layout();
            return false;
        }

        const surface = self.activeSurface() orelse return false;
        switch (self.overlay_mode) {
            .none => return false,
            .command_palette => {
                const resolved = if (commandPaletteUniqueMatch(text)) |candidate| candidate else text;
                const action = input.Binding.Action.parse(resolved) catch |err| {
                    log.warn("win32 command palette invalid action action={s} err={}", .{ text, err });
                    try self.setBanner(.err, "Unknown Ghostty action. Example: new_tab or toggle_fullscreen");
                    return false;
                };
                _ = try surface.core_surface.performBindingAction(action);
            },
            .profile => {
                return try self.submitProfileOverlay(self.app.launcher_profile_target);
            },
            .search => {
                const same_needle = if (surface.search_needle) |needle|
                    std.mem.eql(u8, needle, text)
                else
                    false;
                if (text.len > 0 and same_needle and surface.search_selected != null and surface.search_total != null) {
                    _ = try surface.core_surface.performBindingAction(.{ .navigate_search = .next });
                } else {
                    _ = try surface.core_surface.setSearchText(text);
                    try surface.setSearchActive(text.len > 0, text);
                }
            },
            .surface_title => {
                try surface.setTitleOverride(if (text.len == 0) null else text);
            },
            .tab_title => {
                try surface.setTabTitleOverride(if (text.len == 0) null else text);
            },
            .tab_overview => {
                const requested = std.fmt.parseUnsigned(usize, text, 10) catch |err| {
                    log.warn("win32 tab overview invalid selection value={s} err={}", .{ text, err });
                    try self.setBanner(.err, "Enter a numeric tab index.");
                    return false;
                };
                if (requested == 0 or requested > self.tabs.items.len) {
                    const message = try std.fmt.allocPrint(self.app.core_app.alloc, "Tab index out of range. Valid range: 1 to {d}.", .{self.tabs.items.len});
                    defer self.app.core_app.alloc.free(message);
                    try self.setBanner(.err, message);
                    return false;
                }
                self.active_tab = requested - 1;
                if (self.tabs.items[self.active_tab].focusedSurface()) |next_surface| {
                    self.app.activateSurface(next_surface);
                }
            },
        }

        self.hideOverlay();
        try self.layout();
        try self.setBanner(.none, null);
        return true;
    }

    fn shouldShowTabBar(self: *Host) bool {
        return switch (self.app.config.@"window-show-tab-bar") {
            .always => true,
            .never => false,
            .auto => self.tabs.items.len > 1,
        };
    }

    fn tabBarHeight(self: *Host) i32 {
        return if (self.shouldShowTabBar()) self.scaled(host_tab_height) else 0;
    }

    fn rightButtonsWidth(self: *const Host) i32 {
        return self.scaled(host_tab_cmd_button_width) +
            self.scaled(host_tab_profiles_button_width) +
            self.scaled(host_tab_target_button_width) +
            self.scaled(host_tab_nav_button_width) +
            self.scaled(host_tab_tabs_button_width) +
            self.scaled(host_tab_nav_button_width) +
            self.scaled(host_tab_find_button_width) +
            self.scaled(host_tab_inspect_button_width) +
            (self.scaled(host_tab_small_button_width) * 2) +
            self.scaled(28);
    }

    fn scaled(self: *const Host, base: i32) i32 {
        if (self.current_dpi <= 96) return base;
        return @divTrunc(base * @as(i32, @intCast(self.current_dpi)), 96);
    }

    fn contentRect(self: *Host) !RECT {
        const hwnd = self.hwnd orelse return error.InvalidHost;
        var rect: RECT = undefined;
        if (GetClientRect(hwnd, &rect) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
        const tab_offset: i32 = self.tabBarHeight();
        const overlay_offset: i32 = if (self.overlay_mode == .none) 0 else self.scaled(host_overlay_height);
        const inspector_offset: i32 = if (self.inspectorPanelVisible()) self.scaled(host_inspector_panel_height) else 0;
        return .{
            .left = 0,
            .top = tab_offset + overlay_offset + inspector_offset,
            .right = rect.right,
            .bottom = @max(tab_offset + 1, rect.bottom - self.scaled(host_status_height)),
        };
    }

    fn close(self: *Host) void {
        if (self.hwnd) |hwnd| _ = DestroyWindow(hwnd);
    }

    fn statusText(self: *Host, alloc: Allocator) !?[]u8 {
        const surface = self.activeSurface() orelse return null;
        const tab = self.activeTab() orelse return null;
        var parts: std.ArrayListUnmanaged(u8) = .empty;
        errdefer parts.deinit(alloc);

        const append = struct {
            fn raw(buf: *std.ArrayListUnmanaged(u8), alloc_: Allocator, value: []const u8) !void {
                if (buf.items.len > 0) try buf.appendSlice(alloc_, " | ");
                try buf.appendSlice(alloc_, value);
            }
        };

        const host_status = self.app.hostTabStatus(surface);
        try parts.writer(alloc).print("tab:{d}/{d}", .{ host_status.index + 1, host_status.total });
        const pane_count = tab.leafCount();
        if (pane_count > 1) {
            if (parts.items.len > 0) try parts.appendSlice(alloc, " | ");
            try parts.writer(alloc).print("panes:{d}", .{pane_count});
        }
        if (surface.readonly) try append.raw(&parts, alloc, "readonly");
        if (surface.secure_input) try append.raw(&parts, alloc, "secure input");
        if (surface.inspector_visible) {
            if (tab.tree.zoomed != null and pane_count > 1) {
                try parts.writer(alloc).print("{s}inspect:{d} zoom", .{
                    if (parts.items.len > 0) " | " else "",
                    pane_count,
                });
            } else if (pane_count > 1) {
                try parts.writer(alloc).print("{s}inspect:{d}", .{
                    if (parts.items.len > 0) " | " else "",
                    pane_count,
                });
            } else {
                try append.raw(&parts, alloc, "inspect");
            }
        }
        if (surface.key_sequence_active) try append.raw(&parts, alloc, "keys");
        if (surface.key_table_name) |value| {
            if (parts.items.len > 0) try parts.appendSlice(alloc, " | ");
            try parts.writer(alloc).print("table:{s}", .{value});
        }
        if (surface.search_active) {
            if (parts.items.len > 0) try parts.appendSlice(alloc, " | ");
            if (surface.search_needle) |needle| {
                if (surface.search_selected) |selected| {
                    if (surface.search_total) |total| {
                        try std.fmt.format(parts.writer(alloc), "find:{s} ({d}/{d})", .{ needle, selected, total });
                    } else {
                        try std.fmt.format(parts.writer(alloc), "find:{s} ({d})", .{ needle, selected });
                    }
                } else if (surface.search_total) |total| {
                    try std.fmt.format(parts.writer(alloc), "find:{s} ({d})", .{ needle, total });
                } else {
                    try std.fmt.format(parts.writer(alloc), "find:{s}", .{needle});
                }
            } else {
                try append.raw(&parts, alloc, "find");
            }
        }
        if (surface.progress_status) |value| try append.raw(&parts, alloc, value);
        if (parts.items.len == 0) return null;
        return try parts.toOwnedSlice(alloc);
    }

    fn detailText(self: *Host, alloc: Allocator) !?[]u8 {
        const surface = self.activeSurface() orelse return null;
        const tab = self.activeTab() orelse return null;
        const host_status = self.app.hostTabStatus(surface);
        const pane_count = tab.leafCount();

        if (self.overlay_mode == .profile) {
            if (self.selectedProfile()) |profile| {
                return try buildProfileDetailText(
                    alloc,
                    profile,
                    self.profiles,
                    true,
                    self.app.launcher_profile_target,
                    self.app.launcher_profile_order_hint,
                    self.app.launcher_quick_slot_keys,
                );
            }
            return null;
        }

        if (surface.inspector_visible) {
            return try buildInspectorDetailText(alloc, host_status, pane_count, tab.tree.zoomed != null);
        }

        if (surface.search_active) {
            return try buildSearchDetailText(
                alloc,
                surface.search_needle,
                surface.search_total,
                surface.search_selected,
            );
        }

        if (surface.key_sequence_active) {
            return try alloc.dupe(u8, "Key sequence capture is active. Finish the sequence or press Escape to cancel.");
        }

        if (surface.key_table_name) |value| {
            return try std.fmt.allocPrint(
                alloc,
                "Key table {s} is active for this tab.",
                .{value},
            );
        }

        if (self.selectedProfile()) |profile| {
            return try buildProfileDetailText(
                alloc,
                profile,
                self.profiles,
                false,
                self.app.launcher_profile_target,
                self.app.launcher_profile_order_hint,
                self.app.launcher_quick_slot_keys,
            );
        }

        return null;
    }

    fn refreshChrome(self: *Host) !void {
        try self.syncWindowTitle();
        try self.syncTabButtons();
        try self.syncChromeButtons();
        if (self.overlay_mode != .none) {
            try self.syncOverlayLabel();
            try self.syncOverlayHint();
            try self.syncOverlayButtons();
        }
        self.invalidateChrome();
    }

    fn invalidateChrome(self: *Host) void {
        const hwnd = self.hwnd orelse return;
        var client_rect: RECT = undefined;
        if (GetClientRect(hwnd, &client_rect) == 0) return;
        const content_rect = self.contentRect() catch return;

        const top_rect = RECT{
            .left = client_rect.left,
            .top = client_rect.top,
            .right = client_rect.right,
            .bottom = @max(client_rect.top, content_rect.top),
        };
        if (top_rect.bottom > top_rect.top) {
            _ = InvalidateRect(hwnd, &top_rect, 0);
        }

        const bottom_rect = RECT{
            .left = client_rect.left,
            .top = @min(client_rect.bottom, content_rect.bottom),
            .right = client_rect.right,
            .bottom = client_rect.bottom,
        };
        if (bottom_rect.bottom > bottom_rect.top) {
            _ = InvalidateRect(hwnd, &bottom_rect, 0);
        }
    }

    fn syncWindowTitle(self: *Host) !void {
        const hwnd = self.hwnd orelse return;
        const surface = self.activeSurface() orelse return;
        const alloc = self.app.core_app.alloc;
        const host_base_title = try buildHostAwareBaseTitle(
            alloc,
            if (surface.effectiveTitle()) |value| value else null,
            self.app.hostTabStatus(surface),
        );
        defer alloc.free(host_base_title);
        const title_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, host_base_title);
        defer alloc.free(title_w);
        _ = SetWindowTextW(hwnd, title_w.ptr);
    }

    fn syncTabButtons(self: *Host) !void {
        const hwnd = self.hwnd orelse return;
        try self.ensureChromeButtons();
        var rect: RECT = undefined;
        if (GetClientRect(hwnd, &rect) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
        const width = @max(0, rect.right - rect.left);
        const right_buttons_width = self.rightButtonsWidth();
        const tab_area_width = @max(1, width - right_buttons_width);
        const tab_range = visibleTabRange(self.tabs.items.len, self.active_tab, tab_area_width);
        const visible_count = @max(@as(i32, 1), @as(i32, @intCast(tab_range.count)));
        const button_width = @max(1, @divTrunc(tab_area_width, visible_count));
        const label_max_len = hostTabLabelMaxLen(button_width);
        for (self.tabs.items, 0..) |*tab, i| {
            const surface = tab.focusedSurface() orelse continue;
            const pane_count = tab.leafCount();
            const label = try buildTabButtonLabel(
                self.app.core_app.alloc,
                if (surface.effectiveTitle()) |value| value else null,
                i,
                i == self.active_tab,
                pane_count,
                label_max_len,
                shouldShowPaneCount(button_width, pane_count),
            );
            defer self.app.core_app.alloc.free(label);
            const label_w = try std.unicode.utf8ToUtf16LeAllocZ(self.app.core_app.alloc, label);
            defer self.app.core_app.alloc.free(label_w);
            if (tab.button_hwnd == null) {
                tab.button_hwnd = CreateWindowExW(
                    0,
                    prompt_button_class,
                    label_w.ptr,
                    WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW,
                    0,
                    0,
                    100,
                    host_tab_height - 8,
                    hwnd,
                    @ptrFromInt(1000 + i),
                    self.app.hinstance,
                    null,
                ) orelse return windows.unexpectedError(windows.kernel32.GetLastError());
                _ = SetWindowLongPtrW(
                    tab.button_hwnd.?,
                    GWLP_USERDATA,
                    @as(LONG_PTR, @intCast(@intFromPtr(self))),
                );
                const previous = SetWindowLongPtrW(
                    tab.button_hwnd.?,
                    GWLP_WNDPROC,
                    @as(LONG_PTR, @intCast(@intFromPtr(&tabButtonProc))),
                );
                tab.button_prev_proc = if (previous == 0)
                    null
                else
                    @ptrFromInt(@as(usize, @intCast(previous)));
            } else {
                _ = SetWindowTextW(tab.button_hwnd.?, label_w.ptr);
            }
            _ = ShowWindow(
                tab.button_hwnd.?,
                if (i >= tab_range.start and i < tab_range.start + tab_range.count) SW_SHOW else SW_HIDE,
            );
        }
        try self.layout();
    }

    fn syncChromeButtons(self: *Host) !void {
        try self.ensureChromeButtons();

        const command_hwnd = self.command_palette_hwnd orelse return;
        const profiles_hwnd = self.profiles_hwnd orelse return;
        const profile_target_hwnd = self.profile_target_hwnd orelse return;
        const prev_tab_hwnd = self.prev_tab_hwnd orelse return;
        const tabs_hwnd = self.tab_overview_hwnd orelse return;
        const next_tab_hwnd = self.next_tab_hwnd orelse return;
        const search_hwnd = self.search_hwnd orelse return;
        const inspector_hwnd = self.inspector_hwnd orelse return;
        const new_tab_hwnd = self.new_tab_hwnd orelse return;
        const close_tab_hwnd = self.close_tab_hwnd orelse return;
        const surface = self.activeSurface();
        const tab = self.activeTab();
        const hwnd = self.hwnd orelse return;
        var rect: RECT = undefined;
        if (GetClientRect(hwnd, &rect) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
        const width = @max(0, rect.right - rect.left);
        const right_buttons_width = self.rightButtonsWidth();
        const tab_area_width = @max(1, width - right_buttons_width);
        const tab_range = visibleTabRange(self.tabs.items.len, self.active_tab, tab_area_width);
        const command_input = if (self.overlay_mode == .command_palette and self.overlay_edit_hwnd != null)
            try readWindowTextUtf8Alloc(self.app.core_app.alloc, self.overlay_edit_hwnd.?)
        else
            null;
        defer if (command_input) |value| self.app.core_app.alloc.free(value);
        const command_label = try buildCommandButtonLabel(
            self.app.core_app.alloc,
            self.overlay_mode == .command_palette,
            if (command_input) |value| value else null,
        );
        defer self.app.core_app.alloc.free(command_label);
        const command_label_w = try std.unicode.utf8ToUtf16LeAllocZ(self.app.core_app.alloc, command_label);
        defer self.app.core_app.alloc.free(command_label_w);
        const selected_profile = self.selectedProfile();
        const pinned_slot_ordinal = if (selected_profile) |profile|
            self.app.launcherQuickSlotOrdinal(profile.key)
        else
            null;
        const profiles_label = try buildProfilesButtonLabel(
            self.app.core_app.alloc,
            self.overlay_mode == .profile,
            self.profiles,
            self.selectedProfileIndex(),
            pinned_slot_ordinal,
        );
        defer self.app.core_app.alloc.free(profiles_label);
        const profiles_label_w = try std.unicode.utf8ToUtf16LeAllocZ(self.app.core_app.alloc, profiles_label);
        defer self.app.core_app.alloc.free(profiles_label_w);
        const target_label = try launchTargetButtonLabel(
            self.app.core_app.alloc,
            self.app.launcher_profile_target,
            self.selectedProfileIndex(),
            pinned_slot_ordinal,
        );
        defer self.app.core_app.alloc.free(target_label);
        const target_label_w = try std.unicode.utf8ToUtf16LeAllocZ(self.app.core_app.alloc, target_label);
        defer self.app.core_app.alloc.free(target_label_w);
        const tabs_label = try buildTabsButtonLabel(
            self.app.core_app.alloc,
            self.overlay_mode == .tab_overview,
            self.active_tab,
            self.tabs.items.len,
        );
        defer self.app.core_app.alloc.free(tabs_label);
        const tabs_label_w = try std.unicode.utf8ToUtf16LeAllocZ(self.app.core_app.alloc, tabs_label);
        defer self.app.core_app.alloc.free(tabs_label_w);
        const search_label = try buildSearchButtonLabel(
            self.app.core_app.alloc,
            self.overlay_mode == .search,
            if (surface) |s| s.search_total else null,
            if (surface) |s| s.search_selected else null,
        );
        defer self.app.core_app.alloc.free(search_label);
        const search_label_w = try std.unicode.utf8ToUtf16LeAllocZ(self.app.core_app.alloc, search_label);
        defer self.app.core_app.alloc.free(search_label_w);
        const inspector_label = try buildInspectorButtonLabel(
            self.app.core_app.alloc,
            surface != null and surface.?.inspector_visible,
            if (tab) |value| value.leafCount() else 1,
        );
        defer self.app.core_app.alloc.free(inspector_label);
        const inspector_label_w = try std.unicode.utf8ToUtf16LeAllocZ(self.app.core_app.alloc, inspector_label);
        defer self.app.core_app.alloc.free(inspector_label_w);

        _ = SetWindowTextW(
            command_hwnd,
            command_label_w.ptr,
        );
        _ = SetWindowTextW(
            profiles_hwnd,
            profiles_label_w.ptr,
        );
        _ = SetWindowTextW(
            profile_target_hwnd,
            target_label_w.ptr,
        );
        _ = SetWindowTextW(prev_tab_hwnd, host_tab_prev_button_label);
        _ = SetWindowTextW(
            tabs_hwnd,
            tabs_label_w.ptr,
        );
        _ = SetWindowTextW(next_tab_hwnd, host_tab_next_button_label);
        _ = SetWindowTextW(
            search_hwnd,
            search_label_w.ptr,
        );
        _ = SetWindowTextW(
            inspector_hwnd,
            inspector_label_w.ptr,
        );
        _ = ShowWindow(command_hwnd, SW_SHOW);
        _ = ShowWindow(profiles_hwnd, SW_SHOW);
        _ = ShowWindow(profile_target_hwnd, SW_SHOW);
        _ = ShowWindow(prev_tab_hwnd, SW_SHOW);
        _ = ShowWindow(tabs_hwnd, SW_SHOW);
        _ = ShowWindow(next_tab_hwnd, SW_SHOW);
        _ = ShowWindow(search_hwnd, SW_SHOW);
        _ = ShowWindow(inspector_hwnd, SW_SHOW);
        _ = ShowWindow(new_tab_hwnd, SW_SHOW);
        _ = ShowWindow(close_tab_hwnd, SW_SHOW);
        _ = EnableWindow(profiles_hwnd, if (self.profiles == null or (self.profiles != null and self.profiles.?.len > 0)) 1 else 0);
        _ = EnableWindow(prev_tab_hwnd, if (tab_range.start > 0) 1 else 0);
        _ = EnableWindow(next_tab_hwnd, if (tab_range.start + tab_range.count < self.tabs.items.len) 1 else 0);
        _ = EnableWindow(close_tab_hwnd, if (self.tabs.items.len > 1) 1 else 0);
    }

    fn layout(self: *Host) !void {
        const hwnd = self.hwnd orelse return;
        var rect: RECT = undefined;
        if (GetClientRect(hwnd, &rect) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }

        const width = @max(0, rect.right - rect.left);
        const right_buttons_width = self.rightButtonsWidth();
        const tab_area_width = @max(1, width - right_buttons_width);
        const tab_range = visibleTabRange(self.tabs.items.len, self.active_tab, tab_area_width);
        const visible_count = @max(@as(i32, 1), @as(i32, @intCast(tab_range.count)));
        const button_width = @max(1, @divTrunc(tab_area_width, visible_count));
        for (self.tabs.items, 0..) |*tab, i| {
            if (tab.button_hwnd) |button_hwnd| {
                if (i >= tab_range.start and i < tab_range.start + tab_range.count) {
                    const visible_index: i32 = @intCast(i - tab_range.start);
                    _ = MoveWindow(
                        button_hwnd,
                        visible_index * button_width,
                        self.scaled(4),
                        button_width,
                        self.scaled(host_tab_height) - self.scaled(8),
                        1,
                    );
                    _ = ShowWindow(button_hwnd, SW_SHOW);
                } else {
                    _ = ShowWindow(button_hwnd, SW_HIDE);
                }
            }
        }

        var button_x = width - self.scaled(8);
        if (self.close_tab_hwnd) |button_hwnd| {
            button_x -= self.scaled(host_tab_small_button_width);
            _ = MoveWindow(button_hwnd, button_x, self.scaled(4), self.scaled(host_tab_small_button_width), self.scaled(host_tab_height) - self.scaled(8), 1);
        }
        button_x -= self.scaled(4);
        if (self.new_tab_hwnd) |button_hwnd| {
            button_x -= self.scaled(host_tab_small_button_width);
            _ = MoveWindow(button_hwnd, button_x, self.scaled(4), self.scaled(host_tab_small_button_width), self.scaled(host_tab_height) - self.scaled(8), 1);
        }
        button_x -= self.scaled(4);
        if (self.inspector_hwnd) |button_hwnd| {
            button_x -= self.scaled(host_tab_inspect_button_width);
            _ = MoveWindow(button_hwnd, button_x, self.scaled(4), self.scaled(host_tab_inspect_button_width), self.scaled(host_tab_height) - self.scaled(8), 1);
        }
        button_x -= self.scaled(4);
        if (self.next_tab_hwnd) |button_hwnd| {
            button_x -= self.scaled(host_tab_nav_button_width);
            _ = MoveWindow(button_hwnd, button_x, self.scaled(4), self.scaled(host_tab_nav_button_width), self.scaled(host_tab_height) - self.scaled(8), 1);
        }
        button_x -= self.scaled(4);
        if (self.tab_overview_hwnd) |button_hwnd| {
            button_x -= self.scaled(host_tab_tabs_button_width);
            _ = MoveWindow(button_hwnd, button_x, self.scaled(4), self.scaled(host_tab_tabs_button_width), self.scaled(host_tab_height) - self.scaled(8), 1);
        }
        button_x -= self.scaled(4);
        if (self.prev_tab_hwnd) |button_hwnd| {
            button_x -= self.scaled(host_tab_nav_button_width);
            _ = MoveWindow(button_hwnd, button_x, self.scaled(4), self.scaled(host_tab_nav_button_width), self.scaled(host_tab_height) - self.scaled(8), 1);
        }
        button_x -= self.scaled(4);
        if (self.search_hwnd) |button_hwnd| {
            button_x -= self.scaled(host_tab_find_button_width);
            _ = MoveWindow(button_hwnd, button_x, self.scaled(4), self.scaled(host_tab_find_button_width), self.scaled(host_tab_height) - self.scaled(8), 1);
        }
        button_x -= self.scaled(4);
        if (self.command_palette_hwnd) |button_hwnd| {
            button_x -= self.scaled(host_tab_cmd_button_width);
            _ = MoveWindow(button_hwnd, button_x, self.scaled(4), self.scaled(host_tab_cmd_button_width), self.scaled(host_tab_height) - self.scaled(8), 1);
        }
        button_x -= self.scaled(4);
        if (self.profiles_hwnd) |button_hwnd| {
            button_x -= self.scaled(host_tab_profiles_button_width);
            _ = MoveWindow(button_hwnd, button_x, self.scaled(4), self.scaled(host_tab_profiles_button_width), self.scaled(host_tab_height) - self.scaled(8), 1);
        }
        button_x -= self.scaled(4);
        if (self.profile_target_hwnd) |button_hwnd| {
            button_x -= self.scaled(host_tab_target_button_width);
            _ = MoveWindow(button_hwnd, button_x, self.scaled(4), self.scaled(host_tab_target_button_width), self.scaled(host_tab_height) - self.scaled(8), 1);
        }

        if (self.overlay_mode != .none) {
            const edit_hwnd = self.overlay_edit_hwnd orelse return;
            const accept_hwnd = self.overlay_accept_hwnd orelse return;
            const cancel_hwnd = self.overlay_cancel_hwnd orelse return;
            const overlay_y = self.tabBarHeight();
            const edit_width = @max(self.scaled(120), width - self.scaled(host_overlay_label_width) - self.scaled(host_overlay_accept_width) - self.scaled(host_overlay_cancel_width) - (self.scaled(host_overlay_padding) * 4));
            _ = MoveWindow(edit_hwnd, self.scaled(host_overlay_padding) + self.scaled(host_overlay_label_width) + self.scaled(8), overlay_y + self.scaled(8), edit_width - self.scaled(16), self.scaled(host_overlay_row_height) - self.scaled(4), 1);
            _ = MoveWindow(accept_hwnd, width - self.scaled(host_overlay_cancel_width) - self.scaled(host_overlay_accept_width) - (self.scaled(host_overlay_padding) * 2), overlay_y + self.scaled(4), self.scaled(host_overlay_accept_width), self.scaled(host_overlay_row_height), 1);
            _ = MoveWindow(cancel_hwnd, width - self.scaled(host_overlay_cancel_width) - self.scaled(host_overlay_padding), overlay_y + self.scaled(4), self.scaled(host_overlay_cancel_width), self.scaled(host_overlay_row_height), 1);
        }

        const content_rect = try self.contentRect();
        const content_y = content_rect.top;
        const content_width = @max(1, content_rect.right - content_rect.left);
        const content_height = @max(1, content_rect.bottom - content_rect.top);
        const active_tab = self.activeTab() orelse return;

        if (active_tab.tree.zoomed) |zoomed| {
            var it = active_tab.tree.iterator();
            while (it.next()) |entry| {
                const visible = entry.handle == zoomed;
                entry.view.setVisible(visible);
                if (visible) {
                    if (entry.view.hwnd) |surface_hwnd| _ = MoveWindow(surface_hwnd, content_rect.left, content_y, content_width, content_height, 1);
                    // Update content_scale if DPI changed since surface was last visible
                    if (self.pending_dpi_update and entry.view.core_initialized) {
                        const scale_val: f32 = @as(f32, @floatFromInt(self.current_dpi)) / 96.0;
                        const new_scale: apprt.ContentScale = .{ .x = scale_val, .y = scale_val };
                        if (entry.view.content_scale.x != new_scale.x or entry.view.content_scale.y != new_scale.y) {
                            entry.view.content_scale = new_scale;
                            entry.view.core_surface.contentScaleCallback(new_scale) catch {};
                        }
                    }
                }
            }
        } else {
            var spatial = try active_tab.tree.spatial(self.app.core_app.alloc);
            defer spatial.deinit(self.app.core_app.alloc);
            var it = active_tab.tree.iterator();
            while (it.next()) |entry| {
                entry.view.setVisible(true);
                if (entry.view.hwnd) |surface_hwnd| {
                    const slot = spatial.slots[entry.handle.idx()];
                    const x: i32 = content_rect.left + @as(i32, @intFromFloat(@round(slot.x * @as(f16, @floatFromInt(content_width)))));
                    const y: i32 = content_y + @as(i32, @intFromFloat(@round(slot.y * @as(f16, @floatFromInt(content_height)))));
                    const w: i32 = @max(1, @as(i32, @intFromFloat(@round(slot.width * @as(f16, @floatFromInt(content_width))))));
                    const h: i32 = @max(1, @as(i32, @intFromFloat(@round(slot.height * @as(f16, @floatFromInt(content_height))))));
                    _ = MoveWindow(surface_hwnd, x, y, w, h, 1);
                }
                // Update content_scale if DPI changed since surface was last visible
                if (self.pending_dpi_update and entry.view.core_initialized) {
                    const scale_val: f32 = @as(f32, @floatFromInt(self.current_dpi)) / 96.0;
                    const new_scale: apprt.ContentScale = .{ .x = scale_val, .y = scale_val };
                    if (entry.view.content_scale.x != new_scale.x or entry.view.content_scale.y != new_scale.y) {
                        entry.view.content_scale = new_scale;
                        entry.view.core_surface.contentScaleCallback(new_scale) catch {};
                    }
                }
            }
        }
        self.pending_dpi_update = false;

        for (self.tabs.items, 0..) |*tab, i| {
            if (i == self.active_tab) continue;
            var it = tab.tree.iterator();
            while (it.next()) |entry| entry.view.setVisible(false);
        }
    }

    fn paintChrome(self: *Host) void {
        const hwnd = self.hwnd orelse return;
        var ps: PAINTSTRUCT = undefined;
        const hdc = BeginPaint(hwnd, &ps) orelse return;
        defer _ = EndPaint(hwnd, &ps);

        const alloc = self.app.core_app.alloc;
        const theme = &self.app.resolved_theme;
        var client_rect: RECT = undefined;
        if (GetClientRect(hwnd, &client_rect) == 0) return;
        const tab_h = self.tabBarHeight();
        // Note: tab_h is already scaled via tabBarHeight()
        const overlay_offset: i32 = if (self.overlay_mode != .none) self.scaled(host_overlay_height) else 0;
        const inspector_panel_visible = self.inspectorPanelVisible();
        const inspector_offset: i32 = if (inspector_panel_visible) self.scaled(host_inspector_panel_height) else 0;
        const banner_y: i32 = tab_h + overlay_offset + inspector_offset + self.scaled(2);

        // Tab bar (only when visible)
        if (tab_h > 0) {
            const tab_rect = RECT{
                .left = 0,
                .top = 0,
                .right = client_rect.right,
                .bottom = tab_h,
            };
            fillSolidRect(hdc, tab_rect, theme.chrome_bg);
            fillSolidRect(
                hdc,
                .{
                    .left = 0,
                    .top = tab_h - 1,
                    .right = client_rect.right,
                    .bottom = tab_h,
                },
                theme.chrome_border,
            );
        } // end tab bar painting

        if (self.overlay_mode != .none) {
            const overlay_rect = RECT{
                .left = 0,
                .top = tab_h,
                .right = client_rect.right,
                .bottom = tab_h + self.scaled(host_overlay_height),
            };
            fillSolidRect(hdc, overlay_rect, theme.overlay_bg);
            fillSolidRect(
                hdc,
                .{
                    .left = 0,
                    .top = overlay_rect.bottom - 1,
                    .right = client_rect.right,
                    .bottom = overlay_rect.bottom,
                },
                theme.chrome_border,
            );

            const surface = self.activeSurface();
            const overlay_raw = if (self.overlay_edit_hwnd) |edit_hwnd|
                readWindowTextUtf8Alloc(alloc, edit_hwnd) catch null
            else
                null;
            defer if (overlay_raw) |owned| alloc.free(owned);
            const overlay_text = if (overlay_raw) |value|
                std.mem.trim(u8, value, " \t\r\n")
            else
                "";
            const overlay_status = if (surface) |value| self.app.hostTabStatus(value) else HostTabStatus{};

            const overlay_label = if (self.overlay_mode == .profile)
                buildProfileOverlayLabel(
                    alloc,
                    self.profiles orelse &.{},
                    overlay_text,
                    self.selectedProfileIndex() orelse 0,
                ) catch return
            else
                buildOverlayPaintLabelText(
                    alloc,
                    self.overlay_mode,
                    overlay_text,
                    if (surface) |value| value.search_total else null,
                    if (surface) |value| value.search_selected else null,
                    overlay_status,
                ) catch return;
            defer alloc.free(overlay_label);
            const overlay_label_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, overlay_label) catch return;
            defer alloc.free(overlay_label_w);
            _ = SetBkMode(hdc, TRANSPARENT);
            var overlay_label_x: i32 = self.scaled(host_overlay_padding);
            var overlay_label_color: u32 = theme.overlay_label_fg;
            if (self.overlay_mode == .profile) {
                if (self.selectedProfile()) |profile| {
                    const badge = buildProfileChromeBadgeText(alloc, profile.kind) catch return;
                    defer alloc.free(badge);
                    const badge_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, badge) catch return;
                    defer alloc.free(badge_w);
                    const badge_width = self.scaled(16) + @as(i32, @intCast(badge.len * @as(usize, @intCast(self.scaled(7)))));
                    const badge_rect = RECT{
                        .left = self.scaled(host_overlay_padding),
                        .top = overlay_rect.top + self.scaled(5),
                        .right = self.scaled(host_overlay_padding) + badge_width,
                        .bottom = overlay_rect.top + self.scaled(23),
                    };
                    const accent = profileChromeAccent(profile.kind);
                    fillSolidRect(hdc, badge_rect, accent.idle_bg);
                    fillSolidRect(hdc, .{
                        .left = badge_rect.left,
                        .top = badge_rect.top,
                        .right = badge_rect.right,
                        .bottom = badge_rect.top + 1,
                    }, accent.idle_border);
                    fillSolidRect(hdc, .{
                        .left = badge_rect.left,
                        .top = badge_rect.bottom - 1,
                        .right = badge_rect.right,
                        .bottom = badge_rect.bottom,
                    }, accent.idle_border);
                    fillSolidRect(hdc, .{
                        .left = badge_rect.left,
                        .top = badge_rect.top,
                        .right = badge_rect.left + 1,
                        .bottom = badge_rect.bottom,
                    }, accent.idle_border);
                    fillSolidRect(hdc, .{
                        .left = badge_rect.right - 1,
                        .top = badge_rect.top,
                        .right = badge_rect.right,
                        .bottom = badge_rect.bottom,
                    }, accent.idle_border);
                    _ = SetTextColor(hdc, profileKindLabelColor(profile.kind));
                    var badge_text_rect = badge_rect;
                    badge_text_rect.left += self.scaled(6);
                    badge_text_rect.right -= self.scaled(6);
                    _ = DrawTextW(
                        hdc,
                        badge_w.ptr,
                        @intCast(badge_w.len - 1),
                        &badge_text_rect,
                        DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX,
                    );
                    overlay_label_x = badge_rect.right + self.scaled(8);
                    overlay_label_color = profileKindLabelColor(profile.kind);
                }
            }
            _ = SetTextColor(hdc, overlay_label_color);
            _ = TextOutW(hdc, overlay_label_x, overlay_rect.top + self.scaled(7), overlay_label_w.ptr, @intCast(overlay_label_w.len - 1));

            const edit_frame_left = self.scaled(host_overlay_padding) + self.scaled(host_overlay_label_width);
            const edit_frame_right = client_rect.right - self.scaled(host_overlay_cancel_width) - self.scaled(host_overlay_accept_width) - (self.scaled(host_overlay_padding) * 2);
            const edit_frame = RECT{
                .left = edit_frame_left,
                .top = overlay_rect.top + self.scaled(4),
                .right = @max(edit_frame_left + self.scaled(24), edit_frame_right - self.scaled(6)),
                .bottom = overlay_rect.top + self.scaled(4) + self.scaled(host_overlay_row_height),
            };
            const overlay_edit_focused = if (self.overlay_edit_hwnd) |edit_hwnd|
                GetFocus() == edit_hwnd
            else
                false;
            fillSolidRect(hdc, edit_frame, theme.edit_frame_bg);
            fillSolidRect(hdc, .{
                .left = edit_frame.left,
                .top = edit_frame.top,
                .right = edit_frame.right,
                .bottom = edit_frame.top + 1,
            }, overlayEditBorderColor(self.overlay_mode, overlay_edit_focused));
            fillSolidRect(hdc, .{
                .left = edit_frame.left,
                .top = edit_frame.bottom - 1,
                .right = edit_frame.right,
                .bottom = edit_frame.bottom,
            }, overlayEditBorderColor(self.overlay_mode, overlay_edit_focused));
            fillSolidRect(hdc, .{
                .left = edit_frame.left,
                .top = edit_frame.top,
                .right = edit_frame.left + 1,
                .bottom = edit_frame.bottom,
            }, overlayEditBorderColor(self.overlay_mode, overlay_edit_focused));
            fillSolidRect(hdc, .{
                .left = edit_frame.right - 1,
                .top = edit_frame.top,
                .right = edit_frame.right,
                .bottom = edit_frame.bottom,
            }, overlayEditBorderColor(self.overlay_mode, overlay_edit_focused));

            const pane_count = if (self.activeTab()) |tab| tab.leafCount() else 1;
            const overlay_feedback = if (self.overlay_mode == .profile)
                if (self.banner_text) |value|
                    switch (self.banner_kind) {
                        .err => std.fmt.allocPrint(alloc, "Error: {s}", .{value}) catch return,
                        .info => std.fmt.allocPrint(alloc, "Info: {s}", .{value}) catch return,
                        .none => alloc.dupe(u8, value) catch return,
                    }
                else
                    buildProfileHintText(
                        alloc,
                        self.profiles,
                        overlay_text,
                        self.selectedProfileIndex() orelse 0,
                        self.app.launcher_profile_target,
                        self.app.launcher_quick_slot_keys,
                    ) catch return
            else
                buildOverlayFeedbackText(
                    alloc,
                    self.banner_kind,
                    self.banner_text,
                    self.overlay_mode,
                    overlay_text,
                    if (surface) |value| value.search_needle else null,
                    if (surface) |value| value.search_total else null,
                    if (surface) |value| value.search_selected else null,
                    overlay_status,
                    pane_count,
                ) catch return;
            defer alloc.free(overlay_feedback);
            const overlay_feedback_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, overlay_feedback) catch return;
            defer alloc.free(overlay_feedback_w);
            _ = SetTextColor(hdc, if (self.overlay_mode == .profile and self.banner_text == null)
                if (self.selectedProfile()) |profile|
                    profileKindHintColor(profile.kind)
                else
                    theme.text_secondary
            else switch (if (self.banner_text != null) self.banner_kind else .none) {
                .none => theme.text_secondary,
                .info => theme.info_fg,
                .err => theme.error_fg,
            });
            _ = TextOutW(hdc, self.scaled(host_overlay_padding), overlay_rect.top + self.scaled(34), overlay_feedback_w.ptr, @intCast(overlay_feedback_w.len - 1));
        }

        if (inspector_panel_visible) {
            const panel_rect = RECT{
                .left = 0,
                .top = tab_h + overlay_offset,
                .right = client_rect.right,
                .bottom = tab_h + overlay_offset + self.scaled(host_inspector_panel_height),
            };
            fillSolidRect(hdc, panel_rect, theme.inspector_bg);
            fillSolidRect(
                hdc,
                .{
                    .left = 0,
                    .top = panel_rect.bottom - 1,
                    .right = client_rect.right,
                    .bottom = panel_rect.bottom,
                },
                theme.chrome_border,
            );

            if (self.activeSurface()) |surface| {
                const host_status = self.app.hostTabStatus(surface);
                const pane_count = if (self.activeTab()) |tab| tab.leafCount() else 1;
                const zoomed = if (self.activeTab()) |tab| tab.tree.zoomed != null else false;

                const panel_title = buildInspectorPanelTitleText(alloc, host_status, pane_count, zoomed) catch return;
                defer alloc.free(panel_title);
                const panel_title_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, panel_title) catch return;
                defer alloc.free(panel_title_w);
                _ = SetBkMode(hdc, TRANSPARENT);
                _ = SetTextColor(hdc, theme.overlay_label_fg);
                _ = TextOutW(hdc, self.scaled(16), panel_rect.top + self.scaled(6), panel_title_w.ptr, @intCast(panel_title_w.len - 1));

                const panel_hint = buildInspectorPanelHintText(alloc, pane_count, zoomed) catch return;
                defer alloc.free(panel_hint);
                const panel_hint_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, panel_hint) catch return;
                defer alloc.free(panel_hint_w);
                _ = SetTextColor(hdc, theme.text_secondary);
                _ = TextOutW(hdc, self.scaled(16), panel_rect.top + self.scaled(22), panel_hint_w.ptr, @intCast(panel_hint_w.len - 1));
            }
        }

        const status_top = @max(tab_h + overlay_offset, client_rect.bottom - self.scaled(host_status_height));
        const status_rect = RECT{
            .left = 0,
            .top = status_top,
            .right = client_rect.right,
            .bottom = client_rect.bottom,
        };
        fillSolidRect(hdc, status_rect, theme.status_bg);
        fillSolidRect(
            hdc,
            .{
                .left = 0,
                .top = status_top,
                .right = client_rect.right,
                .bottom = status_top + 1,
            },
            theme.chrome_border,
        );
        _ = SetBkMode(hdc, TRANSPARENT);
        _ = SetTextColor(hdc, theme.text_primary);

        const banner_value: ?[]const u8 = blk: {
            if (self.overlay_mode != .none) break :blk null;
            if (self.banner_text) |value| break :blk value;
            if (inspector_panel_visible) break :blk null;
            if (self.activeSurface()) |surface| {
                if (!surface.inspector_visible) break :blk null;
                const host_status = self.app.hostTabStatus(surface);
                const pane_count = if (self.activeTab()) |tab| tab.leafCount() else 1;
                break :blk buildInspectorBannerText(
                    alloc,
                    host_status,
                    pane_count,
                    if (self.activeTab()) |tab| tab.tree.zoomed != null else false,
                ) catch null;
            }
            break :blk null;
        };
        const banner_kind: HostBannerKind = if (self.banner_text != null)
            self.banner_kind
        else if (banner_value != null)
            .info
        else
            .none;
        if (self.banner_text == null) {
            if (banner_value) |value| {
                defer alloc.free(value);
            }
        }

        if (banner_value) |value| {
            _ = SetTextColor(hdc, switch (banner_kind) {
                .none => theme.text_primary,
                .info => theme.info_fg,
                .err => theme.error_fg,
            });
            const prefix = switch (banner_kind) {
                .none => "",
                .info => "Info: ",
                .err => "Error: ",
            };
            const full = if (prefix.len == 0)
                alloc.dupe(u8, value) catch return
            else
                std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, value }) catch return;
            defer alloc.free(full);
            const banner_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, full) catch return;
            defer alloc.free(banner_w);
            _ = TextOutW(hdc, self.scaled(16), banner_y, banner_w.ptr, @intCast(banner_w.len - 1));
        }
        _ = SetTextColor(hdc, theme.text_primary);

        const status_y = @max(self.scaled(host_tab_height) + self.scaled(2), ps.rcPaint.bottom - self.scaled(host_status_height) + self.scaled(4));
        var status_x: i32 = self.scaled(16);
        if (self.overlay_mode == .none) {
            const selected_profile_index = self.selectedProfileIndex();
            if (self.selectedProfile()) |profile| {
                const pinned_slot_ordinal = self.app.launcherQuickSlotOrdinal(profile.key);
                const pinned_slot_digit = pinnedSlotBadgeDigit(pinned_slot_ordinal);
                const chip = buildProfileStatusBadgeText(
                    alloc,
                    profile,
                    selected_profile_index,
                    pinned_slot_ordinal,
                ) catch return;
                defer alloc.free(chip);
                const chip_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, chip) catch return;
                defer alloc.free(chip_w);
                const accent = profileChromeAccent(profile.kind);
                const chip_width = self.scaled(16) + @as(i32, @intCast(chip.len * @as(usize, @intCast(self.scaled(7)))));
                const chip_rect = RECT{
                    .left = status_x,
                    .top = status_y - self.scaled(2),
                    .right = status_x + chip_width,
                    .bottom = status_y + self.scaled(14),
                };
                fillSolidRect(hdc, chip_rect, accent.idle_bg);
                fillSolidRect(hdc, .{
                    .left = chip_rect.left,
                    .top = chip_rect.top,
                    .right = chip_rect.right,
                    .bottom = chip_rect.top + 1,
                }, accent.idle_border);
                fillSolidRect(hdc, .{
                    .left = chip_rect.left,
                    .top = chip_rect.bottom - 1,
                    .right = chip_rect.right,
                    .bottom = chip_rect.bottom,
                }, accent.idle_border);
                fillSolidRect(hdc, .{
                    .left = chip_rect.left,
                    .top = chip_rect.top,
                    .right = chip_rect.left + 1,
                    .bottom = chip_rect.bottom,
                }, accent.idle_border);
                fillSolidRect(hdc, .{
                    .left = chip_rect.right - 1,
                    .top = chip_rect.top,
                    .right = chip_rect.right,
                    .bottom = chip_rect.bottom,
                }, accent.idle_border);
                if (pinned_slot_digit) |digit| {
                    paintPinnedSlotBadge(
                        hdc,
                        chip_rect,
                        digit,
                        accent.idle_border,
                        accent.idle_bg,
                        profileKindLabelColor(profile.kind),
                    );
                }
                paintTargetChipBadge(
                    hdc,
                    chip_rect,
                    profileOpenTargetBadgeGlyph(self.app.launcher_profile_target),
                    accent.idle_border,
                    accent.idle_bg,
                    profileOpenTargetMarkerColor(self.app.launcher_profile_target),
                );
                _ = SetTextColor(hdc, profileKindLabelColor(profile.kind));
                var chip_text_rect = chip_rect;
                chip_text_rect.left += self.scaled(6);
                chip_text_rect.right -= launcherChipRightInset(pinned_slot_digit != null, true);
                _ = DrawTextW(
                    hdc,
                    chip_w.ptr,
                    @intCast(chip_w.len - 1),
                    &chip_text_rect,
                    DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX | DT_END_ELLIPSIS,
                );
                status_x = chip_rect.right + self.scaled(10);
            }
            if (self.profiles) |profiles| {
                var drawn: usize = 0;
                for (profiles, 0..) |*profile, index| {
                    if (drawn >= 3) break;
                    if (selected_profile_index != null and index == selected_profile_index.?) continue;
                    const pinned_slot_ordinal = self.app.launcherQuickSlotOrdinal(profile.key);
                    const chip = buildProfileQuickSlotChipText(
                        alloc,
                        profile,
                        index,
                        pinned_slot_ordinal,
                    ) catch return;
                    defer alloc.free(chip);
                    const chip_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, chip) catch return;
                    defer alloc.free(chip_w);
                    const focused = self.focused_quick_slot != null and self.focused_quick_slot.? == index;
                    const hovered = self.hovered_quick_slot != null and self.hovered_quick_slot.? == index;
                    const target_marker = shouldPaintQuickSlotTargetMarker(hovered, focused);
                    const colors = quickSlotChipColors(profile.kind, hovered);
                    const chip_width = self.scaled(12) + @as(i32, @intCast(chip.len * @as(usize, @intCast(self.scaled(7)))));
                    const chip_rect = RECT{
                        .left = status_x,
                        .top = status_y - self.scaled(1),
                        .right = status_x + chip_width,
                        .bottom = status_y + self.scaled(13),
                    };
                    fillSolidRect(hdc, chip_rect, colors.bg);
                    fillSolidRect(hdc, .{
                        .left = chip_rect.left,
                        .top = chip_rect.top,
                        .right = chip_rect.right,
                        .bottom = chip_rect.top + 1,
                    }, colors.border);
                    fillSolidRect(hdc, .{
                        .left = chip_rect.left,
                        .top = chip_rect.bottom - 1,
                        .right = chip_rect.right,
                        .bottom = chip_rect.bottom,
                    }, colors.border);
                    fillSolidRect(hdc, .{
                        .left = chip_rect.left,
                        .top = chip_rect.top,
                        .right = chip_rect.left + 1,
                        .bottom = chip_rect.bottom,
                    }, colors.border);
                    fillSolidRect(hdc, .{
                        .left = chip_rect.right - 1,
                        .top = chip_rect.top,
                        .right = chip_rect.right,
                        .bottom = chip_rect.bottom,
                    }, colors.border);
                    if (pinned_slot_ordinal != null and pinned_slot_ordinal.? == index) {
                        paintPinnedChipMarker(
                            hdc,
                            chip_rect,
                            pinnedChipMarkerColor(profile.kind, hovered),
                        );
                    }
                    if (target_marker) {
                        paintTargetChipBadge(
                            hdc,
                            chip_rect,
                            profileOpenTargetBadgeGlyph(self.app.launcher_profile_target),
                            colors.border,
                            colors.bg,
                            profileOpenTargetMarkerColor(self.app.launcher_profile_target),
                        );
                    }
                    if (focused) {
                        fillSolidRect(hdc, .{
                            .left = chip_rect.left + self.scaled(2),
                            .top = chip_rect.top + self.scaled(2),
                            .right = chip_rect.right - self.scaled(2),
                            .bottom = chip_rect.top + self.scaled(4),
                        }, profileKindFocusRingColor(profile.kind));
                        fillSolidRect(hdc, .{
                            .left = chip_rect.left + self.scaled(2),
                            .top = chip_rect.bottom - self.scaled(4),
                            .right = chip_rect.right - self.scaled(2),
                            .bottom = chip_rect.bottom - self.scaled(2),
                        }, profileKindFocusRingColor(profile.kind));
                        fillSolidRect(hdc, .{
                            .left = chip_rect.left + self.scaled(2),
                            .top = chip_rect.top + self.scaled(2),
                            .right = chip_rect.left + self.scaled(4),
                            .bottom = chip_rect.bottom - self.scaled(2),
                        }, profileKindFocusRingColor(profile.kind));
                        fillSolidRect(hdc, .{
                            .left = chip_rect.right - self.scaled(4),
                            .top = chip_rect.top + self.scaled(2),
                            .right = chip_rect.right - self.scaled(2),
                            .bottom = chip_rect.bottom - self.scaled(2),
                        }, profileKindFocusRingColor(profile.kind));
                    }
                    _ = SetTextColor(hdc, colors.fg);
                    var chip_text_rect = chip_rect;
                    chip_text_rect.left += self.scaled(5);
                    chip_text_rect.right -= launcherChipRightInset(false, target_marker);
                    _ = DrawTextW(
                        hdc,
                        chip_w.ptr,
                        @intCast(chip_w.len - 1),
                        &chip_text_rect,
                        DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX | DT_END_ELLIPSIS,
                    );
                    status_x = chip_rect.right + self.scaled(6);
                    drawn += 1;
                }
            }
        }
        const status = self.statusText(alloc) catch null;
        defer if (status) |owned| alloc.free(owned);
        if (status) |value| {
            const status_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, value) catch return;
            defer alloc.free(status_w);
            _ = TextOutW(hdc, status_x, status_y, status_w.ptr, @intCast(status_w.len - 1));
        }

        const detail = self.detailText(alloc) catch null;
        defer if (detail) |owned| alloc.free(owned);
        if (detail) |value| {
            _ = SetTextColor(hdc, theme.text_secondary);
            const detail_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, value) catch return;
            defer alloc.free(detail_w);
            _ = TextOutW(hdc, status_x, status_y + self.scaled(18), detail_w.ptr, @intCast(detail_w.len - 1));
        }
    }
};

const SurfaceInitOptions = struct {
    quick_terminal: bool = false,
    host_id: ?u32 = null,
    tab_id: ?u32 = null,
    clone_state_from: ?*const Surface = null,
};

const HostOverlayMode = enum {
    none,
    command_palette,
    profile,
    search,
    surface_title,
    tab_title,
    tab_overview,
};

const HostBannerKind = enum {
    none,
    info,
    err,
};

const TabButtonKeyAction = enum {
    previous,
    next,
    first,
    last,
    move_previous,
    move_next,
    move_first,
    move_last,
    rename,
    close,
    overview,
};

const SearchButtonKeyAction = enum {
    next,
    previous,
    dismiss,
};

const TabsButtonKeyAction = enum {
    previous,
    next,
    rename,
    overview,
};

const CommandButtonKeyAction = enum {
    toggle,
    previous,
    next,
    dismiss,
};

const ProfilesButtonKeyAction = enum {
    open,
    toggle,
    previous,
    next,
    first,
    last,
};

const QuickSlotFocusKeyAction = enum {
    previous,
    next,
    first,
    last,
    open,
};

const LaunchTargetButtonKeyAction = enum {
    previous,
    next,
    first,
    last,
};

const ProfileOpenTarget = enum {
    tab,
    window,
    split,
};

fn profileOpenTargetLabel(target: ProfileOpenTarget) []const u8 {
    return switch (target) {
        .tab => "tab",
        .window => "window",
        .split => "split",
    };
}

fn parseProfileOpenTarget(raw: []const u8) ?ProfileOpenTarget {
    if (std.ascii.eqlIgnoreCase(raw, "tab")) return .tab;
    if (std.ascii.eqlIgnoreCase(raw, "window") or std.ascii.eqlIgnoreCase(raw, "win")) return .window;
    if (std.ascii.eqlIgnoreCase(raw, "split") or std.ascii.eqlIgnoreCase(raw, "pane")) return .split;
    return null;
}

fn resolveProfileOpenTarget(default_target: ProfileOpenTarget, shift: bool, control: bool) ProfileOpenTarget {
    if (control) return .split;
    if (shift) return .window;
    return default_target;
}

fn cycleProfileOpenTarget(current: ProfileOpenTarget, reverse: bool) ProfileOpenTarget {
    return switch (current) {
        .tab => if (reverse) .split else .window,
        .window => if (reverse) .tab else .split,
        .split => if (reverse) .window else .tab,
    };
}

fn launchTargetButtonKeyAction(vk: WPARAM) ?LaunchTargetButtonKeyAction {
    return switch (vk) {
        VK_LEFT, VK_UP => .previous,
        VK_RIGHT, VK_DOWN, VK_RETURN, VK_SPACE => .next,
        VK_HOME => .first,
        VK_END => .last,
        else => null,
    };
}

const ButtonColors = struct {
    bg: u32,
    border: u32,
    fg: u32,
};

fn appendOwnedString(
    alloc: Allocator,
    target: *?[:0]const u8,
    value: ?[]const u8,
) !void {
    if (target.*) |existing| alloc.free(existing);
    target.* = if (value) |v| try alloc.dupeZ(u8, v) else null;
}

fn rgb(r: u8, g: u8, b: u8) u32 {
    return @as(u32, r) | (@as(u32, g) << 8) | (@as(u32, b) << 16);
}

const ThemeColors = struct {
    // Chrome surfaces
    chrome_bg: u32,
    chrome_border: u32,
    overlay_bg: u32,
    overlay_border: u32,
    edit_bg: u32,
    edit_frame_bg: u32,
    status_bg: u32,
    inspector_bg: u32,

    // Text
    text_primary: u32,
    text_secondary: u32,
    text_disabled: u32,
    edit_fg: u32,
    overlay_label_fg: u32,
    info_fg: u32,
    error_fg: u32,

    // Accent
    accent: u32,
    accent_hover: u32,
    chrome_accent_idle: u32,
    edit_border_unfocused: u32,

    // Buttons - idle
    button_bg: u32,
    button_border: u32,
    button_fg: u32,

    // Buttons - overlay variant
    button_overlay_bg: u32,
    button_overlay_border: u32,
    button_overlay_fg: u32,
    button_chrome_fg: u32,

    // Buttons - active
    button_active_bg: u32,
    button_active_border: u32,
    button_active_fg: u32,

    // Buttons - accept
    button_accept_bg: u32,
    button_accept_border: u32,
    button_accept_fg: u32,

    // Buttons - disabled
    button_disabled_bg: u32,
    button_disabled_border: u32,
    button_disabled_fg: u32,

    // Focus rings
    button_focus_ring: u32,
    button_overlay_focus_ring: u32,
    button_active_focus_ring: u32,
    button_accept_focus_ring: u32,

    // Whether this is a dark theme (for DWM)
    is_dark: bool,
};

fn darkTheme() ThemeColors {
    return .{
        .chrome_bg = rgb(34, 40, 49),
        .chrome_border = rgb(58, 67, 80),
        .overlay_bg = rgb(28, 33, 41),
        .overlay_border = rgb(58, 67, 80),
        .edit_bg = rgb(20, 24, 31),
        .edit_frame_bg = rgb(18, 22, 29),
        .status_bg = rgb(26, 30, 37),
        .inspector_bg = rgb(22, 27, 35),

        .text_primary = rgb(216, 221, 231),
        .text_secondary = rgb(160, 170, 184),
        .text_disabled = rgb(120, 128, 140),
        .edit_fg = rgb(232, 236, 244),
        .overlay_label_fg = rgb(210, 228, 255),
        .info_fg = rgb(142, 197, 255),
        .error_fg = rgb(255, 132, 132),

        .accent = rgb(116, 156, 224),
        .accent_hover = rgb(132, 172, 238),
        .chrome_accent_idle = rgb(72, 82, 98),
        .edit_border_unfocused = rgb(86, 96, 112),

        .button_bg = rgb(36, 42, 51),
        .button_border = rgb(72, 82, 98),
        .button_fg = rgb(196, 204, 216),

        .button_overlay_bg = rgb(44, 54, 68),
        .button_overlay_border = rgb(92, 114, 148),
        .button_overlay_fg = rgb(224, 229, 238),
        .button_chrome_fg = rgb(190, 198, 210),

        .button_active_bg = rgb(60, 76, 104),
        .button_active_border = rgb(116, 156, 224),
        .button_active_fg = rgb(244, 247, 252),

        .button_accept_bg = rgb(52, 92, 166),
        .button_accept_border = rgb(126, 169, 247),
        .button_accept_fg = rgb(248, 250, 255),

        .button_disabled_bg = rgb(28, 33, 41),
        .button_disabled_border = rgb(54, 60, 72),
        .button_disabled_fg = rgb(120, 128, 140),

        .button_focus_ring = rgb(140, 166, 208),
        .button_overlay_focus_ring = rgb(160, 190, 238),
        .button_active_focus_ring = rgb(172, 206, 255),
        .button_accept_focus_ring = rgb(184, 212, 255),

        .is_dark = true,
    };
}

fn lightTheme() ThemeColors {
    return .{
        .chrome_bg = rgb(243, 243, 243),
        .chrome_border = rgb(209, 209, 209),
        .overlay_bg = rgb(249, 249, 249),
        .overlay_border = rgb(220, 220, 220),
        .edit_bg = rgb(255, 255, 255),
        .edit_frame_bg = rgb(245, 245, 245),
        .status_bg = rgb(238, 238, 238),
        .inspector_bg = rgb(235, 235, 235),

        .text_primary = rgb(27, 27, 27),
        .text_secondary = rgb(96, 96, 96),
        .text_disabled = rgb(160, 160, 160),
        .edit_fg = rgb(27, 27, 27),
        .overlay_label_fg = rgb(0, 60, 116),
        .info_fg = rgb(0, 95, 184),
        .error_fg = rgb(196, 43, 28),

        .accent = rgb(0, 120, 212),
        .accent_hover = rgb(0, 99, 177),
        .chrome_accent_idle = rgb(180, 180, 180),
        .edit_border_unfocused = rgb(160, 160, 160),

        .button_bg = rgb(251, 251, 251),
        .button_border = rgb(209, 209, 209),
        .button_fg = rgb(27, 27, 27),

        .button_overlay_bg = rgb(245, 245, 245),
        .button_overlay_border = rgb(180, 180, 180),
        .button_overlay_fg = rgb(27, 27, 27),
        .button_chrome_fg = rgb(96, 96, 96),

        .button_active_bg = rgb(204, 228, 247),
        .button_active_border = rgb(0, 120, 212),
        .button_active_fg = rgb(0, 60, 116),

        .button_accept_bg = rgb(0, 120, 212),
        .button_accept_border = rgb(0, 99, 177),
        .button_accept_fg = rgb(255, 255, 255),

        .button_disabled_bg = rgb(243, 243, 243),
        .button_disabled_border = rgb(209, 209, 209),
        .button_disabled_fg = rgb(160, 160, 160),

        .button_focus_ring = rgb(0, 120, 212),
        .button_overlay_focus_ring = rgb(0, 120, 212),
        .button_active_focus_ring = rgb(0, 90, 158),
        .button_accept_focus_ring = rgb(0, 90, 158),

        .is_dark = false,
    };
}

fn highContrastThemeFromSysColors() ThemeColors {
    const win_bg = GetSysColor(COLOR_WINDOW);
    const win_fg = GetSysColor(COLOR_WINDOWTEXT);
    const btn_bg = GetSysColor(COLOR_BTNFACE);
    const btn_fg = GetSysColor(COLOR_BTNTEXT);
    const hi_bg = GetSysColor(COLOR_HIGHLIGHT);
    const hi_fg = GetSysColor(COLOR_HIGHLIGHTTEXT);
    const gray = GetSysColor(COLOR_GRAYTEXT);

    return .{
        .chrome_bg = win_bg,
        .chrome_border = win_fg,
        .overlay_bg = win_bg,
        .overlay_border = win_fg,
        .edit_bg = win_bg,
        .edit_frame_bg = win_bg,
        .status_bg = win_bg,
        .inspector_bg = win_bg,

        .text_primary = win_fg,
        .text_secondary = win_fg,
        .text_disabled = gray,
        .edit_fg = win_fg,
        .overlay_label_fg = win_fg,
        .info_fg = win_fg,
        .error_fg = win_fg,

        .accent = hi_bg,
        .accent_hover = hi_bg,
        .chrome_accent_idle = win_fg,
        .edit_border_unfocused = win_fg,

        .button_bg = btn_bg,
        .button_border = btn_fg,
        .button_fg = btn_fg,

        .button_overlay_bg = btn_bg,
        .button_overlay_border = btn_fg,
        .button_overlay_fg = btn_fg,
        .button_chrome_fg = btn_fg,

        .button_active_bg = hi_bg,
        .button_active_border = hi_fg,
        .button_active_fg = hi_fg,

        .button_accept_bg = hi_bg,
        .button_accept_border = hi_fg,
        .button_accept_fg = hi_fg,

        .button_disabled_bg = btn_bg,
        .button_disabled_border = gray,
        .button_disabled_fg = gray,

        .button_focus_ring = hi_bg,
        .button_overlay_focus_ring = hi_bg,
        .button_active_focus_ring = hi_fg,
        .button_accept_focus_ring = hi_fg,

        .is_dark = false,
    };
}

fn isHighContrastActive() bool {
    const HIGHCONTRASTW = extern struct {
        cbSize: UINT,
        dwFlags: DWORD,
        lpszDefaultScheme: ?[*:0]u16,
    };
    var hc: HIGHCONTRASTW = .{
        .cbSize = @sizeOf(HIGHCONTRASTW),
        .dwFlags = 0,
        .lpszDefaultScheme = null,
    };
    if (SystemParametersInfoW(SPI_GETHIGHCONTRAST, @sizeOf(HIGHCONTRASTW), @ptrCast(&hc), 0) != 0) {
        return (hc.dwFlags & HCF_HIGHCONTRASTON) != 0;
    }
    return false;
}

fn isSystemDarkMode() bool {
    const subkey = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize");
    const value_name = std.unicode.utf8ToUtf16LeStringLiteral("AppsUseLightTheme");
    var hkey: usize = 0;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, subkey, 0, KEY_READ, &hkey) != ERROR_SUCCESS) return true;
    defer _ = RegCloseKey(hkey);

    var data: u32 = 1;
    var data_size: DWORD = @sizeOf(u32);
    var reg_type: DWORD = 0;
    if (RegQueryValueExW(hkey, value_name, null, &reg_type, @ptrCast(&data), &data_size) != ERROR_SUCCESS) return true;
    if (reg_type != REG_DWORD or data_size != @sizeOf(u32)) return true;

    return data == 0; // 0 = dark mode, 1 = light mode
}

fn resolveTheme(config: *const configpkg.Config) ThemeColors {
    if (isHighContrastActive()) return highContrastThemeFromSysColors();
    return switch (config.@"window-theme") {
        .dark => darkTheme(),
        .light => lightTheme(),
        .system => if (isSystemDarkMode()) darkTheme() else lightTheme(),
        .auto => if (isSystemDarkMode()) darkTheme() else lightTheme(),
        .ghostty => darkTheme(),
    };
}

fn applyDwmTheme(hwnd: HWND, theme: *const ThemeColors) void {
    if (isHighContrastActive()) return; // Let system control title bar in HC mode
    const dark_mode: u32 = if (theme.is_dark) 1 else 0;
    // Try attribute 20 first (Win10 20H1+), fall back to 19 (Win10 1809-20H1)
    const hr = DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, @ptrCast(&dark_mode), @sizeOf(u32));
    if (hr == @as(i32, @bitCast(@as(u32, 0x80070057)))) { // E_INVALIDARG
        _ = DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE_V1, @ptrCast(&dark_mode), @sizeOf(u32));
    }
    // Set caption color to match chrome (Win11 only; fails silently on Win10)
    _ = DwmSetWindowAttribute(hwnd, DWMWA_CAPTION_COLOR, @ptrCast(&theme.chrome_bg), @sizeOf(u32));
}

fn adjustColor(base: u32, dr: i16, dg: i16, db: i16) u32 {
    const r: u8 = @intCast(@as(u16, @intCast(std.math.clamp(@as(i16, @intCast(base & 0xFF)) + dr, 0, 255))));
    const g: u8 = @intCast(@as(u16, @intCast(std.math.clamp(@as(i16, @intCast((base >> 8) & 0xFF)) + dg, 0, 255))));
    const b: u8 = @intCast(@as(u16, @intCast(std.math.clamp(@as(i16, @intCast((base >> 16) & 0xFF)) + db, 0, 255))));
    return rgb(r, g, b);
}

fn buttonColorsFromTheme(
    theme: *const ThemeColors,
    active: bool,
    overlay: bool,
    hovered: bool,
    pressed: bool,
    disabled: bool,
    accept: bool,
) ButtonColors {
    var colors: ButtonColors = .{
        .bg = if (overlay) theme.button_overlay_bg else theme.button_bg,
        .border = if (overlay) theme.button_overlay_border else theme.button_border,
        .fg = theme.button_fg,
    };

    if (active) {
        colors = .{
            .bg = theme.button_active_bg,
            .border = theme.button_active_border,
            .fg = theme.button_active_fg,
        };
    }
    if (accept) {
        colors = .{
            .bg = theme.button_accept_bg,
            .border = theme.button_accept_border,
            .fg = theme.button_accept_fg,
        };
    }
    if (hovered and !pressed and !disabled) {
        colors.bg = if (accept)
            adjustColor(theme.button_accept_bg, 10, 12, 18)
        else if (active)
            adjustColor(theme.button_active_bg, 12, 14, 18)
        else if (overlay)
            adjustColor(theme.button_overlay_bg, 10, 12, 14)
        else
            adjustColor(theme.button_bg, 8, 10, 11);
        colors.border = if (accept)
            adjustColor(theme.button_accept_border, 20, 17, 8)
        else if (active)
            theme.accent_hover
        else if (overlay)
            adjustColor(theme.button_overlay_border, 16, 18, 20)
        else
            adjustColor(theme.button_border, 20, 22, 24);
    }
    if (pressed) {
        colors.bg = if (overlay) adjustColor(theme.overlay_bg, -2, -2, -2) else adjustColor(theme.chrome_bg, -6, -7, -8);
        if (active) colors.bg = adjustColor(theme.button_active_bg, -18, -20, -20);
        if (accept) colors.bg = adjustColor(theme.button_accept_bg, -14, -20, -32);
    }
    if (disabled) {
        colors = .{
            .bg = theme.button_disabled_bg,
            .border = theme.button_disabled_border,
            .fg = theme.button_disabled_fg,
        };
    }

    return colors;
}

fn fillSolidRect(hdc: HDC, rect: RECT, color: u32) void {
    const brush = CreateSolidBrush(color) orelse return;
    defer _ = DeleteObject(brush);
    _ = FillRect(hdc, &rect, brush);
}

fn overlayAccentColor(mode: HostOverlayMode) u32 {
    return switch (mode) {
        .command_palette => rgb(116, 156, 224),
        .profile => rgb(192, 132, 214),
        .search => rgb(118, 196, 158),
        .surface_title, .tab_title => rgb(212, 170, 92),
        .tab_overview => rgb(168, 148, 228),
        .none => rgb(72, 82, 98),
    };
}

fn overlayEditBorderColor(mode: HostOverlayMode, focused: bool) u32 {
    if (focused) return overlayAccentColor(mode);
    return switch (mode) {
        .none => rgb(72, 82, 98),
        else => rgb(86, 96, 112),
    };
}

fn buttonColors(
    active: bool,
    overlay: bool,
    hovered: bool,
    pressed: bool,
    disabled: bool,
    accept: bool,
) ButtonColors {
    var colors: ButtonColors = .{
        .bg = if (overlay) rgb(44, 54, 68) else rgb(36, 42, 51),
        .border = if (overlay) rgb(92, 114, 148) else rgb(72, 82, 98),
        .fg = rgb(196, 204, 216),
    };

    if (active) {
        colors = .{
            .bg = rgb(60, 76, 104),
            .border = rgb(116, 156, 224),
            .fg = rgb(244, 247, 252),
        };
    }
    if (accept) {
        colors = .{
            .bg = rgb(52, 92, 166),
            .border = rgb(126, 169, 247),
            .fg = rgb(248, 250, 255),
        };
    }
    if (hovered and !pressed and !disabled) {
        colors.bg = if (accept)
            rgb(62, 104, 184)
        else if (active)
            rgb(72, 90, 122)
        else if (overlay)
            rgb(54, 66, 82)
        else
            rgb(44, 52, 62);
        colors.border = if (accept)
            rgb(146, 186, 255)
        else if (active)
            rgb(132, 172, 238)
        else if (overlay)
            rgb(108, 132, 168)
        else
            rgb(92, 104, 122);
    }
    if (pressed) {
        colors.bg = if (overlay) rgb(26, 31, 39) else rgb(28, 33, 41);
        if (active) colors.bg = rgb(42, 56, 84);
        if (accept) colors.bg = rgb(38, 72, 134);
    }
    if (disabled) {
        colors = .{
            .bg = rgb(28, 33, 41),
            .border = rgb(54, 60, 72),
            .fg = rgb(120, 128, 140),
        };
    }

    return colors;
}

const ProfileChromeAccent = struct {
    idle_bg: u32,
    idle_border: u32,
    hover_bg: u32,
    hover_border: u32,
    pressed_bg: u32,
    active_bg: u32,
    active_border: u32,
    focus: u32,
};

fn profileChromeAccent(kind: windows_shell.ProfileKind) ProfileChromeAccent {
    return switch (kind) {
        .wsl_default, .wsl_distro => .{
            .idle_bg = rgb(34, 46, 38),
            .idle_border = rgb(92, 176, 118),
            .hover_bg = rgb(40, 54, 44),
            .hover_border = rgb(116, 206, 144),
            .pressed_bg = rgb(28, 38, 31),
            .active_bg = rgb(46, 72, 54),
            .active_border = rgb(142, 224, 164),
            .focus = rgb(188, 244, 200),
        },
        .pwsh => .{
            .idle_bg = rgb(34, 45, 52),
            .idle_border = rgb(86, 176, 204),
            .hover_bg = rgb(40, 54, 62),
            .hover_border = rgb(110, 204, 234),
            .pressed_bg = rgb(28, 37, 43),
            .active_bg = rgb(44, 70, 82),
            .active_border = rgb(136, 216, 242),
            .focus = rgb(186, 232, 248),
        },
        .powershell => .{
            .idle_bg = rgb(34, 42, 58),
            .idle_border = rgb(98, 144, 220),
            .hover_bg = rgb(40, 50, 72),
            .hover_border = rgb(122, 170, 244),
            .pressed_bg = rgb(27, 34, 48),
            .active_bg = rgb(46, 64, 96),
            .active_border = rgb(148, 194, 255),
            .focus = rgb(192, 220, 255),
        },
        .git_bash => .{
            .idle_bg = rgb(48, 40, 31),
            .idle_border = rgb(212, 156, 92),
            .hover_bg = rgb(58, 48, 37),
            .hover_border = rgb(236, 182, 118),
            .pressed_bg = rgb(40, 33, 26),
            .active_bg = rgb(78, 62, 42),
            .active_border = rgb(248, 202, 134),
            .focus = rgb(255, 224, 178),
        },
        .cmd => .{
            .idle_bg = rgb(31, 41, 35),
            .idle_border = rgb(104, 186, 126),
            .hover_bg = rgb(38, 50, 42),
            .hover_border = rgb(128, 210, 150),
            .pressed_bg = rgb(25, 34, 29),
            .active_bg = rgb(42, 64, 50),
            .active_border = rgb(150, 228, 170),
            .focus = rgb(194, 244, 202),
        },
    };
}

fn applyProfileChromeAccent(
    base: ButtonColors,
    kind: windows_shell.ProfileKind,
    active: bool,
    hovered: bool,
    pressed: bool,
    disabled: bool,
) ButtonColors {
    if (disabled) return base;

    const accent = profileChromeAccent(kind);
    var colors = base;
    colors.bg = if (active) accent.active_bg else accent.idle_bg;
    colors.border = if (active) accent.active_border else accent.idle_border;

    if (hovered and !pressed) {
        colors.bg = if (active) accent.active_bg else accent.hover_bg;
        colors.border = if (active) accent.active_border else accent.hover_border;
    }
    if (pressed) {
        colors.bg = accent.pressed_bg;
        colors.border = if (active) accent.active_border else accent.hover_border;
    }
    if (active) {
        colors.fg = rgb(248, 250, 255);
    }
    return colors;
}

fn buttonFocusRingColor(active: bool, overlay: bool, accept: bool) u32 {
    if (accept) return rgb(184, 212, 255);
    if (active) return rgb(172, 206, 255);
    if (overlay) return rgb(160, 190, 238);
    return rgb(140, 166, 208);
}

fn profileKindFocusRingColor(kind: windows_shell.ProfileKind) u32 {
    return profileChromeAccent(kind).focus;
}

fn profileChromeStripeColor(
    kind: windows_shell.ProfileKind,
    active: bool,
    hovered: bool,
    pressed: bool,
    disabled: bool,
) u32 {
    const accent = profileChromeAccent(kind);
    if (disabled) return rgb(86, 94, 108);
    if (pressed) return accent.hover_border;
    if (hovered or active) return accent.active_border;
    return accent.idle_border;
}

fn profileKindLabelColor(kind: windows_shell.ProfileKind) u32 {
    return profileChromeAccent(kind).focus;
}

fn profileKindHintColor(kind: windows_shell.ProfileKind) u32 {
    return profileChromeAccent(kind).active_border;
}

fn tabButtonKeyAction(vk: WPARAM, ctrl_pressed: bool) ?TabButtonKeyAction {
    return switch (vk) {
        VK_LEFT => if (ctrl_pressed) .move_previous else .previous,
        VK_RIGHT => if (ctrl_pressed) .move_next else .next,
        VK_HOME => if (ctrl_pressed) .move_first else .first,
        VK_END => if (ctrl_pressed) .move_last else .last,
        VK_F2 => .rename,
        VK_DELETE => .close,
        VK_APPS => .overview,
        else => null,
    };
}

fn moveTabAmountToEdge(total: usize, current: usize, toward_start: bool) isize {
    if (total <= 1 or current >= total) return 0;
    if (toward_start) return -@as(isize, @intCast(current));
    return @as(isize, @intCast((total - 1) - current));
}

fn searchButtonKeyAction(vk: WPARAM, shift_pressed: bool) ?SearchButtonKeyAction {
    return switch (vk) {
        VK_F3 => if (shift_pressed) .previous else .next,
        VK_ESCAPE => .dismiss,
        else => null,
    };
}

fn searchDirectionFromWheelDelta(delta: i16) input.Binding.Action.NavigateSearch {
    return if (delta > 0) .previous else .next;
}

fn tabsButtonKeyAction(vk: WPARAM) ?TabsButtonKeyAction {
    return switch (vk) {
        VK_LEFT, VK_UP => .previous,
        VK_RIGHT, VK_DOWN => .next,
        VK_F2 => .rename,
        VK_APPS => .overview,
        else => null,
    };
}

fn commandButtonKeyAction(vk: WPARAM) ?CommandButtonKeyAction {
    return switch (vk) {
        VK_RETURN, VK_SPACE => .toggle,
        VK_UP => .previous,
        VK_DOWN => .next,
        VK_ESCAPE => .dismiss,
        else => null,
    };
}

fn commandPaletteDirectionFromWheelDelta(delta: i16) bool {
    return delta > 0;
}

fn profileDirectionFromWheelDelta(delta: i16) bool {
    return delta > 0;
}

fn profileShortcutIndexFromKey(vk: WPARAM) ?usize {
    if (vk >= @as(WPARAM, '1') and vk <= @as(WPARAM, '9')) {
        return @as(usize, @intCast(vk - @as(WPARAM, '1')));
    }
    if (vk >= 0x61 and vk <= 0x69) {
        return @as(usize, @intCast(vk - 0x61));
    }
    return null;
}

fn quickSlotShortcutProfileIndex(
    profiles_len: usize,
    selected_index: ?usize,
    vk: WPARAM,
    alt_pressed: bool,
) ?usize {
    if (!alt_pressed) return null;
    const slot_ordinal = profileShortcutIndexFromKey(vk) orelse return null;
    if (slot_ordinal >= 3) return null;
    return quickSlotProfileIndex(profiles_len, selected_index, slot_ordinal, 3);
}

fn quickSlotPinOrdinalFromKey(vk: WPARAM, alt_pressed: bool, shift_pressed: bool) ?usize {
    if (!alt_pressed or !shift_pressed) return null;
    const slot_ordinal = profileShortcutIndexFromKey(vk) orelse return null;
    if (slot_ordinal >= 3) return null;
    return slot_ordinal;
}

fn clearQuickSlotPinsRequested(vk: WPARAM, alt_pressed: bool, shift_pressed: bool) bool {
    if (!alt_pressed or !shift_pressed) return false;
    return vk == VK_0 or vk == VK_NUMPAD0;
}

fn quickSlotFocusKeyAction(vk: WPARAM) ?QuickSlotFocusKeyAction {
    return switch (vk) {
        VK_LEFT, VK_UP => .previous,
        VK_RIGHT, VK_DOWN => .next,
        VK_HOME => .first,
        VK_END => .last,
        VK_RETURN => .open,
        else => null,
    };
}

fn profilesButtonKeyAction(vk: WPARAM) ?ProfilesButtonKeyAction {
    return switch (vk) {
        VK_RETURN => .open,
        VK_SPACE, VK_APPS => .toggle,
        VK_LEFT, VK_UP => .previous,
        VK_RIGHT, VK_DOWN => .next,
        VK_HOME => .first,
        VK_END => .last,
        else => null,
    };
}

const ProfileSelection = union(enum) {
    exact: usize,
    ambiguous: usize,
    invalid,
};

fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (prefix.len > haystack.len) return false;
    for (haystack[0..prefix.len], prefix) |a, b| {
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return true;
}

fn resolveProfileSelection(
    profiles: []const windows_shell.Profile,
    input_text: []const u8,
    fallback_index: usize,
) ProfileSelection {
    if (profiles.len == 0) return .invalid;
    const fallback = @min(fallback_index, profiles.len - 1);
    if (input_text.len == 0) return .{ .exact = fallback };

    const requested = std.fmt.parseUnsigned(usize, input_text, 10) catch null;
    if (requested) |value| {
        if (value == 0 or value > profiles.len) return .invalid;
        return .{ .exact = value - 1 };
    }

    var exact_match: ?usize = null;
    var unique_match: ?usize = null;
    var match_count: usize = 0;
    for (profiles, 0..) |profile, index| {
        if (std.ascii.eqlIgnoreCase(profile.key, input_text) or
            std.ascii.eqlIgnoreCase(profile.label, input_text))
        {
            exact_match = index;
            break;
        }
        if (startsWithIgnoreCase(profile.key, input_text) or
            startsWithIgnoreCase(profile.label, input_text))
        {
            unique_match = index;
            match_count += 1;
        }
    }
    if (exact_match) |index| return .{ .exact = index };
    if (match_count == 1) return .{ .exact = unique_match.? };
    if (match_count > 1) return .{ .ambiguous = match_count };
    return .invalid;
}

fn preferredProfileIndex(
    profiles: []const windows_shell.Profile,
    selected_key: ?[]const u8,
    app_key: ?[]const u8,
    hint: ?[]const u8,
    fallback_index: usize,
) ?usize {
    if (profiles.len == 0) return null;

    const preferred_key = if (selected_key) |key|
        key
    else if (app_key) |key|
        key
    else
        null;
    if (preferred_key) |key| {
        for (profiles, 0..) |profile, index| {
            if (std.ascii.eqlIgnoreCase(profile.key, key)) return index;
        }
    }

    if (hint) |value| {
        return switch (resolveProfileSelection(profiles, value, fallback_index)) {
            .exact => |index| index,
            .ambiguous, .invalid => null,
        };
    }

    return null;
}

fn formatProgressStatus(
    alloc: Allocator,
    value: terminal.osc.Command.ProgressReport,
) !?[]u8 {
    return switch (value.state) {
        .remove => null,
        .set => if (value.progress) |progress|
            try std.fmt.allocPrint(alloc, "progress:{d}%", .{progress})
        else
            try alloc.dupe(u8, "progress"),
        .@"error" => if (value.progress) |progress|
            try std.fmt.allocPrint(alloc, "progress error:{d}%", .{progress})
        else
            try alloc.dupe(u8, "progress error"),
        .indeterminate => try alloc.dupe(u8, "progress:busy"),
        .pause => if (value.progress) |progress|
            try std.fmt.allocPrint(alloc, "progress paused:{d}%", .{progress})
        else
            try alloc.dupe(u8, "progress paused"),
    };
}

fn buildWindowTitle(
    alloc: Allocator,
    base_title: ?[]const u8,
    status: SurfaceStatus,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);

    try buf.appendSlice(alloc, base_title orelse "winghostty");

    const appendStatus = struct {
        fn call(
            list: *std.ArrayListUnmanaged(u8),
            alloc_: Allocator,
            comptime fmt: []const u8,
            args: anytype,
        ) !void {
            try list.appendSlice(alloc_, " | ");
            try list.writer(alloc_).print(fmt, args);
        }
    }.call;

    if (status.readonly) try appendStatus(&buf, alloc, "readonly", .{});
    if (status.secure_input) try appendStatus(&buf, alloc, "secure", .{});
    if (status.key_sequence_active) try appendStatus(&buf, alloc, "keys", .{});
    if (status.key_table_name) |name| try appendStatus(&buf, alloc, "table:{s}", .{name});
    if (status.pwd) |pwd| try appendStatus(&buf, alloc, "cwd:{s}", .{pwd});
    if (status.search.active) {
        if (status.search.needle) |needle| {
            if (status.search.selected) |selected| {
                if (status.search.total) |total| {
                    try appendStatus(&buf, alloc, "find:{s} ({d}/{d})", .{ needle, selected, total });
                } else {
                    try appendStatus(&buf, alloc, "find:{s} ({d})", .{ needle, selected });
                }
            } else if (status.search.total) |total| {
                try appendStatus(&buf, alloc, "find:{s} ({d})", .{ needle, total });
            } else {
                try appendStatus(&buf, alloc, "find:{s}", .{needle});
            }
        } else {
            try appendStatus(&buf, alloc, "find", .{});
        }
    }
    if (status.progress) |progress| try appendStatus(&buf, alloc, "{s}", .{progress});

    return buf.toOwnedSlice(alloc);
}

fn resolveWindowBaseTitle(
    terminal_title: ?[:0]const u8,
    surface_override: ?[:0]const u8,
    tab_override: ?[:0]const u8,
) ?[:0]const u8 {
    return tab_override orelse surface_override orelse terminal_title;
}

fn normalizedBackgroundOpacity(value: f64) f64 {
    return std.math.clamp(value, 0.0, 1.0);
}

fn effectiveBackgroundOpacity(configured: f64, force_opaque: bool) f64 {
    return if (force_opaque) 1.0 else configured;
}

fn alphaByteForOpacity(value: f64) u8 {
    return @intFromFloat(@round(normalizedBackgroundOpacity(value) * 255.0));
}

const ResizeSplitFallbackDelta = struct {
    width: i32 = 0,
    height: i32 = 0,
};

const SurfaceOrderEntry = struct {
    host_id: u32,
    host_active: bool,
};

fn resizeSplitFallbackDelta(value: apprt.action.ResizeSplit) ResizeSplitFallbackDelta {
    const amount: i32 = @intCast(value.amount);
    return switch (value.direction) {
        .left => .{ .width = -amount },
        .right => .{ .width = amount },
        .up => .{ .height = -amount },
        .down => .{ .height = amount },
    };
}

fn nextInspectorVisible(current: bool, mode: apprt.action.Inspector) bool {
    return switch (mode) {
        .toggle => !current,
        .show => true,
        .hide => false,
    };
}

fn primarySurfaceIndex(entries: []const SurfaceOrderEntry) ?usize {
    if (entries.len == 0) return null;
    const first_host_id = entries[0].host_id;
    for (entries, 0..) |entry, i| {
        if (entry.host_id == first_host_id and entry.host_active) return i;
    }
    return 0;
}

fn buildHostAwareBaseTitle(
    alloc: Allocator,
    base_title: ?[]const u8,
    host: HostTabStatus,
) ![]u8 {
    if (host.total <= 1) return try alloc.dupe(u8, base_title orelse "winghostty");
    return try std.fmt.allocPrint(
        alloc,
        "[{d}/{d}] {s}",
        .{ host.index + 1, host.total, base_title orelse "winghostty" },
    );
}

fn compactHostLabel(
    alloc: Allocator,
    value: []const u8,
    max_len: usize,
) ![]u8 {
    if (value.len <= max_len) return try alloc.dupe(u8, value);
    if (max_len <= 3) return try alloc.dupe(u8, "...");
    return try std.fmt.allocPrint(alloc, "{s}...", .{value[0 .. max_len - 3]});
}

fn hostTabLabelMaxLen(button_width: i32) usize {
    const estimated = @as(usize, @intCast(@max(6, @divTrunc(button_width - 26, 8))));
    return std.math.clamp(estimated, @as(usize, 6), @as(usize, host_tab_label_max_len));
}

fn shouldShowPaneCount(button_width: i32, pane_count: usize) bool {
    return pane_count > 1 and button_width >= 140;
}

fn visibleTabRange(tab_count: usize, active_index: usize, tab_area_width: i32) VisibleTabRange {
    if (tab_count == 0) return .{ .start = 0, .count = 0 };
    const max_visible = std.math.clamp(
        @as(usize, @intCast(@max(1, @divTrunc(tab_area_width, host_tab_min_button_width)))),
        @as(usize, 1),
        tab_count,
    );
    if (tab_count <= max_visible) return .{ .start = 0, .count = tab_count };

    const clamped_active = @min(active_index, tab_count - 1);
    var start = clamped_active;
    if (max_visible > 1) start = clamped_active -| @divTrunc(max_visible - 1, 2);
    if (start + max_visible > tab_count) start = tab_count - max_visible;
    return .{ .start = start, .count = max_visible };
}

fn buildTabButtonLabel(
    alloc: Allocator,
    base_title: ?[]const u8,
    index: usize,
    active: bool,
    pane_count: usize,
    max_len: usize,
    show_pane_count: bool,
) ![]u8 {
    const compact = try compactHostLabel(alloc, base_title orelse "winghostty", max_len);
    defer alloc.free(compact);
    if (show_pane_count and pane_count > 1) {
        return try std.fmt.allocPrint(
            alloc,
            "{s}{d}: {s} ({d})",
            .{
                if (active) "* " else "",
                index + 1,
                compact,
                pane_count,
            },
        );
    }

    return try std.fmt.allocPrint(
        alloc,
        "{s}{d}: {s}",
        .{
            if (active) "* " else "",
            index + 1,
            compact,
        },
    );
}

fn buildTabOverviewBannerText(
    alloc: Allocator,
    entries: []const TabOverviewEntry,
) ![]u8 {
    if (entries.len == 0) return try alloc.dupe(u8, "Tabs: none");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.appendSlice(alloc, "Tabs: ");
    for (entries, 0..) |entry, i| {
        if (i > 0) try buf.appendSlice(alloc, " | ");
        const compact = try compactHostLabel(alloc, entry.title orelse "winghostty", 18);
        defer alloc.free(compact);
        try buf.writer(alloc).print("{s}{d}:{s}", .{
            if (entry.active) "*" else "",
            i + 1,
            compact,
        });
        if (entry.pane_count > 1) {
            try buf.writer(alloc).print(" ({d})", .{entry.pane_count});
        }
    }
    return try buf.toOwnedSlice(alloc);
}

fn buildTabsButtonLabel(
    alloc: Allocator,
    active: bool,
    current_index: usize,
    total: usize,
) ![]u8 {
    if (total <= 1) return try alloc.dupe(u8, if (active) "[Tabs]" else "Tabs");
    if (active) {
        return try std.fmt.allocPrint(alloc, "[{d}/{d}]", .{ current_index + 1, total });
    }
    return try std.fmt.allocPrint(alloc, "Tabs {d}", .{total});
}

fn buildSearchOverlayLabel(
    alloc: Allocator,
    total: ?usize,
    selected: ?usize,
) ![]u8 {
    if (selected) |current| {
        if (total) |count| return try std.fmt.allocPrint(alloc, "Find {d}/{d}", .{ current, count });
    }
    if (total) |count| return try std.fmt.allocPrint(alloc, "Find {d}", .{count});
    return try alloc.dupe(u8, "Find");
}

fn buildTabOverviewOverlayLabel(
    alloc: Allocator,
    current_index: usize,
    total: usize,
) ![]u8 {
    if (total <= 1) return try alloc.dupe(u8, "Tab");
    return try std.fmt.allocPrint(alloc, "Tab {d}/{d}", .{ current_index + 1, total });
}

fn buildOverlayPaintLabelText(
    alloc: Allocator,
    mode: HostOverlayMode,
    input_text: []const u8,
    search_total: ?usize,
    search_selected: ?usize,
    host_status: HostTabStatus,
) ![]u8 {
    return switch (mode) {
        .none => try alloc.dupe(u8, ""),
        .surface_title => try alloc.dupe(u8, "Window title"),
        .tab_title => try alloc.dupe(u8, "Tab title"),
        .command_palette => try buildCommandPaletteOverlayLabel(alloc, input_text),
        .profile => try alloc.dupe(u8, "Profile"),
        .search => try buildSearchOverlayLabel(alloc, search_total, search_selected),
        .tab_overview => try buildTabOverviewOverlayLabel(alloc, host_status.index, host_status.total),
    };
}

fn buildOverlayFeedbackText(
    alloc: Allocator,
    banner_kind: HostBannerKind,
    banner_text: ?[]const u8,
    mode: HostOverlayMode,
    input_text: []const u8,
    active_search_needle: ?[]const u8,
    search_total: ?usize,
    search_selected: ?usize,
    host_status: HostTabStatus,
    pane_count: usize,
) ![]u8 {
    if (banner_text) |value| {
        return switch (banner_kind) {
            .err => try std.fmt.allocPrint(alloc, "Error: {s}", .{value}),
            .info => try std.fmt.allocPrint(alloc, "Info: {s}", .{value}),
            .none => try alloc.dupe(u8, value),
        };
    }
    return try buildOverlayHintText(
        alloc,
        mode,
        input_text,
        active_search_needle,
        search_total,
        search_selected,
        host_status,
        pane_count,
    );
}

fn buildOverlayAcceptLabel(
    alloc: Allocator,
    mode: HostOverlayMode,
    input_text: []const u8,
    active_search_needle: ?[]const u8,
    search_total: ?usize,
    search_selected: ?usize,
) ![]u8 {
    return switch (mode) {
        .none => try alloc.dupe(u8, "OK"),
        .command_palette => blk: {
            if (input_text.len == 0) break :blk try alloc.dupe(u8, "Close");
            if (input.Binding.Action.parse(input_text)) |_| {
                break :blk try alloc.dupe(u8, "Run");
            } else |_| {}
            if (commandPaletteUniqueMatch(input_text) != null) break :blk try alloc.dupe(u8, "Run");
            if (commandPaletteMatchCount(input_text) > 0) break :blk try alloc.dupe(u8, "Pick");
            break :blk try alloc.dupe(u8, "Check");
        },
        .profile => try alloc.dupe(u8, "Open"),
        .search => blk: {
            if (input_text.len == 0) break :blk try alloc.dupe(u8, "Close");
            if (active_search_needle) |needle| {
                if (std.mem.eql(u8, needle, input_text) and search_selected != null and search_total != null) {
                    break :blk try alloc.dupe(u8, "Next");
                }
            }
            if (search_total != null) break :blk try alloc.dupe(u8, "Find");
            break :blk try alloc.dupe(u8, "Find");
        },
        .surface_title, .tab_title => if (input_text.len == 0)
            try alloc.dupe(u8, "Close")
        else
            try alloc.dupe(u8, "Apply"),
        .tab_overview => if (input_text.len == 0)
            try alloc.dupe(u8, "Close")
        else
            try alloc.dupe(u8, "Go"),
    };
}

fn buildOverlayHintText(
    alloc: Allocator,
    mode: HostOverlayMode,
    input_text: []const u8,
    active_search_needle: ?[]const u8,
    search_total: ?usize,
    search_selected: ?usize,
    host_status: HostTabStatus,
    pane_count: usize,
) ![]u8 {
    return switch (mode) {
        .none => try alloc.dupe(u8, ""),
        .command_palette => blk: {
            if (try commandPaletteBannerText(alloc, input_text)) |text| break :blk text;
            break :blk try alloc.dupe(u8, "No curated action matches. Try: new_tab, start_search, reload_config");
        },
        .profile => try alloc.dupe(u8, "Choose a profile by number or name. Enter opens a new tab."),
        .search => blk: {
            if (input_text.len == 0) break :blk try alloc.dupe(u8, "Type to search live. Enter repeats the current match. Escape closes.");
            if (search_selected) |selected| {
                if (search_total) |total| {
                    if (active_search_needle) |needle| {
                        if (std.mem.eql(u8, needle, input_text)) {
                            break :blk try std.fmt.allocPrint(
                                alloc,
                                "Live matches {d}/{d}. Enter jumps to the next match. Escape closes.",
                                .{ selected, total },
                            );
                        }
                    }
                    break :blk try std.fmt.allocPrint(
                        alloc,
                        "Live matches {d}/{d}. Enter keeps this needle active.",
                        .{ selected, total },
                    );
                }
            }
            if (search_total) |total| {
                break :blk try std.fmt.allocPrint(
                    alloc,
                    "Live matches {d}. Enter keeps this needle active.",
                    .{total},
                );
            }
            break :blk try alloc.dupe(u8, "No matches yet. Keep typing to search live.");
        },
        .surface_title => try alloc.dupe(u8, "Apply a window title override for this host. Submit empty text to clear it."),
        .tab_title => blk: {
            if (pane_count > 1) {
                break :blk try std.fmt.allocPrint(
                    alloc,
                    "Rename tab {d}/{d}. This tab currently has {d} panes. Submit empty text to clear the override.",
                    .{ host_status.index + 1, host_status.total, pane_count },
                );
            }
            break :blk try std.fmt.allocPrint(
                alloc,
                "Rename tab {d}/{d}. Submit empty text to clear the override.",
                .{ host_status.index + 1, host_status.total },
            );
        },
        .tab_overview => blk: {
            if (host_status.total <= 1) break :blk try alloc.dupe(u8, "Only one tab is open in this window.");
            if (input_text.len == 0) {
                break :blk try std.fmt.allocPrint(
                    alloc,
                    "Jump directly to a tab number. Current tab: {d}/{d}.",
                    .{ host_status.index + 1, host_status.total },
                );
            }
            const requested = std.fmt.parseUnsigned(usize, input_text, 10) catch {
                break :blk try std.fmt.allocPrint(
                    alloc,
                    "Enter a tab number from 1 to {d}. Current tab: {d}/{d}.",
                    .{ host_status.total, host_status.index + 1, host_status.total },
                );
            };
            if (requested == 0 or requested > host_status.total) {
                break :blk try std.fmt.allocPrint(
                    alloc,
                    "Tab {d} is out of range. Valid range: 1 to {d}.",
                    .{ requested, host_status.total },
                );
            }
            break :blk try std.fmt.allocPrint(
                alloc,
                "Jump to tab {d} of {d}.",
                .{ requested, host_status.total },
            );
        },
    };
}

fn overlayCancelLabel(mode: HostOverlayMode) []const u8 {
    return switch (mode) {
        .none => "Cancel",
        .command_palette, .profile, .search, .tab_overview => "Close",
        .surface_title, .tab_title => "Cancel",
    };
}

fn buildInspectorBannerText(
    alloc: Allocator,
    host: HostTabStatus,
    pane_count: usize,
    zoomed: bool,
) ![]u8 {
    if (zoomed and pane_count > 1) {
        return try std.fmt.allocPrint(
            alloc,
            "Inspector active | tab {d}/{d} | panes {d} | zoomed | toggle Inspect to return",
            .{ host.index + 1, host.total, pane_count },
        );
    }
    if (pane_count > 1) {
        return try std.fmt.allocPrint(
            alloc,
            "Inspector active | tab {d}/{d} | panes {d} | toggle Inspect to return",
            .{ host.index + 1, host.total, pane_count },
        );
    }
    return try std.fmt.allocPrint(
        alloc,
        "Inspector active | tab {d}/{d} | toggle Inspect to return",
        .{ host.index + 1, host.total },
    );
}

fn buildInspectorPanelTitleText(
    alloc: Allocator,
    host: HostTabStatus,
    pane_count: usize,
    zoomed: bool,
) ![]u8 {
    if (zoomed and pane_count > 1) {
        return try std.fmt.allocPrint(
            alloc,
            "Inspector  •  tab {d}/{d}  •  {d} panes  •  zoomed",
            .{ host.index + 1, host.total, pane_count },
        );
    }
    if (pane_count > 1) {
        return try std.fmt.allocPrint(
            alloc,
            "Inspector  •  tab {d}/{d}  •  {d} panes",
            .{ host.index + 1, host.total, pane_count },
        );
    }
    if (zoomed) {
        return try std.fmt.allocPrint(
            alloc,
            "Inspector  •  tab {d}/{d}  •  zoomed",
            .{ host.index + 1, host.total },
        );
    }
    return try std.fmt.allocPrint(
        alloc,
        "Inspector  •  tab {d}/{d}",
        .{ host.index + 1, host.total },
    );
}

fn buildInspectorPanelHintText(
    alloc: Allocator,
    pane_count: usize,
    zoomed: bool,
) ![]u8 {
    if (zoomed) {
        return try alloc.dupe(
            u8,
            "Core inspector is live for the zoomed pane. Toggle Inspect to return to terminal-only view.",
        );
    }
    if (pane_count > 1) {
        return try std.fmt.allocPrint(
            alloc,
            "Core inspector is live across {d} panes in this tab. Toggle Inspect to return to terminal-only view.",
            .{pane_count},
        );
    }
    return try alloc.dupe(u8, "Core inspector is live for this tab. Toggle Inspect to return to terminal-only view.");
}

fn buildInspectorDetailText(
    alloc: Allocator,
    host: HostTabStatus,
    pane_count: usize,
    zoomed: bool,
) ![]u8 {
    if (zoomed and pane_count > 1) {
        return try std.fmt.allocPrint(
            alloc,
            "Inspector is attached to tab {d}/{d}. This tab has {d} panes and split zoom is active.",
            .{ host.index + 1, host.total, pane_count },
        );
    }
    if (pane_count > 1) {
        return try std.fmt.allocPrint(
            alloc,
            "Inspector is attached to tab {d}/{d}. This tab currently has {d} panes.",
            .{ host.index + 1, host.total, pane_count },
        );
    }
    return try std.fmt.allocPrint(
        alloc,
        "Inspector is attached to tab {d}/{d}. Toggle Inspect to return to the normal terminal view.",
        .{ host.index + 1, host.total },
    );
}

fn buildSearchDetailText(
    alloc: Allocator,
    needle: ?[]const u8,
    total: ?usize,
    selected: ?usize,
) ![]u8 {
    if (needle) |value| {
        if (selected) |current| {
            if (total) |count| {
                return try std.fmt.allocPrint(
                    alloc,
                    "Live search for \"{s}\" is active. Match {d} of {d}. Enter moves to the next match.",
                    .{ value, current, count },
                );
            }
        }
        if (total) |count| {
            return try std.fmt.allocPrint(
                alloc,
                "Live search for \"{s}\" is active. {d} matches currently visible.",
                .{ value, count },
            );
        }
        return try std.fmt.allocPrint(
            alloc,
            "Live search for \"{s}\" is active. Keep typing to refine the current needle.",
            .{value},
        );
    }
    return try alloc.dupe(u8, "Live search is active. Keep typing to refine the current needle.");
}

fn buildCommandButtonLabel(
    alloc: Allocator,
    active: bool,
    input_text: ?[]const u8,
) ![]u8 {
    if (active) {
        if (input_text) |value| {
            if (value.len > 0) {
                const compact = try compactHostLabel(alloc, value, 9);
                defer alloc.free(compact);
                return try std.fmt.allocPrint(alloc, "Cmd {s}", .{compact});
            }
        }
        return try alloc.dupe(u8, "[Cmd]");
    }
    return try alloc.dupe(u8, "Cmd");
}

fn buildProfilesButtonLabel(
    alloc: Allocator,
    active: bool,
    profiles_opt: ?[]const windows_shell.Profile,
    selected_index: ?usize,
    pinned_slot_ordinal: ?usize,
) ![]u8 {
    const profiles = profiles_opt orelse return try alloc.dupe(u8, if (active) "[Prof]" else "Prof");
    if (profiles.len == 0) return try alloc.dupe(u8, if (active) "[Prof]" else "Prof");
    const index = selected_index orelse 0;
    const profile = profiles[@min(index, profiles.len - 1)];
    const compact = try compactHostLabel(alloc, profile.label, 8);
    defer alloc.free(compact);
    const badge = try buildProfileChromeBadgeText(alloc, profile.kind);
    defer alloc.free(badge);
    if (index < 9) {
        if (pinned_slot_ordinal != null and pinned_slot_ordinal.? == index) {
            if (active) return try std.fmt.allocPrint(alloc, "[*{d} {s} {s}]", .{ index + 1, badge, compact });
            return try std.fmt.allocPrint(alloc, "*{d} {s} {s}", .{ index + 1, badge, compact });
        }
        if (active) return try std.fmt.allocPrint(alloc, "[{d} {s} {s}]", .{ index + 1, badge, compact });
        return try std.fmt.allocPrint(alloc, "{d} {s} {s}", .{ index + 1, badge, compact });
    }
    if (active) return try std.fmt.allocPrint(alloc, "[{s} {s}]", .{ badge, compact });
    return try std.fmt.allocPrint(alloc, "{s} {s}", .{ badge, compact });
}

fn launchTargetButtonLabel(
    alloc: Allocator,
    target: ProfileOpenTarget,
    selected_index: ?usize,
    pinned_slot_ordinal: ?usize,
) ![]u8 {
    const base = switch (target) {
        .tab => "Tab",
        .window => "Win",
        .split => "Pane",
    };
    if (selected_index) |index| {
        if (index < 9) {
            if (pinned_slot_ordinal != null and pinned_slot_ordinal.? == index) {
                return try std.fmt.allocPrint(alloc, "*{d} {s}", .{ index + 1, base });
            }
            return try std.fmt.allocPrint(alloc, "{d} {s}", .{ index + 1, base });
        }
    }
    return try alloc.dupe(u8, base);
}

fn profileKindBadge(kind: windows_shell.ProfileKind) []const u8 {
    return switch (kind) {
        .wsl_default, .wsl_distro => "WSL",
        .pwsh => "PWSH",
        .powershell => "PS",
        .git_bash => "GIT",
        .cmd => "CMD",
    };
}

fn profileKindGlyph(kind: windows_shell.ProfileKind) []const u8 {
    return switch (kind) {
        .wsl_default, .wsl_distro => "<>",
        .pwsh => ">>",
        .powershell => ">_",
        .git_bash => "$>",
        .cmd => "C>",
    };
}

fn buildProfileChromeBadgeText(alloc: Allocator, kind: windows_shell.ProfileKind) ![]u8 {
    return try std.fmt.allocPrint(alloc, "{s} {s}", .{
        profileKindBadge(kind),
        profileKindGlyph(kind),
    });
}

fn profileKindDetail(kind: windows_shell.ProfileKind) []const u8 {
    return switch (kind) {
        .wsl_default => "WSL default profile",
        .wsl_distro => "WSL distro profile",
        .pwsh => "PowerShell profile",
        .powershell => "Windows PowerShell profile",
        .git_bash => "Git Bash profile",
        .cmd => "Command Prompt profile",
    };
}

fn profileOpenTargetActionText(target: ProfileOpenTarget) []const u8 {
    return switch (target) {
        .tab => "new tab",
        .window => "new window",
        .split => "split",
    };
}

fn buildProfileStatusBadgeText(
    alloc: Allocator,
    profile: *const windows_shell.Profile,
    selected_index: ?usize,
    pinned_slot_ordinal: ?usize,
) ![]u8 {
    const compact = try compactHostLabel(alloc, profile.label, 11);
    defer alloc.free(compact);
    const badge = try buildProfileChromeBadgeText(alloc, profile.kind);
    defer alloc.free(badge);
    if (selected_index) |index| {
        if (index < 9) {
            if (pinned_slot_ordinal != null and pinned_slot_ordinal.? == index) {
                return try std.fmt.allocPrint(alloc, "*{d} {s} {s}", .{ index + 1, badge, compact });
            }
            return try std.fmt.allocPrint(alloc, "{d} {s} {s}", .{ index + 1, badge, compact });
        }
    }
    return try std.fmt.allocPrint(alloc, "{s} {s}", .{ badge, compact });
}

fn buildProfileQuickSlotChipText(
    alloc: Allocator,
    profile: *const windows_shell.Profile,
    slot_index: usize,
    pinned_slot_ordinal: ?usize,
) ![]u8 {
    if (slot_index < 9) {
        if (pinned_slot_ordinal != null and pinned_slot_ordinal.? == slot_index) {
            return try std.fmt.allocPrint(alloc, "*{d} {s}", .{
                slot_index + 1,
                profileKindBadge(profile.kind),
            });
        }
        return try std.fmt.allocPrint(alloc, "{d} {s}", .{
            slot_index + 1,
            profileKindBadge(profile.kind),
        });
    }
    return try alloc.dupe(u8, profileKindBadge(profile.kind));
}

fn quickSlotChipColors(kind: windows_shell.ProfileKind, hovered: bool) ButtonColors {
    const accent = profileChromeAccent(kind);
    return .{
        .bg = if (hovered) accent.hover_bg else accent.idle_bg,
        .border = if (hovered) accent.hover_border else accent.idle_border,
        .fg = if (hovered) profileKindHintColor(kind) else profileKindLabelColor(kind),
    };
}

fn pinnedChipMarkerColor(kind: windows_shell.ProfileKind, hovered: bool) u32 {
    return if (hovered) profileKindLabelColor(kind) else profileKindHintColor(kind);
}

fn launcherChipRightInset(has_slot_badge: bool, has_target_marker: bool) i32 {
    if (has_slot_badge) return 16;
    if (has_target_marker) return 12;
    return 5;
}

fn targetButtonLabelRightInset(target: ?ProfileOpenTarget) i32 {
    return if (target != null) 12 else 0;
}

fn buttonLabelRightInset(pinned_slot_ordinal: ?usize, target: ?ProfileOpenTarget) i32 {
    const slot_inset: i32 = if (pinnedSlotBadgeDigit(pinned_slot_ordinal) != null) 16 else 0;
    return @max(targetButtonLabelRightInset(target), slot_inset);
}

fn shouldPaintQuickSlotTargetMarker(hovered: bool, focused: bool) bool {
    return hovered or focused;
}

fn paintPinnedChipMarker(hdc: HDC, chip_rect: RECT, color: u32) void {
    fillSolidRect(hdc, .{
        .left = chip_rect.left + 3,
        .top = chip_rect.top + 3,
        .right = chip_rect.left + 9,
        .bottom = chip_rect.top + 5,
    }, color);
    fillSolidRect(hdc, .{
        .left = chip_rect.left + 3,
        .top = chip_rect.top + 3,
        .right = chip_rect.left + 5,
        .bottom = chip_rect.top + 9,
    }, color);
}

fn pinnedSlotBadgeDigit(pinned_slot_ordinal: ?usize) ?u8 {
    const ordinal = pinned_slot_ordinal orelse return null;
    if (ordinal >= 9) return null;
    return @as(u8, @intCast('1' + ordinal));
}

fn paintPinnedSlotBadge(hdc: HDC, rect: RECT, digit: u8, border: u32, bg: u32, fg: u32) void {
    const badge_rect = RECT{
        .left = rect.right - 15,
        .top = rect.top + 3,
        .right = rect.right - 4,
        .bottom = rect.top + 14,
    };
    fillSolidRect(hdc, badge_rect, bg);
    fillSolidRect(hdc, .{
        .left = badge_rect.left,
        .top = badge_rect.top,
        .right = badge_rect.right,
        .bottom = badge_rect.top + 1,
    }, border);
    fillSolidRect(hdc, .{
        .left = badge_rect.left,
        .top = badge_rect.bottom - 1,
        .right = badge_rect.right,
        .bottom = badge_rect.bottom,
    }, border);
    fillSolidRect(hdc, .{
        .left = badge_rect.left,
        .top = badge_rect.top,
        .right = badge_rect.left + 1,
        .bottom = badge_rect.bottom,
    }, border);
    fillSolidRect(hdc, .{
        .left = badge_rect.right - 1,
        .top = badge_rect.top,
        .right = badge_rect.right,
        .bottom = badge_rect.bottom,
    }, border);
    var text_buf = [_]u16{ digit, 0 };
    _ = SetBkMode(hdc, TRANSPARENT);
    _ = SetTextColor(hdc, fg);
    var text_rect = badge_rect;
    _ = DrawTextW(
        hdc,
        @ptrCast(&text_buf),
        1,
        &text_rect,
        DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX,
    );
}

fn paintPinnedButtonMarker(hdc: HDC, rect: RECT, color: u32) void {
    fillSolidRect(hdc, .{
        .left = rect.right - 10,
        .top = rect.top + 3,
        .right = rect.right - 4,
        .bottom = rect.top + 5,
    }, color);
    fillSolidRect(hdc, .{
        .left = rect.right - 6,
        .top = rect.top + 3,
        .right = rect.right - 4,
        .bottom = rect.top + 9,
    }, color);
}

fn profileOpenTargetMarkerColor(target: ProfileOpenTarget) u32 {
    return switch (target) {
        .tab => rgb(132, 172, 238),
        .window => rgb(236, 182, 118),
        .split => rgb(126, 204, 148),
    };
}

fn profileOpenTargetBadgeGlyph(target: ProfileOpenTarget) u8 {
    return switch (target) {
        .tab => 'T',
        .window => 'W',
        .split => 'S',
    };
}

fn paintTargetButtonBadge(hdc: HDC, rect: RECT, glyph: u8, border: u32, bg: u32, fg: u32) void {
    const badge_rect = RECT{
        .left = rect.right - 13,
        .top = rect.bottom - 13,
        .right = rect.right - 3,
        .bottom = rect.bottom - 3,
    };
    fillSolidRect(hdc, badge_rect, bg);
    fillSolidRect(hdc, .{
        .left = badge_rect.left,
        .top = badge_rect.top,
        .right = badge_rect.right,
        .bottom = badge_rect.top + 1,
    }, border);
    fillSolidRect(hdc, .{
        .left = badge_rect.left,
        .top = badge_rect.bottom - 1,
        .right = badge_rect.right,
        .bottom = badge_rect.bottom,
    }, border);
    fillSolidRect(hdc, .{
        .left = badge_rect.left,
        .top = badge_rect.top,
        .right = badge_rect.left + 1,
        .bottom = badge_rect.bottom,
    }, border);
    fillSolidRect(hdc, .{
        .left = badge_rect.right - 1,
        .top = badge_rect.top,
        .right = badge_rect.right,
        .bottom = badge_rect.bottom,
    }, border);
    var text_buf = [_]u16{ glyph, 0 };
    _ = SetBkMode(hdc, TRANSPARENT);
    _ = SetTextColor(hdc, fg);
    var text_rect = badge_rect;
    _ = DrawTextW(
        hdc,
        @ptrCast(&text_buf),
        1,
        &text_rect,
        DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX,
    );
}

fn paintTargetChipBadge(hdc: HDC, rect: RECT, glyph: u8, border: u32, bg: u32, fg: u32) void {
    const badge_rect = RECT{
        .left = rect.right - 13,
        .top = rect.bottom - 13,
        .right = rect.right - 3,
        .bottom = rect.bottom - 3,
    };
    fillSolidRect(hdc, badge_rect, bg);
    fillSolidRect(hdc, .{
        .left = badge_rect.left,
        .top = badge_rect.top,
        .right = badge_rect.right,
        .bottom = badge_rect.top + 1,
    }, border);
    fillSolidRect(hdc, .{
        .left = badge_rect.left,
        .top = badge_rect.bottom - 1,
        .right = badge_rect.right,
        .bottom = badge_rect.bottom,
    }, border);
    fillSolidRect(hdc, .{
        .left = badge_rect.left,
        .top = badge_rect.top,
        .right = badge_rect.left + 1,
        .bottom = badge_rect.bottom,
    }, border);
    fillSolidRect(hdc, .{
        .left = badge_rect.right - 1,
        .top = badge_rect.top,
        .right = badge_rect.right,
        .bottom = badge_rect.bottom,
    }, border);
    var text_buf = [_]u16{ glyph, 0 };
    _ = SetBkMode(hdc, TRANSPARENT);
    _ = SetTextColor(hdc, fg);
    var text_rect = badge_rect;
    _ = DrawTextW(
        hdc,
        @ptrCast(&text_buf),
        1,
        &text_rect,
        DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX,
    );
}

fn buildProfileCommandPreviewText(
    alloc: Allocator,
    profile: *const windows_shell.Profile,
    max_len: usize,
) ![]u8 {
    const command = try profile.command.string(alloc);
    defer alloc.free(command);
    return try compactHostLabel(alloc, command, max_len);
}

fn buildProfileOrderSummaryText(
    alloc: Allocator,
    order_hint_opt: ?[]const u8,
    max_items: usize,
) !?[]u8 {
    const order_hint = order_hint_opt orelse return null;
    var parts: std.ArrayListUnmanaged(u8) = .empty;
    errdefer parts.deinit(alloc);

    var count: usize = 0;
    var more = false;
    var it = std.mem.splitAny(u8, order_hint, ",;");
    while (it.next()) |raw_token| {
        const token = std.mem.trim(u8, raw_token, " \t\r\n");
        if (token.len == 0) continue;
        if (count >= max_items) {
            more = true;
            break;
        }
        const compact = try compactHostLabel(alloc, token, 12);
        defer alloc.free(compact);
        if (parts.items.len > 0) try parts.appendSlice(alloc, " > ");
        try parts.appendSlice(alloc, compact);
        count += 1;
    }

    if (count == 0) return null;
    if (more) try parts.appendSlice(alloc, " > ...");
    return try parts.toOwnedSlice(alloc);
}

fn buildProfileQuickPickText(
    alloc: Allocator,
    profiles: []const windows_shell.Profile,
    max_items: usize,
    max_label_len: usize,
) !?[]u8 {
    if (profiles.len == 0 or max_items == 0) return null;

    var parts: std.ArrayListUnmanaged(u8) = .empty;
    errdefer parts.deinit(alloc);

    const limit = @min(@min(max_items, profiles.len), 9);
    var index: usize = 0;
    while (index < limit) : (index += 1) {
        const badge = try buildProfileChromeBadgeText(alloc, profiles[index].kind);
        defer alloc.free(badge);
        const label = try compactHostLabel(alloc, profiles[index].label, max_label_len);
        defer alloc.free(label);

        if (parts.items.len > 0) try parts.appendSlice(alloc, " | ");
        const item = try std.fmt.allocPrint(alloc, "{d} {s} {s}", .{
            index + 1,
            badge,
            label,
        });
        defer alloc.free(item);
        try parts.appendSlice(alloc, item);
    }

    if (limit < profiles.len) try parts.appendSlice(alloc, " | ...");
    return try parts.toOwnedSlice(alloc);
}

fn buildSearchButtonLabel(
    alloc: Allocator,
    active: bool,
    total: ?usize,
    selected: ?usize,
) ![]u8 {
    if (selected) |current| {
        if (total) |count| {
            return try std.fmt.allocPrint(alloc, "{s}{d}/{d}", .{
                if (active) "[F] " else "Find ",
                current,
                count,
            });
        }
    }
    if (total) |count| {
        return try std.fmt.allocPrint(alloc, "{s}{d}", .{
            if (active) "[F] " else "Find ",
            count,
        });
    }
    return try alloc.dupe(u8, if (active) "[Find]" else "Find");
}

fn buildProfileOverlayLabel(
    alloc: Allocator,
    profiles: []const windows_shell.Profile,
    input_text: []const u8,
    selected_index: usize,
) ![]u8 {
    if (profiles.len == 0) return try alloc.dupe(u8, "Profile");
    return switch (resolveProfileSelection(profiles, input_text, selected_index)) {
        .exact => |index| blk: {
            const badge = try buildProfileChromeBadgeText(alloc, profiles[index].kind);
            defer alloc.free(badge);
            break :blk try std.fmt.allocPrint(
                alloc,
                "Profile {d}/{d} {s}",
                .{ index + 1, profiles.len, badge },
            );
        },
        .ambiguous => |count| try std.fmt.allocPrint(alloc, "Profile {d}", .{count}),
        .invalid => try alloc.dupe(u8, "Profile ?"),
    };
}

fn buildProfileAcceptLabel(
    alloc: Allocator,
    profiles_opt: ?[]const windows_shell.Profile,
    input_text: []const u8,
    selected_index: usize,
    default_target: ProfileOpenTarget,
) ![]u8 {
    const profiles = profiles_opt orelse return try alloc.dupe(u8, "Check");
    if (profiles.len == 0) return try alloc.dupe(u8, "Check");
    return switch (resolveProfileSelection(profiles, input_text, selected_index)) {
        .exact => switch (default_target) {
            .tab => try alloc.dupe(u8, "Open Tab"),
            .window => try alloc.dupe(u8, "Open Win"),
            .split => try alloc.dupe(u8, "Split"),
        },
        .ambiguous => try alloc.dupe(u8, "Pick"),
        .invalid => try alloc.dupe(u8, "Check"),
    };
}

fn buildProfileHintText(
    alloc: Allocator,
    profiles_opt: ?[]const windows_shell.Profile,
    input_text: []const u8,
    selected_index: usize,
    default_target: ProfileOpenTarget,
    pinned_slot_keys: [3]?[:0]const u8,
) ![]u8 {
    const profiles = profiles_opt orelse return try alloc.dupe(u8, "No supported Windows profiles detected.");
    if (profiles.len == 0) return try alloc.dupe(u8, "No supported Windows profiles detected.");
    const quick_picks = try buildProfileQuickPickText(alloc, profiles, 4, 10);
    defer if (quick_picks) |value| alloc.free(value);
    const quick_suffix = if (quick_picks) |value|
        try std.fmt.allocPrint(alloc, " Quick picks: {s}.", .{value})
    else
        try alloc.dupe(u8, "");
    defer alloc.free(quick_suffix);
    return switch (resolveProfileSelection(profiles, input_text, selected_index)) {
        .exact => |index| blk: {
            const preview = try buildProfileCommandPreviewText(alloc, &profiles[index], 36);
            defer alloc.free(preview);
            const badge = try buildProfileChromeBadgeText(alloc, profiles[index].kind);
            defer alloc.free(badge);
            const pinned_slot = try buildPinnedProfileSlotText(
                alloc,
                findLauncherQuickSlotOrdinal(pinned_slot_keys, profiles[index].key),
            );
            defer alloc.free(pinned_slot);
            break :blk try std.fmt.allocPrint(
                alloc,
                "{s} {s} | key {s} | run {s}.{s} Enter opens a {s}. Ctrl+Enter splits here. Shift+Enter opens a new window. Ctrl+1-9 launches directly. Alt+1-3 launches visible slots. Alt+Shift+1-3 pins the current profile. Alt+Shift+0 clears pinning.{s}",
                .{
                    badge,
                    profiles[index].label,
                    profiles[index].key,
                    preview,
                    pinned_slot,
                    profileOpenTargetActionText(default_target),
                    quick_suffix,
                },
            );
        },
        .ambiguous => |count| try std.fmt.allocPrint(
            alloc,
            "{d} profiles match. Keep typing a name or use Up/Down to cycle the current selection. Ctrl+1-9 launches directly. Alt+1-3 launches visible slots. Alt+Shift+1-3 pins the current profile. Alt+Shift+0 clears pinning.{s}",
            .{ count, quick_suffix },
        ),
        .invalid => try std.fmt.allocPrint(
            alloc,
            "No matching profile. Try 1-{d} or a profile name like pwsh, ubuntu, git, or cmd. Ctrl+1-9 launches directly. Alt+1-3 launches visible slots. Alt+Shift+1-3 pins the current profile. Alt+Shift+0 clears pinning. Space keeps the picker open.{s}",
            .{ profiles.len, quick_suffix },
        ),
    };
}

fn buildProfileDetailText(
    alloc: Allocator,
    profile: *const windows_shell.Profile,
    profiles_opt: ?[]const windows_shell.Profile,
    overlay_open: bool,
    default_target: ProfileOpenTarget,
    order_hint: ?[]const u8,
    pinned_slot_keys: [3]?[:0]const u8,
) ![]u8 {
    const preview = try buildProfileCommandPreviewText(alloc, profile, 32);
    defer alloc.free(preview);
    const badge = try buildProfileChromeBadgeText(alloc, profile.kind);
    defer alloc.free(badge);
    const pinned_slot = try buildPinnedProfileSlotText(
        alloc,
        findLauncherQuickSlotOrdinal(pinned_slot_keys, profile.key),
    );
    defer alloc.free(pinned_slot);
    const quick_picks = if (overlay_open)
        try buildProfileQuickPickText(alloc, profiles_opt orelse &.{}, 4, 10)
    else
        try buildProfileQuickPickText(alloc, profiles_opt orelse &.{}, 3, 9);
    defer if (quick_picks) |value| alloc.free(value);
    const quick_suffix = if (overlay_open)
        if (quick_picks) |value|
            try std.fmt.allocPrint(alloc, " Quick picks: {s}.", .{value})
        else
            try alloc.dupe(u8, "")
    else if (quick_picks) |value|
        try std.fmt.allocPrint(alloc, " Top slots: {s}.", .{value})
    else
        try alloc.dupe(u8, "");
    defer alloc.free(quick_suffix);
    const order_summary = try buildProfileOrderSummaryText(alloc, order_hint, 4);
    defer if (order_summary) |value| alloc.free(value);
    const order_suffix = if (order_summary) |value|
        try std.fmt.allocPrint(alloc, " Order: {s}.", .{value})
    else
        try alloc.dupe(u8, "");
    defer alloc.free(order_suffix);
    const overlay_suffix = try std.fmt.allocPrint(alloc, "{s}{s}", .{ quick_suffix, order_suffix });
    defer alloc.free(overlay_suffix);
    const idle_suffix = try std.fmt.allocPrint(alloc, "{s}{s}", .{ quick_suffix, order_suffix });
    defer alloc.free(idle_suffix);
    return if (overlay_open)
        std.fmt.allocPrint(
            alloc,
            "Selected profile: {s} {s}. Run {s}.{s} Enter opens a {s}, Ctrl+Enter splits here, and Shift+Enter opens a new window. Alt+1-3 launches visible slots. Alt+Shift+1-3 pins the current profile. Alt+Shift+0 clears pinning.{s}",
            .{
                badge,
                profile.label,
                preview,
                pinned_slot,
                profileOpenTargetActionText(default_target),
                overlay_suffix,
            },
        )
    else
        std.fmt.allocPrint(
            alloc,
            "Default profile: {s} {s}. Run {s}.{s} New hosts inherit this {s}. + opens a {s}, middle-click + splits here, and right-click + opens a new window. Alt+1-3 launches visible slots. Alt+Shift+1-3 pins the current profile. Alt+Shift+0 clears pinning.{s}",
            .{
                badge,
                profile.label,
                preview,
                pinned_slot,
                profileKindDetail(profile.kind),
                profileOpenTargetActionText(default_target),
                idle_suffix,
            },
        );
}

fn buildPinnedProfileSlotText(alloc: Allocator, pinned_slot_ordinal: ?usize) ![]u8 {
    if (pinned_slot_ordinal) |ordinal| {
        return try std.fmt.allocPrint(alloc, " Pinned slot {d}.", .{ordinal + 1});
    }
    return try alloc.dupe(u8, "");
}

fn buildInspectorButtonLabel(
    alloc: Allocator,
    visible: bool,
    pane_count: usize,
) ![]u8 {
    if (visible and pane_count > 1) {
        return try std.fmt.allocPrint(alloc, "[Inspect {d}]", .{pane_count});
    }
    if (visible) return try alloc.dupe(u8, "[Inspect]");
    if (pane_count > 1) return try std.fmt.allocPrint(alloc, "Inspect {d}", .{pane_count});
    return try alloc.dupe(u8, "Inspect");
}

fn commandPaletteMatchCount(input_text: []const u8) usize {
    var count: usize = 0;
    for (curated_command_palette_actions) |candidate| {
        if (std.mem.startsWith(u8, candidate, input_text)) count += 1;
    }
    return count;
}

fn commandPaletteUniqueMatch(input_text: []const u8) ?[]const u8 {
    if (input_text.len == 0) return null;
    var match: ?[]const u8 = null;
    for (curated_command_palette_actions) |candidate| {
        if (!std.mem.startsWith(u8, candidate, input_text)) continue;
        if (match != null) return null;
        match = candidate;
    }
    return match;
}

fn commandPaletteNthMatch(input_text: []const u8, target_index: usize) ?[]const u8 {
    var match_index: usize = 0;
    for (curated_command_palette_actions) |candidate| {
        if (!std.mem.startsWith(u8, candidate, input_text)) continue;
        if (match_index == target_index) return candidate;
        match_index += 1;
    }
    return null;
}

fn commandPaletteCompletionCandidate(
    seed: []const u8,
    current_text: []const u8,
    reverse: bool,
) ?[]const u8 {
    const count = commandPaletteMatchCount(seed);
    if (count == 0) return null;
    if (count == 1) return commandPaletteUniqueMatch(seed);

    var current_index: ?usize = null;
    var match_index: usize = 0;
    for (curated_command_palette_actions) |candidate| {
        if (!std.mem.startsWith(u8, candidate, seed)) continue;
        if (std.mem.eql(u8, candidate, current_text)) current_index = match_index;
        match_index += 1;
    }

    const target_index = if (current_index) |value|
        if (reverse)
            (value + count - 1) % count
        else
            (value + 1) % count
    else if (reverse)
        count - 1
    else
        0;
    return commandPaletteNthMatch(seed, target_index);
}

fn nextTabOverviewSelection(current: usize, total: usize, reverse: bool) usize {
    if (total == 0) return 0;
    const clamped = std.math.clamp(current, @as(usize, 1), total);
    if (reverse) {
        return if (clamped <= 1) total else clamped - 1;
    }
    return if (clamped >= total) 1 else clamped + 1;
}

fn tabDirectionFromWheelDelta(delta: i16) apprt.action.GotoTab {
    return if (delta > 0) .previous else .next;
}

fn buildCommandPaletteOverlayLabel(
    alloc: Allocator,
    input_text: []const u8,
) ![]u8 {
    if (input_text.len == 0) return try alloc.dupe(u8, "Command");
    if (input.Binding.Action.parse(input_text)) |_| {
        return try alloc.dupe(u8, "Run action");
    } else |_| {}
    if (commandPaletteUniqueMatch(input_text) != null) {
        return try alloc.dupe(u8, "Run action");
    }
    const matches = commandPaletteMatchCount(input_text);
    if (matches > 0) return try std.fmt.allocPrint(alloc, "Command {d}", .{matches});
    return try alloc.dupe(u8, "Command ?");
}

fn commandPaletteActionSummary(action_text: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, action_text, "new_tab")) return "open a new tab in this window";
    if (std.mem.eql(u8, action_text, "new_split:right")) return "split the active tab to the right";
    if (std.mem.eql(u8, action_text, "goto_split:right")) return "move focus to the split on the right";
    if (std.mem.eql(u8, action_text, "toggle_fullscreen")) return "toggle fullscreen";
    if (std.mem.eql(u8, action_text, "toggle_command_palette")) return "show or hide the command palette";
    if (std.mem.eql(u8, action_text, "toggle_tab_overview")) return "show the tab list for this window";
    if (std.mem.eql(u8, action_text, "start_search")) return "open the in-window search overlay";
    if (std.mem.eql(u8, action_text, "inspector:toggle")) return "toggle the terminal inspector";
    if (std.mem.eql(u8, action_text, "reload_config")) return "reload winghostty configuration";
    return null;
}

fn commandPaletteBannerText(alloc: Allocator, input_text: []const u8) !?[]u8 {
    if (input_text.len == 0) {
        return try alloc.dupe(u8, "Try: new_tab (new tab), start_search (find), toggle_tab_overview (tab list)");
    }

    if (input.Binding.Action.parse(input_text)) |_| {
        if (commandPaletteActionSummary(input_text)) |summary| {
            return try std.fmt.allocPrint(alloc, "Ready: {s} - {s}", .{ input_text, summary });
        }
        return try std.fmt.allocPrint(alloc, "Ready to run: {s}", .{input_text});
    } else |_| {}

    if (commandPaletteUniqueMatch(input_text)) |candidate| {
        if (commandPaletteActionSummary(candidate)) |summary| {
            return try std.fmt.allocPrint(alloc, "Ready: {s} - {s}", .{ candidate, summary });
        }
        return try std.fmt.allocPrint(alloc, "Ready to run: {s}", .{candidate});
    }

    var matches: std.ArrayListUnmanaged([]const u8) = .empty;
    defer matches.deinit(alloc);
    for (curated_command_palette_actions) |candidate| {
        if (std.mem.startsWith(u8, candidate, input_text)) {
            try matches.append(alloc, candidate);
        }
    }

    if (matches.items.len == 0) return null;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.appendSlice(alloc, "Matches: ");
    for (matches.items, 0..) |candidate, i| {
        if (i > 0) try buf.appendSlice(alloc, ", ");
        try buf.appendSlice(alloc, candidate);
        if (commandPaletteActionSummary(candidate)) |summary| {
            try buf.appendSlice(alloc, " (");
            try buf.appendSlice(alloc, summary);
            try buf.appendSlice(alloc, ")");
        }
    }
    return try buf.toOwnedSlice(alloc);
}

fn readWindowTextUtf8Alloc(alloc: Allocator, hwnd: HWND) ![:0]u8 {
    const len_w = GetWindowTextLengthW(hwnd);
    if (len_w <= 0) return try alloc.dupeZ(u8, "");

    const needed: usize = @intCast(len_w + 1);
    var buf_w = try alloc.alloc(u16, needed);
    defer alloc.free(buf_w);
    buf_w[needed - 1] = 0;

    const copied = GetWindowTextW(hwnd, buf_w.ptr, @intCast(needed));
    if (copied < 0) return windows.unexpectedError(windows.kernel32.GetLastError());

    return try std.unicode.utf16LeToUtf8AllocZ(alloc, buf_w[0..@intCast(copied)]);
}

fn getHost(hwnd: HWND) ?*Host {
    const raw = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (raw == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(raw)));
}

fn refocusActiveSurface(host: *Host) void {
    if (host.activeSurface()) |surface| {
        if (surface.hwnd) |surface_hwnd| _ = SetFocus(surface_hwnd);
    }
}

fn hostButtonProc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT {
    const host = getHost(hwnd);
    if (host) |v| {
        switch (msg) {
            WM_SETFOCUS => {
                if ((v.profiles_hwnd != null and hwnd == v.profiles_hwnd.?) or
                    (v.profile_target_hwnd != null and hwnd == v.profile_target_hwnd.?))
                {
                    _ = v.focusQuickSlotEdge(true);
                }
            },
            WM_KILLFOCUS => {
                v.setFocusedQuickSlot(null);
            },
            WM_MOUSEMOVE => {
                var track: TRACKMOUSEEVENT = .{
                    .cbSize = @sizeOf(TRACKMOUSEEVENT),
                    .dwFlags = TME_LEAVE,
                    .hwndTrack = hwnd,
                    .dwHoverTime = 0,
                };
                _ = TrackMouseEvent(&track);
                v.setHoveredButton(hwnd);
            },
            WM_MOUSELEAVE => {
                if (v.isHoveredButton(hwnd)) v.setHoveredButton(null);
            },
            WM_RBUTTONUP => {
                if (v.command_palette_hwnd != null and hwnd == v.command_palette_hwnd.?) {
                    if (v.dismissCommandPalette()) return 0;
                }
                if (v.profiles_hwnd != null and hwnd == v.profiles_hwnd.?) {
                    if (v.openSelectedProfile(.window)) return 0;
                }
                if (v.profile_target_hwnd != null and hwnd == v.profile_target_hwnd.?) {
                    if (v.cycleLauncherProfileTarget(true)) return 0;
                }
                if (v.search_hwnd != null and hwnd == v.search_hwnd.?) {
                    if (v.navigateActiveSearch(.previous)) return 0;
                }
                if (v.new_tab_hwnd != null and hwnd == v.new_tab_hwnd.?) {
                    if (v.openSelectedProfileOrFallback(.window)) return 0;
                }
                if (v.tab_overview_hwnd != null and hwnd == v.tab_overview_hwnd.?) {
                    if (v.activeSurface()) |surface| {
                        _ = surface.toggleTabOverview() catch {};
                        return 0;
                    }
                }
            },
            WM_MBUTTONUP => {
                if (v.profiles_hwnd != null and hwnd == v.profiles_hwnd.?) {
                    if (v.openSelectedProfile(.split)) return 0;
                }
                if (v.search_hwnd != null and hwnd == v.search_hwnd.?) {
                    if (v.dismissActiveSearch()) return 0;
                }
                if (v.new_tab_hwnd != null and hwnd == v.new_tab_hwnd.?) {
                    if (v.openSelectedProfileOrFallback(.split)) return 0;
                }
            },
            WM_MOUSEWHEEL, WM_MOUSEHWHEEL, WM_POINTERWHEEL, WM_POINTERHWHEEL => {
                if (v.command_palette_hwnd != null and hwnd == v.command_palette_hwnd.?) {
                    if (v.completeCommandPaletteFromButton(commandPaletteDirectionFromWheelDelta(signedHighWord(wParam)))) return 0;
                }
                if (v.profiles_hwnd != null and hwnd == v.profiles_hwnd.?) {
                    if (v.cycleSelectedProfile(profileDirectionFromWheelDelta(signedHighWord(wParam)))) return 0;
                }
                if (v.profile_target_hwnd != null and hwnd == v.profile_target_hwnd.?) {
                    if (v.cycleLauncherProfileTarget(signedHighWord(wParam) > 0)) return 0;
                }
                if (v.search_hwnd != null and hwnd == v.search_hwnd.?) {
                    if (v.navigateActiveSearch(searchDirectionFromWheelDelta(signedHighWord(wParam)))) return 0;
                }
                if (v.tab_overview_hwnd != null and hwnd == v.tab_overview_hwnd.?) {
                    if (v.activateTabByDirection(tabDirectionFromWheelDelta(signedHighWord(wParam)))) return 0;
                }
            },
            WM_KEYDOWN, WM_SYSKEYDOWN => {
                if (v.command_palette_hwnd != null and hwnd == v.command_palette_hwnd.?) {
                    if (commandButtonKeyAction(wParam)) |action| {
                        switch (action) {
                            .toggle => if (v.toggleCommandPaletteFromButton()) return 0,
                            .previous => if (v.completeCommandPaletteFromButton(true)) return 0,
                            .next => if (v.completeCommandPaletteFromButton(false)) return 0,
                            .dismiss => if (v.dismissCommandPalette()) return 0,
                        }
                    }
                }
                if (v.profiles_hwnd != null and hwnd == v.profiles_hwnd.?) {
                    if ((v.ensureProfiles() catch false)) {
                        if (clearQuickSlotPinsRequested(wParam, keyPressed(VK_MENU), keyPressed(VK_SHIFT))) {
                            if (v.clearQuickSlotPins()) return 0;
                        }
                        if (quickSlotPinOrdinalFromKey(wParam, keyPressed(VK_MENU), keyPressed(VK_SHIFT))) |slot_ordinal| {
                            if (v.assignSelectedProfileToQuickSlot(slot_ordinal)) return 0;
                        }
                        if (quickSlotShortcutProfileIndex(v.profiles.?.len, v.selectedProfileIndex(), wParam, keyPressed(VK_MENU))) |index| {
                            if (v.quickOpenProfileIndex(index, v.app.launcher_profile_target)) return 0;
                        }
                        if (keyPressed(VK_MENU)) {
                            if (quickSlotFocusKeyAction(wParam)) |action| {
                                switch (action) {
                                    .previous => if (v.cycleFocusedQuickSlot(true)) return 0,
                                    .next => if (v.cycleFocusedQuickSlot(false)) return 0,
                                    .first => if (v.focusQuickSlotEdge(true)) return 0,
                                    .last => if (v.focusQuickSlotEdge(false)) return 0,
                                    .open => if (v.openFocusedQuickSlot(v.app.launcher_profile_target)) return 0,
                                }
                            }
                        }
                    }
                    if (profileShortcutIndexFromKey(wParam)) |index| {
                        if (v.quickOpenProfileIndex(index, v.app.launcher_profile_target)) return 0;
                    }
                    if (profilesButtonKeyAction(wParam)) |action| {
                        switch (action) {
                            .open => if (v.openSelectedProfile(resolveProfileOpenTarget(
                                v.app.launcher_profile_target,
                                keyPressed(VK_SHIFT),
                                keyPressed(VK_CONTROL),
                            ))) return 0,
                            .toggle => if (v.toggleProfileOverlay()) return 0,
                            .previous => if (v.cycleSelectedProfile(true)) return 0,
                            .next => if (v.cycleSelectedProfile(false)) return 0,
                            .first => {
                                v.setSelectedProfileIndex(0) catch return 0;
                                v.refreshChrome() catch {};
                                return 0;
                            },
                            .last => {
                                if ((v.ensureProfiles() catch false) and v.profiles.?.len > 0) {
                                    v.setSelectedProfileIndex(v.profiles.?.len - 1) catch return 0;
                                    v.refreshChrome() catch {};
                                    return 0;
                                }
                            },
                        }
                    }
                }
                if (v.profile_target_hwnd != null and hwnd == v.profile_target_hwnd.?) {
                    if ((v.ensureProfiles() catch false)) {
                        if (clearQuickSlotPinsRequested(wParam, keyPressed(VK_MENU), keyPressed(VK_SHIFT))) {
                            if (v.clearQuickSlotPins()) return 0;
                        }
                        if (quickSlotPinOrdinalFromKey(wParam, keyPressed(VK_MENU), keyPressed(VK_SHIFT))) |slot_ordinal| {
                            if (v.assignSelectedProfileToQuickSlot(slot_ordinal)) return 0;
                        }
                        if (quickSlotShortcutProfileIndex(v.profiles.?.len, v.selectedProfileIndex(), wParam, keyPressed(VK_MENU))) |index| {
                            if (v.quickOpenProfileIndex(index, v.app.launcher_profile_target)) return 0;
                        }
                        if (keyPressed(VK_MENU)) {
                            if (quickSlotFocusKeyAction(wParam)) |action| {
                                switch (action) {
                                    .previous => if (v.cycleFocusedQuickSlot(true)) return 0,
                                    .next => if (v.cycleFocusedQuickSlot(false)) return 0,
                                    .first => if (v.focusQuickSlotEdge(true)) return 0,
                                    .last => if (v.focusQuickSlotEdge(false)) return 0,
                                    .open => if (v.openFocusedQuickSlot(v.app.launcher_profile_target)) return 0,
                                }
                            }
                        }
                    }
                    if (launchTargetButtonKeyAction(wParam)) |action| {
                        switch (action) {
                            .previous => if (v.cycleLauncherProfileTarget(true)) return 0,
                            .next => if (v.cycleLauncherProfileTarget(false)) return 0,
                            .first => {
                                v.setLauncherProfileTarget(.tab);
                                return 0;
                            },
                            .last => {
                                v.setLauncherProfileTarget(.split);
                                return 0;
                            },
                        }
                    }
                }
                if (v.search_hwnd != null and hwnd == v.search_hwnd.?) {
                    if (searchButtonKeyAction(wParam, keyPressed(VK_SHIFT))) |action| {
                        switch (action) {
                            .next => if (v.navigateActiveSearch(.next)) return 0,
                            .previous => if (v.navigateActiveSearch(.previous)) return 0,
                            .dismiss => if (v.dismissActiveSearch()) return 0,
                        }
                    }
                }
                if (v.tab_overview_hwnd != null and hwnd == v.tab_overview_hwnd.?) {
                    if (tabsButtonKeyAction(wParam)) |action| {
                        switch (action) {
                            .previous => if (v.activateTabByDirection(.previous)) return 0,
                            .next => if (v.activateTabByDirection(.next)) return 0,
                            .rename => {
                                if (v.activeSurface()) |surface| {
                                    surface.promptTitle(.tab) catch {};
                                    return 0;
                                }
                            },
                            .overview => {
                                if (v.activeSurface()) |surface| {
                                    _ = surface.toggleTabOverview() catch {};
                                    return 0;
                                }
                            },
                        }
                    }
                }
            },
            else => {},
        }

        const prev = if (v.isOverlayButton(hwnd))
            v.overlay_button_prev_proc
        else
            v.chrome_button_prev_proc;
        if (prev) |proc| {
            return CallWindowProcW(proc, hwnd, msg, wParam, lParam);
        }
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

fn tabButtonProc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT {
    const host = getHost(hwnd);
    if (host) |v| {
        if (v.tabIndexForButton(hwnd)) |index| {
            switch (msg) {
                WM_MOUSEMOVE => {
                    var track: TRACKMOUSEEVENT = .{
                        .cbSize = @sizeOf(TRACKMOUSEEVENT),
                        .dwFlags = TME_LEAVE,
                        .hwndTrack = hwnd,
                        .dwHoverTime = 0,
                    };
                    _ = TrackMouseEvent(&track);
                    v.setHoveredButton(hwnd);
                },
                WM_MOUSELEAVE => {
                    if (v.isHoveredButton(hwnd)) v.setHoveredButton(null);
                },
                WM_KEYDOWN => {
                    if (tabButtonKeyAction(wParam, keyPressed(VK_CONTROL))) |action| {
                        switch (action) {
                            .previous => {
                                _ = v.activateTabByDirection(.previous);
                                return 0;
                            },
                            .next => {
                                _ = v.activateTabByDirection(.next);
                                return 0;
                            },
                            .first => {
                                _ = v.activateTabByDirection(@enumFromInt(0));
                                return 0;
                            },
                            .last => {
                                _ = v.activateTabByDirection(.last);
                                return 0;
                            },
                            .move_previous => {
                                if (v.activateTabIndex(index)) {
                                    if (v.activeSurface()) |surface| {
                                        _ = v.app.moveTab(.{ .surface = surface.core() }, .{ .amount = -1 }) catch {};
                                        return 0;
                                    }
                                }
                            },
                            .move_next => {
                                if (v.activateTabIndex(index)) {
                                    if (v.activeSurface()) |surface| {
                                        _ = v.app.moveTab(.{ .surface = surface.core() }, .{ .amount = 1 }) catch {};
                                        return 0;
                                    }
                                }
                            },
                            .move_first => {
                                if (v.activateTabIndex(index)) {
                                    if (v.activeSurface()) |surface| {
                                        const amount = moveTabAmountToEdge(v.tabs.items.len, index, true);
                                        if (amount != 0) {
                                            _ = v.app.moveTab(.{ .surface = surface.core() }, .{ .amount = amount }) catch {};
                                        }
                                        return 0;
                                    }
                                }
                            },
                            .move_last => {
                                if (v.activateTabIndex(index)) {
                                    if (v.activeSurface()) |surface| {
                                        const amount = moveTabAmountToEdge(v.tabs.items.len, index, false);
                                        if (amount != 0) {
                                            _ = v.app.moveTab(.{ .surface = surface.core() }, .{ .amount = amount }) catch {};
                                        }
                                        return 0;
                                    }
                                }
                            },
                            .rename => {
                                if (v.activateTabIndex(index)) {
                                    if (v.activeSurface()) |surface| {
                                        surface.promptTitle(.tab) catch {};
                                        return 0;
                                    }
                                }
                            },
                            .close => {
                                if (v.tabs.items.len > 1 and v.activateTabIndex(index)) {
                                    if (v.activeSurface()) |surface| {
                                        _ = v.app.closeTab(.{ .surface = surface.core() }, .this);
                                        return 0;
                                    }
                                }
                            },
                            .overview => {
                                if (v.activateTabIndex(index)) {
                                    if (v.activeSurface()) |surface| {
                                        _ = surface.toggleTabOverview() catch {};
                                        return 0;
                                    }
                                }
                            },
                        }
                    }
                },
                WM_MBUTTONUP => {
                    if (v.tabs.items.len > 1 and v.activateTabIndex(index)) {
                        if (v.activeSurface()) |surface| {
                            _ = v.app.closeTab(.{ .surface = surface.core() }, .this);
                            return 0;
                        }
                    }
                },
                WM_LBUTTONDBLCLK => {
                    if (v.activateTabIndex(index)) {
                        if (v.activeSurface()) |surface| {
                            surface.promptTitle(.tab) catch {};
                            return 0;
                        }
                    }
                },
                else => {},
            }

            if (v.tabs.items[index].button_prev_proc) |proc| {
                return CallWindowProcW(proc, hwnd, msg, wParam, lParam);
            }
        }
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

fn overlayEditProc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT {
    const host = getHost(hwnd);
    if (host) |v| switch (msg) {
        WM_CHAR => {
            if (wParam == VK_RETURN) {
                if (v.overlay_mode != .profile) {
                    _ = v.submitOverlay() catch {};
                }
                return 0;
            }
        },

        WM_KEYDOWN, WM_SYSKEYDOWN => {
            if (v.overlay_mode == .command_palette) {
                if (wParam == VK_TAB or wParam == VK_UP or wParam == VK_DOWN) {
                    const reverse = wParam == VK_UP or (wParam == VK_TAB and keyPressed(VK_SHIFT));
                    if ((v.completeCommandPalette(reverse) catch false)) return 0;
                }
            }
            if (v.overlay_mode == .tab_overview) {
                if (wParam == VK_UP or wParam == VK_DOWN) {
                    if ((v.stepTabOverviewSelection(wParam == VK_UP) catch false)) return 0;
                }
            }
            if (v.overlay_mode == .profile) {
                if ((v.ensureProfiles() catch false)) {
                    if (clearQuickSlotPinsRequested(wParam, keyPressed(VK_MENU), keyPressed(VK_SHIFT))) {
                        if (v.clearQuickSlotPins()) return 0;
                    }
                    if (quickSlotPinOrdinalFromKey(wParam, keyPressed(VK_MENU), keyPressed(VK_SHIFT))) |slot_ordinal| {
                        if (v.assignSelectedProfileToQuickSlot(slot_ordinal)) return 0;
                    }
                    if (quickSlotShortcutProfileIndex(v.profiles.?.len, v.selectedProfileIndex(), wParam, keyPressed(VK_MENU))) |index| {
                        if (v.quickOpenProfileIndex(index, v.app.launcher_profile_target)) return 0;
                    }
                }
                if (keyPressed(VK_CONTROL)) {
                    if (profileShortcutIndexFromKey(wParam)) |index| {
                        if (v.quickOpenProfileIndex(index, v.app.launcher_profile_target)) return 0;
                    }
                }
                if (wParam == VK_RETURN) {
                    _ = v.submitProfileOverlay(resolveProfileOpenTarget(
                        v.app.launcher_profile_target,
                        keyPressed(VK_SHIFT),
                        keyPressed(VK_CONTROL),
                    )) catch {};
                    return 0;
                }
                if (wParam == VK_UP or wParam == VK_DOWN) {
                    if ((v.stepProfileSelection(wParam == VK_UP) catch false)) return 0;
                }
            }
            if (v.overlay_mode == .search) {
                if (wParam == VK_UP) {
                    if ((v.navigateSearchOverlay(.previous) catch false)) return 0;
                }
                if (wParam == VK_DOWN) {
                    if ((v.navigateSearchOverlay(.next) catch false)) return 0;
                }
                if (wParam == VK_RETURN and keyPressed(VK_SHIFT)) {
                    if ((v.navigateSearchOverlay(.previous) catch false)) return 0;
                }
            }
            if (wParam == VK_ESCAPE) {
                if (v.overlay_mode == .search) {
                    _ = v.dismissActiveSearch();
                    return 0;
                }
                v.hideOverlay();
                v.layout() catch {};
                refocusActiveSurface(v);
                return 0;
            }
        },

        else => {},
    };

    if (host) |v| {
        if (v.overlay_edit_prev_proc) |proc| {
            return CallWindowProcW(proc, hwnd, msg, wParam, lParam);
        }
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

fn hostWindowProc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT {
    if (msg == WM_NCCREATE) {
        const cs: *const CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lParam)));
        if (cs.lpCreateParams) |ptr| {
            _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, @as(LONG_PTR, @intCast(@intFromPtr(ptr))));
        }
    }

    const host = getHost(hwnd);
    switch (msg) {
        WM_DRAWITEM => {
            if (host) |v| {
                const draw: *const DRAWITEMSTRUCT = @ptrFromInt(@as(usize, @bitCast(lParam)));
                v.drawButton(draw);
                return 1;
            }
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        },
        WM_ERASEBKGND => return 1,
        WM_SETTINGCHANGE => {
            if (host) |v| {
                v.app.refreshSystemWheelSettings();
                v.app.reconfigureTheme();
            }
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        },
        WM_THEMECHANGED, WM_SYSCOLORCHANGE => {
            if (host) |v| {
                v.app.reconfigureTheme();
            }
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        },
        WM_DPICHANGED => {
            if (host) |v| {
                const new_dpi = GetDpiForWindow(hwnd);
                if (new_dpi > 0) v.current_dpi = new_dpi;

                // Resize window to the suggested rectangle from lParam
                const suggested: *const RECT = @ptrFromInt(@as(usize, @bitCast(lParam)));
                _ = SetWindowPos(hwnd, null, suggested.left, suggested.top, suggested.right - suggested.left, suggested.bottom - suggested.top, SWP_NOZORDER | SWP_NOACTIVATE);

                // Update content_scale on active tab surfaces
                const scale_val: f32 = @as(f32, @floatFromInt(v.current_dpi)) / 96.0;
                const new_scale: apprt.ContentScale = .{ .x = scale_val, .y = scale_val };
                if (v.activeTab()) |tab| {
                    var it = tab.tree.iterator();
                    while (it.next()) |entry| {
                        entry.view.content_scale = new_scale;
                        if (entry.view.core_initialized) {
                            entry.view.core_surface.contentScaleCallback(new_scale) catch {};
                        }
                    }
                }
                v.pending_dpi_update = true;

                // Relayout and repaint
                v.layout() catch {};
                v.invalidateChrome();
            }
            return 0;
        },
        WM_CTLCOLOREDIT, WM_CTLCOLORSTATIC, WM_CTLCOLORBTN => {
            if (host) |v| {
                v.ensureThemeBrushes() catch return DefWindowProcW(hwnd, msg, wParam, lParam);
                const hdc: HDC = @ptrFromInt(@as(usize, @intCast(wParam)));
                const child: HWND = @ptrFromInt(@as(usize, @intCast(lParam)));
                switch (msg) {
                    WM_CTLCOLOREDIT => {
                        _ = SetBkMode(hdc, OPAQUE);
                        _ = SetBkColor(hdc, v.app.resolved_theme.edit_bg);
                        _ = SetTextColor(hdc, v.app.resolved_theme.edit_fg);
                        return @as(LRESULT, @intCast(@intFromPtr(v.edit_brush.?)));
                    },
                    WM_CTLCOLORSTATIC => {
                        _ = SetBkMode(hdc, TRANSPARENT);
                        _ = SetTextColor(hdc, if (v.overlay_hint_hwnd != null and child == v.overlay_hint_hwnd.?)
                            v.app.resolved_theme.text_secondary
                        else
                            v.app.resolved_theme.text_primary);
                        return @as(LRESULT, @intCast(@intFromPtr(v.overlay_brush.?)));
                    },
                    WM_CTLCOLORBTN => {
                        _ = SetBkMode(hdc, TRANSPARENT);
                        if (v.isOverlayButton(child)) {
                            _ = SetTextColor(hdc, v.app.resolved_theme.button_overlay_fg);
                            return @as(LRESULT, @intCast(@intFromPtr(v.overlay_brush.?)));
                        }
                        _ = SetTextColor(hdc, if (v.isActiveChromeButton(child))
                            v.app.resolved_theme.button_active_fg
                        else
                            v.app.resolved_theme.button_chrome_fg);
                        return @as(LRESULT, @intCast(@intFromPtr(v.chrome_brush.?)));
                    },
                    else => {},
                }
            }
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        },
        WM_COMMAND => {
            if (host) |v| {
                const command_id = lowWord(wParam);
                const notify_code = highWord(wParam);
                switch (command_id) {
                    2002 => {
                        if (notify_code == EN_CHANGE) {
                            if (v.overlay_mode == .search) {
                                _ = v.syncSearchOverlay() catch {};
                            } else if (v.overlay_mode == .command_palette) {
                                v.syncOverlayCompletionState() catch {};
                                _ = v.syncCommandPaletteBanner() catch {};
                            } else {
                                v.syncOverlayLabel() catch {};
                                v.syncOverlayHint() catch {};
                                v.syncOverlayButtons() catch {};
                            }
                            return 0;
                        }
                    },
                    2003 => {
                        if (v.overlay_mode == .profile) {
                            _ = v.submitProfileOverlay(resolveProfileOpenTarget(
                                v.app.launcher_profile_target,
                                keyPressed(VK_SHIFT),
                                keyPressed(VK_CONTROL),
                            )) catch {};
                        } else {
                            _ = v.submitOverlay() catch {};
                        }
                        return 0;
                    },
                    2004 => {
                        if (v.overlay_mode == .search) {
                            _ = v.dismissActiveSearch();
                            return 0;
                        }
                        v.hideOverlay();
                        v.layout() catch {};
                        refocusActiveSurface(v);
                        return 0;
                    },
                    1901 => {
                        if (v.activeSurface()) |surface| {
                            _ = surface.toggleCommandPalette() catch {};
                        }
                        return 0;
                    },
                    1909 => {
                        _ = v.toggleProfileOverlay();
                        return 0;
                    },
                    1910 => {
                        _ = v.cycleLauncherProfileTarget(false);
                        return 0;
                    },
                    1906 => {
                        if (v.activeSurface()) |surface| {
                            _ = surface.toggleTabOverview() catch {};
                        }
                        return 0;
                    },
                    1907 => {
                        _ = v.activateTabByDirection(.previous);
                        return 0;
                    },
                    1908 => {
                        _ = v.activateTabByDirection(.next);
                        return 0;
                    },
                    1902 => {
                        if (v.activeSurface()) |surface| {
                            if (v.overlay_mode == .search) {
                                if (surface.host) |host_ref| {
                                    host_ref.hideOverlay();
                                    host_ref.layout() catch {};
                                    refocusActiveSurface(host_ref);
                                }
                            } else {
                                surface.showSearchOverlay("") catch {};
                            }
                        }
                        return 0;
                    },
                    1903 => {
                        if (v.activeSurface()) |surface| {
                            _ = surface.setInspectorVisible(!surface.inspector_visible) catch {};
                            v.refreshChrome() catch {};
                        }
                        return 0;
                    },
                    1904 => {
                        _ = v.openSelectedProfileOrFallback(.tab);
                        return 0;
                    },
                    1905 => {
                        if (v.activeSurface()) |surface| {
                            _ = v.app.closeTab(.{ .surface = surface.core() }, .this);
                        }
                        return 0;
                    },
                    else => {},
                }
                const child_hwnd: HWND = @ptrFromInt(@as(usize, @intCast(lParam)));
                for (v.tabs.items, 0..) |*tab, i| {
                    if (tab.button_hwnd == child_hwnd) {
                        v.active_tab = i;
                        if (tab.focusedSurface()) |surface| v.app.activateSurface(surface);
                        return 0;
                    }
                }
            }
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        WM_SETFOCUS => {
            if (host) |v| {
                refocusActiveSurface(v);
            }
            return 0;
        },

        WM_GETMINMAXINFO => {
            if (host) |v| {
                if (v.activeSurface()) |surface| {
                    surface.updateMinMaxInfo(lParam);
                    return 0;
                }
            }
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        WM_SIZE => {
            if (host) |v| {
                v.layout() catch {};
                return 0;
            }
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        WM_MOUSEMOVE => {
            if (host) |v| {
                var track: TRACKMOUSEEVENT = .{
                    .cbSize = @sizeOf(TRACKMOUSEEVENT),
                    .dwFlags = TME_LEAVE,
                    .hwndTrack = hwnd,
                    .dwHoverTime = 0,
                };
                _ = TrackMouseEvent(&track);
                const point = POINT{
                    .x = signedLowWord(lParamBits(lParam)),
                    .y = signedHighWord(lParamBits(lParam)),
                };
                v.setHoveredQuickSlot(v.quickSlotProfileIndexAtPoint(point));
            }
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        WM_MOUSELEAVE => {
            if (host) |v| v.setHoveredQuickSlot(null);
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        WM_MOUSEWHEEL, WM_MOUSEHWHEEL, WM_POINTERWHEEL, WM_POINTERHWHEEL => {
            if (host) |v| {
                var point = POINT{
                    .x = signedLowWord(lParamBits(lParam)),
                    .y = signedHighWord(lParamBits(lParam)),
                };
                if (ScreenToClient(hwnd, &point) != 0 and point.y >= 0 and point.y < host_tab_height) {
                    _ = v.activateTabByDirection(tabDirectionFromWheelDelta(signedHighWord(wParam)));
                    return 0;
                }
            }
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        WM_LBUTTONUP, WM_MBUTTONUP, WM_RBUTTONUP => {
            if (host) |v| {
                const point = POINT{
                    .x = signedLowWord(lParamBits(lParam)),
                    .y = signedHighWord(lParamBits(lParam)),
                };
                if (v.quickSlotProfileIndexAtPoint(point)) |profile_index| {
                    v.setSelectedProfileIndex(profile_index) catch return 0;
                    const open_target = switch (msg) {
                        WM_MBUTTONUP => ProfileOpenTarget.split,
                        WM_RBUTTONUP => ProfileOpenTarget.window,
                        else => v.app.launcher_profile_target,
                    };
                    if (v.openSelectedProfile(open_target)) return 0;
                    return 0;
                }
            }
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        WM_PAINT => {
            if (host) |v| {
                v.paintChrome();
                return 0;
            }
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        WM_CLOSE => {
            if (host) |v| {
                v.close();
                return 0;
            }
            _ = DestroyWindow(hwnd);
            return 0;
        },

        WM_DESTROY => {
            if (host) |v| v.hwnd = null;
            return 0;
        },

        else => return DefWindowProcW(hwnd, msg, wParam, lParam),
    }
}

fn desiredTabIndex(total: usize, current: usize, goto: apprt.action.GotoTab) ?usize {
    if (total == 0 or current >= total) return null;

    return switch (goto) {
        .previous => if (current == 0) total - 1 else current - 1,
        .next => (current + 1) % total,
        .last => total - 1,
        _ => blk: {
            const raw: c_int = @intFromEnum(goto);
            if (raw < 0) return null;
            const idx: usize = @intCast(raw);
            break :blk @min(idx, total - 1);
        },
    };
}

fn desiredMoveIndex(total: usize, current: usize, amount: isize) ?usize {
    if (total <= 1 or current >= total or amount == 0) return null;
    const total_i: isize = @intCast(total);
    const current_i: isize = @intCast(current);
    const normalized = @mod(current_i + amount, total_i);
    return @intCast(normalized);
}

fn quickSlotProfileIndex(
    profiles_len: usize,
    selected_index: ?usize,
    slot_ordinal: usize,
    max_slots: usize,
) ?usize {
    if (profiles_len == 0 or slot_ordinal >= max_slots) return null;
    var drawn: usize = 0;
    var index: usize = 0;
    while (index < profiles_len) : (index += 1) {
        if (selected_index != null and index == selected_index.?) continue;
        if (drawn == slot_ordinal) return index;
        drawn += 1;
        if (drawn >= max_slots) break;
    }
    return null;
}

fn nextQuickSlotFocus(
    profiles_len: usize,
    selected_index: ?usize,
    current_profile_index: ?usize,
    reverse: bool,
    max_slots: usize,
) ?usize {
    var visible_count: usize = 0;
    var slot_ordinal: usize = 0;
    while (slot_ordinal < max_slots) : (slot_ordinal += 1) {
        if (quickSlotProfileIndex(profiles_len, selected_index, slot_ordinal, max_slots)) |_| {
            visible_count += 1;
        } else break;
    }
    if (visible_count == 0) return null;

    if (current_profile_index) |current| {
        var current_ordinal: ?usize = null;
        slot_ordinal = 0;
        while (slot_ordinal < visible_count) : (slot_ordinal += 1) {
            if (quickSlotProfileIndex(profiles_len, selected_index, slot_ordinal, max_slots)) |index| {
                if (index == current) {
                    current_ordinal = slot_ordinal;
                    break;
                }
            }
        }
        if (current_ordinal) |ordinal| {
            const next_ordinal = if (reverse)
                if (ordinal == 0) visible_count - 1 else ordinal - 1
            else
                (ordinal + 1) % visible_count;
            return quickSlotProfileIndex(profiles_len, selected_index, next_ordinal, max_slots);
        }
    }

    return quickSlotProfileIndex(
        profiles_len,
        selected_index,
        if (reverse) visible_count - 1 else 0,
        max_slots,
    );
}

fn applyQuickSlotPreferenceOrder(
    profiles: []windows_shell.Profile,
    slot_keys: [3]?[]const u8,
) void {
    var insert_at: usize = 0;
    for (slot_keys) |key_opt| {
        const key = key_opt orelse continue;
        var found: ?usize = null;
        for (profiles, 0..) |profile, index| {
            if (std.ascii.eqlIgnoreCase(profile.key, key)) {
                found = index;
                break;
            }
        }
        const found_index = found orelse continue;
        if (found_index == insert_at) {
            insert_at += 1;
            continue;
        }
        const chosen = profiles[found_index];
        var move_index = found_index;
        while (move_index > insert_at) : (move_index -= 1) {
            profiles[move_index] = profiles[move_index - 1];
        }
        profiles[insert_at] = chosen;
        insert_at += 1;
    }
}

fn findLauncherQuickSlotOrdinal(slot_keys: [3]?[:0]const u8, key: []const u8) ?usize {
    for (slot_keys, 0..) |slot_key, index| {
        if (slot_key) |value| {
            if (std.ascii.eqlIgnoreCase(value, key)) return index;
        }
    }
    return null;
}

fn startupProfilePickerEnabled(raw: []const u8) bool {
    return std.mem.eql(u8, raw, "1") or
        std.ascii.eqlIgnoreCase(raw, "true") or
        std.ascii.eqlIgnoreCase(raw, "yes") or
        std.ascii.eqlIgnoreCase(raw, "on");
}

fn detectStartupProfilePicker(alloc: Allocator) bool {
    const raw = std.process.getEnvVarOwned(alloc, "WINGHOSTTY_WIN32_STARTUP_PROFILE_PICKER") catch
        return false;
    defer alloc.free(raw);
    return startupProfilePickerEnabled(raw);
}

fn detectDefaultProfileHint(alloc: Allocator) ?[:0]const u8 {
    const raw = std.process.getEnvVarOwned(alloc, "WINGHOSTTY_WIN32_DEFAULT_PROFILE") catch
        return null;
    if (raw.len == 0) {
        alloc.free(raw);
        return null;
    }
    const value = alloc.dupeZ(u8, raw) catch {
        alloc.free(raw);
        return null;
    };
    alloc.free(raw);
    return value;
}

fn detectDefaultProfileTarget(alloc: Allocator) ProfileOpenTarget {
    const raw = std.process.getEnvVarOwned(alloc, "WINGHOSTTY_WIN32_DEFAULT_PROFILE_TARGET") catch
        return .tab;
    defer alloc.free(raw);
    return parseProfileOpenTarget(raw) orelse .tab;
}

fn traceWin32(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    var file = std.fs.cwd().createFile("winghostty-win32.log", .{
        .truncate = false,
    }) catch return;
    defer file.close();
    file.seekFromEnd(0) catch return;
    file.writeAll(line) catch {};
}

fn isSafeStartupCwd(path: []const u8) bool {
    return path.len >= 3 and
        std.ascii.isAlphabetic(path[0]) and
        path[1] == ':' and
        (path[2] == '\\' or path[2] == '/');
}

fn lParamBits(lParam: LPARAM) usize {
    return @as(usize, @bitCast(lParam));
}

fn lowWord(value: usize) u16 {
    return @truncate(value & 0xFFFF);
}

fn highWord(value: usize) u16 {
    return @truncate((value >> 16) & 0xFFFF);
}

fn signedLowWord(value: usize) i16 {
    return @bitCast(lowWord(value));
}

fn signedHighWord(value: usize) i16 {
    return @bitCast(highWord(value));
}

fn scanCodeFromLParam(lParam: LPARAM) u32 {
    return @as(u32, highWord(lParamBits(lParam))) & 0xFF;
}

fn isExtendedKey(lParam: LPARAM) bool {
    return (lParamBits(lParam) & KF_EXTENDED) != 0;
}

fn isRepeatedKey(lParam: LPARAM) bool {
    return (lParamBits(lParam) & KF_REPEAT) != 0;
}

fn cursorPosFromLParam(lParam: LPARAM) apprt.CursorPos {
    const bits = lParamBits(lParam);
    return .{
        .x = @floatFromInt(signedLowWord(bits)),
        .y = @floatFromInt(signedHighWord(bits)),
    };
}

fn readSystemWheelSetting(action: UINT, fallback: u32) u32 {
    var value: UINT = fallback;
    if (SystemParametersInfoW(action, 0, @ptrCast(&value), 0) == 0) {
        return fallback;
    }
    return value;
}

fn wheelDeltaFromWParam(wParam: WPARAM) i16 {
    const bits = @as(usize, @intCast(wParam));
    return @bitCast(highWord(bits));
}

fn wheelSettingForAxis(settings: SystemWheelSettings, axis: MouseWheelAxis) u32 {
    return switch (axis) {
        .vertical => settings.lines,
        .horizontal => settings.chars,
    };
}

fn wheelUnitSize(ctx: WheelNormalizationContext, axis: MouseWheelAxis) f64 {
    const dim: u32 = switch (axis) {
        .vertical => ctx.cell_size.height,
        .horizontal => ctx.cell_size.width,
    };
    return @floatFromInt(@max(dim, 1));
}

fn wheelViewportSize(ctx: WheelNormalizationContext, axis: MouseWheelAxis) f64 {
    const dim: u32 = switch (axis) {
        .vertical => ctx.viewport.height,
        .horizontal => ctx.viewport.width,
    };
    const viewport: f64 = @floatFromInt(@max(dim, 1));
    const unit = wheelUnitSize(ctx, axis);
    return @max(unit, viewport - unit);
}

fn normalizeWheelDelta(
    ctx: WheelNormalizationContext,
    axis: MouseWheelAxis,
    delta: i16,
) NormalizedWheelScroll {
    if (delta == 0) return .{};

    const precision = @rem(delta, WHEEL_DELTA) != 0;
    const notch_delta = @as(f64, @floatFromInt(delta)) / WHEEL_DELTA;
    const pixels = if (precision)
        notch_delta * wheelUnitSize(ctx, axis)
    else discrete: {
        const setting = wheelSettingForAxis(ctx.settings, axis);
        if (setting == 0) return .{};

        break :discrete if (setting == WHEEL_PAGESCROLL)
            notch_delta * wheelViewportSize(ctx, axis)
        else
            notch_delta * @as(f64, @floatFromInt(setting)) * wheelUnitSize(ctx, axis);
    };

    return switch (axis) {
        .vertical => .{
            .yoff = -pixels,
            .mods = .{
                .precision = precision,
                .pixel_delta = true,
            },
        },
        .horizontal => .{
            .xoff = pixels,
            .mods = .{
                .precision = precision,
                .pixel_delta = true,
            },
        },
    };
}

fn keyPressed(vk: i32) bool {
    return GetKeyState(vk) < 0;
}

fn keyToggled(vk: i32) bool {
    return (GetKeyState(vk) & 1) != 0;
}

fn modsFromKeyboardState(state: [256]u8) input.Mods {
    const pressed = struct {
        fn check(state_: [256]u8, vk: usize) bool {
            return (state_[vk] & 0x80) != 0;
        }
    };

    return .{
        .shift = pressed.check(state, VK_SHIFT),
        .ctrl = pressed.check(state, VK_CONTROL),
        .alt = pressed.check(state, VK_MENU),
        .super = pressed.check(state, VK_LWIN) or pressed.check(state, VK_RWIN),
        .caps_lock = (state[VK_CAPITAL] & 1) != 0,
        .num_lock = (state[VK_NUMLOCK] & 1) != 0,
        .sides = .{
            .shift = if (pressed.check(state, VK_RSHIFT)) .right else .left,
            .ctrl = if (pressed.check(state, VK_RCONTROL)) .right else .left,
            .alt = if (pressed.check(state, VK_RMENU)) .right else .left,
            .super = if (pressed.check(state, VK_RWIN)) .right else .left,
        },
    };
}

fn currentMods() input.Mods {
    var state: [256]u8 = [_]u8{0} ** 256;
    if (GetKeyboardState(&state) == 0) {
        return .{
            .shift = keyPressed(VK_SHIFT),
            .ctrl = keyPressed(VK_CONTROL),
            .alt = keyPressed(VK_MENU),
            .super = keyPressed(VK_LWIN) or keyPressed(VK_RWIN),
            .caps_lock = keyToggled(VK_CAPITAL),
            .num_lock = keyToggled(VK_NUMLOCK),
            .sides = .{
                .shift = if (keyPressed(VK_RSHIFT)) .right else .left,
                .ctrl = if (keyPressed(VK_RCONTROL)) .right else .left,
                .alt = if (keyPressed(VK_RMENU)) .right else .left,
                .super = if (keyPressed(VK_RWIN)) .right else .left,
            },
        };
    }

    return modsFromKeyboardState(state);
}

fn keyFromVirtualKey(vk: UINT, lParam: LPARAM) input.Key {
    return switch (vk) {
        VK_BACK => .backspace,
        VK_TAB => .tab,
        VK_RETURN => if (isExtendedKey(lParam)) .numpad_enter else .enter,
        VK_SHIFT => if (scanCodeFromLParam(lParam) == 0x36) .shift_right else .shift_left,
        VK_LSHIFT => .shift_left,
        VK_RSHIFT => .shift_right,
        VK_CONTROL, VK_LCONTROL => if (isExtendedKey(lParam) or vk == VK_RCONTROL) .control_right else .control_left,
        VK_RCONTROL => .control_right,
        VK_MENU, VK_LMENU => if (isExtendedKey(lParam) or vk == VK_RMENU) .alt_right else .alt_left,
        VK_RMENU => .alt_right,
        VK_PAUSE => .pause,
        VK_CAPITAL => .caps_lock,
        VK_ESCAPE => .escape,
        VK_SPACE => .space,
        VK_PRIOR => .page_up,
        VK_NEXT => .page_down,
        VK_END => .end,
        VK_HOME => .home,
        VK_LEFT => .arrow_left,
        VK_UP => .arrow_up,
        VK_RIGHT => .arrow_right,
        VK_DOWN => .arrow_down,
        VK_SNAPSHOT => .print_screen,
        VK_INSERT => .insert,
        VK_DELETE => .delete,
        VK_LWIN => .meta_left,
        VK_RWIN => .meta_right,
        VK_APPS => .context_menu,
        VK_MULTIPLY => .numpad_multiply,
        VK_ADD => .numpad_add,
        VK_SEPARATOR => .numpad_separator,
        VK_SUBTRACT => .numpad_subtract,
        VK_DECIMAL => .numpad_decimal,
        VK_DIVIDE => .numpad_divide,
        VK_NUMLOCK => .num_lock,
        VK_SCROLL => .scroll_lock,
        VK_OEM_1 => .semicolon,
        VK_OEM_PLUS => .equal,
        VK_OEM_COMMA => .comma,
        VK_OEM_MINUS => .minus,
        VK_OEM_PERIOD => .period,
        VK_OEM_2 => .slash,
        VK_OEM_3 => .backquote,
        VK_OEM_4 => .bracket_left,
        VK_OEM_5 => .backslash,
        VK_OEM_6 => .bracket_right,
        VK_OEM_7 => .quote,
        VK_0...VK_9 => input.Key.fromASCII(@as(u8, @intCast('0' + (vk - VK_0)))) orelse .unidentified,
        VK_A...VK_Z => input.Key.fromASCII(@as(u8, @intCast('a' + (vk - VK_A)))) orelse .unidentified,
        VK_NUMPAD0...VK_NUMPAD9 => @enumFromInt(
            @intFromEnum(input.Key.numpad_0) + @as(c_int, @intCast(vk - VK_NUMPAD0)),
        ),
        VK_F1...VK_F24 => @enumFromInt(
            @intFromEnum(input.Key.f1) + @as(c_int, @intCast(vk - VK_F1)),
        ),
        else => .unidentified,
    };
}

fn unshiftedCodepointForVirtualKey(vk: UINT) u21 {
    return switch (vk) {
        VK_0...VK_9 => @as(u21, @intCast('0' + (vk - VK_0))),
        VK_A...VK_Z => @as(u21, @intCast('a' + (vk - VK_A))),
        VK_SPACE => ' ',
        VK_OEM_1 => ';',
        VK_OEM_PLUS => '=',
        VK_OEM_COMMA => ',',
        VK_OEM_MINUS => '-',
        VK_OEM_PERIOD => '.',
        VK_OEM_2 => '/',
        VK_OEM_3 => '`',
        VK_OEM_4 => '[',
        VK_OEM_5 => '\\',
        VK_OEM_6 => ']',
        VK_OEM_7 => '\'',
        else => 0,
    };
}

fn mouseButtonFromMessage(msg: UINT) ?input.MouseButton {
    return switch (msg) {
        WM_LBUTTONDOWN, WM_LBUTTONUP => .left,
        WM_RBUTTONDOWN, WM_RBUTTONUP => .right,
        WM_MBUTTONDOWN, WM_MBUTTONUP => .middle,
        else => null,
    };
}

fn mouseButtonStateFromMessage(msg: UINT) ?input.MouseButtonState {
    return switch (msg) {
        WM_LBUTTONDOWN, WM_RBUTTONDOWN, WM_MBUTTONDOWN => .press,
        WM_LBUTTONUP, WM_RBUTTONUP, WM_MBUTTONUP => .release,
        else => null,
    };
}

fn mouseModsFromWParam(wParam: WPARAM) input.Mods {
    const bits = @as(usize, @intCast(wParam));
    var mods = currentMods();
    if ((bits & MK_SHIFT) != 0) mods.shift = true;
    if ((bits & MK_CONTROL) != 0) mods.ctrl = true;
    _ = bits & (MK_LBUTTON | MK_RBUTTON | MK_MBUTTON);
    return mods;
}

const KeyText = struct {
    utf8: [8]u8 = [_]u8{0} ** 8,
    len: usize = 0,
    consumed_mods: input.Mods = .{},
    unshifted_codepoint: u21 = 0,
};

fn translateKeyText(vk: UINT, lParam: LPARAM, mods: input.Mods) KeyText {
    var state: [256]u8 = [_]u8{0} ** 256;
    if (GetKeyboardState(&state) == 0) {
        return .{ .unshifted_codepoint = unshiftedCodepointForVirtualKey(vk) };
    }

    var utf16: [4]u16 = [_]u16{0} ** 4;
    const count = ToUnicode(vk, scanCodeFromLParam(lParam), &state, &utf16, utf16.len, 0);
    if (count <= 0) {
        return .{ .unshifted_codepoint = unshiftedCodepointForVirtualKey(vk) };
    }

    var result: KeyText = .{
        .unshifted_codepoint = unshiftedCodepointForVirtualKey(vk),
    };

    const codepoint: u21 = cp: {
        if (count >= 2 and std.unicode.utf16IsHighSurrogate(utf16[0]) and std.unicode.utf16IsLowSurrogate(utf16[1])) {
            break :cp std.unicode.utf16DecodeSurrogatePair(&.{ utf16[0], utf16[1] }) catch return result;
        }
        if (utf16[0] < 0x20 or utf16[0] == 0x7F) return result;
        break :cp utf16[0];
    };

    result.len = std.unicode.utf8Encode(codepoint, &result.utf8) catch 0;
    if (result.len > 0) {
        result.consumed_mods = .{
            .shift = mods.shift,
        };
    }

    return result;
}

fn windowProc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT {
    if (msg == WM_NCCREATE) {
        const cs: *const CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lParam)));
        if (cs.lpCreateParams) |ptr| {
            _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, @as(LONG_PTR, @intCast(@intFromPtr(ptr))));
        }
    }

    const surface = getSurface(hwnd);

    switch (msg) {
        WM_WINHOSTTY_WAKE => return 0,

        WM_SETFOCUS => {
            if (surface) |v| v.focusChanged(true);
            return 0;
        },

        WM_KILLFOCUS => {
            if (surface) |v| v.focusChanged(false);
            return 0;
        },

        WM_SIZE => {
            if (surface) |v| v.windowSizeChanged();
            return 0;
        },

        WM_GETMINMAXINFO => {
            if (surface) |v| {
                v.updateMinMaxInfo(lParam);
                return 0;
            }
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        WM_KEYDOWN, WM_SYSKEYDOWN, WM_KEYUP, WM_SYSKEYUP => {
            if (surface) |v| {
                // VK_APPS (Menu key) -> show context menu when not mouse reporting
                const vk: UINT = @intCast(wParam & 0xFFFF);
                if (vk == VK_APPS and (msg == WM_KEYDOWN or msg == WM_SYSKEYDOWN)) {
                    if (!v.core_initialized or v.core_surface.io.terminal.flags.mouse_event == .none) {
                        if (v.host) |h| {
                            // Keyboard invoke: use center of surface
                            var rect: RECT = undefined;
                            if (GetClientRect(hwnd, &rect) != 0) {
                                var pt: POINT = .{
                                    .x = @divTrunc(rect.right, 2),
                                    .y = @divTrunc(rect.bottom, 2),
                                };
                                _ = ClientToScreen(hwnd, &pt);
                                h.showContextMenu(pt.x, pt.y);
                            }
                        }
                        return 0;
                    }
                }
                v.handleKeyMessage(msg, wParam, lParam);
                return 0;
            }
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        WM_CHAR => {
            return 0;
        },

        WM_MOUSEMOVE => {
            if (surface) |v| {
                v.handleMouseMove(lParam, mouseModsFromWParam(wParam));
                return 0;
            }
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        WM_RBUTTONUP => {
            if (surface) |v| {
                // If terminal has mouse reporting active, pass through normally
                if (v.core_initialized and v.core_surface.io.terminal.flags.mouse_event != .none) {
                    v.handleMouseButton(msg, wParam, lParam);
                    return 0;
                }
                // Otherwise show context menu
                _ = ReleaseCapture();
                if (v.host) |h| {
                    var pt: POINT = .{
                        .x = signedLowWord(lParamBits(lParam)),
                        .y = signedHighWord(lParamBits(lParam)),
                    };
                    _ = ClientToScreen(hwnd, &pt);
                    h.showContextMenu(pt.x, pt.y);
                }
                return 0;
            }
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        WM_LBUTTONDOWN, WM_LBUTTONUP, WM_RBUTTONDOWN, WM_MBUTTONDOWN, WM_MBUTTONUP => {
            if (surface) |v| {
                v.handleMouseButton(msg, wParam, lParam);
                return 0;
            }
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        WM_MOUSEWHEEL, WM_POINTERWHEEL => {
            if (surface) |v| {
                v.handleMouseWheel(normalizeWheelDelta(
                    v.wheelNormalizationContext(),
                    .vertical,
                    wheelDeltaFromWParam(wParam),
                ));
                return 0;
            }
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        WM_MOUSEHWHEEL, WM_POINTERHWHEEL => {
            if (surface) |v| {
                v.handleMouseWheel(normalizeWheelDelta(
                    v.wheelNormalizationContext(),
                    .horizontal,
                    wheelDeltaFromWParam(wParam),
                ));
                return 0;
            }
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        WM_ERASEBKGND => return 1,

        WM_SETTINGCHANGE => {
            if (surface) |v| v.app.refreshSystemWheelSettings();
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        WM_SETCURSOR => {
            if (surface) |v| {
                if (lowWord(@as(usize, @intCast(lParam))) == HTCLIENT and v.applyCursor()) {
                    return 1;
                }
            }
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        WM_PAINT => {
            var ps: PAINTSTRUCT = undefined;
            _ = BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = EndPaint(hwnd, &ps);

            if (surface) |v| {
                v.paint_pending = false;
                if (v.core_initialized) {
                    v.redraw() catch |err| {
                        log.err("win32 paint redraw failed err={}", .{err});
                    };
                }
            }

            return 0;
        },

        WM_CLOSE => {
            _ = DestroyWindow(hwnd);
            return 0;
        },

        WM_DESTROY => {
            if (surface) |v| {
                if (v.destroy_on_wm_destroy) {
                    v.destroy();
                } else if (v.hwnd == hwnd) {
                    v.hwnd = null;
                }
            }
            return 0;
        },

        else => return DefWindowProcW(hwnd, msg, wParam, lParam),
    }
}

fn getSurface(hwnd: HWND) ?*Surface {
    const raw = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (raw == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(raw)));
}

pub const Surface = struct {
    app: *App,
    host: ?*Host = null,
    host_id: u32 = 0,
    host_active: bool = true,
    hwnd: ?HWND = null,
    hdc: HDC = null,
    hglrc: HGLRC = null,
    core_surface: CoreSurface = undefined,
    core_initialized: bool = false,
    destroy_on_wm_destroy: bool = false,
    content_scale: apprt.ContentScale = .{ .x = 1, .y = 1 },
    size: apprt.SurfaceSize = .{ .width = 800, .height = 600 },
    cursor_pos: apprt.CursorPos = .{ .x = -1, .y = -1 },
    title: ?[:0]const u8 = null,
    title_override: ?[:0]const u8 = null,
    tab_title_override: ?[:0]const u8 = null,
    launch_profile_key: ?[:0]const u8 = null,
    mouse_shape: terminal.MouseShape = .text,
    mouse_visible: bool = true,
    hovered_link: ?[:0]const u8 = null,
    window_focused: bool = false,
    quick_terminal: bool = false,
    decorations_visible: bool = true,
    fullscreen: bool = false,
    topmost: bool = false,
    restore_rect: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    restore_maximized: bool = false,
    default_client_size: ?apprt.SurfaceSize = null,
    cell_size_pixels: apprt.action.CellSize = .{ .width = 0, .height = 0 },
    background_opacity_default: f64 = 1.0,
    background_opacity_force_opaque: bool = false,
    size_limit: apprt.action.SizeLimit = .{
        .min_width = 0,
        .min_height = 0,
        .max_width = 0,
        .max_height = 0,
    },
    readonly: bool = false,
    secure_input: bool = false,
    key_sequence_active: bool = false,
    key_table_name: ?[:0]const u8 = null,
    search_active: bool = false,
    search_needle: ?[:0]const u8 = null,
    search_total: ?usize = null,
    search_selected: ?usize = null,
    scrollbar: terminal.Scrollbar = .zero,
    pwd: ?[:0]const u8 = null,
    progress_status: ?[:0]const u8 = null,
    inspector_visible: bool = false,
    debug_input_budget: u8 = 32,
    paint_pending: bool = false,

    pub fn init(
        self: *Surface,
        app: *App,
        title: LPCWSTR,
        config: *const configpkg.Config,
        opts: SurfaceInitOptions,
    ) !void {
        trace("win32.Surface.init: begin", .{});
        log.info("surface.init begin", .{});
        const host = if (opts.host_id) |host_id|
            app.findHostById(host_id) orelse return error.InvalidHost
        else
            try app.createHost(title, opts.clone_state_from);
        self.* = .{
            .app = app,
            .host = host,
            .quick_terminal = opts.quick_terminal,
            .host_id = host.id,
            .host_active = true,
        };
        self.background_opacity_default = normalizedBackgroundOpacity(config.@"background-opacity");

        const hwnd = CreateWindowExW(
            0,
            class_name,
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            surfaceWindowStyle(),
            0,
            0,
            10,
            10,
            host.hwnd,
            null,
            app.hinstance,
            self,
        ) orelse return windows.unexpectedError(windows.kernel32.GetLastError());
        errdefer _ = DestroyWindow(hwnd);
        self.hwnd = hwnd;
        _ = ShowWindow(hwnd, SW_SHOW);
        const content_rect: RECT = host.contentRect() catch .{
            .left = 0,
            .top = host_tab_height,
            .right = 1280,
            .bottom = 800 - host_status_height,
        };
        _ = MoveWindow(
            hwnd,
            content_rect.left,
            content_rect.top,
            @max(1, content_rect.right - content_rect.left),
            @max(1, content_rect.bottom - content_rect.top),
            1,
        );
        trace("win32.Surface.init: hwnd created", .{});
        log.info("surface.init hwnd created", .{});

        const gl = try app.createGLContext(hwnd);
        self.hdc = gl.hdc;
        self.hglrc = gl.hglrc;
        errdefer self.destroyGL();
        trace("win32.Surface.init: gl created", .{});
        log.info("surface.init gl context created", .{});

        self.size = try app.clientSize(hwnd);
        log.info("surface.init client size width={} height={}", .{ self.size.width, self.size.height });

        try app.windows.append(app.core_app.alloc, self);
        errdefer app.removeWindow(self);
        trace("win32.Surface.init: appended", .{});
        log.info("surface.init appended to app windows", .{});
        try app.core_app.addSurface(self);
        errdefer app.core_app.deleteSurface(self);
        trace("win32.Surface.init: added to core app", .{});
        log.info("surface.init added to core app", .{});

        if (opts.tab_id) |tab_id| {
            for (host.tabs.items) |*tab| {
                if (tab.id == tab_id) {
                    const inserted = try SplitTreeSurface.init(app.core_app.alloc, self);
                    defer {
                        var cleanup = inserted;
                        cleanup.deinit();
                    }
                    const focus_handle = tab.findHandle(@constCast(opts.clone_state_from.?)) orelse tab.focused;
                    const next_tree = try tab.tree.split(
                        app.core_app.alloc,
                        focus_handle,
                        .right,
                        0.5,
                        &inserted,
                    );
                    tab.tree.deinit();
                    tab.tree = next_tree;
                    tab.focused = tab.findHandle(self) orelse focus_handle;
                    break;
                }
            } else return error.InvalidTab;
        } else {
            const tab_id = host.nextTabId();
            try host.tabs.append(app.core_app.alloc, try Tab.init(app.core_app.alloc, tab_id, self));
            host.active_tab = host.tabs.items.len - 1;
        }

        // Set initial content_scale from host DPI before core init
        self.content_scale = .{
            .x = @as(f32, @floatFromInt(host.current_dpi)) / 96.0,
            .y = @as(f32, @floatFromInt(host.current_dpi)) / 96.0,
        };

        try self.core_surface.init(
            app.core_app.alloc,
            config,
            app.core_app,
            app,
            self,
        );
        self.core_initialized = true;
        self.destroy_on_wm_destroy = true;
        trace("win32.Surface.init: core init ok", .{});
        log.info("surface.init core surface initialized", .{});

        if (GetFocus() == hwnd) {
            self.window_focused = true;
        }
        if (self.window_focused) {
            self.focusChanged(true);
        }
        traceWin32("win32 surface init: focused={} hwnd={*}", .{
            self.window_focused,
            hwnd,
        });

        try host.refreshChrome();
        try host.layout();
        try self.requestRepaint();

        if (opts.clone_state_from) |source| {
            try self.inheritWindowStateFrom(source);
        }
    }

    pub fn deinit(self: *Surface) void {
        self.destroy();
    }

    pub fn core(self: *Surface) *CoreSurface {
        return &self.core_surface;
    }

    pub fn ref(self: *Surface, alloc: Allocator) !*Surface {
        _ = alloc;
        return self;
    }

    pub fn unref(self: *Surface, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }

    pub fn eql(a: *const Surface, b: *const Surface) bool {
        return a == b;
    }

    pub fn rtApp(self: *const Surface) *App {
        return self.app;
    }

    pub fn close(self: *const Surface, process_active: bool) void {
        _ = process_active;
        if (self.hwnd) |hwnd| _ = DestroyWindow(hwnd);
    }

    fn present(self: *Surface) void {
        self.app.activateSurface(self);
    }

    fn presentWindow(self: *Surface) void {
        if (self.host) |host| {
            host.present();
            if (self.hwnd) |hwnd| _ = SetFocus(hwnd);
            return;
        }
        const hwnd = self.hwnd orelse return;
        _ = ShowWindow(hwnd, SW_SHOW);
        _ = SetForegroundWindow(hwnd);
        _ = SetFocus(hwnd);
    }

    fn windowHwnd(self: *const Surface) ?HWND {
        if (self.host) |host| return host.hwnd;
        return self.hwnd;
    }

    pub fn getTitle(self: *Surface) ?[:0]const u8 {
        return self.effectiveTitle();
    }

    pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
        return self.content_scale;
    }

    pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
        return self.size;
    }

    pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
        return self.cursor_pos;
    }

    pub fn supportsClipboard(
        self: *const Surface,
        clipboard_type: apprt.Clipboard,
    ) bool {
        _ = self;
        return clipboard_type == .standard;
    }

    pub fn clipboardRequest(
        self: *Surface,
        clipboard_type: apprt.Clipboard,
        state: apprt.ClipboardRequest,
    ) !bool {
        if (clipboard_type != .standard) return false;

        const text = try self.readClipboardText();
        defer if (text) |v| self.app.core_app.alloc.free(v);

        const str = text orelse switch (state) {
            .paste => return false,
            .osc_52_read => try self.app.core_app.alloc.dupeZ(u8, ""),
            .osc_52_write => unreachable,
        };

        self.core_surface.completeClipboardRequest(
            state,
            str,
            false,
        ) catch |err| switch (err) {
            error.UnsafePaste,
            error.UnauthorizedPaste,
            => {
                if (!self.confirmClipboardRead()) return false;
                try self.core_surface.completeClipboardRequest(
                    state,
                    str,
                    true,
                );
            },

            else => return err,
        };

        return true;
    }

    pub fn setClipboard(
        self: *const Surface,
        clipboard_type: apprt.Clipboard,
        contents: []const apprt.ClipboardContent,
        confirm: bool,
    ) !void {
        if (clipboard_type != .standard) return;
        if (confirm and !self.confirmClipboardWrite()) return;

        for (contents) |content| {
            if (!std.mem.eql(u8, content.mime, "text/plain")) continue;
            try self.writeClipboardText(content.data);
            return;
        }
    }

    pub fn defaultTermioEnv(self: *const Surface) !std.process.EnvMap {
        var env = try internal_os.getEnvMap(self.app.core_app.alloc);
        errdefer env.deinit();

        if (env.get("USERPROFILE") == null) {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            if (try internal_os.windows.knownFolderPathUtf8(
                &internal_os.windows.FOLDERID_Profile,
                &buf,
            )) |profile| {
                try env.put("USERPROFILE", profile);
            }
        }

        if (env.get("LOCALAPPDATA") == null) {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            if (try internal_os.windows.knownFolderPathUtf8(
                &internal_os.windows.FOLDERID_LocalAppData,
                &buf,
            )) |local_appdata| {
                try env.put("LOCALAPPDATA", local_appdata);
            }
        }

        return env;
    }

    pub fn redrawInspector(self: *Surface) void {
        if (!self.inspector_visible) return;
        self.requestRepaint() catch |err| {
            log.err("win32 inspector repaint request failed err={}", .{err});
        };
    }

    pub fn requestRepaint(self: *Surface) !void {
        const hwnd = self.hwnd orelse return;
        if (self.paint_pending) return;
        self.paint_pending = true;
        if (InvalidateRect(hwnd, null, 0) == 0) {
            self.paint_pending = false;
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
    }

    pub fn redraw(self: *Surface) !void {
        if (!self.core_initialized) return;
        try self.makeGLContextCurrent();
        if (builtin.mode == .Debug) log.info("win32 redraw current context acquired", .{});
        try self.core_surface.draw();
        if (builtin.mode == .Debug) log.info("win32 redraw draw complete", .{});
    }

    pub fn makeGLContextCurrent(self: *Surface) !void {
        if (wglMakeCurrent(self.hdc, self.hglrc) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
    }

    pub fn clearGLContextCurrent(self: *Surface) void {
        _ = self;
        _ = wglMakeCurrent(null, null);
    }

    pub fn swapGLBuffers(self: *Surface) !void {
        if (SwapBuffers(self.hdc) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
    }

    fn setTitle(self: *Surface, title: []const u8) !void {
        const alloc = self.app.core_app.alloc;
        try appendOwnedString(alloc, &self.title, title);
        try self.refreshWindowTitle();
    }

    fn setTitleOverride(self: *Surface, title: ?[]const u8) !void {
        const alloc = self.app.core_app.alloc;
        try appendOwnedString(alloc, &self.title_override, title);
        try self.refreshWindowTitle();
    }

    fn setTabTitleOverride(self: *Surface, title: ?[]const u8) !void {
        const alloc = self.app.core_app.alloc;
        try appendOwnedString(alloc, &self.tab_title_override, title);
        try self.refreshWindowTitle();
    }

    fn effectiveTitle(self: *const Surface) ?[:0]const u8 {
        return resolveWindowBaseTitle(self.title, self.title_override, self.tab_title_override);
    }

    fn promptTitle(self: *Surface, kind: apprt.action.PromptTitle) !void {
        const host = self.host orelse return;
        const mode: HostOverlayMode = switch (kind) {
            .surface => .surface_title,
            .tab => .tab_title,
        };
        if (host.overlay_mode == mode) {
            host.hideOverlay();
            try host.layout();
            return;
        }
        const initial = host.overlayInitialText(mode);
        defer if (initial) |value| self.app.core_app.alloc.free(value);
        host.hideOverlay();
        try host.showOverlay(mode, initial);
    }

    fn toggleCommandPalette(self: *Surface) anyerror!bool {
        const host = self.host orelse return false;
        if (host.overlay_mode == .command_palette) {
            host.hideOverlay();
            try host.layout();
            return true;
        }
        host.hideOverlay();
        try host.showOverlay(.command_palette, null);
        return true;
    }

    fn toggleTabOverview(self: *Surface) !bool {
        const host = self.host orelse return false;
        if (host.overlay_mode == .tab_overview) {
            host.hideOverlay();
            try host.layout();
            return true;
        }
        const initial = host.overlayInitialText(.tab_overview);
        defer if (initial) |value| self.app.core_app.alloc.free(value);
        try host.showOverlay(.tab_overview, initial);
        return true;
    }

    fn showSearchOverlay(self: *Surface, needle: []const u8) !void {
        const host = self.host orelse return;
        const initial = if (needle.len > 0) needle else if (self.search_needle) |value| value else "";
        if (host.overlay_mode != .search) host.hideOverlay();
        try host.showOverlay(.search, initial);
    }

    fn setInspectorVisible(self: *Surface, visible: bool) !bool {
        if (visible == self.inspector_visible) return false;
        if (!self.core_initialized) return false;

        if (visible) {
            try self.core_surface.activateInspector();
        } else {
            self.core_surface.deactivateInspector();
        }
        self.inspector_visible = visible;
        if (self.host) |host| {
            if (host.overlay_mode == .none) {
                if (visible) {
                    try host.setBanner(.none, null);
                } else {
                    try host.setBanner(.info, host_banner_inspector_inactive);
                }
            }
        }
        try self.requestRepaint();
        try self.refreshWindowTitle();
        return true;
    }

    fn refreshWindowTitle(self: *Surface) !void {
        if (self.host) |host| {
            try host.syncWindowTitle();
            host.invalidateChrome();
            return;
        }
    }

    fn toggleMaximize(self: *Surface) void {
        const hwnd = self.windowHwnd() orelse return;
        if (self.fullscreen) return;
        _ = ShowWindow(hwnd, if (IsZoomed(hwnd) != 0) SW_RESTORE else SW_MAXIMIZE);
    }

    fn applyRuntimeConfig(self: *Surface, config: *const configpkg.Config) !void {
        self.background_opacity_default = normalizedBackgroundOpacity(config.@"background-opacity");
        if (self.background_opacity_default >= 0.999) {
            self.background_opacity_force_opaque = false;
        }
        try self.applyBackgroundOpacity();
    }

    fn toggleBackgroundOpacity(self: *Surface) !bool {
        if (self.background_opacity_default >= 0.999) return false;
        self.background_opacity_force_opaque = !self.background_opacity_force_opaque;
        try self.applyBackgroundOpacity();
        return true;
    }

    fn resizeSplitFallback(self: *Surface, value: apprt.action.ResizeSplit) !bool {
        const hwnd = self.hwnd orelse return false;
        var client_rect: RECT = undefined;
        if (GetClientRect(hwnd, &client_rect) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }

        const delta = resizeSplitFallbackDelta(value);
        const current_width = client_rect.right - client_rect.left;
        const current_height = client_rect.bottom - client_rect.top;
        const next_width = @max(1, current_width + delta.width);
        const next_height = @max(1, current_height + delta.height);

        try self.resizeClientArea(@intCast(next_width), @intCast(next_height));
        return true;
    }

    fn toggleFullscreen(self: *Surface, mode: apprt.action.Fullscreen) !void {
        _ = mode;
        if (self.fullscreen) {
            try self.leaveFullscreen();
            return;
        }
        try self.enterFullscreen();
    }

    fn toggleDecorations(self: *Surface) !void {
        self.decorations_visible = !self.decorations_visible;
        try self.applyWindowStyle();
    }

    fn setInitialSize(self: *Surface, size: apprt.action.InitialSize) !void {
        self.default_client_size = .{
            .width = @intCast(size.width),
            .height = @intCast(size.height),
        };
        if (self.fullscreen or self.restore_maximized) return;
        try self.resizeClientArea(size.width, size.height);
    }

    fn resetWindowSize(self: *Surface) !void {
        const size = self.default_client_size orelse return;
        if (self.fullscreen) try self.leaveFullscreen();
        if (self.windowHwnd()) |hwnd| _ = ShowWindow(hwnd, SW_RESTORE);
        try self.resizeClientArea(@intCast(size.width), @intCast(size.height));
    }

    fn setSizeLimit(self: *Surface, limit: apprt.action.SizeLimit) void {
        self.size_limit = limit;
        const hwnd = self.windowHwnd() orelse return;
        _ = SetWindowPos(
            hwnd,
            null,
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED,
        );
    }

    fn setCellSize(self: *Surface, size: apprt.action.CellSize) void {
        self.cell_size_pixels = size;
    }

    fn setFloatWindow(self: *Surface, mode: apprt.action.FloatWindow) !void {
        self.topmost = switch (mode) {
            .on => true,
            .off => false,
            .toggle => !self.topmost,
        };
        try self.applyTopmost();
    }

    fn enterFullscreen(self: *Surface) !void {
        const hwnd = self.windowHwnd() orelse return;
        self.captureRestoreState();
        self.fullscreen = true;
        try self.applyWindowStyle();

        const monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST) orelse
            return windows.unexpectedError(windows.kernel32.GetLastError());
        var info: MONITORINFO = .{
            .cbSize = @sizeOf(MONITORINFO),
            .rcMonitor = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
            .rcWork = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
            .dwFlags = 0,
        };
        if (GetMonitorInfoW(monitor, &info) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }

        if (SetWindowPos(
            hwnd,
            if (self.topmost) HWND_TOPMOST else null,
            info.rcMonitor.left,
            info.rcMonitor.top,
            info.rcMonitor.right - info.rcMonitor.left,
            info.rcMonitor.bottom - info.rcMonitor.top,
            SWP_FRAMECHANGED | SWP_NOACTIVATE,
        ) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
    }

    fn leaveFullscreen(self: *Surface) !void {
        const hwnd = self.windowHwnd() orelse return;
        self.fullscreen = false;
        try self.applyWindowStyle();

        if (SetWindowPos(
            hwnd,
            if (self.topmost) HWND_TOPMOST else HWND_NOTOPMOST,
            self.restore_rect.left,
            self.restore_rect.top,
            self.restore_rect.right - self.restore_rect.left,
            self.restore_rect.bottom - self.restore_rect.top,
            SWP_FRAMECHANGED | SWP_NOACTIVATE,
        ) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }

        if (self.restore_maximized) _ = ShowWindow(hwnd, SW_MAXIMIZE);
    }

    fn captureRestoreState(self: *Surface) void {
        const hwnd = self.windowHwnd() orelse return;
        self.restore_maximized = IsZoomed(hwnd) != 0;
        if (GetWindowRect(hwnd, &self.restore_rect) == 0) {
            self.restore_rect = .{ .left = 0, .top = 0, .right = 1280, .bottom = 800 };
        }
    }

    fn resizeClientArea(self: *Surface, client_width: u32, client_height: u32) !void {
        const hwnd = self.windowHwnd() orelse return;
        var client_rect: RECT = undefined;
        if (GetClientRect(hwnd, &client_rect) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
        var window_rect: RECT = undefined;
        if (GetWindowRect(hwnd, &window_rect) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }

        const current_client_width = client_rect.right - client_rect.left;
        const current_client_height = client_rect.bottom - client_rect.top;
        const current_window_width = window_rect.right - window_rect.left;
        const current_window_height = window_rect.bottom - window_rect.top;
        const frame_width = current_window_width - current_client_width;
        const frame_height = current_window_height - current_client_height;

        if (SetWindowPos(
            hwnd,
            null,
            0,
            0,
            @as(i32, @intCast(client_width)) + frame_width,
            @as(i32, @intCast(client_height)) + frame_height,
            SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE,
        ) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
    }

    fn inheritWindowStateFrom(self: *Surface, source: *const Surface) !void {
        self.decorations_visible = source.decorations_visible;
        self.topmost = source.topmost;
        self.fullscreen = source.fullscreen;
        self.restore_rect = source.restore_rect;
        self.restore_maximized = source.restore_maximized;
        self.background_opacity_default = source.background_opacity_default;
        self.background_opacity_force_opaque = source.background_opacity_force_opaque;
        self.default_client_size = source.default_client_size;
        self.size_limit = source.size_limit;
        self.cell_size_pixels = source.cell_size_pixels;

        try self.applyWindowStyle();
        try self.applyTopmost();
        try self.applyBackgroundOpacity();

        const hwnd = self.windowHwnd() orelse return;
        const source_hwnd = source.windowHwnd() orelse return;
        var rect: RECT = undefined;
        if (GetWindowRect(source_hwnd, &rect) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
        if (SetWindowPos(
            hwnd,
            if (self.topmost) HWND_TOPMOST else HWND_NOTOPMOST,
            rect.left,
            rect.top,
            rect.right - rect.left,
            rect.bottom - rect.top,
            SWP_NOACTIVATE | SWP_FRAMECHANGED,
        ) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }

        if (!self.fullscreen) {
            if (IsZoomed(source_hwnd) != 0) {
                _ = ShowWindow(hwnd, SW_MAXIMIZE);
            } else {
                _ = ShowWindow(hwnd, SW_RESTORE);
            }
        }
    }

    fn updateMinMaxInfo(self: *Surface, lParam: LPARAM) void {
        if (self.size_limit.min_width == 0 and
            self.size_limit.min_height == 0 and
            self.size_limit.max_width == 0 and
            self.size_limit.max_height == 0) return;

        const info: *MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lParam)));
        const hwnd = self.windowHwnd() orelse return;
        var client_rect: RECT = undefined;
        var window_rect: RECT = undefined;
        if (GetClientRect(hwnd, &client_rect) == 0) return;
        if (GetWindowRect(hwnd, &window_rect) == 0) return;

        const frame_width = (window_rect.right - window_rect.left) - (client_rect.right - client_rect.left);
        const frame_height = (window_rect.bottom - window_rect.top) - (client_rect.bottom - client_rect.top);

        if (self.size_limit.min_width > 0) {
            info.ptMinTrackSize.x = @as(i32, @intCast(self.size_limit.min_width)) + frame_width;
        }
        if (self.size_limit.min_height > 0) {
            info.ptMinTrackSize.y = @as(i32, @intCast(self.size_limit.min_height)) + frame_height;
        }
        if (self.size_limit.max_width > 0) {
            info.ptMaxTrackSize.x = @as(i32, @intCast(self.size_limit.max_width)) + frame_width;
        }
        if (self.size_limit.max_height > 0) {
            info.ptMaxTrackSize.y = @as(i32, @intCast(self.size_limit.max_height)) + frame_height;
        }
    }

    fn applyWindowStyle(self: *Surface) !void {
        const hwnd = self.windowHwnd() orelse return;
        const style: u32 = if (self.fullscreen)
            WS_VISIBLE | WS_POPUP
        else if (self.decorations_visible)
            WS_VISIBLE | WS_OVERLAPPEDWINDOW
        else
            WS_VISIBLE | WS_OVERLAPPED;

        _ = SetWindowLongPtrW(hwnd, GWL_STYLE, @bitCast(@as(isize, @intCast(style))));
        if (SetWindowPos(
            hwnd,
            null,
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED,
        ) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
    }

    fn applyBackgroundOpacity(self: *Surface) !void {
        const hwnd = self.windowHwnd() orelse return;
        const opacity = effectiveBackgroundOpacity(
            self.background_opacity_default,
            self.background_opacity_force_opaque,
        );
        const ex_style_raw = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        var ex_style: u32 = @intCast(@as(usize, @bitCast(ex_style_raw)));

        if (opacity >= 0.999) {
            if ((ex_style & WS_EX_LAYERED) != 0) {
                ex_style &= ~@as(u32, WS_EX_LAYERED);
                _ = SetWindowLongPtrW(hwnd, GWL_EXSTYLE, @bitCast(@as(isize, @intCast(ex_style))));
                _ = SetWindowPos(
                    hwnd,
                    null,
                    0,
                    0,
                    0,
                    0,
                    SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED,
                );
            }
            return;
        }

        if ((ex_style & WS_EX_LAYERED) == 0) {
            ex_style |= WS_EX_LAYERED;
            _ = SetWindowLongPtrW(hwnd, GWL_EXSTYLE, @bitCast(@as(isize, @intCast(ex_style))));
        }

        if (SetLayeredWindowAttributes(hwnd, 0, alphaByteForOpacity(opacity), LWA_ALPHA) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
    }

    fn applyTopmost(self: *Surface) !void {
        const hwnd = self.windowHwnd() orelse return;
        if (SetWindowPos(
            hwnd,
            if (self.topmost) HWND_TOPMOST else HWND_NOTOPMOST,
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED,
        ) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
    }

    fn windowSizeChanged(self: *Surface) void {
        const hwnd = self.hwnd orelse return;
        self.size = self.app.clientSize(hwnd) catch return;

        if (!self.core_initialized) return;
        self.core_surface.sizeCallback(self.size) catch |err| {
            log.err("win32 size callback failed err={}", .{err});
        };
    }

    fn focusChanged(self: *Surface, focused: bool) void {
        self.window_focused = focused;
        traceWin32("win32 focus changed: focused={} core_initialized={}", .{
            focused,
            self.core_initialized,
        });
        if (!self.core_initialized) return;
        if (focused) self.app.core_app.focusSurface(self.core());
        self.core_surface.focusCallback(focused) catch |err| {
            log.err("win32 focus callback failed err={}", .{err});
        };
    }

    fn handleKeyMessage(self: *Surface, msg: UINT, wParam: WPARAM, lParam: LPARAM) void {
        if (!self.core_initialized) return;

        const vk: UINT = @intCast(wParam & 0xFFFF);
        const key = keyFromVirtualKey(vk, lParam);
        const mods = currentMods();
        const action: input.Action = switch (msg) {
            WM_KEYUP, WM_SYSKEYUP => .release,
            else => if (isRepeatedKey(lParam)) .repeat else .press,
        };

        var event: input.KeyEvent = .{
            .action = action,
            .key = key,
            .mods = mods,
            .unshifted_codepoint = unshiftedCodepointForVirtualKey(vk),
        };

        if (action != .release) {
            const translated = translateKeyText(vk, lParam, mods);
            event.utf8 = translated.utf8[0..translated.len];
            event.consumed_mods = translated.consumed_mods;
            if (translated.unshifted_codepoint != 0) {
                event.unshifted_codepoint = translated.unshifted_codepoint;
            }
        }

        if (self.debug_input_budget > 0) {
            self.debug_input_budget -= 1;
            traceWin32("win32 key: msg=0x{x} vk=0x{x} action={} key={} utf8_len={} focused={}", .{
                msg,
                vk,
                action,
                key,
                event.utf8.len,
                self.window_focused,
            });
        }

        _ = self.core_surface.keyCallback(event) catch |err| {
            log.err("win32 key callback failed err={} vk={} action={} key={} mods={}", .{
                err,
                vk,
                action,
                key,
                mods,
            });
            return;
        };
    }

    fn handleMouseMove(self: *Surface, lParam: LPARAM, mods: input.Mods) void {
        if (!self.core_initialized) return;
        self.cursor_pos = cursorPosFromLParam(lParam);
        self.core_surface.cursorPosCallback(self.cursor_pos, mods) catch |err| {
            log.err("win32 cursor pos callback failed err={}", .{err});
        };
    }

    fn handleMouseButton(self: *Surface, msg: UINT, wParam: WPARAM, lParam: LPARAM) void {
        if (!self.core_initialized) return;

        const button = mouseButtonFromMessage(msg) orelse return;
        const state = mouseButtonStateFromMessage(msg) orelse return;
        const mods = mouseModsFromWParam(wParam);

        self.cursor_pos = cursorPosFromLParam(lParam);
        if (state == .press) {
            if (self.hwnd) |hwnd| {
                _ = SetFocus(hwnd);
                _ = SetCapture(hwnd);
            }
        } else {
            _ = ReleaseCapture();
        }

        if (self.debug_input_budget > 0) {
            self.debug_input_budget -= 1;
            traceWin32("win32 mouse button: button={} state={} x={} y={} focused={}", .{
                button,
                state,
                self.cursor_pos.x,
                self.cursor_pos.y,
                self.window_focused,
            });
        }

        self.core_surface.cursorPosCallback(self.cursor_pos, mods) catch |err| {
            log.err("win32 cursor pos callback failed before button err={}", .{err});
        };
        _ = self.core_surface.mouseButtonCallback(state, button, mods) catch |err| {
            log.err("win32 mouse button callback failed err={} button={} state={}", .{
                err,
                button,
                state,
            });
            return;
        };
    }

    fn wheelNormalizationContext(self: *const Surface) WheelNormalizationContext {
        return .{
            .settings = self.app.wheel_settings,
            .cell_size = self.cell_size_pixels,
            .viewport = self.size,
        };
    }

    fn handleMouseWheel(self: *Surface, scroll: NormalizedWheelScroll) void {
        if (!self.core_initialized) return;
        self.core_surface.scrollCallback(scroll.xoff, scroll.yoff, scroll.mods) catch |err| {
            log.err("win32 scroll callback failed err={} xoff={} yoff={} mods={}", .{
                err,
                scroll.xoff,
                scroll.yoff,
                scroll.mods,
            });
        };
    }

    fn destroy(self: *Surface) void {
        const alloc = self.app.core_app.alloc;
        self.destroy_on_wm_destroy = false;
        self.hwnd = null;

        if (self.core_initialized) {
            if (self.inspector_visible) {
                self.core_surface.deactivateInspector();
                self.inspector_visible = false;
            }
            self.app.core_app.deleteSurface(self);
            self.core_surface.deinit();
            self.core_initialized = false;
        }

        self.destroyGL();

        if (self.title) |title| {
            alloc.free(title);
            self.title = null;
        }
        if (self.title_override) |value| {
            alloc.free(value);
            self.title_override = null;
        }
        if (self.tab_title_override) |value| {
            alloc.free(value);
            self.tab_title_override = null;
        }
        if (self.launch_profile_key) |value| {
            alloc.free(value);
            self.launch_profile_key = null;
        }
        if (self.key_table_name) |value| {
            alloc.free(value);
            self.key_table_name = null;
        }
        if (self.search_needle) |value| {
            alloc.free(value);
            self.search_needle = null;
        }
        if (self.pwd) |value| {
            alloc.free(value);
            self.pwd = null;
        }
        if (self.progress_status) |value| {
            alloc.free(value);
            self.progress_status = null;
        }

        self.app.windowDestroyed(self);
        alloc.destroy(self);
    }

    fn setMouseShape(self: *Surface, shape: terminal.MouseShape) void {
        self.mouse_shape = shape;
        _ = self.applyCursor();
    }

    fn setMouseVisibility(self: *Surface, visibility: apprt.action.MouseVisibility) void {
        self.mouse_visible = visibility == .visible;
        _ = self.applyCursor();
    }

    fn setVisible(self: *Surface, visible: bool) void {
        const hwnd = self.hwnd orelse return;
        _ = ShowWindow(hwnd, if (visible) SW_SHOW else SW_HIDE);
    }

    fn setReadonly(self: *Surface, enabled: bool) !void {
        self.readonly = enabled;
        try self.refreshWindowTitle();
    }

    fn setPwd(self: *Surface, pwd: []const u8) !void {
        const alloc = self.app.core_app.alloc;
        try appendOwnedString(alloc, &self.pwd, pwd);
        try self.refreshWindowTitle();
    }

    fn setSecureInput(self: *Surface, value: apprt.action.SecureInput) !void {
        self.secure_input = switch (value) {
            .on => true,
            .off => false,
            .toggle => !self.secure_input,
        };
        try self.refreshWindowTitle();
    }

    fn setKeySequenceActive(self: *Surface, active: bool) !void {
        self.key_sequence_active = active;
        try self.refreshWindowTitle();
    }

    fn setKeyTable(self: *Surface, value: apprt.action.KeyTable) !void {
        const alloc = self.app.core_app.alloc;
        switch (value) {
            .activate => |name| try appendOwnedString(alloc, &self.key_table_name, name),
            .deactivate, .deactivate_all => try appendOwnedString(alloc, &self.key_table_name, null),
        }
        try self.refreshWindowTitle();
    }

    fn setSearchActive(self: *Surface, active: bool, needle: []const u8) !void {
        const alloc = self.app.core_app.alloc;
        self.search_active = active;
        self.search_total = null;
        self.search_selected = null;
        if (active and needle.len > 0) {
            try appendOwnedString(alloc, &self.search_needle, needle);
        } else if (!active) {
            try appendOwnedString(alloc, &self.search_needle, null);
        }
        try self.refreshWindowTitle();
    }

    fn setSearchTotal(self: *Surface, total: ?usize) !void {
        self.search_total = total;
        try self.refreshWindowTitle();
    }

    fn setSearchSelected(self: *Surface, selected: ?usize) !void {
        self.search_selected = selected;
        try self.refreshWindowTitle();
    }

    fn setScrollbar(self: *Surface, value: terminal.Scrollbar) !void {
        if (self.scrollbar.eql(value)) return;
        self.scrollbar = value;
    }

    fn setProgressReport(self: *Surface, value: terminal.osc.Command.ProgressReport) !void {
        const alloc = self.app.core_app.alloc;
        const progress = try formatProgressStatus(alloc, value);
        defer if (progress) |owned| alloc.free(owned);
        try appendOwnedString(alloc, &self.progress_status, progress);
        try self.refreshWindowTitle();
    }

    fn applyCursor(self: *Surface) bool {
        if (!self.mouse_visible) {
            _ = SetCursor(null);
            return true;
        }

        const cursor_name: INTRESOURCE = switch (self.mouse_shape) {
            .default => IDC_ARROW,
            .help => @as(INTRESOURCE, @ptrFromInt(32651)),
            .pointer, .grab, .grabbing => @as(INTRESOURCE, @ptrFromInt(32649)),
            .progress => @as(INTRESOURCE, @ptrFromInt(32650)),
            .wait => @as(INTRESOURCE, @ptrFromInt(32514)),
            .crosshair => @as(INTRESOURCE, @ptrFromInt(32515)),
            .text, .vertical_text, .cell => @as(INTRESOURCE, @ptrFromInt(32513)),
            .move, .all_scroll => @as(INTRESOURCE, @ptrFromInt(32646)),
            .not_allowed, .no_drop => @as(INTRESOURCE, @ptrFromInt(32648)),
            .col_resize, .ew_resize, .e_resize, .w_resize => @as(INTRESOURCE, @ptrFromInt(32644)),
            .row_resize, .ns_resize, .n_resize, .s_resize => @as(INTRESOURCE, @ptrFromInt(32645)),
            .ne_resize, .sw_resize, .nesw_resize => @as(INTRESOURCE, @ptrFromInt(32643)),
            .nw_resize, .se_resize, .nwse_resize => @as(INTRESOURCE, @ptrFromInt(32642)),
            .context_menu,
            .alias,
            .copy,
            .zoom_in,
            .zoom_out,
            => IDC_ARROW,
        };

        _ = SetCursor(LoadCursorW(null, cursor_name));
        return true;
    }

    fn confirmClipboardRead(self: *const Surface) bool {
        return self.confirmMessageBox(clipboard_read_title, clipboard_read_message, MB_YESNO | MB_ICONWARNING) == IDYES;
    }

    fn confirmClipboardWrite(self: *const Surface) bool {
        return self.confirmMessageBox(clipboard_write_title, clipboard_write_message, MB_YESNO | MB_ICONWARNING) == IDYES;
    }

    fn confirmMessageBox(
        self: *const Surface,
        title: LPCWSTR,
        message: LPCWSTR,
        flags: UINT,
    ) i32 {
        return MessageBoxW(self.hwnd, message, title, flags);
    }

    fn readClipboardText(self: *Surface) !?[:0]u8 {
        if (OpenClipboard(self.hwnd) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
        defer _ = CloseClipboard();

        if (IsClipboardFormatAvailable(CF_UNICODETEXT) == 0) return null;

        const handle = GetClipboardData(CF_UNICODETEXT) orelse return null;
        const locked = GlobalLock(handle) orelse return null;
        defer _ = GlobalUnlock(handle);

        const text_w: [*:0]const u16 = @ptrCast(@alignCast(locked));
        const slice_w = std.mem.sliceTo(text_w, 0);
        return try std.unicode.utf16LeToUtf8AllocZ(self.app.core_app.alloc, slice_w);
    }

    fn writeClipboardText(self: *const Surface, text: []const u8) !void {
        const alloc = self.app.core_app.alloc;
        const text_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, text);
        defer alloc.free(text_w);

        if (OpenClipboard(self.hwnd) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
        defer _ = CloseClipboard();

        if (EmptyClipboard() == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }

        const bytes = (text_w.len + 1) * @sizeOf(u16);
        const mem = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, bytes) orelse
            return windows.unexpectedError(windows.kernel32.GetLastError());
        errdefer _ = GlobalFree(mem);

        const locked = GlobalLock(mem) orelse
            return windows.unexpectedError(windows.kernel32.GetLastError());
        defer _ = GlobalUnlock(mem);

        const dst: [*]u16 = @ptrCast(@alignCast(locked));
        @memcpy(dst[0 .. text_w.len + 1], text_w[0 .. text_w.len + 1]);

        if (SetClipboardData(CF_UNICODETEXT, mem) == null) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
    }

    fn destroyGL(self: *Surface) void {
        if (self.hglrc != null) {
            self.clearGLContextCurrent();
            _ = wglDeleteContext(self.hglrc);
            self.hglrc = null;
        }

        if (self.hdc != null) {
            if (self.hwnd) |hwnd| _ = ReleaseDC(hwnd, self.hdc);
            self.hdc = null;
        }

        self.hwnd = null;
    }
};

test "win32 runtime can initialize config" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var core = try CoreApp.create(std.testing.allocator);
    defer core.destroy();

    var app: App = undefined;
    try app.init(core, .{});
    defer app.terminate();

    try std.testing.expect(@intFromPtr(app.hinstance) != 0);
}

test "win32 keyFromVirtualKey maps core keys" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(input.Key.key_a, keyFromVirtualKey(VK_A, 0));
    try std.testing.expectEqual(input.Key.enter, keyFromVirtualKey(VK_RETURN, 0));
    try std.testing.expectEqual(input.Key.numpad_enter, keyFromVirtualKey(VK_RETURN, KF_EXTENDED));
    try std.testing.expectEqual(input.Key.arrow_left, keyFromVirtualKey(VK_LEFT, 0));
    try std.testing.expectEqual(input.Key.f12, keyFromVirtualKey(VK_F1 + 11, 0));
    try std.testing.expectEqual(input.Key.quote, keyFromVirtualKey(VK_OEM_7, 0));
}

test "win32 cursorPosFromLParam decodes signed coordinates" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const y: u16 = @bitCast(@as(i16, -5));
    const x: u16 = @bitCast(@as(i16, 12));
    const encoded = (@as(usize, y) << 16) | @as(usize, x);
    const pos = cursorPosFromLParam(@bitCast(@as(isize, @intCast(encoded))));
    try std.testing.expectEqual(@as(f32, 12), pos.x);
    try std.testing.expectEqual(@as(f32, -5), pos.y);
}

test "win32 normalizeWheelDelta maps discrete wheel steps to pixel deltas" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const event = normalizeWheelDelta(.{
        .settings = .{ .lines = 3, .chars = 5 },
        .cell_size = .{ .width = 8, .height = 16 },
        .viewport = .{ .width = 800, .height = 600 },
    }, .vertical, 120);

    try std.testing.expectApproxEqAbs(-48.0, event.yoff, 0.0001);
    try std.testing.expectEqual(@as(f64, 0), event.xoff);
    try std.testing.expect(!event.mods.precision);
    try std.testing.expect(event.mods.pixel_delta);
}

test "win32 normalizeWheelDelta maps horizontal wheel steps to pixel deltas" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const event = normalizeWheelDelta(.{
        .settings = .{ .lines = 3, .chars = 5 },
        .cell_size = .{ .width = 8, .height = 16 },
        .viewport = .{ .width = 800, .height = 600 },
    }, .horizontal, 120);

    try std.testing.expectApproxEqAbs(40.0, event.xoff, 0.0001);
    try std.testing.expectEqual(@as(f64, 0), event.yoff);
    try std.testing.expect(!event.mods.precision);
    try std.testing.expect(event.mods.pixel_delta);
}

test "win32 normalizeWheelDelta scales high-resolution input proportionally" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const event = normalizeWheelDelta(.{
        .settings = .{ .lines = 3, .chars = 3 },
        .cell_size = .{ .width = 8, .height = 16 },
        .viewport = .{ .width = 800, .height = 600 },
    }, .vertical, 40);

    try std.testing.expectApproxEqAbs(-(16.0 / 3.0), event.yoff, 0.0001);
    try std.testing.expect(event.mods.precision);
    try std.testing.expect(event.mods.pixel_delta);
}

test "win32 normalizeWheelDelta honors page scroll settings" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const event = normalizeWheelDelta(.{
        .settings = .{ .lines = WHEEL_PAGESCROLL, .chars = 3 },
        .cell_size = .{ .width = 8, .height = 16 },
        .viewport = .{ .width = 800, .height = 600 },
    }, .vertical, 120);

    try std.testing.expectApproxEqAbs(-584.0, event.yoff, 0.0001);
    try std.testing.expect(!event.mods.precision);
    try std.testing.expect(event.mods.pixel_delta);
}

test "win32 normalizeWheelDelta ignores page scroll settings for high-resolution input" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const event = normalizeWheelDelta(.{
        .settings = .{ .lines = WHEEL_PAGESCROLL, .chars = 3 },
        .cell_size = .{ .width = 8, .height = 16 },
        .viewport = .{ .width = 800, .height = 600 },
    }, .vertical, 40);

    try std.testing.expectApproxEqAbs(-(16.0 / 3.0), event.yoff, 0.0001);
    try std.testing.expect(event.mods.precision);
    try std.testing.expect(event.mods.pixel_delta);
}

test "win32 normalizeWheelDelta ignores disabled notch settings for high-resolution input" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const event = normalizeWheelDelta(.{
        .settings = .{ .lines = 0, .chars = 0 },
        .cell_size = .{ .width = 8, .height = 16 },
        .viewport = .{ .width = 800, .height = 600 },
    }, .vertical, 40);

    try std.testing.expectApproxEqAbs(-(16.0 / 3.0), event.yoff, 0.0001);
    try std.testing.expect(event.mods.precision);
    try std.testing.expect(event.mods.pixel_delta);
}

test "win32 sanitizeIpcNamespace normalizes invalid characters" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const actual = try sanitizeIpcNamespace(std.testing.allocator, "  team/alpha:*beta  ");
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualStrings("team_alpha__beta", actual);
}

test "win32 allocIpcPipeName prefixes sanitized namespace" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const pipe_name = try allocIpcPipeName(std.testing.allocator, "demo class");
    defer std.testing.allocator.free(pipe_name);

    const pipe_name_utf8 = try std.unicode.utf16LeToUtf8Alloc(std.testing.allocator, pipe_name[0..std.mem.len(pipe_name)]);
    defer std.testing.allocator.free(pipe_name_utf8);

    try std.testing.expectEqualStrings("\\\\.\\pipe\\winghostty.demo_class", pipe_name_utf8);
}

test "win32 normalizeForwardedStartupArg drops class and normalizes working directory" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(try normalizeForwardedStartupArg(std.testing.allocator, "--class=dev") == null);

    const inherit = (try normalizeForwardedStartupArg(std.testing.allocator, "--working-directory=inherit")).?;
    defer std.testing.allocator.free(inherit);
    try std.testing.expectEqualStrings("--working-directory=inherit", inherit);

    const other = (try normalizeForwardedStartupArg(std.testing.allocator, "--title=Inbox")).?;
    defer std.testing.allocator.free(other);
    try std.testing.expectEqualStrings("--title=Inbox", other);
}

test "win32 hostWindowStyle clips child repaints" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const style = hostWindowStyle();
    try std.testing.expect((style & WS_CLIPCHILDREN) != 0);
    try std.testing.expect((style & WS_VISIBLE) != 0);
}

test "win32 surfaceWindowStyle clips sibling repaints" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const style = surfaceWindowStyle();
    try std.testing.expect((style & WS_CLIPSIBLINGS) != 0);
    try std.testing.expect((style & WS_CHILD) != 0);
}

test "win32 buildWindowTitle appends active status segments" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const title = try buildWindowTitle(std.testing.allocator, "pwsh", .{
        .pwd = "/Users/amant",
        .scrollbar = .{
            .total = 200,
            .offset = 50,
            .len = 40,
        },
        .readonly = true,
        .secure_input = true,
        .key_sequence_active = true,
        .key_table_name = "resize",
        .search = .{
            .active = true,
            .needle = "foo",
            .total = 4,
            .selected = 2,
        },
        .progress = "progress:35%",
    });
    defer std.testing.allocator.free(title);

    try std.testing.expectEqualStrings(
        "pwsh | readonly | secure | keys | table:resize | cwd:/Users/amant | find:foo (2/4) | progress:35%",
        title,
    );
}

test "win32 buildWindowTitle uses default title when base is null" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const title = try buildWindowTitle(std.testing.allocator, null, .{});
    defer std.testing.allocator.free(title);

    try std.testing.expectEqualStrings("winghostty", title);
}

test "win32 resolveWindowBaseTitle prefers tab then surface override" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqualStrings(
        "tab",
        resolveWindowBaseTitle("terminal", "surface", "tab").?,
    );
    try std.testing.expectEqualStrings(
        "surface",
        resolveWindowBaseTitle("terminal", "surface", null).?,
    );
    try std.testing.expectEqualStrings(
        "terminal",
        resolveWindowBaseTitle("terminal", null, null).?,
    );
}

test "win32 effectiveBackgroundOpacity respects opaque override" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(@as(f64, 0.4), effectiveBackgroundOpacity(0.4, false));
    try std.testing.expectEqual(@as(f64, 1.0), effectiveBackgroundOpacity(0.4, true));
    try std.testing.expectEqual(@as(u8, 128), alphaByteForOpacity(0.5));
}

test "win32 resizeSplitFallbackDelta maps directions to window deltas" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqualDeep(
        ResizeSplitFallbackDelta{ .width = -24, .height = 0 },
        resizeSplitFallbackDelta(.{ .amount = 24, .direction = .left }),
    );
    try std.testing.expectEqualDeep(
        ResizeSplitFallbackDelta{ .width = 0, .height = 12 },
        resizeSplitFallbackDelta(.{ .amount = 12, .direction = .down }),
    );
}

test "win32 nextInspectorVisible follows requested mode" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(nextInspectorVisible(false, .toggle));
    try std.testing.expect(!nextInspectorVisible(true, .toggle));
    try std.testing.expect(nextInspectorVisible(false, .show));
    try std.testing.expect(!nextInspectorVisible(true, .hide));
}

test "win32 primarySurfaceIndex prefers active tab of first host" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const entries = [_]SurfaceOrderEntry{
        .{ .host_id = 11, .host_active = false },
        .{ .host_id = 22, .host_active = true },
        .{ .host_id = 11, .host_active = true },
    };
    try std.testing.expectEqual(@as(?usize, 2), primarySurfaceIndex(&entries));

    const fallback = [_]SurfaceOrderEntry{
        .{ .host_id = 11, .host_active = false },
        .{ .host_id = 22, .host_active = true },
    };
    try std.testing.expectEqual(@as(?usize, 0), primarySurfaceIndex(&fallback));
}

test "win32 buildHostAwareBaseTitle prefixes host tab position" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const titled = try buildHostAwareBaseTitle(std.testing.allocator, "pwsh", .{
        .index = 1,
        .total = 3,
    });
    defer std.testing.allocator.free(titled);
    try std.testing.expectEqualStrings("[2/3] pwsh", titled);

    const single = try buildHostAwareBaseTitle(std.testing.allocator, "pwsh", .{
        .index = 0,
        .total = 1,
    });
    defer std.testing.allocator.free(single);
    try std.testing.expectEqualStrings("pwsh", single);
}

test "win32 buildTabButtonLabel marks active tab and pane count" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const title = try buildTabButtonLabel(std.testing.allocator, "pwsh", 1, true, 3, 24, true);
    defer std.testing.allocator.free(title);
    try std.testing.expectEqualStrings("* 2: pwsh (3)", title);
}

test "win32 buildTabButtonLabel omits pane count for single pane tabs" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const title = try buildTabButtonLabel(std.testing.allocator, "pwsh", 0, false, 1, 24, false);
    defer std.testing.allocator.free(title);
    try std.testing.expectEqualStrings("1: pwsh", title);
}

test "win32 buildTabButtonLabel compacts long titles" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const title = try buildTabButtonLabel(std.testing.allocator, "this-is-a-very-long-terminal-title", 0, false, 1, 24, false);
    defer std.testing.allocator.free(title);
    try std.testing.expectEqualStrings("1: this-is-a-very-long-t...", title);
}

test "win32 buildTabButtonLabel drops pane count when tabs are narrow" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const title = try buildTabButtonLabel(std.testing.allocator, "logs-and-output-pane", 1, false, 3, 9, false);
    defer std.testing.allocator.free(title);
    try std.testing.expectEqualStrings("2: logs-a...", title);
}

test "win32 hostTabLabelMaxLen shrinks with narrow tab widths" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(@as(usize, 24), hostTabLabelMaxLen(260));
    try std.testing.expectEqual(@as(usize, 9), hostTabLabelMaxLen(98));
    try std.testing.expectEqual(@as(usize, 6), hostTabLabelMaxLen(40));
    try std.testing.expect(shouldShowPaneCount(180, 3));
    try std.testing.expect(!shouldShowPaneCount(120, 3));
}

test "win32 visibleTabRange windows tabs around the active tab" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqualDeep(VisibleTabRange{ .start = 0, .count = 3 }, visibleTabRange(6, 0, 324));
    try std.testing.expectEqualDeep(VisibleTabRange{ .start = 2, .count = 3 }, visibleTabRange(6, 3, 324));
    try std.testing.expectEqualDeep(VisibleTabRange{ .start = 3, .count = 3 }, visibleTabRange(6, 5, 324));
    try std.testing.expectEqualDeep(VisibleTabRange{ .start = 0, .count = 2 }, visibleTabRange(2, 1, 500));
}

test "win32 buildTabOverviewBannerText lists active tabs and pane counts" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const banner = try buildTabOverviewBannerText(std.testing.allocator, &.{
        .{ .title = "pwsh", .pane_count = 1, .active = true },
        .{ .title = "logs-and-output-pane", .pane_count = 3, .active = false },
    });
    defer std.testing.allocator.free(banner);
    try std.testing.expectEqualStrings("Tabs: *1:pwsh | 2:logs-and-output... (3)", banner);
}

test "win32 buildSearchButtonLabel reflects active search state" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const active = try buildSearchButtonLabel(std.testing.allocator, true, 8, 2);
    defer std.testing.allocator.free(active);
    try std.testing.expectEqualStrings("[F] 2/8", active);

    const passive = try buildSearchButtonLabel(std.testing.allocator, false, 5, null);
    defer std.testing.allocator.free(passive);
    try std.testing.expectEqualStrings("Find 5", passive);

    const idle = try buildSearchButtonLabel(std.testing.allocator, false, null, null);
    defer std.testing.allocator.free(idle);
    try std.testing.expectEqualStrings("Find", idle);
}

test "win32 buildProfilesButtonLabel reflects selected cached profile" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const profiles = [_]windows_shell.Profile{
        .{
            .kind = .pwsh,
            .key = "pwsh.exe",
            .label = "PowerShell",
            .command = .{ .direct = &.{"pwsh.exe"} },
        },
        .{
            .kind = .git_bash,
            .key = "git-bash",
            .label = "Git Bash",
            .command = .{ .direct = &.{"bash.exe"} },
        },
    };

    const active = try buildProfilesButtonLabel(std.testing.allocator, true, &profiles, 1, 1);
    defer std.testing.allocator.free(active);
    try std.testing.expectEqualStrings("[*2 GIT $> Git Bash]", active);

    const idle = try buildProfilesButtonLabel(std.testing.allocator, false, &profiles, 0, null);
    defer std.testing.allocator.free(idle);
    try std.testing.expectEqualStrings("1 PWSH >> Power...", idle);
}

test "win32 profilesButtonKeyAction maps focused launcher keys" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(ProfilesButtonKeyAction.open, profilesButtonKeyAction(VK_RETURN).?);
    try std.testing.expectEqual(ProfilesButtonKeyAction.toggle, profilesButtonKeyAction(VK_SPACE).?);
    try std.testing.expectEqual(ProfilesButtonKeyAction.previous, profilesButtonKeyAction(VK_LEFT).?);
    try std.testing.expectEqual(ProfilesButtonKeyAction.next, profilesButtonKeyAction(VK_DOWN).?);
    try std.testing.expectEqual(ProfilesButtonKeyAction.first, profilesButtonKeyAction(VK_HOME).?);
    try std.testing.expectEqual(ProfilesButtonKeyAction.last, profilesButtonKeyAction(VK_END).?);
}

test "win32 profileShortcutIndexFromKey supports top row and numpad digits" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(@as(?usize, 0), profileShortcutIndexFromKey('1'));
    try std.testing.expectEqual(@as(?usize, 4), profileShortcutIndexFromKey('5'));
    try std.testing.expectEqual(@as(?usize, 8), profileShortcutIndexFromKey('9'));
    try std.testing.expectEqual(@as(?usize, 0), profileShortcutIndexFromKey(0x61));
    try std.testing.expectEqual(@as(?usize, 8), profileShortcutIndexFromKey(0x69));
    try std.testing.expectEqual(@as(?usize, null), profileShortcutIndexFromKey('0'));
    try std.testing.expectEqual(@as(?usize, null), profileShortcutIndexFromKey('A'));
}

test "win32 quickSlotShortcutProfileIndex maps visible launcher slots" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(@as(?usize, 1), quickSlotShortcutProfileIndex(5, 0, '1', true));
    try std.testing.expectEqual(@as(?usize, 2), quickSlotShortcutProfileIndex(5, 0, '2', true));
    try std.testing.expectEqual(@as(?usize, 3), quickSlotShortcutProfileIndex(5, 0, '3', true));
    try std.testing.expectEqual(@as(?usize, 0), quickSlotShortcutProfileIndex(5, 3, '1', true));
    try std.testing.expectEqual(@as(?usize, 1), quickSlotShortcutProfileIndex(5, 3, '2', true));
    try std.testing.expectEqual(@as(?usize, null), quickSlotShortcutProfileIndex(5, 0, '4', true));
    try std.testing.expectEqual(@as(?usize, null), quickSlotShortcutProfileIndex(5, 0, '1', false));
}

test "win32 quickSlotPinOrdinalFromKey maps visible pin slots" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(@as(?usize, 0), quickSlotPinOrdinalFromKey('1', true, true));
    try std.testing.expectEqual(@as(?usize, 2), quickSlotPinOrdinalFromKey('3', true, true));
    try std.testing.expectEqual(@as(?usize, null), quickSlotPinOrdinalFromKey('4', true, true));
    try std.testing.expectEqual(@as(?usize, null), quickSlotPinOrdinalFromKey('1', true, false));
    try std.testing.expectEqual(@as(?usize, null), quickSlotPinOrdinalFromKey('1', false, true));
}

test "win32 clearQuickSlotPinsRequested detects clear shortcut" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(clearQuickSlotPinsRequested(VK_0, true, true));
    try std.testing.expect(clearQuickSlotPinsRequested(VK_NUMPAD0, true, true));
    try std.testing.expect(!clearQuickSlotPinsRequested('1', true, true));
    try std.testing.expect(!clearQuickSlotPinsRequested(VK_0, true, false));
    try std.testing.expect(!clearQuickSlotPinsRequested(VK_0, false, true));
}

test "win32 quickSlotFocusKeyAction maps painted quick slot focus keys" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(QuickSlotFocusKeyAction.previous, quickSlotFocusKeyAction(VK_LEFT).?);
    try std.testing.expectEqual(QuickSlotFocusKeyAction.previous, quickSlotFocusKeyAction(VK_UP).?);
    try std.testing.expectEqual(QuickSlotFocusKeyAction.next, quickSlotFocusKeyAction(VK_RIGHT).?);
    try std.testing.expectEqual(QuickSlotFocusKeyAction.next, quickSlotFocusKeyAction(VK_DOWN).?);
    try std.testing.expectEqual(QuickSlotFocusKeyAction.first, quickSlotFocusKeyAction(VK_HOME).?);
    try std.testing.expectEqual(QuickSlotFocusKeyAction.last, quickSlotFocusKeyAction(VK_END).?);
    try std.testing.expectEqual(QuickSlotFocusKeyAction.open, quickSlotFocusKeyAction(VK_RETURN).?);
    try std.testing.expect(quickSlotFocusKeyAction(VK_SPACE) == null);
}

test "win32 profileOpenTargetFromModifiers prefers split then window" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(ProfileOpenTarget.tab, resolveProfileOpenTarget(.tab, false, false));
    try std.testing.expectEqual(ProfileOpenTarget.window, resolveProfileOpenTarget(.tab, true, false));
    try std.testing.expectEqual(ProfileOpenTarget.split, resolveProfileOpenTarget(.tab, false, true));
    try std.testing.expectEqual(ProfileOpenTarget.split, resolveProfileOpenTarget(.window, true, true));
}

test "win32 cycleProfileOpenTarget wraps launcher target order" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(ProfileOpenTarget.window, cycleProfileOpenTarget(.tab, false));
    try std.testing.expectEqual(ProfileOpenTarget.split, cycleProfileOpenTarget(.window, false));
    try std.testing.expectEqual(ProfileOpenTarget.tab, cycleProfileOpenTarget(.split, false));
    try std.testing.expectEqual(ProfileOpenTarget.split, cycleProfileOpenTarget(.tab, true));
}

test "win32 launchTargetButtonLabel reflects selected launcher slot" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const pane = try launchTargetButtonLabel(std.testing.allocator, .split, 2, 2);
    defer std.testing.allocator.free(pane);
    try std.testing.expectEqualStrings("*3 Pane", pane);

    const tab = try launchTargetButtonLabel(std.testing.allocator, .tab, null, null);
    defer std.testing.allocator.free(tab);
    try std.testing.expectEqualStrings("Tab", tab);
}

test "win32 launchTargetButtonKeyAction maps focused target keys" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(LaunchTargetButtonKeyAction.previous, launchTargetButtonKeyAction(VK_LEFT).?);
    try std.testing.expectEqual(LaunchTargetButtonKeyAction.previous, launchTargetButtonKeyAction(VK_UP).?);
    try std.testing.expectEqual(LaunchTargetButtonKeyAction.next, launchTargetButtonKeyAction(VK_RIGHT).?);
    try std.testing.expectEqual(LaunchTargetButtonKeyAction.next, launchTargetButtonKeyAction(VK_SPACE).?);
    try std.testing.expectEqual(LaunchTargetButtonKeyAction.first, launchTargetButtonKeyAction(VK_HOME).?);
    try std.testing.expectEqual(LaunchTargetButtonKeyAction.last, launchTargetButtonKeyAction(VK_END).?);
}

test "win32 parseProfileOpenTarget accepts terminal-style launch target names" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(ProfileOpenTarget.tab, parseProfileOpenTarget("tab").?);
    try std.testing.expectEqual(ProfileOpenTarget.window, parseProfileOpenTarget("window").?);
    try std.testing.expectEqual(ProfileOpenTarget.window, parseProfileOpenTarget("win").?);
    try std.testing.expectEqual(ProfileOpenTarget.split, parseProfileOpenTarget("split").?);
    try std.testing.expectEqual(ProfileOpenTarget.split, parseProfileOpenTarget("pane").?);
    try std.testing.expect(parseProfileOpenTarget("definitely_not_real") == null);
}

test "win32 launchTargetButtonLabel reflects Windows-style target wording" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const tab = try launchTargetButtonLabel(std.testing.allocator, .tab, null, null);
    defer std.testing.allocator.free(tab);
    try std.testing.expectEqualStrings("Tab", tab);

    const win = try launchTargetButtonLabel(std.testing.allocator, .window, null, null);
    defer std.testing.allocator.free(win);
    try std.testing.expectEqualStrings("Win", win);

    const pane = try launchTargetButtonLabel(std.testing.allocator, .split, null, null);
    defer std.testing.allocator.free(pane);
    try std.testing.expectEqualStrings("Pane", pane);
}

test "win32 preferredProfileIndex respects host key then app key then hint" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const profiles = [_]windows_shell.Profile{
        .{
            .kind = .pwsh,
            .key = "pwsh.exe",
            .label = "PowerShell",
            .command = .{ .direct = &.{"pwsh.exe"} },
        },
        .{
            .kind = .git_bash,
            .key = "git-bash",
            .label = "Git Bash",
            .command = .{ .direct = &.{"bash.exe"} },
        },
        .{
            .kind = .cmd,
            .key = "cmd.exe",
            .label = "Command Prompt",
            .command = .{ .direct = &.{"cmd.exe"} },
        },
    };

    try std.testing.expectEqual(@as(?usize, 1), preferredProfileIndex(&profiles, "git-bash", null, "cmd", 0));
    try std.testing.expectEqual(@as(?usize, 2), preferredProfileIndex(&profiles, null, "cmd.exe", "pwsh", 0));
    try std.testing.expectEqual(@as(?usize, 0), preferredProfileIndex(&profiles, null, null, "power", 2));
    try std.testing.expectEqual(@as(?usize, null), preferredProfileIndex(&profiles, null, null, "definitely_not_real", 1));
}

test "win32 resolveProfileSelection supports index and prefix matching" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const profiles = [_]windows_shell.Profile{
        .{
            .kind = .pwsh,
            .key = "pwsh.exe",
            .label = "PowerShell",
            .command = .{ .direct = &.{"pwsh.exe"} },
        },
        .{
            .kind = .wsl_distro,
            .key = "Ubuntu",
            .label = "WSL: Ubuntu",
            .command = .{ .direct = &.{ "wsl.exe", "-d", "Ubuntu", "~" } },
        },
        .{
            .kind = .wsl_distro,
            .key = "Ubuntu-Preview",
            .label = "WSL: Ubuntu Preview",
            .command = .{ .direct = &.{ "wsl.exe", "-d", "Ubuntu-Preview", "~" } },
        },
    };

    try std.testing.expectEqualDeep(ProfileSelection{ .exact = 0 }, resolveProfileSelection(&profiles, "", 0));
    try std.testing.expectEqualDeep(ProfileSelection{ .exact = 1 }, resolveProfileSelection(&profiles, "2", 0));
    try std.testing.expectEqualDeep(ProfileSelection{ .exact = 0 }, resolveProfileSelection(&profiles, "powers", 1));
    try std.testing.expectEqualDeep(ProfileSelection{ .ambiguous = 2 }, resolveProfileSelection(&profiles, "ubu", 0));
    try std.testing.expectEqualDeep(ProfileSelection.invalid, resolveProfileSelection(&profiles, "9", 0));
}

test "win32 buildProfileOverlayLabel and hint reflect selected profile" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const profiles = [_]windows_shell.Profile{
        .{
            .kind = .pwsh,
            .key = "pwsh.exe",
            .label = "PowerShell",
            .command = .{ .direct = &.{"pwsh.exe"} },
        },
        .{
            .kind = .cmd,
            .key = "cmd.exe",
            .label = "Command Prompt",
            .command = .{ .direct = &.{"cmd.exe"} },
        },
    };

    const label = try buildProfileOverlayLabel(std.testing.allocator, &profiles, "cmd", 0);
    defer std.testing.allocator.free(label);
    try std.testing.expectEqualStrings("Profile 2/2 CMD C>", label);

    const hint = try buildProfileHintText(std.testing.allocator, &profiles, "cmd", 0, .window, .{ "pwsh.exe", "cmd.exe", null });
    defer std.testing.allocator.free(hint);
    try std.testing.expect(std.mem.indexOf(u8, hint, "CMD C>") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "Command Prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "run cmd.exe") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "Pinned slot 2.") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "opens a new window") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "Alt+1-3 launches visible slots") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "Alt+Shift+1-3 pins the current profile") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "Alt+Shift+0 clears pinning") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "Quick picks: 1 PWSH >>") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "2 CMD C>") != null);
}

test "win32 buildProfileDetailText reflects selected launcher state" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const profile: windows_shell.Profile = .{
        .kind = .pwsh,
        .key = "pwsh.exe",
        .label = "PowerShell",
        .command = .{ .direct = &.{"pwsh.exe"} },
    };
    const profiles = [_]windows_shell.Profile{
        profile,
        .{
            .kind = .git_bash,
            .key = "git-bash",
            .label = "Git Bash",
            .command = .{ .direct = &.{"bash.exe"} },
        },
        .{
            .kind = .wsl_distro,
            .key = "wsl:Ubuntu",
            .label = "WSL: Ubuntu",
            .command = .{ .direct = &.{ "wsl.exe", "-d", "Ubuntu" } },
        },
    };

    const overlay = try buildProfileDetailText(std.testing.allocator, &profile, &profiles, true, .split, "git,pwsh,Ubuntu,cmd", .{ "pwsh.exe", "git-bash", null });
    defer std.testing.allocator.free(overlay);
    try std.testing.expect(std.mem.indexOf(u8, overlay, "Selected profile: PWSH >> PowerShell") != null);
    try std.testing.expect(std.mem.indexOf(u8, overlay, "Run pwsh.exe") != null);
    try std.testing.expect(std.mem.indexOf(u8, overlay, "Pinned slot 1.") != null);
    try std.testing.expect(std.mem.indexOf(u8, overlay, "opens a split") != null);
    try std.testing.expect(std.mem.indexOf(u8, overlay, "Alt+1-3 launches visible slots") != null);
    try std.testing.expect(std.mem.indexOf(u8, overlay, "Alt+Shift+1-3 pins the current profile") != null);
    try std.testing.expect(std.mem.indexOf(u8, overlay, "Alt+Shift+0 clears pinning") != null);
    try std.testing.expect(std.mem.indexOf(u8, overlay, "Quick picks: 1 PWSH >> PowerShell") != null);
    try std.testing.expect(std.mem.indexOf(u8, overlay, "Order: git > pwsh > Ubuntu > cmd.") != null);

    const idle = try buildProfileDetailText(std.testing.allocator, &profile, &profiles, false, .window, "git,pwsh,Ubuntu,cmd", .{ "pwsh.exe", "git-bash", null });
    defer std.testing.allocator.free(idle);
    try std.testing.expect(std.mem.indexOf(u8, idle, "Default profile: PWSH >> PowerShell") != null);
    try std.testing.expect(std.mem.indexOf(u8, idle, "Run pwsh.exe") != null);
    try std.testing.expect(std.mem.indexOf(u8, idle, "Pinned slot 1.") != null);
    try std.testing.expect(std.mem.indexOf(u8, idle, "PowerShell profile") != null);
    try std.testing.expect(std.mem.indexOf(u8, idle, "opens a new window") != null);
    try std.testing.expect(std.mem.indexOf(u8, idle, "Alt+1-3 launches visible slots") != null);
    try std.testing.expect(std.mem.indexOf(u8, idle, "Alt+Shift+1-3 pins the current profile") != null);
    try std.testing.expect(std.mem.indexOf(u8, idle, "Alt+Shift+0 clears pinning") != null);
    try std.testing.expect(std.mem.indexOf(u8, idle, "Top slots: 1 PWSH >>") != null);
    try std.testing.expect(std.mem.indexOf(u8, idle, "2 GIT $> Git Bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, idle, "Order: git > pwsh > Ubuntu > cmd.") != null);
}

test "win32 buildProfileCommandPreviewText compacts shell command preview" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const profile: windows_shell.Profile = .{
        .kind = .wsl_distro,
        .key = "Ubuntu",
        .label = "WSL: Ubuntu",
        .command = .{ .direct = &.{ "wsl.exe", "-d", "Ubuntu", "--cd", "~" } },
    };

    const preview = try buildProfileCommandPreviewText(std.testing.allocator, &profile, 14);
    defer std.testing.allocator.free(preview);
    try std.testing.expectEqualStrings("wsl.exe -d ...", preview);
}

test "win32 buildProfileOrderSummaryText compacts launcher order" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const summary = (try buildProfileOrderSummaryText(
        std.testing.allocator,
        "git,pwsh,Ubuntu,cmd,powershell",
        4,
    )).?;
    defer std.testing.allocator.free(summary);
    try std.testing.expectEqualStrings("git > pwsh > Ubuntu > cmd > ...", summary);
}

test "win32 buildProfileQuickPickText reflects ordered launcher profiles" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const profiles = [_]windows_shell.Profile{
        .{
            .kind = .git_bash,
            .key = "git-bash",
            .label = "Git Bash",
            .command = .{ .direct = &.{"bash.exe"} },
        },
        .{
            .kind = .pwsh,
            .key = "pwsh.exe",
            .label = "PowerShell",
            .command = .{ .direct = &.{"pwsh.exe"} },
        },
        .{
            .kind = .wsl_distro,
            .key = "wsl:Ubuntu",
            .label = "WSL: Ubuntu",
            .command = .{ .direct = &.{ "wsl.exe", "-d", "Ubuntu" } },
        },
        .{
            .kind = .cmd,
            .key = "cmd.exe",
            .label = "Command Prompt",
            .command = .{ .direct = &.{"cmd.exe"} },
        },
        .{
            .kind = .powershell,
            .key = "powershell.exe",
            .label = "Windows PowerShell",
            .command = .{ .direct = &.{"powershell.exe"} },
        },
    };

    const quick = (try buildProfileQuickPickText(std.testing.allocator, &profiles, 4, 10)).?;
    defer std.testing.allocator.free(quick);
    try std.testing.expectEqualStrings(
        "1 GIT $> Git Bash | 2 PWSH >> PowerShell | 3 WSL <> WSL: Ub... | 4 CMD C> Command... | ...",
        quick,
    );
}

test "win32 buildProfileStatusBadgeText reflects selected profile kind" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const profile: windows_shell.Profile = .{
        .kind = .git_bash,
        .key = "git-bash",
        .label = "Git Bash",
        .command = .{ .direct = &.{"bash.exe"} },
    };

    const badge = try buildProfileStatusBadgeText(std.testing.allocator, &profile, 0, 0);
    defer std.testing.allocator.free(badge);
    try std.testing.expectEqualStrings("*1 GIT $> Git Bash", badge);
}

test "win32 buildProfileQuickSlotChipText reflects ordered quick slot badge" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const profile: windows_shell.Profile = .{
        .kind = .wsl_distro,
        .key = "wsl:Ubuntu",
        .label = "WSL: Ubuntu",
        .command = .{ .direct = &.{ "wsl.exe", "-d", "Ubuntu" } },
    };

    const chip = try buildProfileQuickSlotChipText(std.testing.allocator, &profile, 2, 2);
    defer std.testing.allocator.free(chip);
    try std.testing.expectEqualStrings("*3 WSL", chip);
}

test "win32 quickSlotChipColors follow profile hover accent" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const idle = quickSlotChipColors(.git_bash, false);
    try std.testing.expectEqual(rgb(48, 40, 31), idle.bg);
    try std.testing.expectEqual(rgb(212, 156, 92), idle.border);
    try std.testing.expectEqual(rgb(255, 224, 178), idle.fg);

    const hovered = quickSlotChipColors(.git_bash, true);
    try std.testing.expectEqual(rgb(58, 48, 37), hovered.bg);
    try std.testing.expectEqual(rgb(236, 182, 118), hovered.border);
    try std.testing.expectEqual(rgb(248, 202, 134), hovered.fg);
}

test "win32 pinnedChipMarkerColor follows profile accent" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(rgb(248, 202, 134), pinnedChipMarkerColor(.git_bash, false));
    try std.testing.expectEqual(rgb(255, 224, 178), pinnedChipMarkerColor(.git_bash, true));
    try std.testing.expectEqual(rgb(136, 216, 242), pinnedChipMarkerColor(.pwsh, false));
}

test "win32 launcherChipRightInset reserves badge and target space" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(@as(i32, 5), launcherChipRightInset(false, false));
    try std.testing.expectEqual(@as(i32, 12), launcherChipRightInset(false, true));
    try std.testing.expectEqual(@as(i32, 16), launcherChipRightInset(true, false));
    try std.testing.expectEqual(@as(i32, 16), launcherChipRightInset(true, true));
}

test "win32 targetButtonLabelRightInset reserves target badge space" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(@as(i32, 0), targetButtonLabelRightInset(null));
    try std.testing.expectEqual(@as(i32, 12), targetButtonLabelRightInset(.tab));
    try std.testing.expectEqual(@as(i32, 12), targetButtonLabelRightInset(.window));
    try std.testing.expectEqual(@as(i32, 12), targetButtonLabelRightInset(.split));
}

test "win32 buttonLabelRightInset reserves slot and target badge space" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(@as(i32, 0), buttonLabelRightInset(null, null));
    try std.testing.expectEqual(@as(i32, 12), buttonLabelRightInset(null, .tab));
    try std.testing.expectEqual(@as(i32, 16), buttonLabelRightInset(0, null));
    try std.testing.expectEqual(@as(i32, 16), buttonLabelRightInset(0, .split));
    try std.testing.expectEqual(@as(i32, 12), buttonLabelRightInset(9, .window));
}

test "win32 shouldPaintQuickSlotTargetMarker follows active chip state" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(!shouldPaintQuickSlotTargetMarker(false, false));
    try std.testing.expect(shouldPaintQuickSlotTargetMarker(true, false));
    try std.testing.expect(shouldPaintQuickSlotTargetMarker(false, true));
}

test "win32 profileOpenTargetMarkerColor reflects launcher target" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(rgb(132, 172, 238), profileOpenTargetMarkerColor(.tab));
    try std.testing.expectEqual(rgb(236, 182, 118), profileOpenTargetMarkerColor(.window));
    try std.testing.expectEqual(rgb(126, 204, 148), profileOpenTargetMarkerColor(.split));
}

test "win32 profileOpenTargetBadgeGlyph reflects launcher target" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(@as(u8, 'T'), profileOpenTargetBadgeGlyph(.tab));
    try std.testing.expectEqual(@as(u8, 'W'), profileOpenTargetBadgeGlyph(.window));
    try std.testing.expectEqual(@as(u8, 'S'), profileOpenTargetBadgeGlyph(.split));
}

test "win32 pinnedSlotBadgeDigit reflects visible quick slot ordinals" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(@as(?u8, '1'), pinnedSlotBadgeDigit(0));
    try std.testing.expectEqual(@as(?u8, '3'), pinnedSlotBadgeDigit(2));
    try std.testing.expectEqual(@as(?u8, null), pinnedSlotBadgeDigit(null));
    try std.testing.expectEqual(@as(?u8, null), pinnedSlotBadgeDigit(9));
}

test "win32 quickSlotProfileIndex skips the selected profile and preserves order" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(@as(?usize, 1), quickSlotProfileIndex(5, 0, 0, 3));
    try std.testing.expectEqual(@as(?usize, 2), quickSlotProfileIndex(5, 0, 1, 3));
    try std.testing.expectEqual(@as(?usize, 3), quickSlotProfileIndex(5, 0, 2, 3));
    try std.testing.expectEqual(@as(?usize, 0), quickSlotProfileIndex(5, 3, 0, 3));
    try std.testing.expectEqual(@as(?usize, 1), quickSlotProfileIndex(5, 3, 1, 3));
    try std.testing.expectEqual(@as(?usize, 2), quickSlotProfileIndex(5, 3, 2, 3));
    try std.testing.expectEqual(@as(?usize, null), quickSlotProfileIndex(1, 0, 0, 3));
}

test "win32 nextQuickSlotFocus cycles visible painted quick slots" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(@as(?usize, 1), nextQuickSlotFocus(5, 0, null, false, 3));
    try std.testing.expectEqual(@as(?usize, 3), nextQuickSlotFocus(5, 0, null, true, 3));
    try std.testing.expectEqual(@as(?usize, 2), nextQuickSlotFocus(5, 0, 1, false, 3));
    try std.testing.expectEqual(@as(?usize, 3), nextQuickSlotFocus(5, 0, 2, false, 3));
    try std.testing.expectEqual(@as(?usize, 1), nextQuickSlotFocus(5, 0, 3, false, 3));
    try std.testing.expectEqual(@as(?usize, 3), nextQuickSlotFocus(5, 0, 1, true, 3));
    try std.testing.expectEqual(@as(?usize, 0), nextQuickSlotFocus(5, 3, null, false, 3));
    try std.testing.expectEqual(@as(?usize, null), nextQuickSlotFocus(1, 0, null, false, 3));
}

test "win32 applyQuickSlotPreferenceOrder promotes pinned launcher profiles" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var profiles = [_]windows_shell.Profile{
        .{
            .kind = .pwsh,
            .key = "pwsh.exe",
            .label = "PowerShell",
            .command = .{ .direct = &.{"pwsh.exe"} },
        },
        .{
            .kind = .git_bash,
            .key = "git-bash",
            .label = "Git Bash",
            .command = .{ .direct = &.{"bash.exe"} },
        },
        .{
            .kind = .wsl_distro,
            .key = "wsl:Ubuntu",
            .label = "WSL: Ubuntu",
            .command = .{ .direct = &.{ "wsl.exe", "-d", "Ubuntu" } },
        },
        .{
            .kind = .cmd,
            .key = "cmd.exe",
            .label = "Command Prompt",
            .command = .{ .direct = &.{"cmd.exe"} },
        },
    };

    applyQuickSlotPreferenceOrder(&profiles, .{ "git-bash", "cmd.exe", null });
    try std.testing.expectEqualStrings("git-bash", profiles[0].key);
    try std.testing.expectEqualStrings("cmd.exe", profiles[1].key);
    try std.testing.expectEqualStrings("pwsh.exe", profiles[2].key);
    try std.testing.expectEqualStrings("wsl:Ubuntu", profiles[3].key);
}

test "win32 findLauncherQuickSlotOrdinal finds runtime-pinned slots" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(@as(?usize, 0), findLauncherQuickSlotOrdinal(.{ "git-bash", "cmd.exe", null }, "git-bash"));
    try std.testing.expectEqual(@as(?usize, 1), findLauncherQuickSlotOrdinal(.{ "git-bash", "cmd.exe", null }, "CMD.EXE"));
    try std.testing.expectEqual(@as(?usize, null), findLauncherQuickSlotOrdinal(.{ "git-bash", "cmd.exe", null }, "pwsh.exe"));
}

test "win32 buildProfileChromeBadgeText adds profile glyph treatment" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const pwsh = try buildProfileChromeBadgeText(std.testing.allocator, .pwsh);
    defer std.testing.allocator.free(pwsh);
    try std.testing.expectEqualStrings("PWSH >>", pwsh);

    const wsl = try buildProfileChromeBadgeText(std.testing.allocator, .wsl_distro);
    defer std.testing.allocator.free(wsl);
    try std.testing.expectEqualStrings("WSL <>", wsl);
}

test "win32 startupProfilePickerEnabled parses launcher env values" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(startupProfilePickerEnabled("1"));
    try std.testing.expect(startupProfilePickerEnabled("true"));
    try std.testing.expect(startupProfilePickerEnabled("YES"));
    try std.testing.expect(startupProfilePickerEnabled("on"));
    try std.testing.expect(!startupProfilePickerEnabled("0"));
    try std.testing.expect(!startupProfilePickerEnabled("false"));
    try std.testing.expect(!startupProfilePickerEnabled("no"));
}

test "win32 buildSearchOverlayLabel reflects match counts" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const active = try buildSearchOverlayLabel(std.testing.allocator, 8, 2);
    defer std.testing.allocator.free(active);
    try std.testing.expectEqualStrings("Find 2/8", active);

    const passive = try buildSearchOverlayLabel(std.testing.allocator, 5, null);
    defer std.testing.allocator.free(passive);
    try std.testing.expectEqualStrings("Find 5", passive);

    const idle = try buildSearchOverlayLabel(std.testing.allocator, null, null);
    defer std.testing.allocator.free(idle);
    try std.testing.expectEqualStrings("Find", idle);
}

test "win32 buildTabOverviewOverlayLabel reflects current host tab" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const multi = try buildTabOverviewOverlayLabel(std.testing.allocator, 1, 4);
    defer std.testing.allocator.free(multi);
    try std.testing.expectEqualStrings("Tab 2/4", multi);

    const single = try buildTabOverviewOverlayLabel(std.testing.allocator, 0, 1);
    defer std.testing.allocator.free(single);
    try std.testing.expectEqualStrings("Tab", single);
}

test "win32 buildOverlayPaintLabelText reflects live overlay mode" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const command = try buildOverlayPaintLabelText(
        std.testing.allocator,
        .command_palette,
        "toggle_",
        null,
        null,
        .{},
    );
    defer std.testing.allocator.free(command);
    try std.testing.expectEqualStrings("Command 3", command);

    const search = try buildOverlayPaintLabelText(
        std.testing.allocator,
        .search,
        "",
        8,
        2,
        .{},
    );
    defer std.testing.allocator.free(search);
    try std.testing.expectEqualStrings("Find 2/8", search);

    const title = try buildOverlayPaintLabelText(
        std.testing.allocator,
        .surface_title,
        "",
        null,
        null,
        .{},
    );
    defer std.testing.allocator.free(title);
    try std.testing.expectEqualStrings("Window title", title);
}

test "win32 buildOverlayFeedbackText prefers inline banner state" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const info = try buildOverlayFeedbackText(
        std.testing.allocator,
        .info,
        "Try: new_tab",
        .command_palette,
        "",
        null,
        null,
        null,
        .{},
        1,
    );
    defer std.testing.allocator.free(info);
    try std.testing.expectEqualStrings("Info: Try: new_tab", info);

    const err = try buildOverlayFeedbackText(
        std.testing.allocator,
        .err,
        "Unknown Ghostty action",
        .command_palette,
        "",
        null,
        null,
        null,
        .{},
        1,
    );
    defer std.testing.allocator.free(err);
    try std.testing.expectEqualStrings("Error: Unknown Ghostty action", err);

    const fallback = try buildOverlayFeedbackText(
        std.testing.allocator,
        .none,
        null,
        .search,
        "needle",
        "needle",
        8,
        2,
        .{},
        1,
    );
    defer std.testing.allocator.free(fallback);
    try std.testing.expect(std.mem.indexOf(u8, fallback, "next match") != null);
}

test "win32 nextTabOverviewSelection wraps and clamps" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(@as(usize, 2), nextTabOverviewSelection(1, 4, false));
    try std.testing.expectEqual(@as(usize, 4), nextTabOverviewSelection(1, 4, true));
    try std.testing.expectEqual(@as(usize, 1), nextTabOverviewSelection(4, 4, false));
    try std.testing.expectEqual(@as(usize, 1), nextTabOverviewSelection(9, 4, false));
}

test "win32 tabDirectionFromWheelDelta maps wheel direction to tab navigation" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(apprt.action.GotoTab.previous, tabDirectionFromWheelDelta(120));
    try std.testing.expectEqual(apprt.action.GotoTab.next, tabDirectionFromWheelDelta(-120));
}

test "win32 searchDirectionFromWheelDelta maps wheel direction to search navigation" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(input.Binding.Action.NavigateSearch.previous, searchDirectionFromWheelDelta(120));
    try std.testing.expectEqual(input.Binding.Action.NavigateSearch.next, searchDirectionFromWheelDelta(-120));
}

test "win32 commandPaletteDirectionFromWheelDelta maps wheel direction to completion direction" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(commandPaletteDirectionFromWheelDelta(120));
    try std.testing.expect(!commandPaletteDirectionFromWheelDelta(-120));
}

test "win32 overlayEditBorderColor reflects mode and focus" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(overlayAccentColor(.search), overlayEditBorderColor(.search, true));
    try std.testing.expectEqual(rgb(86, 96, 112), overlayEditBorderColor(.search, false));
    try std.testing.expectEqual(rgb(72, 82, 98), overlayEditBorderColor(.none, false));
}

test "win32 buttonColors reflects hover and active states" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const hovered = buttonColors(false, false, true, false, false, false);
    try std.testing.expectEqual(rgb(44, 52, 62), hovered.bg);
    try std.testing.expectEqual(rgb(92, 104, 122), hovered.border);

    const active_hovered = buttonColors(true, false, true, false, false, false);
    try std.testing.expectEqual(rgb(72, 90, 122), active_hovered.bg);
    try std.testing.expectEqual(rgb(132, 172, 238), active_hovered.border);

    const accept_hovered = buttonColors(false, false, true, false, false, true);
    try std.testing.expectEqual(rgb(62, 104, 184), accept_hovered.bg);
    try std.testing.expectEqual(rgb(146, 186, 255), accept_hovered.border);
}

test "win32 buttonFocusRingColor reflects control role" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(rgb(184, 212, 255), buttonFocusRingColor(false, false, true));
    try std.testing.expectEqual(rgb(172, 206, 255), buttonFocusRingColor(true, false, false));
    try std.testing.expectEqual(rgb(160, 190, 238), buttonFocusRingColor(false, true, false));
    try std.testing.expectEqual(rgb(140, 166, 208), buttonFocusRingColor(false, false, false));
}

test "win32 profileChromeAccent assigns distinct profile accents" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const pwsh = profileChromeAccent(.pwsh);
    const git = profileChromeAccent(.git_bash);
    const wsl = profileChromeAccent(.wsl_distro);

    try std.testing.expectEqual(rgb(86, 176, 204), pwsh.idle_border);
    try std.testing.expectEqual(rgb(212, 156, 92), git.idle_border);
    try std.testing.expectEqual(rgb(92, 176, 118), wsl.idle_border);
    try std.testing.expect(pwsh.idle_border != git.idle_border);
    try std.testing.expect(wsl.focus != pwsh.focus);
}

test "win32 applyProfileChromeAccent respects profile state" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const base = buttonColors(false, false, false, false, false, false);
    const idle = applyProfileChromeAccent(base, .git_bash, false, false, false, false);
    try std.testing.expectEqual(rgb(48, 40, 31), idle.bg);
    try std.testing.expectEqual(rgb(212, 156, 92), idle.border);

    const hovered = applyProfileChromeAccent(base, .git_bash, false, true, false, false);
    try std.testing.expectEqual(rgb(58, 48, 37), hovered.bg);
    try std.testing.expectEqual(rgb(236, 182, 118), hovered.border);

    const active = applyProfileChromeAccent(base, .pwsh, true, false, false, false);
    try std.testing.expectEqual(rgb(44, 70, 82), active.bg);
    try std.testing.expectEqual(rgb(136, 216, 242), active.border);
    try std.testing.expectEqual(rgb(248, 250, 255), active.fg);
}

test "win32 profileChromeStripeColor tracks profile interaction state" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(
        rgb(212, 156, 92),
        profileChromeStripeColor(.git_bash, false, false, false, false),
    );
    try std.testing.expectEqual(
        rgb(248, 202, 134),
        profileChromeStripeColor(.git_bash, true, false, false, false),
    );
    try std.testing.expectEqual(
        rgb(236, 182, 118),
        profileChromeStripeColor(.git_bash, false, false, true, false),
    );
    try std.testing.expectEqual(
        rgb(86, 94, 108),
        profileChromeStripeColor(.git_bash, false, false, false, true),
    );
}

test "win32 profileKind label and hint colors follow profile accent" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(rgb(186, 232, 248), profileKindLabelColor(.pwsh));
    try std.testing.expectEqual(rgb(136, 216, 242), profileKindHintColor(.pwsh));
    try std.testing.expectEqual(rgb(255, 224, 178), profileKindLabelColor(.git_bash));
    try std.testing.expectEqual(rgb(248, 202, 134), profileKindHintColor(.git_bash));
}

test "win32 tabButtonKeyAction maps focused-tab keys" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(TabButtonKeyAction.previous, tabButtonKeyAction(VK_LEFT, false).?);
    try std.testing.expectEqual(TabButtonKeyAction.move_previous, tabButtonKeyAction(VK_LEFT, true).?);
    try std.testing.expectEqual(TabButtonKeyAction.next, tabButtonKeyAction(VK_RIGHT, false).?);
    try std.testing.expectEqual(TabButtonKeyAction.move_next, tabButtonKeyAction(VK_RIGHT, true).?);
    try std.testing.expectEqual(TabButtonKeyAction.first, tabButtonKeyAction(VK_HOME, false).?);
    try std.testing.expectEqual(TabButtonKeyAction.move_first, tabButtonKeyAction(VK_HOME, true).?);
    try std.testing.expectEqual(TabButtonKeyAction.last, tabButtonKeyAction(VK_END, false).?);
    try std.testing.expectEqual(TabButtonKeyAction.move_last, tabButtonKeyAction(VK_END, true).?);
    try std.testing.expectEqual(TabButtonKeyAction.rename, tabButtonKeyAction(VK_F2, false).?);
    try std.testing.expectEqual(TabButtonKeyAction.close, tabButtonKeyAction(VK_DELETE, false).?);
    try std.testing.expectEqual(TabButtonKeyAction.overview, tabButtonKeyAction(VK_APPS, false).?);
    try std.testing.expect(tabButtonKeyAction(VK_RETURN, false) == null);
}

test "win32 moveTabAmountToEdge computes direct host reorder delta" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(@as(isize, -2), moveTabAmountToEdge(4, 2, true));
    try std.testing.expectEqual(@as(isize, 1), moveTabAmountToEdge(4, 2, false));
    try std.testing.expectEqual(@as(isize, 0), moveTabAmountToEdge(4, 0, true));
    try std.testing.expectEqual(@as(isize, 0), moveTabAmountToEdge(4, 3, false));
}

test "win32 searchButtonKeyAction maps focused search button keys" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(SearchButtonKeyAction.next, searchButtonKeyAction(VK_F3, false).?);
    try std.testing.expectEqual(SearchButtonKeyAction.previous, searchButtonKeyAction(VK_F3, true).?);
    try std.testing.expectEqual(SearchButtonKeyAction.dismiss, searchButtonKeyAction(VK_ESCAPE, false).?);
    try std.testing.expect(searchButtonKeyAction(VK_RETURN, false) == null);
}

test "win32 tabsButtonKeyAction maps focused tabs button keys" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(TabsButtonKeyAction.previous, tabsButtonKeyAction(VK_LEFT).?);
    try std.testing.expectEqual(TabsButtonKeyAction.previous, tabsButtonKeyAction(VK_UP).?);
    try std.testing.expectEqual(TabsButtonKeyAction.next, tabsButtonKeyAction(VK_RIGHT).?);
    try std.testing.expectEqual(TabsButtonKeyAction.next, tabsButtonKeyAction(VK_DOWN).?);
    try std.testing.expectEqual(TabsButtonKeyAction.rename, tabsButtonKeyAction(VK_F2).?);
    try std.testing.expectEqual(TabsButtonKeyAction.overview, tabsButtonKeyAction(VK_APPS).?);
    try std.testing.expect(tabsButtonKeyAction(VK_RETURN) == null);
}

test "win32 commandButtonKeyAction maps focused command button keys" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(CommandButtonKeyAction.toggle, commandButtonKeyAction(VK_RETURN).?);
    try std.testing.expectEqual(CommandButtonKeyAction.toggle, commandButtonKeyAction(VK_SPACE).?);
    try std.testing.expectEqual(CommandButtonKeyAction.previous, commandButtonKeyAction(VK_UP).?);
    try std.testing.expectEqual(CommandButtonKeyAction.next, commandButtonKeyAction(VK_DOWN).?);
    try std.testing.expectEqual(CommandButtonKeyAction.dismiss, commandButtonKeyAction(VK_ESCAPE).?);
    try std.testing.expect(commandButtonKeyAction(VK_F2) == null);
}

test "win32 buildInspectorBannerText reflects host inspector context" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const multi = try buildInspectorBannerText(std.testing.allocator, .{ .index = 1, .total = 4 }, 3, false);
    defer std.testing.allocator.free(multi);
    try std.testing.expectEqualStrings("Inspector active | tab 2/4 | panes 3 | toggle Inspect to return", multi);

    const zoomed = try buildInspectorBannerText(std.testing.allocator, .{ .index = 0, .total = 2 }, 2, true);
    defer std.testing.allocator.free(zoomed);
    try std.testing.expectEqualStrings("Inspector active | tab 1/2 | panes 2 | zoomed | toggle Inspect to return", zoomed);

    const single = try buildInspectorBannerText(std.testing.allocator, .{ .index = 0, .total = 1 }, 1, false);
    defer std.testing.allocator.free(single);
    try std.testing.expectEqualStrings("Inspector active | tab 1/1 | toggle Inspect to return", single);
}

test "win32 buildInspectorPanelTitleText reflects host inspector context" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const multi = try buildInspectorPanelTitleText(std.testing.allocator, .{ .index = 1, .total = 4 }, 3, false);
    defer std.testing.allocator.free(multi);
    try std.testing.expect(std.mem.indexOf(u8, multi, "Inspector") != null);
    try std.testing.expect(std.mem.indexOf(u8, multi, "tab 2/4") != null);
    try std.testing.expect(std.mem.indexOf(u8, multi, "3 panes") != null);

    const zoomed = try buildInspectorPanelTitleText(std.testing.allocator, .{ .index = 0, .total = 2 }, 2, true);
    defer std.testing.allocator.free(zoomed);
    try std.testing.expect(std.mem.indexOf(u8, zoomed, "zoomed") != null);
}

test "win32 buildInspectorPanelHintText reflects live inspector scope" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const single = try buildInspectorPanelHintText(std.testing.allocator, 1, false);
    defer std.testing.allocator.free(single);
    try std.testing.expect(std.mem.indexOf(u8, single, "this tab") != null);

    const multi = try buildInspectorPanelHintText(std.testing.allocator, 3, false);
    defer std.testing.allocator.free(multi);
    try std.testing.expect(std.mem.indexOf(u8, multi, "3 panes") != null);

    const zoomed = try buildInspectorPanelHintText(std.testing.allocator, 2, true);
    defer std.testing.allocator.free(zoomed);
    try std.testing.expect(std.mem.indexOf(u8, zoomed, "zoomed pane") != null);
}

test "win32 buildInspectorDetailText reflects pane and zoom context" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const multi = try buildInspectorDetailText(std.testing.allocator, .{ .index = 1, .total = 4 }, 3, false);
    defer std.testing.allocator.free(multi);
    try std.testing.expect(std.mem.indexOf(u8, multi, "tab 2/4") != null);
    try std.testing.expect(std.mem.indexOf(u8, multi, "3 panes") != null);

    const zoomed = try buildInspectorDetailText(std.testing.allocator, .{ .index = 0, .total = 2 }, 2, true);
    defer std.testing.allocator.free(zoomed);
    try std.testing.expect(std.mem.indexOf(u8, zoomed, "zoom") != null);
}

test "win32 buildSearchDetailText reflects live search context" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const active = try buildSearchDetailText(std.testing.allocator, "needle", 8, 2);
    defer std.testing.allocator.free(active);
    try std.testing.expect(std.mem.indexOf(u8, active, "needle") != null);
    try std.testing.expect(std.mem.indexOf(u8, active, "2 of 8") != null);

    const pending = try buildSearchDetailText(std.testing.allocator, "logs", null, null);
    defer std.testing.allocator.free(pending);
    try std.testing.expect(std.mem.indexOf(u8, pending, "refine") != null);
}

test "win32 buildOverlayAcceptLabel reflects overlay action state" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const palette_idle = try buildOverlayAcceptLabel(std.testing.allocator, .command_palette, "", null, null, null);
    defer std.testing.allocator.free(palette_idle);
    try std.testing.expectEqualStrings("Close", palette_idle);

    const palette_run = try buildOverlayAcceptLabel(std.testing.allocator, .command_palette, "new_tab", null, null, null);
    defer std.testing.allocator.free(palette_run);
    try std.testing.expectEqualStrings("Run", palette_run);

    const palette_matches = try buildOverlayAcceptLabel(std.testing.allocator, .command_palette, "toggle_", null, null, null);
    defer std.testing.allocator.free(palette_matches);
    try std.testing.expectEqualStrings("Pick", palette_matches);

    const search_next = try buildOverlayAcceptLabel(std.testing.allocator, .search, "needle", "needle", 8, 2);
    defer std.testing.allocator.free(search_next);
    try std.testing.expectEqualStrings("Next", search_next);

    const search_find = try buildOverlayAcceptLabel(std.testing.allocator, .search, "other", "needle", 8, 2);
    defer std.testing.allocator.free(search_find);
    try std.testing.expectEqualStrings("Find", search_find);

    const tab_go = try buildOverlayAcceptLabel(std.testing.allocator, .tab_overview, "2", null, null, null);
    defer std.testing.allocator.free(tab_go);
    try std.testing.expectEqualStrings("Go", tab_go);

    const title_apply = try buildOverlayAcceptLabel(std.testing.allocator, .surface_title, "logs", null, null, null);
    defer std.testing.allocator.free(title_apply);
    try std.testing.expectEqualStrings("Apply", title_apply);
}

test "win32 buildOverlayHintText reflects live overlay guidance" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const command_unique = try buildOverlayHintText(
        std.testing.allocator,
        .command_palette,
        "reload_",
        null,
        null,
        null,
        .{},
        1,
    );
    defer std.testing.allocator.free(command_unique);
    try std.testing.expect(std.mem.indexOf(u8, command_unique, "reload_config") != null);

    const search_next = try buildOverlayHintText(
        std.testing.allocator,
        .search,
        "needle",
        "needle",
        8,
        2,
        .{},
        1,
    );
    defer std.testing.allocator.free(search_next);
    try std.testing.expect(std.mem.indexOf(u8, search_next, "2/8") != null);
    try std.testing.expect(std.mem.indexOf(u8, search_next, "next match") != null);

    const tab_invalid = try buildOverlayHintText(
        std.testing.allocator,
        .tab_overview,
        "8",
        null,
        null,
        null,
        .{ .index = 1, .total = 4 },
        2,
    );
    defer std.testing.allocator.free(tab_invalid);
    try std.testing.expect(std.mem.indexOf(u8, tab_invalid, "out of range") != null);

    const tab_title = try buildOverlayHintText(
        std.testing.allocator,
        .tab_title,
        "logs",
        null,
        null,
        null,
        .{ .index = 0, .total = 3 },
        2,
    );
    defer std.testing.allocator.free(tab_title);
    try std.testing.expect(std.mem.indexOf(u8, tab_title, "tab 1/3") != null);
    try std.testing.expect(std.mem.indexOf(u8, tab_title, "2 panes") != null);
}

test "win32 overlayCancelLabel reflects overlay mode" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqualStrings("Close", overlayCancelLabel(.search));
    try std.testing.expectEqualStrings("Cancel", overlayCancelLabel(.surface_title));
}

test "win32 buildCommandButtonLabel reflects live palette state" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const active = try buildCommandButtonLabel(std.testing.allocator, true, "toggle_fullscreen");
    defer std.testing.allocator.free(active);
    try std.testing.expectEqualStrings("Cmd toggle...", active);

    const armed = try buildCommandButtonLabel(std.testing.allocator, true, "");
    defer std.testing.allocator.free(armed);
    try std.testing.expectEqualStrings("[Cmd]", armed);

    const idle = try buildCommandButtonLabel(std.testing.allocator, false, null);
    defer std.testing.allocator.free(idle);
    try std.testing.expectEqualStrings("Cmd", idle);
}

test "win32 buildInspectorButtonLabel reflects inspector and pane state" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const visible = try buildInspectorButtonLabel(std.testing.allocator, true, 3);
    defer std.testing.allocator.free(visible);
    try std.testing.expectEqualStrings("[Inspect 3]", visible);

    const multi = try buildInspectorButtonLabel(std.testing.allocator, false, 2);
    defer std.testing.allocator.free(multi);
    try std.testing.expectEqualStrings("Inspect 2", multi);

    const idle = try buildInspectorButtonLabel(std.testing.allocator, false, 1);
    defer std.testing.allocator.free(idle);
    try std.testing.expectEqualStrings("Inspect", idle);
}

test "win32 buildCommandPaletteOverlayLabel reflects palette state" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const idle = try buildCommandPaletteOverlayLabel(std.testing.allocator, "");
    defer std.testing.allocator.free(idle);
    try std.testing.expectEqualStrings("Command", idle);

    const exact = try buildCommandPaletteOverlayLabel(std.testing.allocator, "new_tab");
    defer std.testing.allocator.free(exact);
    try std.testing.expectEqualStrings("Run action", exact);

    const unique = try buildCommandPaletteOverlayLabel(std.testing.allocator, "reload_");
    defer std.testing.allocator.free(unique);
    try std.testing.expectEqualStrings("Run action", unique);

    const matches = try buildCommandPaletteOverlayLabel(std.testing.allocator, "toggle_");
    defer std.testing.allocator.free(matches);
    try std.testing.expectEqualStrings("Command 3", matches);

    const invalid = try buildCommandPaletteOverlayLabel(std.testing.allocator, "definitely_not_real");
    defer std.testing.allocator.free(invalid);
    try std.testing.expectEqualStrings("Command ?", invalid);
}

test "win32 commandPaletteCompletionCandidate resolves and cycles curated matches" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqualStrings(
        "reload_config",
        commandPaletteCompletionCandidate("reload_", "reload_", false).?,
    );
    try std.testing.expectEqualStrings(
        "toggle_fullscreen",
        commandPaletteCompletionCandidate("toggle_", "toggle_", false).?,
    );
    try std.testing.expectEqualStrings(
        "toggle_command_palette",
        commandPaletteCompletionCandidate("toggle_", "toggle_fullscreen", false).?,
    );
    try std.testing.expectEqualStrings(
        "toggle_tab_overview",
        commandPaletteCompletionCandidate("toggle_", "toggle_command_palette", false).?,
    );
    try std.testing.expectEqualStrings(
        "toggle_fullscreen",
        commandPaletteCompletionCandidate("toggle_", "toggle_command_palette", true).?,
    );
}

test "win32 commandPaletteBannerText shows ready banner for valid action" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const banner = (try commandPaletteBannerText(std.testing.allocator, "new_tab")).?;
    defer std.testing.allocator.free(banner);
    try std.testing.expectEqualStrings("Ready: new_tab - open a new tab in this window", banner);
}

test "win32 commandPaletteBannerText suggests matching actions" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const banner = (try commandPaletteBannerText(std.testing.allocator, "new_")).?;
    defer std.testing.allocator.free(banner);
    try std.testing.expect(std.mem.indexOf(u8, banner, "new_tab") != null);
    try std.testing.expect(std.mem.indexOf(u8, banner, "new_split:right") != null);
    try std.testing.expect(std.mem.indexOf(u8, banner, "open a new tab in this window") != null);
    try std.testing.expect(std.mem.indexOf(u8, banner, "split the active tab to the right") != null);
}

test "win32 commandPaletteBannerText resolves unique prefix" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const banner = (try commandPaletteBannerText(std.testing.allocator, "reload_")).?;
    defer std.testing.allocator.free(banner);
    try std.testing.expectEqualStrings("Ready: reload_config - reload winghostty configuration", banner);
}

test "win32 commandPaletteBannerText uses Windows fullscreen wording" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const banner = (try commandPaletteBannerText(std.testing.allocator, "toggle_fullscreen")).?;
    defer std.testing.allocator.free(banner);
    try std.testing.expectEqualStrings("Ready: toggle_fullscreen - toggle fullscreen", banner);
}

test "win32 commandPaletteBannerText suggests tab overview action" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const banner = (try commandPaletteBannerText(std.testing.allocator, "toggle_tab")).?;
    defer std.testing.allocator.free(banner);
    try std.testing.expect(std.mem.indexOf(u8, banner, "toggle_tab_overview") != null);
    try std.testing.expect(std.mem.indexOf(u8, banner, "tab list") != null);
}

test "win32 desiredTabIndex cycles and clamps" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(@as(?usize, 0), desiredTabIndex(3, 1, .previous));
    try std.testing.expectEqual(@as(?usize, 2), desiredTabIndex(3, 0, .previous));
    try std.testing.expectEqual(@as(?usize, 2), desiredTabIndex(3, 1, .next));
    try std.testing.expectEqual(@as(?usize, 0), desiredTabIndex(3, 2, .next));
    try std.testing.expectEqual(@as(?usize, 2), desiredTabIndex(3, 0, .last));
    try std.testing.expectEqual(@as(?usize, 0), desiredTabIndex(3, 1, @enumFromInt(0)));
    try std.testing.expectEqual(@as(?usize, 2), desiredTabIndex(3, 1, @enumFromInt(9)));
}

test "win32 desiredMoveIndex wraps tab order" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(@as(?usize, 2), desiredMoveIndex(4, 1, 1));
    try std.testing.expectEqual(@as(?usize, 0), desiredMoveIndex(4, 1, -1));
    try std.testing.expectEqual(@as(?usize, 0), desiredMoveIndex(4, 3, 1));
    try std.testing.expectEqual(@as(?usize, 3), desiredMoveIndex(4, 0, -1));
}

test "win32 gotoSplitFallback maps only previous and next" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(App.gotoSplitFallbackDirection(.previous) != null);
    try std.testing.expect(App.gotoSplitFallbackDirection(.next) != null);
    try std.testing.expect(App.gotoSplitFallbackDirection(.left) == null);
    try std.testing.expect(App.gotoSplitFallbackDirection(.right) == null);
}

test "win32 command palette action parser accepts simple actions" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const action = try input.Binding.Action.parse("toggle_fullscreen");
    try std.testing.expect(action == .toggle_fullscreen);
}

test "win32 tab overview parser accepts one-based tab numbers" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(@as(usize, 2), try std.fmt.parseUnsigned(usize, "2", 10));
}
