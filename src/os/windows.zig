const std = @import("std");
const windows = std.os.windows;

// Export any constants or functions we need from the Windows API so
// we can just import one file.
pub const kernel32 = windows.kernel32;
pub const unexpectedError = windows.unexpectedError;
pub const OpenFile = windows.OpenFile;
pub const CloseHandle = windows.CloseHandle;
pub const GetCurrentProcessId = windows.GetCurrentProcessId;
pub const SetHandleInformation = windows.SetHandleInformation;
pub const DWORD = windows.DWORD;
pub const FILE_ATTRIBUTE_NORMAL = windows.FILE_ATTRIBUTE_NORMAL;
pub const FILE_FLAG_OVERLAPPED = windows.FILE_FLAG_OVERLAPPED;
pub const FILE_SHARE_READ = windows.FILE_SHARE_READ;
pub const GENERIC_READ = windows.GENERIC_READ;
pub const HANDLE = windows.HANDLE;
pub const HANDLE_FLAG_INHERIT = windows.HANDLE_FLAG_INHERIT;
pub const INFINITE = windows.INFINITE;
pub const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;
pub const OPEN_EXISTING = windows.OPEN_EXISTING;
pub const PIPE_ACCESS_OUTBOUND = windows.PIPE_ACCESS_OUTBOUND;
pub const PIPE_TYPE_BYTE = windows.PIPE_TYPE_BYTE;
pub const PROCESS_INFORMATION = windows.PROCESS_INFORMATION;
pub const S_OK = windows.S_OK;
pub const SECURITY_ATTRIBUTES = windows.SECURITY_ATTRIBUTES;
pub const STARTUPINFOW = windows.STARTUPINFOW;
pub const STARTF_USESTDHANDLES = windows.STARTF_USESTDHANDLES;
pub const SYNCHRONIZE = windows.SYNCHRONIZE;
pub const WAIT_FAILED = windows.WAIT_FAILED;
pub const FALSE = windows.FALSE;
pub const TRUE = windows.TRUE;

// User32 types and constants
pub const WNDCLASSEXW = extern struct {
    cbSize: windows.UINT,
    style: windows.UINT,
    lpfnWndProc: windows.WNDPROC,
    cbClsExtra: windows.INT = 0,
    cbWndExtra: windows.INT = 0,
    hInstance: windows.HINSTANCE,
    hIcon: ?windows.HICON,
    hCursor: ?windows.HCURSOR,
    hbrBackground: ?windows.HBRUSH,
    lpszMenuName: ?windows.LPCWSTR,
    lpszClassName: windows.LPCWSTR,
    hIconSm: ?windows.HICON,
};

pub const MSG = extern struct {
    hwnd: ?windows.HWND,
    message: windows.UINT,
    wParam: windows.WPARAM,
    lParam: windows.LPARAM,
    time: windows.DWORD,
    pt: windows.POINT,
    lPrivate: windows.DWORD,
};

pub const PAINTSTRUCT = extern struct {
    hdc: windows.HDC,
    fErase: windows.BOOL,
    rcPaint: windows.RECT,
    fRestore: windows.BOOL,
    fIncUpdate: windows.BOOL,
    rgbReserved: [32]windows.BYTE,
};

pub const CREATESTRUCTW = extern struct {
    lpCreateParams: windows.LPVOID,
    hInstance: windows.HINSTANCE,
    hMenu: ?windows.HMENU,
    hwndParent: ?windows.HWND,
    cy: windows.INT,
    cx: windows.INT,
    y: windows.INT,
    x: windows.INT,
    style: windows.LONG,
    lpszName: windows.LPCWSTR,
    lpszClass: windows.LPCWSTR,
    dwExStyle: windows.DWORD,
};

pub const CS_HREDRAW = 0x0002;
pub const CS_VREDRAW = 0x0001;
pub const IDC_ARROW: windows.LPCWSTR = @ptrFromInt(32512);
pub const WS_OVERLAPPEDWINDOW = 0x00CF0000;
pub const WS_VISIBLE = 0x10000000;
pub const CW_USEDEFAULT: windows.INT = @as(windows.INT, @bitCast(@as(windows.UINT, 0x80000000)));
pub const WM_NULL = 0x0000;
pub const WM_DESTROY = 0x0002;
pub const WM_PAINT = 0x000F;
pub const WM_NCCREATE = 0x0081;
pub const GWLP_USERDATA = -21;
pub const COLOR_WINDOW = 5;

// user32 functions
pub const user32 = struct {
    pub extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: ?windows.HWND, wMsgFilterMin: windows.UINT, wMsgFilterMax: windows.UINT) callconv(windows.WINAPI) windows.BOOL;
    pub extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(windows.WINAPI) windows.BOOL;
    pub extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(windows.WINAPI) windows.LRESULT;
    pub extern "user32" fn PostThreadMessageW(idThread: windows.DWORD, Msg: windows.UINT, wParam: windows.WPARAM, lParam: windows.LPARAM) callconv(windows.WINAPI) windows.BOOL;
    pub extern "user32" fn RegisterClassExW(lpwcx: *const WNDCLASSEXW) callconv(windows.WINAPI) windows.ATOM;
    pub extern "user32" fn CreateWindowExW(
        dwExStyle: windows.DWORD,
        lpClassName: windows.LPCWSTR,
        lpWindowName: windows.LPCWSTR,
        dwStyle: windows.DWORD,
        x: windows.INT,
        y: windows.INT,
        nWidth: windows.INT,
        nHeight: windows.INT,
        hWndParent: ?windows.HWND,
        hMenu: ?windows.HMENU,
        hInstance: windows.HINSTANCE,
        lpParam: ?windows.LPVOID,
    ) callconv(windows.WINAPI) ?windows.HWND;
    pub extern "user32" fn DestroyWindow(hWnd: windows.HWND) callconv(windows.WINAPI) windows.BOOL;
    pub extern "user32" fn DefWindowProcW(hWnd: windows.HWND, Msg: windows.UINT, wParam: windows.WPARAM, lParam: windows.LPARAM) callconv(windows.WINAPI) windows.LRESULT;
    pub extern "user32" fn PostQuitMessage(nExitCode: windows.INT) callconv(windows.WINAPI) void;
    pub extern "user32" fn BeginPaint(hWnd: windows.HWND, lpPaint: *PAINTSTRUCT) callconv(windows.WINAPI) windows.HDC;
    pub extern "user32" fn EndPaint(hWnd: windows.HWND, lpPaint: *const PAINTSTRUCT) callconv(windows.WINAPI) windows.BOOL;
    pub extern "user32" fn FillRect(hDC: windows.HDC, lprc: *const windows.RECT, hbr: windows.HBRUSH) callconv(windows.WINAPI) windows.INT;
    pub extern "user32" fn LoadCursorW(hInstance: ?windows.HINSTANCE, lpCursorName: windows.LPCWSTR) callconv(windows.WINAPI) ?windows.HCURSOR;
    pub extern "user32" fn SetWindowLongPtrW(hWnd: windows.HWND, nIndex: windows.INT, dwNewLong: windows.LONG_PTR) callconv(windows.WINAPI) windows.LONG_PTR;
    pub extern "user32" fn GetWindowLongPtrW(hWnd: windows.HWND, nIndex: windows.INT) callconv(windows.WINAPI) windows.LONG_PTR;
    pub extern "user32" fn InvalidateRect(hWnd: windows.HWND, lpRect: ?*const windows.RECT, bErase: windows.BOOL) callconv(windows.WINAPI) windows.BOOL;
    pub extern "user32" fn GetCursorPos(lpPoint: *windows.POINT) callconv(windows.WINAPI) windows.BOOL;
    pub extern "user32" fn ScreenToClient(hWnd: windows.HWND, lpPoint: *windows.POINT) callconv(windows.WINAPI) windows.BOOL;
};

pub const exp = struct {
    pub const HPCON = windows.LPVOID;

    pub const CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    pub const EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    pub const LPPROC_THREAD_ATTRIBUTE_LIST = ?*anyopaque;
    pub const FILE_FLAG_FIRST_PIPE_INSTANCE = 0x00080000;

    pub const STATUS_PENDING = 0x00000103;
    pub const STILL_ACTIVE = STATUS_PENDING;

    pub const STARTUPINFOEX = extern struct {
        StartupInfo: windows.STARTUPINFOW,
        lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
    };

    pub const kernel32 = struct {
        pub extern "kernel32" fn CreatePipe(
            hReadPipe: *windows.HANDLE,
            hWritePipe: *windows.HANDLE,
            lpPipeAttributes: ?*const windows.SECURITY_ATTRIBUTES,
            nSize: windows.DWORD,
        ) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn CreatePseudoConsole(
            size: windows.COORD,
            hInput: windows.HANDLE,
            hOutput: windows.HANDLE,
            dwFlags: windows.DWORD,
            phPC: *HPCON,
        ) callconv(.winapi) windows.HRESULT;
        pub extern "kernel32" fn ResizePseudoConsole(hPC: HPCON, size: windows.COORD) callconv(.winapi) windows.HRESULT;
        pub extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.winapi) void;
        pub extern "kernel32" fn InitializeProcThreadAttributeList(
            lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
            dwAttributeCount: windows.DWORD,
            dwFlags: windows.DWORD,
            lpSize: *windows.SIZE_T,
        ) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn UpdateProcThreadAttribute(
            lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
            dwFlags: windows.DWORD,
            Attribute: windows.DWORD_PTR,
            lpValue: windows.PVOID,
            cbSize: windows.SIZE_T,
            lpPreviousValue: ?windows.PVOID,
            lpReturnSize: ?*windows.SIZE_T,
        ) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn PeekNamedPipe(
            hNamedPipe: windows.HANDLE,
            lpBuffer: ?windows.LPVOID,
            nBufferSize: windows.DWORD,
            lpBytesRead: ?*windows.DWORD,
            lpTotalBytesAvail: ?*windows.DWORD,
            lpBytesLeftThisMessage: ?*windows.DWORD,
        ) callconv(.winapi) windows.BOOL;
        // Duplicated here because lpCommandLine is not marked optional in zig std
        pub extern "kernel32" fn CreateProcessW(
            lpApplicationName: ?windows.LPWSTR,
            lpCommandLine: ?windows.LPWSTR,
            lpProcessAttributes: ?*windows.SECURITY_ATTRIBUTES,
            lpThreadAttributes: ?*windows.SECURITY_ATTRIBUTES,
            bInheritHandles: windows.BOOL,
            dwCreationFlags: windows.DWORD,
            lpEnvironment: ?*anyopaque,
            lpCurrentDirectory: ?windows.LPWSTR,
            lpStartupInfo: *windows.STARTUPINFOW,
            lpProcessInformation: *windows.PROCESS_INFORMATION,
        ) callconv(.winapi) windows.BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getcomputernamea
        pub extern "kernel32" fn GetComputerNameA(
            lpBuffer: windows.LPSTR,
            nSize: *windows.DWORD,
        ) callconv(.winapi) windows.BOOL;
    };

    pub const PROC_THREAD_ATTRIBUTE_NUMBER = 0x0000FFFF;
    pub const PROC_THREAD_ATTRIBUTE_THREAD = 0x00010000;
    pub const PROC_THREAD_ATTRIBUTE_INPUT = 0x00020000;
    pub const PROC_THREAD_ATTRIBUTE_ADDITIVE = 0x00040000;

    pub const ProcThreadAttributeNumber = enum(windows.DWORD) {
        ProcThreadAttributePseudoConsole = 22,
        _,
    };

    /// Corresponds to the ProcThreadAttributeValue define in WinBase.h
    pub fn ProcThreadAttributeValue(
        comptime attribute: ProcThreadAttributeNumber,
        comptime thread: bool,
        comptime input: bool,
        comptime additive: bool,
    ) windows.DWORD {
        return (@intFromEnum(attribute) & PROC_THREAD_ATTRIBUTE_NUMBER) |
            (if (thread) PROC_THREAD_ATTRIBUTE_THREAD else 0) |
            (if (input) PROC_THREAD_ATTRIBUTE_INPUT else 0) |
            (if (additive) PROC_THREAD_ATTRIBUTE_ADDITIVE else 0);
    }

    pub const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = ProcThreadAttributeValue(.ProcThreadAttributePseudoConsole, false, true, false);
};
