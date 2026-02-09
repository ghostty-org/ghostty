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
        ) callconv(std.builtin.CallingConvention.winapi) windows.BOOL;
        pub extern "kernel32" fn InitializeProcThreadAttributeList(
            lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
            dwAttributeCount: windows.DWORD,
            dwFlags: windows.DWORD,
            lpSize: *windows.SIZE_T,
        ) callconv(std.builtin.CallingConvention.winapi) windows.BOOL;
        pub extern "kernel32" fn UpdateProcThreadAttribute(
            lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
            dwFlags: windows.DWORD,
            Attribute: windows.DWORD_PTR,
            lpValue: windows.PVOID,
            cbSize: windows.SIZE_T,
            lpPreviousValue: ?windows.PVOID,
            lpReturnSize: ?*windows.SIZE_T,
        ) callconv(std.builtin.CallingConvention.winapi) windows.BOOL;
        pub extern "kernel32" fn PeekNamedPipe(
            hNamedPipe: windows.HANDLE,
            lpBuffer: ?windows.LPVOID,
            nBufferSize: windows.DWORD,
            lpBytesRead: ?*windows.DWORD,
            lpTotalBytesAvail: ?*windows.DWORD,
            lpBytesLeftThisMessage: ?*windows.DWORD,
        ) callconv(std.builtin.CallingConvention.winapi) windows.BOOL;
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
        ) callconv(std.builtin.CallingConvention.winapi) windows.BOOL;
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

/// Dynamically-loaded ConPTY functions. Tries to load from a local conpty.dll
/// (e.g. a patched OpenConsole shipped alongside Ghostty) first, falling back
/// to kernel32.dll (system conhost). A local conpty.dll + OpenConsole.exe can
/// provide features the system conhost lacks, such as APC passthrough for
/// Kitty graphics.
pub const conpty = struct {
    const log = std.log.scoped(.conpty);
    const WINAPI = std.builtin.CallingConvention.winapi;
    const HPCON = exp.HPCON;

    const CreatePseudoConsoleFn = *const fn (windows.COORD, windows.HANDLE, windows.HANDLE, windows.DWORD, *HPCON) callconv(WINAPI) windows.HRESULT;
    const ResizePseudoConsoleFn = *const fn (HPCON, windows.COORD) callconv(WINAPI) windows.HRESULT;
    const ClosePseudoConsoleFn = *const fn (HPCON) callconv(WINAPI) void;

    var create_fn: ?CreatePseudoConsoleFn = null;
    var resize_fn: ?ResizePseudoConsoleFn = null;
    var close_fn: ?ClosePseudoConsoleFn = null;
    var dll_handle: ?windows.HANDLE = null;
    var initialized: bool = false;

    /// Kernel32 fallbacks (static extern linkage).
    const k32 = struct {
        extern "kernel32" fn CreatePseudoConsole(windows.COORD, windows.HANDLE, windows.HANDLE, windows.DWORD, *HPCON) callconv(WINAPI) windows.HRESULT;
        extern "kernel32" fn ResizePseudoConsole(HPCON, windows.COORD) callconv(WINAPI) windows.HRESULT;
        extern "kernel32" fn ClosePseudoConsole(HPCON) callconv(WINAPI) void;
    };

    fn init() void {
        if (initialized) return;
        initialized = true;

        // Try loading conpty.dll from the executable's directory.
        const handle = windows.kernel32.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("conpty.dll"));
        if (handle) |h| {
            const c = getProcAddress(CreatePseudoConsoleFn, h, "CreatePseudoConsole");
            const r = getProcAddress(ResizePseudoConsoleFn, h, "CreatePseudoConsole"); // Will re-resolve below
            const cl = getProcAddress(ClosePseudoConsoleFn, h, "ClosePseudoConsole");
            // Need all three for a usable conpty.dll
            if (c != null and cl != null) {
                create_fn = c;
                resize_fn = getProcAddress(ResizePseudoConsoleFn, h, "ResizePseudoConsole");
                close_fn = cl;
                dll_handle = h;
                log.warn("Loaded conpty.dll — using bundled OpenConsole for ConPTY", .{});
                _ = r;
                return;
            }
            // DLL loaded but missing expected exports
            _ = windows.kernel32.FreeLibrary(h);
        }
        log.info("conpty.dll not found, using system ConPTY", .{});
    }

    fn getProcAddress(comptime T: type, module: windows.HANDLE, name: [*:0]const u8) ?T {
        return @ptrCast(windows.kernel32.GetProcAddress(@ptrCast(module), name));
    }

    pub fn CreatePseudoConsole(
        size: windows.COORD,
        hInput: windows.HANDLE,
        hOutput: windows.HANDLE,
        dwFlags: windows.DWORD,
        phPC: *HPCON,
    ) windows.HRESULT {
        init();
        if (create_fn) |f| return f(size, hInput, hOutput, dwFlags, phPC);
        return k32.CreatePseudoConsole(size, hInput, hOutput, dwFlags, phPC);
    }

    pub fn ResizePseudoConsole(hPC: HPCON, size: windows.COORD) windows.HRESULT {
        init();
        if (resize_fn) |f| return f(hPC, size);
        return k32.ResizePseudoConsole(hPC, size);
    }

    pub fn ClosePseudoConsole(hPC: HPCON) void {
        init();
        if (close_fn) |f| return f(hPC);
        return k32.ClosePseudoConsole(hPC);
    }
};
