const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const apprt = @import("../apprt.zig");
const CoreApp = @import("../App.zig");
const CoreSurface = @import("../Surface.zig");
const configpkg = @import("../config.zig");
const config_edit = @import("../config/edit.zig");
const input = @import("../input.zig");
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
const WORD = u16;
const BYTE = u8;
const BOOL = windows.BOOL;
const HWND = windows.HWND;
const HINSTANCE = windows.HINSTANCE;
const INTRESOURCE = ?*const anyopaque;

const CS_HREDRAW = 0x0002;
const CS_VREDRAW = 0x0001;
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
const WM_GETMINMAXINFO = 0x0024;
const WM_CHAR = 0x0102;
const WM_KILLFOCUS = 0x0008;
const WM_KEYDOWN = 0x0100;
const WM_KEYUP = 0x0101;
const WM_LBUTTONDOWN = 0x0201;
const WM_LBUTTONUP = 0x0202;
const WM_MBUTTONDOWN = 0x0207;
const WM_MBUTTONUP = 0x0208;
const WM_MOUSEHWHEEL = 0x020E;
const WM_MOUSEMOVE = 0x0200;
const WM_MOUSEWHEEL = 0x020A;
const WM_NCCREATE = 0x0081;
const WM_PAINT = 0x000F;
const WM_RBUTTONDOWN = 0x0204;
const WM_RBUTTONUP = 0x0205;
const WM_SETCURSOR = 0x0020;
const WM_SETFOCUS = 0x0007;
const WM_SIZE = 0x0005;
const WM_SYSKEYDOWN = 0x0104;
const WM_SYSKEYUP = 0x0105;
const WM_WINHOSTTY_WAKE = WM_APP + 1;
const WS_OVERLAPPED = 0x00000000;
const WS_CHILD = 0x40000000;
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
const ES_AUTOHSCROLL = 0x0080;
const BN_CLICKED = 0;
const host_tab_height = 34;
const host_overlay_height = 34;
const host_status_height = 24;
const host_tab_cmd_button_width = 64;
const host_tab_find_button_width = 64;
const host_tab_inspect_button_width = 78;
const host_tab_small_button_width = 34;
const PFD_DRAW_TO_WINDOW = 0x00000004;
const PFD_SUPPORT_OPENGL = 0x00000020;
const PFD_DOUBLEBUFFER = 0x00000001;
const PFD_TYPE_RGBA = 0;
const PFD_MAIN_PLANE = 0;

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
const WHEEL_DELTA = 120;

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
extern "user32" fn SetWindowTextW(hWnd: HWND, lpString: LPCWSTR) callconv(.winapi) BOOL;
extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: i32) callconv(.winapi) LONG_PTR;
extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: i32) callconv(.winapi) BOOL;
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
extern "kernel32" fn GetProcAddress(hModule: HMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) callconv(.winapi) HMODULE;
extern "kernel32" fn SetCurrentDirectoryW(lpPathName: LPCWSTR) callconv(.winapi) BOOL;
extern "kernel32" fn GlobalAlloc(uFlags: UINT, dwBytes: usize) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalLock(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(hMem: ?*anyopaque) callconv(.winapi) BOOL;
extern "gdi32" fn ChoosePixelFormat(hdc: HDC, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(.winapi) i32;
extern "gdi32" fn SetPixelFormat(hdc: HDC, format: i32, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(.winapi) BOOL;
extern "gdi32" fn SwapBuffers(hdc: HDC) callconv(.winapi) BOOL;
extern "gdi32" fn TextOutW(hdc: HDC, x: i32, y: i32, lpString: LPCWSTR, c: i32) callconv(.winapi) BOOL;
extern "opengl32" fn wglCreateContext(hdc: HDC) callconv(.winapi) HGLRC;
extern "opengl32" fn wglDeleteContext(hglrc: HGLRC) callconv(.winapi) BOOL;
extern "opengl32" fn wglGetProcAddress(lpszProc: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "opengl32" fn wglMakeCurrent(hdc: HDC, hglrc: HGLRC) callconv(.winapi) BOOL;
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
const host_overlay_surface_title_label = std.unicode.utf8ToUtf16LeStringLiteral("Window title:");
const host_overlay_tab_title_label = std.unicode.utf8ToUtf16LeStringLiteral("Tab title:");
const host_overlay_tab_overview_label = std.unicode.utf8ToUtf16LeStringLiteral("Tab:");
const host_tab_command_button_label = std.unicode.utf8ToUtf16LeStringLiteral("Cmd");
const host_tab_command_button_active_label = std.unicode.utf8ToUtf16LeStringLiteral("[Cmd]");
const host_tab_search_button_label = std.unicode.utf8ToUtf16LeStringLiteral("Find");
const host_tab_search_button_active_label = std.unicode.utf8ToUtf16LeStringLiteral("[Find]");
const host_tab_inspector_button_label = std.unicode.utf8ToUtf16LeStringLiteral("Inspect");
const host_tab_inspector_button_active_label = std.unicode.utf8ToUtf16LeStringLiteral("[Inspect]");
const host_tab_new_button_label = std.unicode.utf8ToUtf16LeStringLiteral("+");
const host_tab_close_button_label = std.unicode.utf8ToUtf16LeStringLiteral("x");
const fallback_line_1 = std.unicode.utf8ToUtf16LeStringLiteral("winghostty Win32");
const fallback_line_2 = std.unicode.utf8ToUtf16LeStringLiteral("Native rendering is disabled for this run.");
const fallback_line_3 = std.unicode.utf8ToUtf16LeStringLiteral("Unset WINGHOSTTY_WIN32_DISABLE_EXPERIMENTAL_DRAW to use the live renderer.");
const clipboard_read_title = std.unicode.utf8ToUtf16LeStringLiteral("Allow clipboard paste?");
const clipboard_read_message = std.unicode.utf8ToUtf16LeStringLiteral("winghostty needs confirmation before completing this clipboard paste or read request.");
const clipboard_write_title = std.unicode.utf8ToUtf16LeStringLiteral("Allow clipboard write?");
const clipboard_write_message = std.unicode.utf8ToUtf16LeStringLiteral("winghostty needs confirmation before allowing this application to write to the Windows clipboard.");
const notification_title = std.unicode.utf8ToUtf16LeStringLiteral("winghostty");
const opengl32_name: [*:0]const u8 = "opengl32.dll";
const shell_open: LPCWSTR = std.unicode.utf8ToUtf16LeStringLiteral("open");

var opengl32_module: HMODULE = null;

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
    hinstance: HINSTANCE,
    class_atom: ATOM = 0,
    host_class_atom: ATOM = 0,
    hosts: std.ArrayListUnmanaged(*Host) = .empty,
    windows: std.ArrayListUnmanaged(*Surface) = .empty,
    next_host_id: u32 = 1,
    running: bool = false,
    experimental_draw: bool = true,
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
            .experimental_draw = detectExperimentalDraw(core_app.alloc),
        };
        log.info("win32 experimental_draw={}", .{self.experimental_draw});
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

        if (self.config.@"initial-window") {
            try self.createWindow(default_title);
            trace("win32.App.run: initial window created", .{});
        } else {
            log.info("initial-window is disabled; win32 runtime exiting without a window", .{});
            return;
        }

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
        self.destroyAllWindows();
        self.hosts.deinit(self.core_app.alloc);
        self.windows.deinit(self.core_app.alloc);
        self.config.deinit();
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
                if (!self.allowExperimentalDraw()) return true;
                return switch (target) {
                    .app => blk: {
                        for (self.windows.items) |surface| try surface.redraw();
                        break :blk true;
                    },
                    .surface => if (self.findSurfaceForTarget(target)) |surface| blk: {
                        try surface.redraw();
                        break :blk true;
                    } else false,
                };
            },

            .render_inspector => {
                if (!self.allowExperimentalDraw()) return true;
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
                    const caption = try std.unicode.utf8ToUtf16LeAllocZ(
                        self.core_app.alloc,
                        "GTK Inspector Unsupported",
                    );
                    defer self.core_app.alloc.free(caption);
                    const body = try std.unicode.utf8ToUtf16LeAllocZ(
                        self.core_app.alloc,
                        "The GTK inspector is not available on the native Win32 runtime.",
                    );
                    defer self.core_app.alloc.free(body);
                    _ = MessageBoxW(surface.hwnd, body.ptr, caption.ptr, MB_OK | MB_ICONINFORMATION);
                    return true;
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

            else => {
                log.warn("win32 apprt action not implemented action={}", .{action});
                return false;
            },
        }
    }

    pub fn performIpc(
        _: Allocator,
        _: apprt.ipc.Target,
        comptime action: apprt.ipc.Action.Key,
        _: apprt.ipc.Action.Value(action),
    ) !bool {
        switch (action) {
            .new_window => return false,
        }
    }

    fn ensureWindowClass(self: *App) !void {
        if (self.class_atom != 0) return;

        var wc: WNDCLASSEXW = .{
            .cbSize = @sizeOf(WNDCLASSEXW),
            .style = CS_HREDRAW | CS_VREDRAW,
            .lpfnWndProc = &windowProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = self.hinstance,
            .hIcon = null,
            .hCursor = LoadCursorW(null, IDC_ARROW),
            .hbrBackground = @ptrFromInt(COLOR_WINDOW + 1),
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
            .style = CS_HREDRAW | CS_VREDRAW,
            .lpfnWndProc = &hostWindowProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = self.hinstance,
            .hIcon = null,
            .hCursor = LoadCursorW(null, IDC_ARROW),
            .hbrBackground = @ptrFromInt(COLOR_WINDOW + 1),
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

    fn createWindow(self: *App, title: LPCWSTR) !void {
        _ = try self.createWindowSurface(&self.config, title, .{});
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

        const hwnd = CreateWindowExW(
            0,
            host_class_name,
            title,
            WS_OVERLAPPEDWINDOW | WS_VISIBLE,
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

    fn allowExperimentalDraw(self: *App) bool {
        return self.experimental_draw;
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
            "Child exited with code {d}\nRuntime: {d:.2}s",
            .{ exited.exit_code, seconds },
        );
        defer self.core_app.alloc.free(message);
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
                "Command finished with exit code {d}\nRuntime: {d:.2}s",
                .{ code, seconds },
            )
        else
            try std.fmt.allocPrint(
                self.core_app.alloc,
                "Command finished\nRuntime: {d:.2}s",
                .{seconds},
            );
        defer self.core_app.alloc.free(message);
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
};

const SearchStatus = struct {
    active: bool = false,
    needle: ?[]const u8 = null,
    total: ?usize = null,
    selected: ?usize = null,
};

const SurfaceStatus = struct {
    pwd: ?[]const u8 = null,
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

const SplitTreeSurface = SplitTree(Surface);

const Tab = struct {
    id: u32,
    tree: SplitTreeSurface,
    focused: SplitTreeSurface.Node.Handle = .root,
    button_hwnd: ?HWND = null,

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
    overlay_accept_hwnd: ?HWND = null,
    overlay_cancel_hwnd: ?HWND = null,
    command_palette_hwnd: ?HWND = null,
    search_hwnd: ?HWND = null,
    inspector_hwnd: ?HWND = null,
    new_tab_hwnd: ?HWND = null,
    close_tab_hwnd: ?HWND = null,
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
        if (self.hwnd) |hwnd| _ = InvalidateRect(hwnd, null, 1);
    }

    fn setOverlayDefaultBanner(self: *Host, mode: HostOverlayMode) !void {
        switch (mode) {
            .none => try self.setBanner(.none, null),
            .command_palette => try self.setBanner(.info, "Enter a Ghostty action. Examples: new_tab, toggle_fullscreen, goto_split:right"),
            .search => try self.setBanner(.info, "Type to search live. Enter keeps the current needle. Escape closes search."),
            .surface_title => try self.setBanner(.info, "Set a window title override. Submit an empty value to clear it."),
            .tab_title => try self.setBanner(.info, "Set a tab title override. Submit an empty value to clear it."),
            .tab_overview => {
                const count = self.tabs.items.len;
                const info = try std.fmt.allocPrint(self.app.core_app.alloc, "Jump to a tab number from 1 to {d}.", .{count});
                defer self.app.core_app.alloc.free(info);
                try self.setBanner(.info, info);
            },
        }
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
            WS_CHILD | WS_TABSTOP | WS_BORDER | ES_AUTOHSCROLL,
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

        self.overlay_accept_hwnd = CreateWindowExW(
            0,
            prompt_button_class,
            prompt_ok_label,
            WS_CHILD | WS_TABSTOP | BS_DEFPUSHBUTTON,
            0,
            0,
            70,
            host_overlay_height - 8,
            hwnd,
            @ptrFromInt(2003),
            self.app.hinstance,
            null,
        ) orelse return windows.unexpectedError(windows.kernel32.GetLastError());

        self.overlay_cancel_hwnd = CreateWindowExW(
            0,
            prompt_button_class,
            prompt_cancel_label,
            WS_CHILD | WS_TABSTOP | BS_PUSHBUTTON,
            0,
            0,
            80,
            host_overlay_height - 8,
            hwnd,
            @ptrFromInt(2004),
            self.app.hinstance,
            null,
        ) orelse return windows.unexpectedError(windows.kernel32.GetLastError());

        self.hideOverlay();
    }

    fn ensureChromeButtons(self: *Host) !void {
        const hwnd = self.hwnd orelse return;

        if (self.command_palette_hwnd == null) {
            self.command_palette_hwnd = CreateWindowExW(
                0,
                prompt_button_class,
                host_tab_command_button_label,
                WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON,
                0,
                0,
                host_tab_cmd_button_width,
                host_tab_height - 8,
                hwnd,
                @ptrFromInt(1901),
                self.app.hinstance,
                null,
            ) orelse return windows.unexpectedError(windows.kernel32.GetLastError());
        }

        if (self.search_hwnd == null) {
            self.search_hwnd = CreateWindowExW(
                0,
                prompt_button_class,
                host_tab_search_button_label,
                WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON,
                0,
                0,
                host_tab_find_button_width,
                host_tab_height - 8,
                hwnd,
                @ptrFromInt(1902),
                self.app.hinstance,
                null,
            ) orelse return windows.unexpectedError(windows.kernel32.GetLastError());
        }

        if (self.inspector_hwnd == null) {
            self.inspector_hwnd = CreateWindowExW(
                0,
                prompt_button_class,
                host_tab_inspector_button_label,
                WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON,
                0,
                0,
                host_tab_inspect_button_width,
                host_tab_height - 8,
                hwnd,
                @ptrFromInt(1903),
                self.app.hinstance,
                null,
            ) orelse return windows.unexpectedError(windows.kernel32.GetLastError());
        }

        if (self.new_tab_hwnd == null) {
            self.new_tab_hwnd = CreateWindowExW(
                0,
                prompt_button_class,
                host_tab_new_button_label,
                WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON,
                0,
                0,
                host_tab_small_button_width,
                host_tab_height - 8,
                hwnd,
                @ptrFromInt(1904),
                self.app.hinstance,
                null,
            ) orelse return windows.unexpectedError(windows.kernel32.GetLastError());
        }

        if (self.close_tab_hwnd == null) {
            self.close_tab_hwnd = CreateWindowExW(
                0,
                prompt_button_class,
                host_tab_close_button_label,
                WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON,
                0,
                0,
                host_tab_small_button_width,
                host_tab_height - 8,
                hwnd,
                @ptrFromInt(1905),
                self.app.hinstance,
                null,
            ) orelse return windows.unexpectedError(windows.kernel32.GetLastError());
        }
    }

    fn showOverlay(self: *Host, mode: HostOverlayMode, initial: ?[]const u8) !void {
        try self.ensureOverlayControls();
        self.overlay_mode = mode;
        try self.setOverlayDefaultBanner(mode);

        const label_hwnd = self.overlay_label_hwnd orelse return;
        const edit_hwnd = self.overlay_edit_hwnd orelse return;
        const accept_hwnd = self.overlay_accept_hwnd orelse return;
        const cancel_hwnd = self.overlay_cancel_hwnd orelse return;
        _ = ShowWindow(label_hwnd, SW_SHOW);
        _ = ShowWindow(edit_hwnd, SW_SHOW);
        _ = ShowWindow(accept_hwnd, SW_SHOW);
        _ = ShowWindow(cancel_hwnd, SW_SHOW);

        const label = switch (mode) {
            .none => host_overlay_command_palette_label,
            .command_palette => host_overlay_command_palette_label,
            .search => host_overlay_search_label,
            .surface_title => host_overlay_surface_title_label,
            .tab_title => host_overlay_tab_title_label,
            .tab_overview => host_overlay_tab_overview_label,
        };
        _ = SetWindowTextW(label_hwnd, label);

        const initial_text = initial orelse "";
        const initial_w = try std.unicode.utf8ToUtf16LeAllocZ(self.app.core_app.alloc, initial_text);
        defer self.app.core_app.alloc.free(initial_w);
        _ = SetWindowTextW(edit_hwnd, initial_w.ptr);

        try self.layout();
        _ = SetFocus(edit_hwnd);
    }

    fn hideOverlay(self: *Host) void {
        self.overlay_mode = .none;
        self.setBanner(.none, null) catch {};
        if (self.overlay_label_hwnd) |hwnd| _ = ShowWindow(hwnd, SW_HIDE);
        if (self.overlay_edit_hwnd) |hwnd| _ = ShowWindow(hwnd, SW_HIDE);
        if (self.overlay_accept_hwnd) |hwnd| _ = ShowWindow(hwnd, SW_HIDE);
        if (self.overlay_cancel_hwnd) |hwnd| _ = ShowWindow(hwnd, SW_HIDE);
    }

    fn overlayInitialText(self: *Host, mode: HostOverlayMode) ?[]const u8 {
        const surface = self.activeSurface() orelse return null;
        return switch (mode) {
            .none => null,
            .command_palette => null,
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

    fn syncSearchOverlay(self: *Host) !bool {
        const edit_hwnd = self.overlay_edit_hwnd orelse return false;
        const surface = self.activeSurface() orelse return false;
        const raw = try readWindowTextUtf8Alloc(self.app.core_app.alloc, edit_hwnd);
        defer self.app.core_app.alloc.free(raw);
        const text = std.mem.trim(u8, raw, " \t\r\n");
        _ = try surface.core_surface.setSearchText(text);
        try surface.setSearchActive(text.len > 0, text);
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
            try self.setOverlayDefaultBanner(.command_palette);
        }
        return true;
    }

    fn submitOverlay(self: *Host) !bool {
        const edit_hwnd = self.overlay_edit_hwnd orelse return false;
        const raw = try readWindowTextUtf8Alloc(self.app.core_app.alloc, edit_hwnd);
        defer self.app.core_app.alloc.free(raw);
        const text = std.mem.trim(u8, raw, " \t\r\n");
        if (text.len == 0 and self.overlay_mode != .search) {
            self.hideOverlay();
            try self.layout();
            return false;
        }

        const surface = self.activeSurface() orelse return false;
        switch (self.overlay_mode) {
            .none => return false,
            .command_palette => {
                const action = input.Binding.Action.parse(text) catch |err| {
                    log.warn("win32 command palette invalid action action={s} err={}", .{ text, err });
                    try self.setBanner(.err, "Unknown Ghostty action. Example: new_tab or toggle_fullscreen");
                    return false;
                };
                _ = try surface.core_surface.performBindingAction(action);
            },
            .search => {
                _ = try surface.core_surface.setSearchText(text);
                try surface.setSearchActive(text.len > 0, text);
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

    fn contentRect(self: *Host) !RECT {
        const hwnd = self.hwnd orelse return error.InvalidHost;
        var rect: RECT = undefined;
        if (GetClientRect(hwnd, &rect) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
        const overlay_offset: i32 = if (self.overlay_mode == .none) 0 else host_overlay_height;
        return .{
            .left = 0,
            .top = host_tab_height + overlay_offset,
            .right = rect.right,
            .bottom = @max(host_tab_height + 1, rect.bottom - host_status_height),
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
        if (surface.inspector_visible) try append.raw(&parts, alloc, "inspector");
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

    fn refreshChrome(self: *Host) !void {
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
        _ = InvalidateRect(hwnd, null, 1);
        try self.syncTabButtons();
        try self.syncChromeButtons();
    }

    fn syncTabButtons(self: *Host) !void {
        const hwnd = self.hwnd orelse return;
        try self.ensureChromeButtons();
        for (self.tabs.items, 0..) |*tab, i| {
            const surface = tab.focusedSurface() orelse continue;
            const label = try buildTabButtonLabel(
                self.app.core_app.alloc,
                if (surface.effectiveTitle()) |value| value else null,
                i,
                i == self.active_tab,
                tab.leafCount(),
            );
            defer self.app.core_app.alloc.free(label);
            const label_w = try std.unicode.utf8ToUtf16LeAllocZ(self.app.core_app.alloc, label);
            defer self.app.core_app.alloc.free(label_w);
            if (tab.button_hwnd == null) {
                tab.button_hwnd = CreateWindowExW(
                    0,
                    prompt_button_class,
                    label_w.ptr,
                    WS_CHILD | WS_VISIBLE | WS_TABSTOP | @as(u32, if (i == self.active_tab) BS_DEFPUSHBUTTON else BS_PUSHBUTTON),
                    0,
                    0,
                    100,
                    host_tab_height - 8,
                    hwnd,
                    @ptrFromInt(1000 + i),
                    self.app.hinstance,
                    null,
                ) orelse return windows.unexpectedError(windows.kernel32.GetLastError());
            } else {
                _ = SetWindowTextW(tab.button_hwnd.?, label_w.ptr);
            }
        }
        try self.layout();
    }

    fn syncChromeButtons(self: *Host) !void {
        try self.ensureChromeButtons();

        const command_hwnd = self.command_palette_hwnd orelse return;
        const search_hwnd = self.search_hwnd orelse return;
        const inspector_hwnd = self.inspector_hwnd orelse return;
        const new_tab_hwnd = self.new_tab_hwnd orelse return;
        const close_tab_hwnd = self.close_tab_hwnd orelse return;
        const surface = self.activeSurface();

        _ = SetWindowTextW(
            command_hwnd,
            if (self.overlay_mode == .command_palette)
                host_tab_command_button_active_label
            else
                host_tab_command_button_label,
        );
        _ = SetWindowTextW(
            search_hwnd,
            if (self.overlay_mode == .search)
                host_tab_search_button_active_label
            else
                host_tab_search_button_label,
        );
        _ = SetWindowTextW(
            inspector_hwnd,
            if (surface != null and surface.?.inspector_visible)
                host_tab_inspector_button_active_label
            else
                host_tab_inspector_button_label,
        );
        _ = ShowWindow(command_hwnd, SW_SHOW);
        _ = ShowWindow(search_hwnd, SW_SHOW);
        _ = ShowWindow(inspector_hwnd, SW_SHOW);
        _ = ShowWindow(new_tab_hwnd, SW_SHOW);
        _ = ShowWindow(close_tab_hwnd, SW_SHOW);
    }

    fn layout(self: *Host) !void {
        const hwnd = self.hwnd orelse return;
        var rect: RECT = undefined;
        if (GetClientRect(hwnd, &rect) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }

        const width = @max(0, rect.right - rect.left);
        const right_buttons_width =
            host_tab_cmd_button_width +
            host_tab_find_button_width +
            host_tab_inspect_button_width +
            (host_tab_small_button_width * 2) +
            28;
        const tab_count = @max(@as(i32, 1), @as(i32, @intCast(self.tabs.items.len)));
        const tab_area_width = @max(1, width - right_buttons_width);
        const button_width = @max(1, @divTrunc(tab_area_width, tab_count));
        for (self.tabs.items, 0..) |*tab, i| {
            if (tab.button_hwnd) |button_hwnd| {
                _ = MoveWindow(
                    button_hwnd,
                    @as(i32, @intCast(i)) * button_width,
                    4,
                    button_width,
                    host_tab_height - 8,
                    1,
                );
                _ = ShowWindow(button_hwnd, SW_SHOW);
            }
        }

        var button_x = width - 8;
        if (self.close_tab_hwnd) |button_hwnd| {
            button_x -= host_tab_small_button_width;
            _ = MoveWindow(button_hwnd, button_x, 4, host_tab_small_button_width, host_tab_height - 8, 1);
        }
        button_x -= 4;
        if (self.new_tab_hwnd) |button_hwnd| {
            button_x -= host_tab_small_button_width;
            _ = MoveWindow(button_hwnd, button_x, 4, host_tab_small_button_width, host_tab_height - 8, 1);
        }
        button_x -= 4;
        if (self.inspector_hwnd) |button_hwnd| {
            button_x -= host_tab_inspect_button_width;
            _ = MoveWindow(button_hwnd, button_x, 4, host_tab_inspect_button_width, host_tab_height - 8, 1);
        }
        button_x -= 4;
        if (self.search_hwnd) |button_hwnd| {
            button_x -= host_tab_find_button_width;
            _ = MoveWindow(button_hwnd, button_x, 4, host_tab_find_button_width, host_tab_height - 8, 1);
        }
        button_x -= 4;
        if (self.command_palette_hwnd) |button_hwnd| {
            button_x -= host_tab_cmd_button_width;
            _ = MoveWindow(button_hwnd, button_x, 4, host_tab_cmd_button_width, host_tab_height - 8, 1);
        }

        if (self.overlay_mode != .none) {
            const label_hwnd = self.overlay_label_hwnd orelse return;
            const edit_hwnd = self.overlay_edit_hwnd orelse return;
            const accept_hwnd = self.overlay_accept_hwnd orelse return;
            const cancel_hwnd = self.overlay_cancel_hwnd orelse return;
            const overlay_y = host_tab_height;
            const label_width = 86;
            const accept_width = 70;
            const cancel_width = 80;
            const padding = 10;
            const edit_width = @max(120, width - label_width - accept_width - cancel_width - (padding * 5));
            _ = MoveWindow(label_hwnd, padding, overlay_y + 4, label_width, host_overlay_height - 8, 1);
            _ = MoveWindow(edit_hwnd, padding + label_width + padding, overlay_y + 4, edit_width, host_overlay_height - 8, 1);
            _ = MoveWindow(accept_hwnd, width - cancel_width - accept_width - (padding * 2), overlay_y + 4, accept_width, host_overlay_height - 8, 1);
            _ = MoveWindow(cancel_hwnd, width - cancel_width - padding, overlay_y + 4, cancel_width, host_overlay_height - 8, 1);
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
            }
        }

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
        const overlay_offset: i32 = if (self.overlay_mode != .none) host_overlay_height else 0;
        const banner_y: i32 = host_tab_height + overlay_offset + 2;
        const banner_value: ?[]const u8 = if (self.banner_text) |value|
            value
        else if (self.activeSurface()) |surface|
            if (surface.inspector_visible) "Inspector active. Toggle inspector to return to the terminal view." else null
        else
            null;
        const banner_kind: HostBannerKind = if (self.banner_text != null)
            self.banner_kind
        else if (banner_value != null)
            .info
        else
            .none;

        if (banner_value) |value| {
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
            _ = TextOutW(hdc, 16, banner_y, banner_w.ptr, @intCast(banner_w.len - 1));
        }

        const status = self.statusText(alloc) catch null;
        defer if (status) |owned| alloc.free(owned);
        if (status) |value| {
            const status_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, value) catch return;
            defer alloc.free(status_w);
            _ = TextOutW(hdc, 16, @max(host_tab_height + 2, ps.rcPaint.bottom - host_status_height + 4), status_w.ptr, @intCast(status_w.len - 1));
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

fn appendOwnedString(
    alloc: Allocator,
    target: *?[:0]const u8,
    value: ?[]const u8,
) !void {
    if (target.*) |existing| alloc.free(existing);
    target.* = if (value) |v| try alloc.dupeZ(u8, v) else null;
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

fn buildTabButtonLabel(
    alloc: Allocator,
    base_title: ?[]const u8,
    index: usize,
    active: bool,
    pane_count: usize,
) ![]u8 {
    if (pane_count > 1) {
        return try std.fmt.allocPrint(
            alloc,
            "{s}{d}: {s} ({d})",
            .{
                if (active) "* " else "",
                index + 1,
                base_title orelse "winghostty",
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
            base_title orelse "winghostty",
        },
    );
}

fn commandPaletteBannerText(alloc: Allocator, input_text: []const u8) !?[]u8 {
    const curated = [_][]const u8{
        "new_tab",
        "new_split:right",
        "goto_split:right",
        "toggle_fullscreen",
        "toggle_command_palette",
        "start_search",
        "inspector:toggle",
        "reload_config",
    };

    if (input_text.len == 0) {
        return try alloc.dupe(u8, "Try: new_tab, new_split:right, goto_split:right, toggle_fullscreen");
    }

    if (input.Binding.Action.parse(input_text)) |_| {
        return try std.fmt.allocPrint(alloc, "Ready to run: {s}", .{input_text});
    } else |_| {}

    var matches: std.ArrayListUnmanaged([]const u8) = .empty;
    defer matches.deinit(alloc);
    for (curated) |candidate| {
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

fn overlayEditProc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT {
    const host = getHost(hwnd);
    if (host) |v| switch (msg) {
        WM_CHAR => {
            if (wParam == VK_RETURN) {
                _ = v.submitOverlay() catch {};
                return 0;
            }
        },

        WM_KEYDOWN => {
            if (wParam == VK_ESCAPE) {
                if (v.overlay_mode == .search) {
                    if (v.activeSurface()) |surface| {
                        _ = surface.core_surface.endSearch() catch {};
                    }
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
                                _ = v.syncCommandPaletteBanner() catch {};
                            }
                            return 0;
                        }
                    },
                    2003 => {
                        _ = v.submitOverlay() catch {};
                        return 0;
                    },
                    2004 => {
                        if (v.overlay_mode == .search) {
                            if (v.activeSurface()) |surface| {
                                _ = surface.core_surface.endSearch() catch {};
                            }
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
                        if (v.activeSurface()) |surface| {
                            _ = v.app.performAction(.{ .surface = surface.core() }, .new_tab, {}) catch {};
                        }
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

fn detectExperimentalDraw(alloc: Allocator) bool {
    const disable = std.process.getEnvVarOwned(alloc, "WINGHOSTTY_WIN32_DISABLE_EXPERIMENTAL_DRAW") catch
        return true;
    defer alloc.free(disable);
    return !(std.mem.eql(u8, disable, "1") or
        std.ascii.eqlIgnoreCase(disable, "true") or
        std.ascii.eqlIgnoreCase(disable, "yes"));
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

fn scrollAmountFromWParam(wParam: WPARAM) f64 {
    const bits = @as(usize, @intCast(wParam));
    const delta: i16 = @bitCast(highWord(bits));
    return @as(f64, @floatFromInt(delta)) / WHEEL_DELTA;
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

        WM_LBUTTONDOWN, WM_LBUTTONUP, WM_RBUTTONDOWN, WM_RBUTTONUP, WM_MBUTTONDOWN, WM_MBUTTONUP => {
            if (surface) |v| {
                v.handleMouseButton(msg, wParam, lParam);
                return 0;
            }
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        WM_MOUSEWHEEL => {
            if (surface) |v| {
                v.handleMouseWheel(0, -scrollAmountFromWParam(wParam));
                return 0;
            }
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        WM_MOUSEHWHEEL => {
            if (surface) |v| {
                v.handleMouseWheel(scrollAmountFromWParam(wParam), 0);
                return 0;
            }
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
            if (surface) |v| {
                if (v.app.allowExperimentalDraw() and v.core_initialized) {
                    var ps: PAINTSTRUCT = undefined;
                    _ = BeginPaint(hwnd, &ps) orelse return 0;
                    defer _ = EndPaint(hwnd, &ps);

                    v.redraw() catch |err| {
                        log.err("win32 paint redraw failed err={}", .{err});
                    };
                } else {
                    v.paintPreview();
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
    pwd: ?[:0]const u8 = null,
    progress_status: ?[:0]const u8 = null,
    inspector_visible: bool = false,
    debug_input_budget: u8 = 32,

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
            WS_CHILD | WS_VISIBLE,
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
        if (app.allowExperimentalDraw()) {
            try self.redraw();
        }

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
        self.redraw() catch |err| {
            log.err("win32 inspector redraw failed err={}", .{err});
        };
    }

    pub fn supportsRender(self: *const Surface) bool {
        _ = self;
        return true;
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
        if (self.app.allowExperimentalDraw()) {
            try self.redraw();
        }
        return true;
    }

    fn refreshWindowTitle(self: *Surface) !void {
        if (self.host) |host| {
            try host.refreshChrome();
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

    fn handleMouseWheel(self: *Surface, xoff: f64, yoff: f64) void {
        if (!self.core_initialized) return;
        self.core_surface.scrollCallback(xoff, yoff, .{}) catch |err| {
            log.err("win32 scroll callback failed err={} xoff={} yoff={}", .{
                err,
                xoff,
                yoff,
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

    fn paintPreview(self: *Surface) void {
        const hwnd = self.hwnd orelse return;

        var ps: PAINTSTRUCT = undefined;
        const hdc = BeginPaint(hwnd, &ps) orelse return;
        defer _ = EndPaint(hwnd, &ps);

        _ = TextOutW(hdc, 24, 24, fallback_line_1, fallback_line_1.len - 1);
        _ = TextOutW(hdc, 24, 56, fallback_line_2, fallback_line_2.len - 1);
        _ = TextOutW(hdc, 24, 88, fallback_line_3, fallback_line_3.len - 1);
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

test "win32 preview runtime can initialize config" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var core = try CoreApp.create(std.testing.allocator);
    defer core.destroy();

    var app: App = undefined;
    try app.init(core, .{});
    defer app.terminate();

    try std.testing.expect(app.hinstance != null);
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

    const encoded = (@as(usize, @bitCast(@as(u16, @bitCast(@as(i16, -5))))) << 16) |
        @as(usize, @bitCast(@as(u16, @bitCast(@as(i16, 12)))));
    const pos = cursorPosFromLParam(@bitCast(@as(isize, @intCast(encoded))));
    try std.testing.expectEqual(@as(f32, 12), pos.x);
    try std.testing.expectEqual(@as(f32, -5), pos.y);
}

test "win32 buildWindowTitle appends active status segments" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const title = try buildWindowTitle(std.testing.allocator, "pwsh", .{
        .pwd = "/Users/amant",
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

    const title = try buildTabButtonLabel(std.testing.allocator, "pwsh", 1, true, 3);
    defer std.testing.allocator.free(title);
    try std.testing.expectEqualStrings("* 2: pwsh (3)", title);
}

test "win32 buildTabButtonLabel omits pane count for single pane tabs" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const title = try buildTabButtonLabel(std.testing.allocator, "pwsh", 0, false, 1);
    defer std.testing.allocator.free(title);
    try std.testing.expectEqualStrings("1: pwsh", title);
}

test "win32 commandPaletteBannerText shows ready banner for valid action" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const banner = (try commandPaletteBannerText(std.testing.allocator, "new_tab")).?;
    defer std.testing.allocator.free(banner);
    try std.testing.expectEqualStrings("Ready to run: new_tab", banner);
}

test "win32 commandPaletteBannerText suggests matching actions" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const banner = (try commandPaletteBannerText(std.testing.allocator, "new_")).?;
    defer std.testing.allocator.free(banner);
    try std.testing.expect(std.mem.indexOf(u8, banner, "new_tab") != null);
    try std.testing.expect(std.mem.indexOf(u8, banner, "new_split:right") != null);
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
