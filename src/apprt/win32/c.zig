//! The slice of the Win32 API the runtime uses, declared by hand.
//!
//! Handles are plain opaque pointers and the message parameters are
//! pointer-sized integers, which matches how the headers define them on
//! 64-bit Windows.
const std = @import("std");

pub const Handle = *anyopaque;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;

pub const WndProc = *const fn (Handle, u32, WPARAM, LPARAM) callconv(.c) LRESULT;

// Window messages.
pub const WM_NCCREATE = 0x0081;
pub const WM_DESTROY = 0x0002;
pub const WM_SIZE = 0x0005;
pub const WM_SETFOCUS = 0x0007;
pub const WM_KILLFOCUS = 0x0008;
pub const WM_PAINT = 0x000F;
pub const WM_CLOSE = 0x0010;
pub const WM_ERASEBKGND = 0x0014;
pub const WM_SETCURSOR = 0x0020;
pub const WM_KEYDOWN = 0x0100;
pub const WM_KEYUP = 0x0101;
pub const WM_SYSKEYDOWN = 0x0104;
pub const WM_SYSKEYUP = 0x0105;
pub const WM_PRINTCLIENT = 0x0318;
pub const WM_MOUSEMOVE = 0x0200;
pub const WM_LBUTTONDOWN = 0x0201;
pub const WM_LBUTTONUP = 0x0202;
pub const WM_RBUTTONDOWN = 0x0204;
pub const WM_RBUTTONUP = 0x0205;
pub const WM_MBUTTONDOWN = 0x0207;
pub const WM_MBUTTONUP = 0x0208;
pub const WM_MOUSEWHEEL = 0x020A;
pub const WM_MOUSEHWHEEL = 0x020E;
pub const WM_DPICHANGED = 0x02E0;
pub const WM_APP = 0x8000;

pub const SW_SHOW = 5;
pub const PM_REMOVE = 1;
pub const GWLP_USERDATA = -21;
pub const CS_OWNDC = 0x0020;
pub const WS_OVERLAPPEDWINDOW = 0x00CF0000;
pub const CW_USEDEFAULT: c_int = @bitCast(@as(u32, 0x80000000));
pub const IDC_ARROW: usize = 32512;
pub const HWND_MESSAGE: usize = @bitCast(@as(isize, -3));
pub const DPI_AWARENESS_PER_MONITOR_V2: isize = -4;
pub const DIB_RGB_COLORS = 0;
pub const CF_UNICODETEXT = 13;
pub const GMEM_MOVEABLE = 0x0002;

pub const VK_SHIFT = 0x10;
pub const VK_CONTROL = 0x11;
pub const VK_MENU = 0x12;
pub const VK_CAPITAL = 0x14;
pub const VK_F4 = 0x73;
pub const VK_SPACE = 0x20;
pub const VK_NUMLOCK = 0x90;
pub const VK_LWIN = 0x5B;
pub const VK_RWIN = 0x5C;
pub const VK_LCONTROL = 0xA2;
pub const VK_RMENU = 0xA5;

pub const Point = extern struct { x: i32, y: i32 };
pub const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

pub const Msg = extern struct {
    hwnd: ?Handle,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
    time: u32,
    pt: Point,
    private: u32,
};

pub const WndClassExW = extern struct {
    size: u32 = @sizeOf(WndClassExW),
    style: u32 = 0,
    wnd_proc: WndProc,
    class_extra: c_int = 0,
    window_extra: c_int = 0,
    instance: ?Handle,
    icon: ?Handle = null,
    cursor: ?Handle = null,
    background: ?Handle = null,
    menu_name: ?[*:0]const u16 = null,
    class_name: [*:0]const u16,
    icon_small: ?Handle = null,
};

pub const CreateStructW = extern struct {
    create_params: ?*anyopaque,
    instance: ?Handle,
    menu: ?Handle,
    parent: ?Handle,
    cy: c_int,
    cx: c_int,
    y: c_int,
    x: c_int,
    style: i32,
    name: ?[*:0]const u16,
    class_name: ?[*:0]const u16,
    ex_style: u32,
};

pub const PaintStruct = extern struct {
    hdc: ?Handle,
    erase: c_int,
    paint: Rect,
    restore: c_int,
    update: c_int,
    reserved: [32]u8,
};

pub const BitmapInfoHeader = extern struct {
    size: u32 = @sizeOf(BitmapInfoHeader),
    width: i32,
    height: i32,
    planes: u16 = 1,
    bit_count: u16 = 32,
    compression: u32 = 0,
    size_image: u32 = 0,
    x_pixels_per_meter: i32 = 0,
    y_pixels_per_meter: i32 = 0,
    colors_used: u32 = 0,
    colors_important: u32 = 0,
};

pub extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.c) ?Handle;
pub extern "kernel32" fn GlobalAlloc(flags: u32, bytes: usize) callconv(.c) ?Handle;
pub extern "kernel32" fn GlobalLock(mem: Handle) callconv(.c) ?[*]u8;
pub extern "kernel32" fn GlobalUnlock(mem: Handle) callconv(.c) c_int;
pub extern "kernel32" fn GlobalFree(mem: Handle) callconv(.c) ?Handle;

pub extern "user32" fn RegisterClassExW(class: *const WndClassExW) callconv(.c) u16;
pub extern "user32" fn CreateWindowExW(
    ex_style: u32,
    class_name: [*:0]const u16,
    window_name: [*:0]const u16,
    style: u32,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    parent: ?Handle,
    menu: ?Handle,
    instance: ?Handle,
    param: ?*anyopaque,
) callconv(.c) ?Handle;
pub extern "user32" fn DefWindowProcW(hwnd: Handle, msg: u32, w: WPARAM, l: LPARAM) callconv(.c) LRESULT;
pub extern "user32" fn DestroyWindow(hwnd: Handle) callconv(.c) c_int;
pub extern "user32" fn ShowWindow(hwnd: Handle, cmd: c_int) callconv(.c) c_int;
pub extern "user32" fn SetFocus(hwnd: Handle) callconv(.c) ?Handle;
pub extern "user32" fn GetMessageW(msg: *Msg, hwnd: ?Handle, min: u32, max: u32) callconv(.c) c_int;
pub extern "user32" fn DispatchMessageW(msg: *const Msg) callconv(.c) LRESULT;
pub extern "user32" fn PostMessageW(hwnd: Handle, msg: u32, w: WPARAM, l: LPARAM) callconv(.c) c_int;
pub extern "user32" fn PostQuitMessage(code: c_int) callconv(.c) void;
pub extern "user32" fn SetWindowLongPtrW(hwnd: Handle, index: c_int, value: isize) callconv(.c) isize;
pub extern "user32" fn GetWindowLongPtrW(hwnd: Handle, index: c_int) callconv(.c) isize;
pub extern "user32" fn GetClientRect(hwnd: Handle, rect: *Rect) callconv(.c) c_int;
pub extern "user32" fn InvalidateRect(hwnd: Handle, rect: ?*const Rect, erase: c_int) callconv(.c) c_int;
pub extern "user32" fn BeginPaint(hwnd: Handle, ps: *PaintStruct) callconv(.c) ?Handle;
pub extern "user32" fn EndPaint(hwnd: Handle, ps: *const PaintStruct) callconv(.c) c_int;
pub extern "user32" fn SetWindowTextW(hwnd: Handle, text: [*:0]const u16) callconv(.c) c_int;
pub extern "user32" fn LoadCursorW(instance: ?Handle, name: usize) callconv(.c) ?Handle;
pub extern "user32" fn SetCursor(cursor: ?Handle) callconv(.c) ?Handle;
pub extern "user32" fn SetCapture(hwnd: Handle) callconv(.c) ?Handle;
pub extern "user32" fn ReleaseCapture() callconv(.c) c_int;
pub extern "user32" fn GetDpiForWindow(hwnd: Handle) callconv(.c) u32;
pub extern "user32" fn SetProcessDpiAwarenessContext(value: isize) callconv(.c) c_int;
pub extern "user32" fn GetKeyState(vk: c_int) callconv(.c) i16;
pub extern "user32" fn GetKeyboardState(state: *[256]u8) callconv(.c) c_int;
pub extern "user32" fn GetKeyboardLayout(thread: u32) callconv(.c) ?Handle;
pub extern "user32" fn ToUnicodeEx(
    vk: u32,
    scan: u32,
    state: *const [256]u8,
    buf: [*]u16,
    buf_len: c_int,
    flags: u32,
    layout: ?Handle,
) callconv(.c) c_int;
pub extern "user32" fn OpenClipboard(owner: ?Handle) callconv(.c) c_int;
pub extern "user32" fn CloseClipboard() callconv(.c) c_int;
pub extern "user32" fn EmptyClipboard() callconv(.c) c_int;
pub extern "user32" fn GetClipboardData(format: u32) callconv(.c) ?Handle;
pub extern "user32" fn SetClipboardData(format: u32, mem: Handle) callconv(.c) ?Handle;

pub extern "gdi32" fn SetDIBitsToDevice(
    hdc: Handle,
    x_dest: c_int,
    y_dest: c_int,
    width: u32,
    height: u32,
    x_src: c_int,
    y_src: c_int,
    start_scan: u32,
    scan_lines: u32,
    bits: *const anyopaque,
    info: *const BitmapInfoHeader,
    usage: u32,
) callconv(.c) c_int;

/// The low and high words of a message parameter, as signed values since
/// mouse coordinates can be negative on multi-monitor setups.
pub fn loword(value: isize) i16 {
    return @truncate(value);
}

pub fn hiword(value: isize) i16 {
    return @truncate(value >> 16);
}

pub fn utf16Literal(comptime s: []const u8) *const [s.len:0]u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

pub const WM_GETMINMAXINFO = 0x0024;
pub const WM_CLOSE_CONFIRMED = WM_APP + 2;
pub const GWL_STYLE = -16;
pub const SW_MAXIMIZE = 3;
pub const SW_RESTORE = 9;
pub const WS_POPUP = 0x80000000;
pub const WS_CAPTION = 0x00C00000;
pub const WS_THICKFRAME = 0x00040000;
pub const WS_VISIBLE = 0x10000000;
pub const SWP_NOSIZE = 0x0001;
pub const SWP_NOMOVE = 0x0002;
pub const SWP_NOZORDER = 0x0004;
pub const SWP_NOACTIVATE = 0x0010;
pub const SWP_FRAMECHANGED = 0x0020;
pub const MONITOR_DEFAULTTONEAREST = 2;
pub const MB_YESNO = 0x4;
pub const MB_ICONWARNING = 0x30;
pub const MB_DEFBUTTON2 = 0x100;
pub const IDYES = 6;

pub const IDC_IBEAM: usize = 32513;
pub const IDC_WAIT: usize = 32514;
pub const IDC_CROSS: usize = 32515;
pub const IDC_SIZENWSE: usize = 32642;
pub const IDC_SIZENESW: usize = 32643;
pub const IDC_SIZEWE: usize = 32644;
pub const IDC_SIZENS: usize = 32645;
pub const IDC_SIZEALL: usize = 32646;
pub const IDC_NO: usize = 32648;
pub const IDC_HAND: usize = 32649;
pub const IDC_APPSTARTING: usize = 32650;
pub const IDC_HELP: usize = 32651;

pub const MinMaxInfo = extern struct {
    reserved: Point,
    max_size: Point,
    max_position: Point,
    min_track_size: Point,
    max_track_size: Point,
};

pub const WindowPlacement = extern struct {
    length: u32 = @sizeOf(WindowPlacement),
    flags: u32 = 0,
    show_cmd: u32 = 0,
    min_position: Point = .{ .x = 0, .y = 0 },
    max_position: Point = .{ .x = 0, .y = 0 },
    normal_position: Rect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
};

pub const MonitorInfo = extern struct {
    size: u32 = @sizeOf(MonitorInfo),
    monitor: Rect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    work: Rect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    flags: u32 = 0,
};

pub extern "shell32" fn ShellExecuteW(
    hwnd: ?Handle,
    verb: ?[*:0]const u16,
    file: [*:0]const u16,
    params: ?[*:0]const u16,
    dir: ?[*:0]const u16,
    show: c_int,
) callconv(.c) ?Handle;
pub extern "user32" fn MessageBeep(kind: u32) callconv(.c) c_int;
pub extern "user32" fn MessageBoxW(hwnd: ?Handle, text: [*:0]const u16, caption: [*:0]const u16, kind: u32) callconv(.c) c_int;
pub extern "user32" fn SetWindowPos(hwnd: Handle, after: ?Handle, x: c_int, y: c_int, w: c_int, h: c_int, flags: u32) callconv(.c) c_int;
pub extern "user32" fn GetWindowLongW(hwnd: Handle, index: c_int) callconv(.c) i32;
pub extern "user32" fn SetWindowLongW(hwnd: Handle, index: c_int, value: i32) callconv(.c) i32;
pub extern "user32" fn IsZoomed(hwnd: Handle) callconv(.c) c_int;
pub extern "user32" fn GetWindowPlacement(hwnd: Handle, wp: *WindowPlacement) callconv(.c) c_int;
pub extern "user32" fn SetWindowPlacement(hwnd: Handle, wp: *const WindowPlacement) callconv(.c) c_int;
pub extern "user32" fn MonitorFromWindow(hwnd: Handle, flags: u32) callconv(.c) ?Handle;
pub extern "user32" fn GetMonitorInfoW(monitor: Handle, info: *MonitorInfo) callconv(.c) c_int;
pub extern "user32" fn AdjustWindowRectExForDpi(rect: *Rect, style: u32, menu: c_int, ex_style: u32, dpi: u32) callconv(.c) c_int;

pub const WM_LBUTTONDBLCLK = 0x0203;
pub const WS_CHILD = 0x40000000;
pub const WS_CLIPSIBLINGS = 0x04000000;
pub const WS_CLIPCHILDREN = 0x02000000;
pub const SW_HIDE = 0;
pub const SRCCOPY = 0x00CC0020;
pub const TRANSPARENT = 1;
pub const DT_LEFT = 0x0000;
pub const DT_VCENTER = 0x0004;
pub const DT_SINGLELINE = 0x0020;
pub const DT_END_ELLIPSIS = 0x8000;
pub const DT_CENTER = 0x0001;
pub const FW_NORMAL = 400;
pub const DEFAULT_CHARSET = 1;
pub const CLEARTYPE_QUALITY = 5;
pub const HTCLIENT = 1;

pub extern "user32" fn ScreenToClient(hwnd: Handle, pt: *Point) callconv(.c) c_int;
pub extern "user32" fn GetCursorPos(pt: *Point) callconv(.c) c_int;
pub extern "user32" fn FillRect(hdc: Handle, rect: *const Rect, brush: Handle) callconv(.c) c_int;
pub extern "user32" fn DrawTextW(hdc: Handle, text: [*]const u16, len: c_int, rect: *Rect, format: u32) callconv(.c) c_int;
pub extern "user32" fn IsChild(parent: Handle, child: Handle) callconv(.c) c_int;

pub extern "gdi32" fn CreateSolidBrush(color: u32) callconv(.c) ?Handle;
pub extern "gdi32" fn DeleteObject(obj: Handle) callconv(.c) c_int;
pub extern "gdi32" fn CreateCompatibleDC(hdc: ?Handle) callconv(.c) ?Handle;
pub extern "gdi32" fn CreateCompatibleBitmap(hdc: Handle, w: c_int, h: c_int) callconv(.c) ?Handle;
pub extern "gdi32" fn SelectObject(hdc: Handle, obj: Handle) callconv(.c) ?Handle;
pub extern "gdi32" fn DeleteDC(hdc: Handle) callconv(.c) c_int;
pub extern "gdi32" fn BitBlt(dst: Handle, x: c_int, y: c_int, w: c_int, h: c_int, src: Handle, sx: c_int, sy: c_int, rop: u32) callconv(.c) c_int;
pub extern "gdi32" fn SetBkMode(hdc: Handle, mode: c_int) callconv(.c) c_int;
pub extern "gdi32" fn SetTextColor(hdc: Handle, color: u32) callconv(.c) u32;
pub extern "gdi32" fn CreateFontW(
    height: c_int,
    width: c_int,
    escapement: c_int,
    orientation: c_int,
    weight: c_int,
    italic: u32,
    underline: u32,
    strike: u32,
    charset: u32,
    out_precision: u32,
    clip_precision: u32,
    quality: u32,
    pitch_family: u32,
    face: [*:0]const u16,
) callconv(.c) ?Handle;

pub fn rgb(r: u8, g: u8, b: u8) u32 {
    return @as(u32, r) | (@as(u32, g) << 8) | (@as(u32, b) << 16);
}

pub const WM_CHAR = 0x0102;
pub const WM_DEADCHAR = 0x0103;
pub const WM_SYSCHAR = 0x0106;
pub const WM_SYSDEADCHAR = 0x0107;
pub const WM_IME_STARTCOMPOSITION = 0x010D;
pub const WM_IME_ENDCOMPOSITION = 0x010E;
pub const WM_IME_COMPOSITION = 0x010F;
pub const WM_IME_SETCONTEXT = 0x0281;
pub const GCS_COMPSTR = 0x0008;
pub const GCS_RESULTSTR = 0x0800;
pub const ISC_SHOWUICOMPOSITIONWINDOW: isize = 0x80000000;
pub const CFS_POINT = 0x0002;
pub const CFS_CANDIDATEPOS = 0x0040;
pub const VK_PROCESSKEY = 0xE5;

pub const CompositionForm = extern struct {
    style: u32,
    current_pos: Point,
    area: Rect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
};

pub const CandidateForm = extern struct {
    index: u32,
    style: u32,
    current_pos: Point,
    area: Rect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
};

pub extern "user32" fn TranslateMessage(msg: *const Msg) callconv(.c) c_int;
pub extern "user32" fn PeekMessageW(msg: *Msg, hwnd: ?Handle, min: u32, max: u32, remove: u32) callconv(.c) c_int;

pub extern "imm32" fn ImmGetContext(hwnd: Handle) callconv(.c) ?Handle;
pub extern "imm32" fn ImmReleaseContext(hwnd: Handle, himc: Handle) callconv(.c) c_int;
pub extern "imm32" fn ImmGetCompositionStringW(himc: Handle, index: u32, buf: ?*anyopaque, len: u32) callconv(.c) i32;
pub extern "imm32" fn ImmSetCompositionWindow(himc: Handle, form: *const CompositionForm) callconv(.c) c_int;
pub extern "imm32" fn ImmSetCandidateWindow(himc: Handle, form: *const CandidateForm) callconv(.c) c_int;

pub const WM_TIMER = 0x0113;
pub extern "kernel32" fn GetTickCount64() callconv(.c) u64;
pub extern "user32" fn SetTimer(hwnd: Handle, id: usize, ms: u32, proc: ?*anyopaque) callconv(.c) usize;
pub extern "user32" fn KillTimer(hwnd: Handle, id: usize) callconv(.c) c_int;

pub extern "dwmapi" fn DwmSetWindowAttribute(hwnd: Handle, attribute: u32, value: *const anyopaque, size: u32) callconv(.c) i32;
pub const DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
pub const DWMWA_BORDER_COLOR = 34;
pub const DWMWA_CAPTION_COLOR = 35;
pub const DWMWA_TEXT_COLOR = 36;

pub const WM_COMMAND = 0x0111;
pub const WM_SETFONT = 0x0030;
pub const EN_CHANGE = 0x0300;
pub const EM_SETSEL = 0x00B1;
pub const ES_AUTOHSCROLL = 0x0080;
pub const WS_BORDER = 0x00800000;
pub const GWLP_WNDPROC = -4;
pub const VK_RETURN = 0x0D;
pub const VK_ESCAPE = 0x1B;
pub const DEFAULT_GUI_FONT = 17;
pub const DT_RIGHT = 0x0002;

pub extern "user32" fn SendMessageW(hwnd: Handle, msg: u32, w: WPARAM, l: LPARAM) callconv(.c) LRESULT;
pub extern "user32" fn GetWindowTextW(hwnd: Handle, buf: [*]u16, max: c_int) callconv(.c) c_int;
pub extern "user32" fn GetWindowTextLengthW(hwnd: Handle) callconv(.c) c_int;
pub extern "user32" fn CallWindowProcW(prev: isize, hwnd: Handle, msg: u32, w: WPARAM, l: LPARAM) callconv(.c) LRESULT;
pub extern "user32" fn GetParent(hwnd: Handle) callconv(.c) ?Handle;
pub extern "gdi32" fn GetStockObject(index: c_int) callconv(.c) ?Handle;

pub const WM_CTLCOLOREDIT = 0x0133;
pub const WM_CTLCOLORLISTBOX = 0x0134;
pub const LB_ADDSTRING = 0x0180;
pub const LB_SETCURSEL = 0x0186;
pub const LB_GETCURSEL = 0x0188;
pub const LB_GETCOUNT = 0x018B;
pub const LB_RESETCONTENT = 0x0184;
pub const LBN_DBLCLK = 2;
pub const LBS_NOTIFY = 0x0001;
pub const LBS_NOINTEGRALHEIGHT = 0x0100;
pub const WS_VSCROLL = 0x00200000;
pub const VK_UP = 0x26;
pub const VK_DOWN = 0x28;
pub const VK_PRIOR = 0x21;
pub const VK_NEXT = 0x22;
pub const EN_KILLFOCUS_UNUSED = 0;

pub extern "user32" fn BringWindowToTop(hwnd: Handle) callconv(.c) c_int;
pub extern "gdi32" fn SetBkColor(hdc: Handle, color: u32) callconv(.c) u32;

pub const HALFTONE = 4;
pub extern "gdi32" fn SetStretchBltMode(hdc: Handle, mode: c_int) callconv(.c) c_int;
pub extern "gdi32" fn StretchDIBits(
    hdc: Handle,
    x_dest: c_int,
    y_dest: c_int,
    w_dest: c_int,
    h_dest: c_int,
    x_src: c_int,
    y_src: c_int,
    w_src: c_int,
    h_src: c_int,
    bits: *const anyopaque,
    info: *const BitmapInfoHeader,
    usage: u32,
    rop: u32,
) callconv(.c) c_int;

pub const VK_LEFT = 0x25;
pub const VK_RIGHT = 0x27;

pub const WS_EX_TOPMOST = 0x00000008;
pub const WS_EX_TOOLWINDOW = 0x00000080;
pub const WM_ACTIVATE = 0x0006;
pub const WM_HOTKEY = 0x0312;
pub const MOD_ALT = 0x0001;
pub const MOD_CONTROL = 0x0002;
pub const MOD_SHIFT = 0x0004;
pub const MOD_WIN = 0x0008;
pub const MOD_NOREPEAT = 0x4000;
pub const HWND_TOPMOST: usize = std.math.maxInt(usize);

pub extern "user32" fn MonitorFromPoint(pt: Point, flags: u32) callconv(.c) ?Handle;
pub extern "user32" fn RegisterHotKey(hwnd: ?Handle, id: c_int, modifiers: u32, vk: u32) callconv(.c) c_int;
pub extern "user32" fn UnregisterHotKey(hwnd: ?Handle, id: c_int) callconv(.c) c_int;
pub extern "user32" fn SetForegroundWindow(hwnd: Handle) callconv(.c) c_int;
pub extern "user32" fn IsWindowVisible(hwnd: Handle) callconv(.c) c_int;

pub const WS_EX_LAYERED = 0x00080000;
pub const GWL_EXSTYLE = -20;
pub const LWA_ALPHA = 0x00000002;
pub extern "user32" fn SetLayeredWindowAttributes(hwnd: Handle, key: u32, alpha: u8, flags: u32) callconv(.c) c_int;

/// Undocumented but long-stable user32 call that Windows' own apps use to
/// turn on blur and acrylic behind a window.
pub const AccentPolicy = extern struct {
    state: u32,
    flags: u32,
    gradient_color: u32,
    animation_id: u32,
};
pub const WindowCompositionAttributeData = extern struct {
    attribute: u32,
    data: *anyopaque,
    size: usize,
};
pub const WCA_ACCENT_POLICY = 19;
pub const ACCENT_DISABLED = 0;
pub const ACCENT_ENABLE_BLURBEHIND = 3;
pub const ACCENT_ENABLE_ACRYLICBLURBEHIND = 4;
pub extern "user32" fn SetWindowCompositionAttribute(hwnd: Handle, data: *WindowCompositionAttributeData) callconv(.c) c_int;
