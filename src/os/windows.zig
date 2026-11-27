const std = @import("std");
const windows = std.os.windows;

// NOTE: The Windows part of the Zig stdlib is currently in the process of
// having most of its features removed, with the ultimate goal of switching to
// serve as a support for higher-level functionality offered in places like
// `std.Io` only. As such this file serves as a "bridge" between type
// information (mostly coming from stdlib) and manually-defined constants and
// external functions.

// Utility functions
pub const GetCurrentProcessId = windows.GetCurrentProcessId;
pub const GetLastError = windows.GetLastError;
pub const unexpectedError = windows.unexpectedError;
pub const unexpectedStatus = windows.unexpectedStatus;

// Primitive types
pub const BOOL = windows.BOOL;
pub const COORD = windows.COORD;
pub const DWORD = windows.DWORD;
pub const DWORD_PTR = windows.DWORD_PTR;
pub const HANDLE = windows.HANDLE;
pub const HINSTANCE = windows.HINSTANCE;
pub const HPCON = windows.LPVOID;
pub const HRESULT = c_long;
pub const LARGE_INTEGER = windows.LARGE_INTEGER;
pub const LPCWSTR = windows.LPCWSTR;
pub const LPSTR = windows.LPSTR;
pub const LPVOID = windows.LPVOID;
pub const LPCVOID = *const anyopaque;
pub const LPWSTR = windows.LPWSTR;
pub const PVOID = windows.PVOID;
pub const SIZE_T = windows.SIZE_T;
pub const UINT = windows.UINT;
pub const ULONG = windows.ULONG;
pub const ULONG_PTR = windows.ULONG_PTR;
pub const UNICODE_STRING = windows.UNICODE_STRING;

// Structs and opaque types
pub const LPPROC_THREAD_ATTRIBUTE_LIST = ?*anyopaque;
pub const SECURITY_ATTRIBUTES = windows.SECURITY_ATTRIBUTES;
pub const STARTF_USESTDHANDLES = windows.STARTF_USESTDHANDLES;
pub const STARTUPINFOW = windows.STARTUPINFOW;

pub const OVERLAPPED = extern struct {
    Internal: ULONG_PTR,
    InternalHigh: ULONG_PTR,
    DUMMYUNIONNAME: extern union {
        DUMMYSTRUCTNAME: extern struct {
            Offset: DWORD,
            OffsetHigh: DWORD,
        },
        Pointer: ?PVOID,
    },
    hEvent: ?HANDLE,
};
pub const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};
pub const STARTUPINFOEX = extern struct {
    StartupInfo: windows.STARTUPINFOW,
    lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
};

// Well-known constant values
pub const INFINITE = 4294967295;
pub const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;
pub const MAX_PATH = windows.MAX_PATH;
pub const FALSE: windows.BOOL = .fromBool(false);
pub const TRUE: windows.BOOL = .fromBool(true);

// Bit-field and enum constant values
pub const CREATE_UNICODE_ENVIRONMENT = 0x00000400;
pub const DELETE = 0x00010000;
pub const ERROR_SUCCESS = 0;
pub const EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
pub const FILE_ATTRIBUTE_NORMAL = 0x80;
pub const FILE_FLAG_FIRST_PIPE_INSTANCE = 0x00080000;
pub const FILE_FLAG_OVERLAPPED = 0x40000000;
/// GetFinalPathNameByHandleW dwFlags: normalized name with a DOS drive
/// letter (both are the zero flag values).
pub const FILE_NAME_NORMALIZED = 0x0;
pub const FILE_NON_DIRECTORY_FILE = 0x00000040;
/// NtCreateFile CreateDisposition: open an existing file, never create.
/// Distinct from the Win32 CreateFileW value OPEN_EXISTING.
pub const FILE_OPEN = 0x00000001;
pub const FILE_OPEN_REPARSE_POINT = 0x00200000;
pub const FILE_SHARE_DELETE = 0x00000004;
pub const FILE_SHARE_READ = 0x00000001;
pub const FILE_SHARE_WRITE = 0x00000002;
pub const FILE_SYNCHRONOUS_IO_NONALERT = 0x00000020;
pub const GENERIC_READ = 0x80000000;
pub const HANDLE_FLAG_INHERIT = 0x00000001;
pub const MEM_COMMIT = 0x1000;
pub const MEM_RELEASE = 0x8000;
pub const MEM_RESERVE = 0x2000;
pub const OPEN_EXISTING = 3; // Known as FILE_OPEN in Windows docs
pub const PAGE_READWRITE = 0x04;
pub const PIPE_ACCESS_OUTBOUND = 0x00000002;
pub const PIPE_TYPE_BYTE = 0x00000000;
pub const PROC_THREAD_ATTRIBUTE_ADDITIVE = 0x00040000;
pub const PROC_THREAD_ATTRIBUTE_INPUT = 0x00020000;
pub const PROC_THREAD_ATTRIBUTE_NUMBER = 0x0000FFFF;
pub const PROC_THREAD_ATTRIBUTE_THREAD = 0x00010000;
pub const S_OK = 0;
pub const SYNCHRONIZE = 0x00100000;
pub const VOLUME_NAME_DOS = 0x0;
pub const WAIT_FAILED = 0xFFFFFFFF;

/// IOCTL that fills the output buffer with bytes from the kernel CSPRNG
/// behind `\Device\CNG` (what ProcessPrng and BCryptGenRandom draw from).
pub const IOCTL_KSEC_GEN_RANDOM: CTL_CODE = windows.IOCTL.KSEC.GEN_RANDOM;

pub const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = ProcThreadAttributeValue(
    .ProcThreadAttributePseudoConsole,
    false,
    true,
    false,
);

// Types needed for ntdll calls
pub const ACCESS_MASK = windows.ACCESS_MASK;
pub const CTL_CODE = windows.CTL_CODE;
pub const FILE_ALL_INFORMATION = windows.FILE.ALL_INFORMATION;
pub const FILE_ATTRIBUTE_TAG_INFORMATION = windows.FILE.ATTRIBUTE_TAG_INFO;
pub const FILE_DISPOSITION_INFORMATION = windows.FILE.DISPOSITION.INFORMATION;
pub const FILE_DISPOSITION_INFORMATION_EX = windows.FILE.DISPOSITION.INFORMATION.EX;
pub const FILE_INFORMATION_CLASS = windows.FILE.INFORMATION_CLASS;
pub const FILE_POSITION_INFORMATION = windows.FILE.POSITION_INFORMATION;
pub const FILE_STANDARD_INFORMATION = windows.FILE.STANDARD_INFORMATION;
pub const IO_STATUS_BLOCK = windows.IO_STATUS_BLOCK;
pub const NTSTATUS = windows.NTSTATUS;
pub const OBJECT_ATTRIBUTES = windows.OBJECT.ATTRIBUTES;

// Exported functions by library
pub const exp = struct {
    pub const kernel32 = struct {
        pub extern "kernel32" fn CreatePipe(
            hReadPipe: *HANDLE,
            hWritePipe: *HANDLE,
            lpPipeAttributes: ?*const SECURITY_ATTRIBUTES,
            nSize: DWORD,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn CreatePseudoConsole(
            size: COORD,
            hInput: HANDLE,
            hOutput: HANDLE,
            dwFlags: DWORD,
            phPC: *HPCON,
        ) callconv(.winapi) HRESULT;
        pub extern "kernel32" fn ResizePseudoConsole(
            hPC: HPCON,
            size: COORD,
        ) callconv(.winapi) HRESULT;
        pub extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.winapi) void;
        pub extern "kernel32" fn InitializeProcThreadAttributeList(
            lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
            dwAttributeCount: DWORD,
            dwFlags: DWORD,
            lpSize: *SIZE_T,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn UpdateProcThreadAttribute(
            lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
            dwFlags: DWORD,
            Attribute: DWORD_PTR,
            lpValue: PVOID,
            cbSize: SIZE_T,
            lpPreviousValue: ?PVOID,
            lpReturnSize: ?*SIZE_T,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn PeekNamedPipe(
            hNamedPipe: HANDLE,
            lpBuffer: ?LPVOID,
            nBufferSize: DWORD,
            lpBytesRead: ?*DWORD,
            lpTotalBytesAvail: ?*DWORD,
            lpBytesLeftThisMessage: ?*DWORD,
        ) callconv(.winapi) BOOL;
        // Duplicated here because lpCommandLine is not marked optional in zig std
        pub extern "kernel32" fn CreateProcessW(
            lpApplicationName: ?LPWSTR,
            lpCommandLine: ?LPWSTR,
            lpProcessAttributes: ?*SECURITY_ATTRIBUTES,
            lpThreadAttributes: ?*SECURITY_ATTRIBUTES,
            bInheritHandles: BOOL,
            dwCreationFlags: DWORD,
            lpEnvironment: ?*anyopaque,
            lpCurrentDirectory: ?LPWSTR,
            lpStartupInfo: *STARTUPINFOW,
            lpProcessInformation: *PROCESS_INFORMATION,
        ) callconv(.winapi) BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getcomputernamea
        pub extern "kernel32" fn GetComputerNameA(
            lpBuffer: LPSTR,
            nSize: *DWORD,
        ) callconv(.winapi) BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-gettemppathw
        pub extern "kernel32" fn GetTempPathW(
            nBufferLength: DWORD,
            lpBuffer: LPWSTR,
        ) callconv(.winapi) DWORD;
        pub extern "kernel32" fn SetHandleInformation(
            hObject: HANDLE,
            dwMask: DWORD,
            dwFlags: DWORD,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn CreateFileW(
            lpFileName: LPCWSTR,
            dwDesiredAccess: DWORD,
            dwShareMode: DWORD,
            lpSecurityAttributes: ?*SECURITY_ATTRIBUTES,
            dwCreationDisposition: DWORD,
            dwFlagsAndAttributes: DWORD,
            hTemplateFile: ?HANDLE,
        ) callconv(.winapi) HANDLE;
        pub extern "kernel32" fn CreateNamedPipeW(
            lpName: LPCWSTR,
            dwOpenMode: DWORD,
            dwPipeMode: DWORD,
            nMaxInstances: DWORD,
            nOutBufferSize: DWORD,
            nInBufferSize: DWORD,
            nDefaultTimeOut: DWORD,
            lpSecurityAttributes: ?*const SECURITY_ATTRIBUTES,
        ) callconv(.winapi) HANDLE;
        pub extern "kernel32" fn CloseHandle(
            hObject: HANDLE,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn VirtualAlloc(
            lpAddress: ?LPVOID,
            dwSize: SIZE_T,
            flAllocationType: DWORD,
            flProtect: DWORD,
        ) callconv(.winapi) ?LPVOID;
        pub extern "kernel32" fn VirtualFree(
            lpAddress: ?LPVOID,
            dwSize: SIZE_T,
            dwFreeType: DWORD,
        ) callconv(.winapi) BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/memoryapi/nf-memoryapi-discardvirtualmemory
        pub extern "kernel32" fn DiscardVirtualMemory(
            VirtualAddress: PVOID,
            Size: SIZE_T,
        ) callconv(.winapi) DWORD;
        pub extern "kernel32" fn WaitForSingleObject(
            hHandle: HANDLE,
            dwMilliseconds: DWORD,
        ) callconv(.winapi) DWORD;
        pub extern "kernel32" fn GetExitCodeProcess(
            hProcess: HANDLE,
            lpExitCode: *DWORD,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn TerminateProcess(
            hProcess: HANDLE,
            uExitCode: UINT,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn CancelIoEx(
            hFile: HANDLE,
            lpOverlapped: ?*OVERLAPPED,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn ReadFile(
            hFile: HANDLE,
            lpBuffer: LPVOID,
            nNumberOfBytesToRead: DWORD,
            lpNumberOfBytesRead: ?*DWORD,
            lpOverlapped: ?*OVERLAPPED,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn WriteFile(
            hFile: HANDLE,
            lpBuffer: LPCVOID,
            nNumberOfBytesToWrite: DWORD,
            lpNumberOfBytesWritten: ?*DWORD,
            lpOverlapped: ?*OVERLAPPED,
        ) callconv(.winapi) BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfinalpathnamebyhandlew
        pub extern "kernel32" fn GetFinalPathNameByHandleW(
            hFile: HANDLE,
            lpszFilePath: [*]u16,
            cchFilePath: DWORD,
            dwFlags: DWORD,
        ) callconv(.winapi) DWORD;
    };
    pub const ntdll = struct {
        pub extern "ntdll" fn NtCreateFile(
            FileHandle: *HANDLE,
            DesiredAccess: ACCESS_MASK,
            ObjectAttributes: *OBJECT_ATTRIBUTES,
            IoStatusBlock: *IO_STATUS_BLOCK,
            AllocationSize: ?*LARGE_INTEGER,
            FileAttributes: ULONG,
            ShareAccess: ULONG,
            CreateDisposition: ULONG,
            CreateOptions: ULONG,
            EaBuffer: ?*anyopaque,
            EaLength: ULONG,
        ) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn NtOpenFile(
            FileHandle: *HANDLE,
            DesiredAccess: ACCESS_MASK,
            ObjectAttributes: *OBJECT_ATTRIBUTES,
            IoStatusBlock: *IO_STATUS_BLOCK,
            ShareAccess: ULONG,
            OpenOptions: ULONG,
        ) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn NtClose(Handle: HANDLE) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn NtReadFile(
            FileHandle: HANDLE,
            Event: ?HANDLE,
            ApcRoutine: ?*const anyopaque,
            ApcContext: ?*anyopaque,
            IoStatusBlock: *IO_STATUS_BLOCK,
            Buffer: *anyopaque,
            Length: ULONG,
            ByteOffset: ?*const LARGE_INTEGER,
            Key: ?*const ULONG,
        ) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn NtQueryInformationFile(
            FileHandle: HANDLE,
            IoStatusBlock: *IO_STATUS_BLOCK,
            FileInformation: *anyopaque,
            Length: ULONG,
            FileInformationClass: FILE_INFORMATION_CLASS,
        ) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn NtSetInformationFile(
            FileHandle: HANDLE,
            IoStatusBlock: *IO_STATUS_BLOCK,
            FileInformation: *anyopaque,
            Length: ULONG,
            FileInformationClass: FILE_INFORMATION_CLASS,
        ) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn NtDeviceIoControlFile(
            FileHandle: HANDLE,
            Event: ?HANDLE,
            ApcRoutine: ?*const anyopaque,
            ApcContext: ?*anyopaque,
            IoStatusBlock: *IO_STATUS_BLOCK,
            IoControlCode: CTL_CODE,
            InputBuffer: ?*const anyopaque,
            InputBufferLength: ULONG,
            OutputBuffer: ?*anyopaque,
            OutputBufferLength: ULONG,
        ) callconv(.winapi) NTSTATUS;
        /// Resolves a Win32 path against the process working directory and
        /// canonicalizes it, keeping any `\\?\` or `\\.\` prefix. Returns
        /// the byte length written excluding the terminator, the required
        /// byte length if the buffer is too small, or 0 on failure.
        pub extern "ntdll" fn RtlGetFullPathName_U(
            FileName: [*:0]const u16,
            BufferByteLength: ULONG,
            Buffer: [*]u16,
            ShortName: ?*[*:0]const u16,
        ) callconv(.winapi) ULONG;
        /// The futex primitives that kernel32's WaitOnAddress and
        /// WakeByAddress* forward to. Timeout is a relative (negative)
        /// interval in 100ns units, null to wait forever.
        pub extern "ntdll" fn RtlWaitOnAddress(
            Address: *const anyopaque,
            CompareAddress: *const anyopaque,
            AddressSize: SIZE_T,
            Timeout: ?*const LARGE_INTEGER,
        ) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn RtlWakeAddressSingle(Address: *const anyopaque) callconv(.winapi) void;
        pub extern "ntdll" fn RtlWakeAddressAll(Address: *const anyopaque) callconv(.winapi) void;
    };
};

pub const ProcThreadAttributeNumber = enum(DWORD) {
    ProcThreadAttributePseudoConsole = 22,
    _,
};

/// Corresponds to the ProcThreadAttributeValue define in WinBase.h
pub fn ProcThreadAttributeValue(
    comptime attribute: ProcThreadAttributeNumber,
    comptime thread: bool,
    comptime input: bool,
    comptime additive: bool,
) DWORD {
    return (@backingInt(attribute) & PROC_THREAD_ATTRIBUTE_NUMBER) |
        (if (thread) PROC_THREAD_ATTRIBUTE_THREAD else 0) |
        (if (input) PROC_THREAD_ATTRIBUTE_INPUT else 0) |
        (if (additive) PROC_THREAD_ATTRIBUTE_ADDITIVE else 0);
}

/// Ghostty is a Windows GUI program, so a console it was started from is
/// not connected to it by default and `ghostty +version` would print
/// nothing. This connects the program's output to the console it was
/// started from, when there is one and output has not been redirected.
pub fn attachParentConsole() void {
    const attach_parent_process: u32 = 0xFFFFFFFF;
    const std_input_handle: u32 = @bitCast(@as(i32, -10));
    const std_output_handle: u32 = @bitCast(@as(i32, -11));
    const std_error_handle: u32 = @bitCast(@as(i32, -12));

    const k = struct {
        extern "kernel32" fn AttachConsole(pid: u32) callconv(.winapi) i32;
        extern "kernel32" fn GetStdHandle(which: u32) callconv(.winapi) ?*anyopaque;
        extern "kernel32" fn SetStdHandle(which: u32, handle: ?*anyopaque) callconv(.winapi) i32;
        extern "kernel32" fn GetConsoleMode(handle: ?*anyopaque, mode: *u32) callconv(.winapi) i32;
        extern "kernel32" fn SetConsoleMode(handle: ?*anyopaque, mode: u32) callconv(.winapi) i32;
        extern "kernel32" fn CreateFileW(
            name: [*:0]const u16,
            access: u32,
            share: u32,
            security: ?*anyopaque,
            disposition: u32,
            flags: u32,
            template: ?*anyopaque,
        ) callconv(.winapi) ?*anyopaque;
    };

    // Output that was redirected to a file or pipe already works.
    const invalid: usize = std.math.maxInt(usize);
    const existing = k.GetStdHandle(std_output_handle);
    if (existing != null and @intFromPtr(existing.?) != invalid) return;

    if (k.AttachConsole(attach_parent_process) == 0) return;

    const generic_read: u32 = 0x80000000;
    const generic_write: u32 = 0x40000000;
    const share_read_write: u32 = 3;
    const open_existing: u32 = 3;

    const out = k.CreateFileW(std.unicode.utf8ToUtf16LeStringLiteral("CONOUT$"), generic_read | generic_write, share_read_write, null, open_existing, 0, null);
    if (out != null and @intFromPtr(out.?) != invalid) {
        _ = k.SetStdHandle(std_output_handle, out);
        _ = k.SetStdHandle(std_error_handle, out);

        // Older consoles print escape sequences, like the ones that make
        // links clickable, as text unless they are asked to interpret them.
        var mode: u32 = 0;
        if (k.GetConsoleMode(out, &mode) != 0) {
            const processed_output: u32 = 0x1;
            const virtual_terminal_processing: u32 = 0x4;
            _ = k.SetConsoleMode(out, mode | processed_output | virtual_terminal_processing);
        }
    }
    const in = k.CreateFileW(std.unicode.utf8ToUtf16LeStringLiteral("CONIN$"), generic_read | generic_write, share_read_write, null, open_existing, 0, null);
    if (in != null and @intFromPtr(in.?) != invalid) _ = k.SetStdHandle(std_input_handle, in);
}

/// True when the command line has a Ghostty CLI action, which is an
/// argument starting with a plus sign such as `+version`.
pub fn commandLineHasAction() bool {
    const get_command_line = struct {
        extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]const u16;
    }.GetCommandLineW;
    const text = std.mem.span(get_command_line());
    var i: usize = 0;
    while (i + 1 < text.len) : (i += 1) {
        if (text[i] == ' ' and text[i + 1] == '+') return true;
    }
    return false;
}

/// The current directory of another process, or null when it cannot be
/// read. Windows does not report a program's folder to anyone else, so this
/// reads it out of the process's own memory: the process environment block
/// points to its startup parameters, and those hold the folder.
///
/// The handle needs query and read-memory access, which the handle returned
/// when the process was created already has.
pub fn currentDirectoryOfProcess(alloc: std.mem.Allocator, process: HANDLE) std.mem.Allocator.Error!?[]u8 {
    const k = struct {
        const BasicInformation = extern struct {
            exit_status: isize,
            peb_base_address: ?*anyopaque,
            affinity_mask: usize,
            base_priority: isize,
            unique_process_id: usize,
            inherited_from: usize,
        };
        extern "ntdll" fn NtQueryInformationProcess(
            process: ?*anyopaque,
            class: u32,
            info: *anyopaque,
            len: u32,
            returned: ?*u32,
        ) callconv(.winapi) i32;
        extern "kernel32" fn ReadProcessMemory(
            process: ?*anyopaque,
            address: ?*const anyopaque,
            buffer: *anyopaque,
            size: usize,
            read: ?*usize,
        ) callconv(.winapi) i32;
    };

    // These offsets are for 64-bit Windows.
    const peb_process_parameters_offset = 0x20;
    const parameters_current_directory_offset = 0x38;

    var info: k.BasicInformation = undefined;
    if (k.NtQueryInformationProcess(process, 0, &info, @sizeOf(k.BasicInformation), null) != 0) return null;
    const peb = info.peb_base_address orelse return null;

    var parameters: ?*anyopaque = null;
    if (k.ReadProcessMemory(process, @ptrFromInt(@intFromPtr(peb) + peb_process_parameters_offset), @ptrCast(&parameters), @sizeOf(usize), null) == 0) return null;
    const params = parameters orelse return null;

    // A UNICODE_STRING: a byte length, a capacity, then a pointer.
    const UnicodeString = extern struct { length: u16, maximum_length: u16, buffer: ?*anyopaque };
    var path: UnicodeString = undefined;
    if (k.ReadProcessMemory(process, @ptrFromInt(@intFromPtr(params) + parameters_current_directory_offset), &path, @sizeOf(UnicodeString), null) == 0) return null;
    const buffer = path.buffer orelse return null;
    if (path.length == 0 or path.length % 2 != 0 or path.length > 32768) return null;

    const wide = try alloc.alloc(u16, path.length / 2);
    defer alloc.free(wide);
    if (k.ReadProcessMemory(process, buffer, wide.ptr, path.length, null) == 0) return null;

    // The folder ends with a backslash, except for a drive root like C:\.
    var end = wide.len;
    if (end > 3 and wide[end - 1] == '\\') end -= 1;
    return std.unicode.utf16LeToUtf8Alloc(alloc, wide[0..end]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
}
