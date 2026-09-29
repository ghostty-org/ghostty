//! Windows (NT) impl of TinyIo.
//!
//! Modeled on the Windows impl of `std.Io.Threaded`, minus cancelation and
//! the sleep-and-retry loops it wraps around two kernel quirks (TinyIo
//! cannot sleep, so those statuses surface as `error.FileBusy`). Everything
//! goes through ntdll and kernel32, which static consumers already link.
//! Paths arrive as WTF-8 and are converted to the NT-prefixed WTF-16 form
//! `NtCreateFile` expects, the same way Threaded converts them.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const Threaded = std.Io.Threaded;
const TinyIo = @import("../TinyIo.zig");
const windows = std.os.windows;
const os_windows = @import("../../os/windows.zig");
const ntdll = os_windows.exp.ntdll;
const kernel32 = os_windows.exp.kernel32;
const HANDLE = windows.HANDLE;

const nt_prefix = [_]u16{ '\\', '?', '?', '\\' };
const unc_nt_prefix = [_]u16{ '\\', '?', '?', '\\', 'U', 'N', 'C', '\\' };
const share_all = os_windows.FILE_SHARE_READ |
    os_windows.FILE_SHARE_WRITE |
    os_windows.FILE_SHARE_DELETE;

/// A WTF-16 path buffer sized for the longest path NT accepts, plus one
/// slot for the terminator the Rtl path functions want. The array is
/// deliberately not a sentinel type: `undefined` sentinel arrays make the
/// compiler materialize a 64 KiB constant image of the buffer (to place
/// the sentinel) in .rdata, which cost ~200 KB across three buffers.
const WindowsPath = struct {
    data: [windows.PATH_MAX_WIDE + 1]u16,
    len: usize,

    fn span(self: *const WindowsPath) [:0]const u16 {
        return self.data[0..self.len :0];
    }

    fn setLen(self: *WindowsPath, len: usize) void {
        self.len = len;
        self.data[len] = 0;
    }

    /// True for absolute NT paths (`\??\...`). These must be opened with
    /// a null root directory; anything else is relative to a handle.
    fn isNt(self: *const WindowsPath) bool {
        return windows.hasCommonNtPrefix(u16, self.span());
    }

    /// Rewrites the Win32 path produced by RtlGetFullPathName_U into NT
    /// form in place: `\\?\X` and `\\.\X` become `\??\X`, `\\server\share`
    /// becomes `\??\UNC\server\share`, and `C:\...` gets `\??\` in front.
    fn win32ToNt(self: *WindowsPath) error{NameTooLong}!void {
        const p = self.data[0..self.len];
        const sep: u16 = '\\';
        if (p.len >= 4 and p[0] == sep and p[1] == sep and
            (p[2] == '?' or p[2] == '.') and p[3] == sep)
        {
            self.data[0..nt_prefix.len].* = nt_prefix;
            return;
        }
        if (p.len >= 2 and p[0] == sep and p[1] == sep) {
            const rest_len = p.len - 2;
            if (unc_nt_prefix.len + rest_len > windows.PATH_MAX_WIDE) return error.NameTooLong;
            @memmove(self.data[unc_nt_prefix.len..][0..rest_len], p[2..]);
            self.data[0..unc_nt_prefix.len].* = unc_nt_prefix;
            self.setLen(unc_nt_prefix.len + rest_len);
            return;
        }
        if (nt_prefix.len + p.len > windows.PATH_MAX_WIDE) return error.NameTooLong;
        @memmove(self.data[nt_prefix.len..][0..p.len], p);
        self.data[0..nt_prefix.len].* = nt_prefix;
        self.setLen(nt_prefix.len + p.len);
    }
};

const PathError = Dir.PathNameError || Io.UnexpectedError;

/// Converts a WTF-8 path into what `NtCreateFile` accepts, the way
/// `std.Io.Threaded.sliceToPrefixedFileW` does: NT paths (`\??\...`) pass
/// through, relative paths are normalized and stay relative to `dir`,
/// and everything else (drive-absolute, drive-relative, rooted, UNC,
/// `\\.\` and `\\?\` device paths, plus relative paths with more `..`
/// components than can be removed) is resolved to an absolute `\??\`
/// path through RtlGetFullPathName_U. `dir` matters only for that last
/// case; the process working directory is what Rtl resolves against.
///
/// The result is written to `out`, which is 64 KiB, so callers keep it
/// rather than having it returned by value.
fn pathToNt(dir: ?HANDLE, path: []const u8, out: *WindowsPath) PathError!void {
    out.setLen(try windows.wtf8ToWtf16Le(out.data[0..windows.PATH_MAX_WIDE], path));
    if (out.isNt()) return;

    const path_type = std.fs.path.getWin32PathType(u16, out.span());
    switch (path_type) {
        .relative => {
            if (windows.normalizePath(u16, out.data[0..out.len])) |len| {
                out.setLen(len);
                return;
            } else |err| switch (err) {
                // Escapes the directory; resolved to an absolute path below.
                error.TooManyParentDirs => {},
            }
        },
        .root_local_device => {
            // `\\.` and `\\?` are the NT prefix and nothing else.
            out.data[0..nt_prefix.len].* = nt_prefix;
            out.setLen(nt_prefix.len);
            return;
        },
        else => {},
    }

    // RtlGetFullPathName_U resolves against the process working directory,
    // so a relative path against any other directory handle is anchored to
    // that directory's final path first.
    var full: [windows.PATH_MAX_WIDE + 1]u16 = undefined;
    var full_len: usize = 0;
    if (path_type == .relative) anchor: {
        const dir_handle = dir orelse break :anchor;
        if (dir_handle == Dir.cwd().handle) break :anchor;
        const dir_path = finalPath(dir_handle, &full) catch |err| switch (err) {
            error.NameTooLong => return error.NameTooLong,
            else => return error.Unexpected,
        };
        full_len = dir_path.len;
        full[full_len] = '\\';
        full_len += 1;
    }
    if (full_len + out.len > windows.PATH_MAX_WIDE) return error.NameTooLong;
    @memcpy(full[full_len..][0..out.len], out.span());
    full_len += out.len;
    full[full_len] = 0;

    const byte_len = ntdll.RtlGetFullPathName_U(
        full[0..full_len :0].ptr,
        @intCast(windows.PATH_MAX_WIDE * 2),
        &out.data,
        null,
    );
    if (byte_len == 0) return error.BadPathName;
    if (byte_len / 2 > windows.PATH_MAX_WIDE) return error.NameTooLong;
    out.setLen(byte_len / 2);
    try out.win32ToNt();
}

const FinalPathError = error{
    FileNotFound,
    AccessDenied,
    NameTooLong,
    SystemResources,
} || Io.UnexpectedError;

/// The canonical Win32 path of an open handle from GetFinalPathNameByHandleW
/// with the `\\?\` prefix removed, which is the form Threaded's realpath
/// returns and the Kitty graphics path validation expects: `\\?\C:\x`
/// becomes `C:\x` and `\\?\UNC\srv\share\x` becomes `\\srv\share\x`.
/// The result aliases `buf`.
fn finalPath(handle: HANDLE, buf: *[windows.PATH_MAX_WIDE + 1]u16) FinalPathError![]u16 {
    const len = kernel32.GetFinalPathNameByHandleW(
        handle,
        buf,
        @intCast(buf.len),
        os_windows.FILE_NAME_NORMALIZED | os_windows.VOLUME_NAME_DOS,
    );
    if (len == 0) return switch (os_windows.GetLastError()) {
        .FILE_NOT_FOUND, .PATH_NOT_FOUND, .INVALID_HANDLE => error.FileNotFound,
        .ACCESS_DENIED => error.AccessDenied,
        .NOT_ENOUGH_MEMORY => error.SystemResources,
        else => |err| os_windows.unexpectedError(err),
    };
    // A too-small buffer reports the size needed, terminator included.
    if (len > windows.PATH_MAX_WIDE) return error.NameTooLong;

    const path = buf[0..len];
    if (path.len >= 4 and path[0] == '\\' and path[1] == '\\' and
        path[2] == '?' and path[3] == '\\')
    {
        // `\\?\` is the Win32 spelling of `\??\`; rewrite it so the std
        // helper strips it and folds `UNC\` back into `\\`.
        path[1] = '?';
        return windows.ntToWin32Namespace(path, path) catch |err| switch (err) {
            error.NotNtPath => unreachable,
            error.NameTooLong => error.NameTooLong,
        };
    }
    return path;
}

fn realPathHandle(handle: HANDLE, out_buffer: []u8) File.RealPathError!usize {
    var wide: [windows.PATH_MAX_WIDE + 1]u16 = undefined;
    const path = try finalPath(handle, &wide);
    if (std.unicode.calcWtf8Len(path) > out_buffer.len) return error.NameTooLong;
    return std.unicode.wtf16LeToWtf8(out_buffer, path);
}

const OpenNtError = error{
    BadPathName,
    FileNotFound,
    NetworkNotFound,
    NoDevice,
    AccessDenied,
    PipeBusy,
    PathAlreadyExists,
    IsDir,
    NotDir,
    AntivirusInterference,
    FileBusy,
} || Io.UnexpectedError;

/// Opens an existing file or directory. `path` is relative to `dir`
/// unless it is an absolute NT path, in which case `dir` is ignored
/// (NtCreateFile rejects a root directory paired with an absolute name).
fn openNt(
    dir: HANDLE,
    path: *const WindowsPath,
    access: windows.ACCESS_MASK,
    options: u32,
) OpenNtError!HANDLE {
    var attr: os_windows.OBJECT_ATTRIBUTES = .{
        .RootDirectory = if (path.isNt()) null else dir,
        .ObjectName = @constCast(&windows.UNICODE_STRING.init(path.span())),
    };
    var iosb: os_windows.IO_STATUS_BLOCK = undefined;
    var handle: HANDLE = undefined;
    return switch (ntdll.NtCreateFile(
        &handle,
        access,
        &attr,
        &iosb,
        null,
        os_windows.FILE_ATTRIBUTE_NORMAL,
        share_all,
        os_windows.FILE_OPEN,
        options,
        null,
        0,
    )) {
        .SUCCESS => handle,
        .OBJECT_NAME_INVALID, .OBJECT_PATH_SYNTAX_BAD => error.BadPathName,
        .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND => error.FileNotFound,
        .BAD_NETWORK_PATH, .BAD_NETWORK_NAME => error.NetworkNotFound,
        .NO_MEDIA_IN_DEVICE, .PIPE_NOT_AVAILABLE => error.NoDevice,
        .ACCESS_DENIED, .USER_MAPPED_FILE => error.AccessDenied,
        .PIPE_BUSY => error.PipeBusy,
        .OBJECT_NAME_COLLISION => error.PathAlreadyExists,
        .FILE_IS_A_DIRECTORY => error.IsDir,
        .NOT_A_DIRECTORY => error.NotDir,
        .VIRUS_INFECTED, .VIRUS_DELETED => error.AntivirusInterference,
        // Threaded sleeps and retries these (a kernel bug with recently
        // closed executables, and deletes still in progress).
        .SHARING_VIOLATION, .DELETE_PENDING => error.FileBusy,
        else => |status| os_windows.unexpectedStatus(status),
    };
}

pub fn dirOpenFile(
    _: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    options: Dir.OpenFileOptions,
) File.OpenError!File {
    // Same as the POSIX impl: nothing in the terminal locks files.
    if (options.lock != .none) return error.FileLocksUnsupported;
    var path: WindowsPath = undefined;
    try pathToNt(dir.handle, sub_path, &path);

    // Directories can never be opened for writing, and `.` and `..`
    // always name a directory.
    const allow_directory = options.allow_directory and !options.isWrite();
    if (!allow_directory and (std.mem.eql(u16, path.span(), &.{'.'}) or
        std.mem.eql(u16, path.span(), &.{ '.', '.' })))
    {
        return error.IsDir;
    }

    var flags: u32 = os_windows.FILE_SYNCHRONOUS_IO_NONALERT;
    if (!allow_directory) flags |= os_windows.FILE_NON_DIRECTORY_FILE;
    if (!options.follow_symlinks) flags |= os_windows.FILE_OPEN_REPARSE_POINT;
    const handle = try openNt(dir.handle, &path, .{
        .STANDARD = .{ .SYNCHRONIZE = true },
        .GENERIC = .{ .READ = options.isRead(), .WRITE = options.isWrite() },
    }, flags);
    return .{ .handle = handle, .flags = .{ .nonblocking = false } };
}

pub fn dirClose(_: ?*anyopaque, dirs: []const Dir) void {
    for (dirs) |dir| _ = ntdll.NtClose(dir.handle);
}

pub fn fileClose(_: ?*anyopaque, files: []const File) void {
    for (files) |file| _ = ntdll.NtClose(file.handle);
}

pub fn fileStat(_: ?*anyopaque, file: File) File.StatError!File.Stat {
    var iosb: os_windows.IO_STATUS_BLOCK = undefined;
    var info: os_windows.FILE_ALL_INFORMATION = undefined;
    switch (ntdll.NtQueryInformationFile(
        file.handle,
        &iosb,
        &info,
        @sizeOf(os_windows.FILE_ALL_INFORMATION),
        .All,
    )) {
        // The trailing name is variable length and unused, so an
        // overflow only means it was truncated.
        .SUCCESS, .BUFFER_OVERFLOW => {},
        .ACCESS_DENIED => return error.AccessDenied,
        else => |status| return os_windows.unexpectedStatus(status),
    }

    const kind: File.Kind = kind: {
        if (info.BasicInformation.FileAttributes.REPARSE_POINT) {
            var tag: os_windows.FILE_ATTRIBUTE_TAG_INFORMATION = undefined;
            switch (ntdll.NtQueryInformationFile(
                file.handle,
                &iosb,
                &tag,
                @sizeOf(os_windows.FILE_ATTRIBUTE_TAG_INFORMATION),
                .AttributeTag,
            )) {
                .SUCCESS => {},
                .ACCESS_DENIED => return error.AccessDenied,
                else => |status| return os_windows.unexpectedStatus(status),
            }
            break :kind if (tag.ReparseTag.IsSurrogate) .sym_link else .unknown;
        }
        break :kind if (info.BasicInformation.FileAttributes.DIRECTORY)
            .directory
        else
            .file;
    };

    return .{
        .inode = info.InternalInformation.IndexNumber,
        .size = @as(u64, @bitCast(info.StandardInformation.EndOfFile)),
        .permissions = .default_file,
        .kind = kind,
        .atime = windows.fromSysTime(info.BasicInformation.LastAccessTime),
        .mtime = windows.fromSysTime(info.BasicInformation.LastWriteTime),
        .ctime = windows.fromSysTime(info.BasicInformation.ChangeTime),
        .nlink = info.StandardInformation.NumberOfLinks,
        .block_size = @intCast(std.heap.page_size_max),
    };
}

pub fn fileLength(_: ?*anyopaque, file: File) File.LengthError!u64 {
    var iosb: os_windows.IO_STATUS_BLOCK = undefined;
    var info: os_windows.FILE_STANDARD_INFORMATION = undefined;
    return switch (ntdll.NtQueryInformationFile(
        file.handle,
        &iosb,
        &info,
        @sizeOf(os_windows.FILE_STANDARD_INFORMATION),
        .Standard,
    )) {
        .SUCCESS => @as(u64, @bitCast(info.EndOfFile)),
        .ACCESS_DENIED => error.AccessDenied,
        else => |status| os_windows.unexpectedStatus(status),
    };
}

/// One NtReadFile into one buffer. A positional read supplies an explicit
/// byte offset; a streaming read uses and advances the handle's own file
/// position (TinyIo only opens synchronous handles, which track it).
fn ntRead(comptime positional: bool, handle: HANDLE, buffer: []u8, offset: u64) !usize {
    var iosb: os_windows.IO_STATUS_BLOCK = undefined;
    var signed_offset: windows.LARGE_INTEGER = undefined;
    const offset_ptr: ?*const windows.LARGE_INTEGER = if (positional) o: {
        signed_offset = std.math.cast(i64, offset) orelse return error.Unseekable;
        break :o &signed_offset;
    } else null;
    return switch (ntdll.NtReadFile(
        handle,
        null,
        null,
        null,
        &iosb,
        buffer.ptr,
        std.math.lossyCast(u32, buffer.len),
        offset_ptr,
        null,
    )) {
        .SUCCESS => iosb.Information,
        .END_OF_FILE, .PIPE_BROKEN => error.EndOfStream,
        .INVALID_HANDLE => error.NotOpenForReading,
        .INVALID_DEVICE_REQUEST => error.IsDir,
        .FILE_LOCK_CONFLICT => error.LockViolation,
        .ACCESS_DENIED => error.AccessDenied,
        // Pipes and devices reject explicit offsets.
        .INVALID_PARAMETER => |status| if (positional)
            error.Unseekable
        else
            os_windows.unexpectedStatus(status),
        // Only asynchronous handles complete later, and TinyIo never
        // creates one; returning here would hand the kernel a dead buffer.
        .PENDING => unreachable,
        else => |status| os_windows.unexpectedStatus(status),
    };
}

pub fn fileReadPositional(
    _: ?*anyopaque,
    file: File,
    data: []const []u8,
    offset: u64,
) File.ReadPositionalError!usize {
    // NtReadFile takes one buffer, so a scatter read is issued one buffer
    // at a time, bounded like the POSIX iovec path, stopping at the first
    // short read. Positional reads only make sense on seekable files, so
    // the extra calls cannot block.
    var total: usize = 0;
    var count: usize = 0;
    for (data) |buffer| {
        if (buffer.len == 0) continue;
        if (count == Threaded.max_iovecs_len) break;
        count += 1;
        const n = ntRead(true, file.handle, buffer, offset + total) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        total += n;
        if (n < buffer.len) break;
    }
    return total;
}

pub fn fileReadStreaming(
    file: File,
    data: []const []u8,
) Io.Operation.FileReadStreaming.Error!usize {
    // Like Threaded, a streaming read fills one buffer per call: a second
    // NtReadFile could block on a pipe that already delivered data.
    for (data) |buffer| {
        if (buffer.len == 0) continue;
        return ntRead(false, file.handle, buffer, 0);
    }
    return 0;
}

fn setFilePosition(
    handle: HANDLE,
    info: *os_windows.FILE_POSITION_INFORMATION,
) File.SeekError!void {
    var iosb: os_windows.IO_STATUS_BLOCK = undefined;
    return switch (ntdll.NtSetInformationFile(
        handle,
        &iosb,
        info,
        @sizeOf(os_windows.FILE_POSITION_INFORMATION),
        .Position,
    )) {
        .SUCCESS => {},
        .ACCESS_DENIED => error.AccessDenied,
        .PIPE_NOT_AVAILABLE, .INVALID_PARAMETER, .INVALID_DEVICE_REQUEST => error.Unseekable,
        else => |status| os_windows.unexpectedStatus(status),
    };
}

pub fn fileSeekBy(_: ?*anyopaque, file: File, offset: i64) File.SeekError!void {
    var iosb: os_windows.IO_STATUS_BLOCK = undefined;
    var info: os_windows.FILE_POSITION_INFORMATION = undefined;
    switch (ntdll.NtQueryInformationFile(
        file.handle,
        &iosb,
        &info,
        @sizeOf(os_windows.FILE_POSITION_INFORMATION),
        .Position,
    )) {
        .SUCCESS => {},
        .ACCESS_DENIED => return error.AccessDenied,
        .PIPE_NOT_AVAILABLE, .INVALID_PARAMETER, .INVALID_DEVICE_REQUEST => return error.Unseekable,
        else => |status| return os_windows.unexpectedStatus(status),
    }
    const current: u64 = @bitCast(info.CurrentByteOffset);
    const target = if (offset >= 0)
        std.math.add(u64, current, @intCast(offset))
    else
        std.math.sub(u64, current, @abs(offset));
    info.CurrentByteOffset = @bitCast(target catch return error.Unseekable);
    return setFilePosition(file.handle, &info);
}

pub fn fileSeekTo(_: ?*anyopaque, file: File, offset: u64) File.SeekError!void {
    var info: os_windows.FILE_POSITION_INFORMATION = .{
        .CurrentByteOffset = @bitCast(offset),
    };
    return setFilePosition(file.handle, &info);
}

pub fn fileRealPath(
    _: ?*anyopaque,
    file: File,
    out_buffer: []u8,
) File.RealPathError!usize {
    return realPathHandle(file.handle, out_buffer);
}

pub fn dirRealPathFile(
    _: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    out_buffer: []u8,
) Dir.RealPathFileError!usize {
    var path: WindowsPath = undefined;
    try pathToNt(dir.handle, sub_path, &path);
    const handle = try openNt(dir.handle, &path, .{
        .STANDARD = .{ .SYNCHRONIZE = true },
        .GENERIC = .{ .READ = true },
    }, os_windows.FILE_SYNCHRONOUS_IO_NONALERT);
    defer _ = ntdll.NtClose(handle);

    // The path buffer is free again, so it holds the wide result.
    const final = try finalPath(handle, &path.data);
    if (std.unicode.calcWtf8Len(final) > out_buffer.len) return error.NameTooLong;
    return std.unicode.wtf16LeToWtf8(out_buffer, final);
}

pub fn dirDeleteFile(
    _: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
) Dir.DeleteFileError!void {
    // The parent cannot be removed through a handle inside it.
    if (std.mem.eql(u8, sub_path, "..")) return error.FileBusy;
    var path: WindowsPath = undefined;
    try pathToNt(dir.handle, sub_path, &path);
    // NT has no `.`, but an empty name reopens `dir` itself.
    if (std.mem.eql(u8, sub_path, ".")) path.setLen(0);

    const handle = openNt(dir.handle, &path, .{
        .STANDARD = .{ .RIGHTS = .{ .DELETE = true }, .SYNCHRONIZE = true },
    }, os_windows.FILE_SYNCHRONOUS_IO_NONALERT |
        os_windows.FILE_NON_DIRECTORY_FILE |
        os_windows.FILE_OPEN_REPARSE_POINT) catch |err| switch (err) {
        // Not produced by a plain file open, and not in DeleteFileError.
        error.PipeBusy,
        error.NoDevice,
        error.PathAlreadyExists,
        error.AntivirusInterference,
        => return error.Unexpected,
        else => |e| return e,
    };
    defer _ = ntdll.NtClose(handle);

    // Prefer POSIX delete semantics (the name is gone immediately, even
    // with other handles open, e.g. an antivirus scan of a temp file) and
    // fall back to delete-on-close where the kernel or file system does
    // not support them.
    var iosb: os_windows.IO_STATUS_BLOCK = undefined;
    var ex: os_windows.FILE_DISPOSITION_INFORMATION_EX = .{ .Flags = .{
        .DELETE = true,
        .POSIX_SEMANTICS = true,
        .IGNORE_READONLY_ATTRIBUTE = true,
    } };
    const status = switch (ntdll.NtSetInformationFile(
        handle,
        &iosb,
        &ex,
        @sizeOf(os_windows.FILE_DISPOSITION_INFORMATION_EX),
        .DispositionEx,
    )) {
        .INVALID_PARAMETER, .INVALID_INFO_CLASS, .NOT_SUPPORTED => fallback: {
            var info: os_windows.FILE_DISPOSITION_INFORMATION = .{ .DeleteFile = .TRUE };
            break :fallback ntdll.NtSetInformationFile(
                handle,
                &iosb,
                &info,
                @sizeOf(os_windows.FILE_DISPOSITION_INFORMATION),
                .Disposition,
            );
        },
        else => |status| status,
    };
    switch (status) {
        .SUCCESS => {},
        .CANNOT_DELETE, .MEDIA_WRITE_PROTECTED, .ACCESS_DENIED => return error.AccessDenied,
        else => |s| return os_windows.unexpectedStatus(s),
    }
}

pub fn randomSecure(buffer: []u8) Io.RandomSecureError!void {
    // Read the kernel CSPRNG device directly, which is what ProcessPrng
    // and BCryptGenRandom draw from and what Threaded reads through a
    // cached handle. TinyIo is stateless, so the device is opened per
    // call: three syscalls, fine for one-time password generation, and
    // no bcryptprimitives or advapi32 import for static consumers.
    var name: windows.UNICODE_STRING = .init(
        std.unicode.utf8ToUtf16LeStringLiteral("\\Device\\CNG"),
    );
    var attr: os_windows.OBJECT_ATTRIBUTES = .{ .ObjectName = &name };
    var iosb: os_windows.IO_STATUS_BLOCK = undefined;
    var handle: HANDLE = undefined;
    switch (ntdll.NtOpenFile(
        &handle,
        .{
            .STANDARD = .{ .SYNCHRONIZE = true },
            .SPECIFIC = .{ .FILE = .{ .READ_DATA = true } },
        },
        &attr,
        &iosb,
        share_all,
        os_windows.FILE_SYNCHRONOUS_IO_NONALERT,
    )) {
        .SUCCESS => {},
        else => return error.EntropyUnavailable,
    }
    defer _ = ntdll.NtClose(handle);

    var i: usize = 0;
    while (i < buffer.len) {
        const len = std.math.lossyCast(u32, buffer.len - i);
        switch (ntdll.NtDeviceIoControlFile(
            handle,
            null,
            null,
            null,
            &iosb,
            os_windows.IOCTL_KSEC_GEN_RANDOM,
            null,
            0,
            buffer[i..].ptr,
            len,
        )) {
            .SUCCESS => i += len,
            else => return error.EntropyUnavailable,
        }
    }
}

pub fn futexWaitInner(ptr: *const u32, expected: u32, timeout_ns: ?u64) void {
    @branchHint(.cold);
    if (builtin.single_threaded) unreachable; // nobody would ever wake us

    // RtlWaitOnAddress is what kernel32's WaitOnAddress forwards
    // to; going through ntdll keeps static consumers off
    // synchronization.lib. A negative timeout is relative in
    // 100ns units and null waits forever. It returns SUCCESS on a
    // wake or when the value already differs and TIMEOUT
    // otherwise; either way the caller re-checks its condition.
    var interval: windows.LARGE_INTEGER = undefined;
    const timeout: ?*const windows.LARGE_INTEGER = if (timeout_ns) |ns| t: {
        interval = -@as(i64, @intCast(@min(ns / 100, std.math.maxInt(i64))));
        break :t &interval;
    } else null;
    _ = ntdll.RtlWaitOnAddress(ptr, &expected, @sizeOf(u32), timeout);
}

pub fn futexWake(userdata: ?*anyopaque, ptr: *const u32, max_waiters: u32) void {
    @branchHint(.cold);
    _ = userdata;
    if (builtin.single_threaded) return; // nothing to wake up
    if (max_waiters > 1) ntdll.RtlWakeAddressAll(ptr) else ntdll.RtlWakeAddressSingle(ptr);
}

test "windows: path conversion" {
    const testing = std.testing;
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    const cwd = Dir.cwd().handle;

    // Absolute Win32 paths are canonicalized and NT-prefixed, with either
    // separator and `..` resolved.
    var p: WindowsPath = undefined;
    try pathToNt(cwd, "C:/foo/../bar", &p);
    try testing.expectEqualSlices(u16, L("\\??\\C:\\bar"), p.span());
    try pathToNt(cwd, "\\\\server\\share\\x\\..\\y", &p);
    try testing.expectEqualSlices(u16, L("\\??\\UNC\\server\\share\\y"), p.span());
    try pathToNt(cwd, "\\\\?\\C:\\x", &p);
    try testing.expectEqualSlices(u16, L("\\??\\C:\\x"), p.span());
    try pathToNt(cwd, "\\\\.\\pipe\\x", &p);
    try testing.expectEqualSlices(u16, L("\\??\\pipe\\x"), p.span());

    // NT paths pass through untouched.
    try pathToNt(cwd, "\\??\\C:\\x", &p);
    try testing.expectEqualSlices(u16, L("\\??\\C:\\x"), p.span());

    // Relative paths stay relative to the directory handle, normalized.
    try pathToNt(cwd, "a/../b\\c", &p);
    try testing.expectEqualSlices(u16, L("b\\c"), p.span());
    try testing.expect(!p.isNt());

    // Relative paths that climb out of the directory resolve against the
    // handle's real path (or the working directory for cwd).
    try pathToNt(cwd, "..\\up.txt", &p);
    try testing.expect(p.isNt());
    try testing.expect(std.mem.endsWith(u16, p.span(), L("\\up.txt")));

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = dir_buf[0..try tmp_dir.dir.realPath(testing.io, &dir_buf)];
    const parent = std.fs.path.dirname(dir_path).?;
    try pathToNt(tmp_dir.dir.handle, "..\\up.txt", &p);
    var got_buf: [std.fs.max_path_bytes]u8 = undefined;
    const got = got_buf[0..std.unicode.wtf16LeToWtf8(&got_buf, p.span())];
    try testing.expect(std.mem.startsWith(u8, got, "\\??\\"));
    try testing.expectEqualStrings(parent, got[4 .. 4 + parent.len]);
    try testing.expectEqualStrings("\\up.txt", got[4 + parent.len ..]);

    // Encoding errors are path errors.
    try testing.expectError(error.BadPathName, pathToNt(cwd, "bad\xff", &p));
    try testing.expectError(error.NameTooLong, pathToNt(cwd, "a" ** (windows.PATH_MAX_WIDE + 1), &p));
}

test "windows: realPath resolves through symlinks" {
    const tio: TinyIo = .init;
    const test_io = tio.io();
    const testing = std.testing;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "target.txt",
        .data = "target",
    });
    // Needs SeCreateSymbolicLinkPrivilege, which plain users and CI lack.
    tmp_dir.dir.symLink(testing.io, "target.txt", "link.txt", .{}) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    const dir: Dir = .{ .handle = tmp_dir.dir.handle };

    // Following the link (the default) opens the target and realPath
    // resolves to it, which is what the Kitty path validation relies on.
    var file = try dir.openFile(test_io, "link.txt", .{});
    defer file.close(test_io);
    try testing.expectEqual(@as(u64, "target".len), try file.length(test_io));
    try testing.expectEqual(File.Kind.file, (try file.stat(test_io)).kind);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try file.realPath(test_io, &path_buf)];
    try testing.expect(std.mem.endsWith(u8, path, "target.txt"));

    // Opening the link itself reports a symlink.
    var link = try dir.openFile(test_io, "link.txt", .{ .follow_symlinks = false });
    defer link.close(test_io);
    try testing.expectEqual(File.Kind.sym_link, (try link.stat(test_io)).kind);

    // dirRealPathFile through the link resolves the target too.
    var path_buf2: [std.fs.max_path_bytes]u8 = undefined;
    const path2 = path_buf2[0..try dir.realPathFile(test_io, "link.txt", &path_buf2)];
    try testing.expectEqualStrings(path, path2);
}
