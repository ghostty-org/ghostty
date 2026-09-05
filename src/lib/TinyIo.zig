//! TinyIo: a tiny, blocking `std.Io` implementation optimized for
//! binary size.
//!
//! Compared to `std.Io.Threaded`, the binary cost is roughly ~100KB to
//! ~200KB (macOS vs Linux) smaller, and the runtime cost is ~300KB (256KB
//! of TLS plus the ~20KB threaded structure) smaller.
//!
//! Utilizing the built-in Zig `std.Io.Threaded` is easy but due to its
//! vtable architecture, the linker can't prune uncalled functions, meaning
//! you have to pay for all the code for every op. Plus, at runtime, Threaded
//! requires 256KB of thread-local storage, plus the structure itself is
//! very large.
//!
//! TinyIo implements exactly the operations we need as plain blocking
//! syscalls. It doesn't support cancelation. It doesn't support concurrency
//! operations, but all our APIs are direct syscalls so it supports the
//! concurrency of calls that those syscalls support (which is usually
//! safe on POSIX systems).
//!
//! A lot of the direct syscall code is cribbed from Zig's std.posix.

const TinyIo = @This();

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const Threaded = std.Io.Threaded;

/// True if this platform has a real TinyIo implementation. On
/// unsupported platforms `io()` still works but every operation fails
/// like `std.Io.failing`.
pub const supported: bool = switch (builtin.os.tag) {
    .windows, .wasi, .freestanding, .other, .uefi => false,
    else => true,
};

/// Initialize a TinyIo. TinyIo is stateless (zero-sized), so this exists
/// purely to mirror the `std.Io.Threaded` initialization and usage shape,
/// making the two easy to swap.
pub const init: TinyIo = .{};

/// Returns the `std.Io` interface for this implementation.
pub fn io(self: TinyIo) Io {
    _ = self;
    return .{
        .userdata = null,
        .vtable = &vtable,
    };
}

const vtable: Io.VTable = if (!supported) std.Io.failing.vtable.* else .{
    .crashHandler = Io.noCrashHandler,

    // `noAsync` runs the task synchronously and returns null, which means
    // `await`/`cancel` can never be called. `concurrent` reports that
    // concurrency is unavailable, which callers must handle anyway.
    .async = Io.noAsync,
    .concurrent = Io.failingConcurrent,
    .await = Io.unreachableAwait,
    .cancel = Io.unreachableCancel,

    .groupAsync = Io.noGroupAsync,
    .groupConcurrent = Io.failingGroupConcurrent,
    .groupAwait = Io.unreachableGroupAwait,
    .groupCancel = Io.unreachableGroupCancel,

    // Cancelation is never requested (there is no async), but these are
    // benign no-ops instead of `unreachable` since generic std code may
    // toggle cancel protection around operations.
    .recancel = recancel,
    .swapCancelProtection = swapCancelProtection,
    .checkCancel = checkCancel,

    // Real futexes: `std.Io.Mutex` (used by kitty graphics storage) parks
    // on these when contended.
    .futexWait = futexWait,
    .futexWaitUncancelable = futexWaitUncancelable,
    .futexWake = futexWake,

    // `operate` carries the streaming file reads used by `File.Reader`.
    .operate = operate,
    .batchAwaitAsync = Io.unreachableBatchAwaitAsync,
    .batchAwaitConcurrent = Io.unreachableBatchAwaitConcurrent,
    .batchCancel = Io.unreachableBatchCancel,

    .dirCreateDir = Io.failingDirCreateDir,
    .dirCreateDirPath = Io.failingDirCreateDirPath,
    .dirCreateDirPathOpen = Io.failingDirCreateDirPathOpen,
    .dirOpenDir = Io.failingDirOpenDir,
    .dirStat = Io.failingDirStat,
    .dirStatFile = Io.failingDirStatFile,
    .dirAccess = Io.failingDirAccess,
    .dirCreateFile = Io.failingDirCreateFile,
    .dirCreateFileAtomic = Io.failingDirCreateFileAtomic,
    .dirOpenFile = dirOpenFile,
    .dirClose = dirClose,
    .dirRead = Io.noDirRead,
    .dirRealPath = Io.failingDirRealPath,
    .dirRealPathFile = dirRealPathFile,
    .dirDeleteFile = dirDeleteFile,
    .dirDeleteDir = Io.failingDirDeleteDir,
    .dirRename = Io.failingDirRename,
    .dirRenamePreserve = Io.failingDirRenamePreserve,
    .dirSymLink = Io.failingDirSymLink,
    .dirReadLink = Io.failingDirReadLink,
    .dirSetOwner = Io.failingDirSetOwner,
    .dirSetFileOwner = Io.failingDirSetFileOwner,
    .dirSetPermissions = Io.failingDirSetPermissions,
    .dirSetFilePermissions = Io.failingDirSetFilePermissions,
    .dirSetTimestamps = Io.noDirSetTimestamps,
    .dirHardLink = Io.failingDirHardLink,

    .fileStat = fileStat,
    .fileLength = fileLength,
    .fileClose = fileClose,
    .fileWritePositional = Io.failingFileWritePositional,
    .fileWriteFileStreaming = Io.noFileWriteFileStreaming,
    .fileWriteFilePositional = Io.noFileWriteFilePositional,
    .fileReadPositional = fileReadPositional,
    .fileSeekBy = fileSeekBy,
    .fileSeekTo = fileSeekTo,
    .fileSync = Io.failingFileSync,
    .fileIsTty = Io.unreachableFileIsTty,
    .fileEnableAnsiEscapeCodes = Io.unreachableFileEnableAnsiEscapeCodes,
    .fileSupportsAnsiEscapeCodes = Io.unreachableFileSupportsAnsiEscapeCodes,
    .fileSetLength = Io.failingFileSetLength,
    .fileSetOwner = Io.failingFileSetOwner,
    .fileSetPermissions = Io.failingFileSetPermissions,
    .fileSetTimestamps = Io.noFileSetTimestamps,
    .fileLock = Io.failingFileLock,
    .fileTryLock = Io.failingFileTryLock,
    .fileUnlock = Io.unreachableFileUnlock,
    .fileDowngradeLock = Io.failingFileDowngradeLock,
    .fileRealPath = fileRealPath,
    .fileHardLink = Io.failingFileHardLink,

    .fileMemoryMapCreate = Io.failingFileMemoryMapCreate,
    .fileMemoryMapDestroy = Io.unreachableFileMemoryMapDestroy,
    .fileMemoryMapSetLength = Io.unreachableFileMemoryMapSetLength,
    .fileMemoryMapRead = Io.unreachableFileMemoryMapRead,
    .fileMemoryMapWrite = Io.unreachableFileMemoryMapWrite,

    .processExecutableOpen = Io.failingProcessExecutableOpen,
    .processExecutablePath = Io.failingProcessExecutablePath,
    .lockStderr = Io.unreachableLockStderr,
    .tryLockStderr = Io.noTryLockStderr,
    .unlockStderr = Io.unreachableUnlockStderr,
    .processCurrentPath = Io.failingProcessCurrentPath,
    .processSetCurrentDir = Io.failingProcessSetCurrentDir,
    .processSetCurrentPath = Io.failingProcessSetCurrentPath,
    .processReplace = Io.failingProcessReplace,
    .processReplacePath = Io.failingProcessReplacePath,
    .processSpawn = Io.failingProcessSpawn,
    .processSpawnPath = Io.failingProcessSpawnPath,
    .childWait = Io.unreachableChildWait,
    .childKill = Io.unreachableChildKill,

    .progressParentFile = Io.failingProgressParentFile,

    .random = Io.noRandom,
    .randomSecure = randomSecure,

    .now = Io.noNow,
    .clockResolution = Io.failingClockResolution,
    .sleep = Io.noSleep,

    .netListenIp = Io.failingNetListenIp,
    .netAccept = Io.failingNetAccept,
    .netBindIp = Io.failingNetBindIp,
    .netConnectIp = Io.failingNetConnectIp,
    .netListenUnix = Io.failingNetListenUnix,
    .netConnectUnix = Io.failingNetConnectUnix,
    .netSocketCreatePair = Io.failingNetSocketCreatePair,
    .netSend = Io.failingNetSend,
    .netRead = Io.failingNetRead,
    .netWrite = Io.failingNetWrite,
    .netWriteFile = Io.failingNetWriteFile,
    .netClose = Io.unreachableNetClose,
    .netShutdown = Io.failingNetShutdown,
    .netInterfaceNameResolve = Io.failingNetInterfaceNameResolve,
    .netInterfaceName = Io.unreachableNetInterfaceName,
    .netLookup = Io.failingNetLookup,
};

// 64-bit offset syscall selection, same as `std.Io.Threaded`.
const openat_sym = if (posix.lfs64_abi) posix.system.openat64 else posix.system.openat;
const fstat_sym = if (posix.lfs64_abi) posix.system.fstat64 else posix.system.fstat;
const fstatat_sym = if (posix.lfs64_abi) posix.system.fstatat64 else posix.system.fstatat;
const lseek_sym = if (posix.lfs64_abi) posix.system.lseek64 else posix.system.lseek;
const preadv_sym = if (posix.lfs64_abi) posix.system.preadv64 else posix.system.preadv;

const have_preadv = switch (builtin.os.tag) {
    .haiku => false,
    else => true,
};

fn recancel(_: ?*anyopaque) void {}

fn swapCancelProtection(
    _: ?*anyopaque,
    new: Io.CancelProtection,
) Io.CancelProtection {
    // Stateless: there is no async, so cancelation can never be requested
    // and the protection state is meaningless. Callers save this return
    // value only to restore it via another call to this function.
    _ = new;
    return .blocked;
}

fn checkCancel(_: ?*anyopaque) Io.Cancelable!void {}

fn randomSecure(_: ?*anyopaque, buffer: []u8) Io.RandomSecureError!void {
    if (buffer.len == 0) return;

    // The same sources as `std.Io.Threaded.randomSecure` minus
    // cancelation and the /dev/urandom fallback: arc4random_buf where
    // libc provides it (all the BSDs and Darwin, glibc 2.36+), otherwise
    // the getrandom syscall on Linux. Anything else has no entropy.
    if (builtin.link_libc and @TypeOf(posix.system.arc4random_buf) != void) {
        posix.system.arc4random_buf(buffer.ptr, buffer.len);
        return;
    }

    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var i: usize = 0;
        while (i < buffer.len) {
            const rc = linux.getrandom(buffer[i..].ptr, buffer.len - i, 0);
            switch (linux.errno(rc)) {
                .SUCCESS => i += rc,
                .INTR => continue,
                else => return error.EntropyUnavailable,
            }
        }
        return;
    }

    return error.EntropyUnavailable;
}

fn closeFd(fd: posix.fd_t) void {
    // Never retry close on EINTR: POSIX leaves the fd state unspecified
    // and Linux always closes it, so retrying risks closing an unrelated
    // fd opened by another thread.
    _ = posix.system.close(fd);
}

fn dirOpenFile(
    _: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    options: Dir.OpenFileOptions,
) File.OpenError!File {
    var path_buffer: [posix.PATH_MAX]u8 = undefined;
    const sub_path_posix = try Threaded.pathToPosix(sub_path, &path_buffer);

    // Nothing in the terminal locks files. Implementing this requires
    // flock fallbacks (see std.Io.Threaded); report it as unsupported.
    if (options.lock != .none) return error.FileLocksUnsupported;

    var flags: posix.O = .{
        .ACCMODE = switch (options.mode) {
            .read_only => .RDONLY,
            .write_only => .WRONLY,
            .read_write => .RDWR,
        },
        .NOFOLLOW = !options.follow_symlinks,
    };
    if (@hasField(posix.O, "CLOEXEC")) flags.CLOEXEC = true;
    if (@hasField(posix.O, "LARGEFILE")) flags.LARGEFILE = true;
    if (@hasField(posix.O, "NOCTTY")) flags.NOCTTY = !options.allow_ctty;
    if (@hasField(posix.O, "PATH")) flags.PATH = options.path_only;
    if (@hasField(posix.O, "RESOLVE_BENEATH")) flags.RESOLVE_BENEATH = options.resolve_beneath;

    const mode: posix.mode_t = 0;
    const fd: posix.fd_t = while (true) {
        const rc = openat_sym(dir.handle, sub_path_posix, flags, mode);
        switch (posix.errno(rc)) {
            .SUCCESS => break @intCast(rc),
            .INTR => continue,
            .INVAL => return error.BadPathName,
            .ACCES => return error.AccessDenied,
            .FBIG => return error.FileTooBig,
            .OVERFLOW => return error.FileTooBig,
            .ISDIR => return error.IsDir,
            .LOOP => return error.SymLinkLoop,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NAMETOOLONG => return error.NameTooLong,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NODEV => return error.NoDevice,
            .NOENT => return error.FileNotFound,
            .SRCH => return error.FileNotFound,
            .NOMEM => return error.SystemResources,
            .NOSPC => return error.NoSpaceLeft,
            .NOTDIR => return error.NotDir,
            .PERM => return error.PermissionDenied,
            .EXIST => return error.PathAlreadyExists,
            .BUSY => return error.DeviceBusy,
            .OPNOTSUPP => return error.FileLocksUnsupported,
            .AGAIN => return error.WouldBlock,
            .TXTBSY => return error.FileBusy,
            .NXIO => return error.NoDevice,
            .ROFS => return error.ReadOnlyFileSystem,
            .ILSEQ => return error.BadPathName,
            else => |err| return posix.unexpectedErrno(err),
        }
    };
    errdefer closeFd(fd);

    const file: File = .{ .handle = fd, .flags = .{ .nonblocking = false } };

    if (!options.allow_directory) {
        const is_dir = is_dir: {
            const stat = fileStat(null, file) catch |err| switch (err) {
                // Directory-ness is unknown or unknowable.
                error.Streaming => break :is_dir false,
                else => |e| return e,
            };
            break :is_dir stat.kind == .directory;
        };
        if (is_dir) return error.IsDir;
    }

    return file;
}

fn dirClose(_: ?*anyopaque, dirs: []const Dir) void {
    for (dirs) |dir| closeFd(dir.handle);
}

fn fileClose(_: ?*anyopaque, files: []const File) void {
    for (files) |file| closeFd(file.handle);
}

fn fileStat(_: ?*anyopaque, file: File) File.StatError!File.Stat {
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        while (true) {
            var statx = std.mem.zeroes(linux.Statx);
            switch (linux.errno(linux.statx(
                file.handle,
                "",
                linux.AT.EMPTY_PATH,
                Threaded.linux_statx_request,
                &statx,
            ))) {
                .SUCCESS => return Threaded.statFromLinux(&statx),
                .INTR => continue,
                .NOMEM => return error.SystemResources,
                else => |err| return posix.unexpectedErrno(err),
            }
        }
    }

    while (true) {
        var stat = std.mem.zeroes(posix.Stat);
        switch (posix.errno(fstat_sym(file.handle, &stat))) {
            .SUCCESS => return Threaded.statFromPosix(&stat),
            .INTR => continue,
            .NOMEM => return error.SystemResources,
            .ACCES => return error.AccessDenied,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

fn fileLength(userdata: ?*anyopaque, file: File) File.LengthError!u64 {
    const stat = try fileStat(userdata, file);
    return stat.size;
}

/// Gathers non-empty buffers into iovecs. Returns an empty slice if there
/// is nothing to read into.
fn buffersToIovecs(
    data: []const []u8,
    iovecs_buffer: *[Threaded.max_iovecs_len]posix.iovec,
) []posix.iovec {
    var i: usize = 0;
    for (data) |buf| {
        if (iovecs_buffer.len - i == 0) break;
        if (buf.len != 0) {
            iovecs_buffer[i] = .{ .base = buf.ptr, .len = buf.len };
            i += 1;
        }
    }
    return iovecs_buffer[0..i];
}

fn fileReadPositional(
    _: ?*anyopaque,
    file: File,
    data: []const []u8,
    offset: u64,
) File.ReadPositionalError!usize {
    var iovecs_buffer: [Threaded.max_iovecs_len]posix.iovec = undefined;
    const dest = buffersToIovecs(data, &iovecs_buffer);
    if (dest.len == 0) return 0;

    while (true) {
        const rc = if (comptime have_preadv)
            preadv_sym(file.handle, dest.ptr, @intCast(dest.len), @bitCast(offset))
        else
            posix.system.pread(file.handle, dest[0].base, dest[0].len, @bitCast(offset));
        switch (posix.errno(rc)) {
            .SUCCESS => return @bitCast(rc),
            .INTR, .TIMEDOUT => continue,
            .NXIO => return error.Unseekable,
            .SPIPE => return error.Unseekable,
            .OVERFLOW => return error.Unseekable,
            .NOBUFS => return error.SystemResources,
            .NOMEM => return error.SystemResources,
            .AGAIN => return error.WouldBlock,
            .IO => return error.InputOutput,
            .ISDIR => return error.IsDir,
            .BADF => return error.NotOpenForReading,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

fn fileReadStreaming(
    file: File,
    data: []const []u8,
) Io.Operation.FileReadStreaming.Error!usize {
    var iovecs_buffer: [Threaded.max_iovecs_len]posix.iovec = undefined;
    const dest = buffersToIovecs(data, &iovecs_buffer);
    if (dest.len == 0) return 0;

    while (true) {
        const rc = posix.system.readv(file.handle, dest.ptr, @intCast(dest.len));
        switch (posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.EndOfStream;
                return @intCast(rc);
            },
            .INTR, .TIMEDOUT => continue,
            .AGAIN => return error.WouldBlock,
            .IO => return error.InputOutput,
            .ISDIR => return error.IsDir,
            .NOBUFS => return error.SystemResources,
            .NOMEM => return error.SystemResources,
            .NOTCONN => return error.SocketUnconnected,
            .CONNRESET => return error.ConnectionResetByPeer,
            .BADF => return error.NotOpenForReading,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

fn operate(
    userdata: ?*anyopaque,
    operation: Io.Operation,
) Io.Cancelable!Io.Operation.Result {
    switch (operation) {
        // Streaming file reads are how `File.Reader` consumes files that
        // don't support positional reads (and the fallback path in
        // general).
        .file_read_streaming => |o| return .{
            .file_read_streaming = fileReadStreaming(o.file, o.data),
        },

        // Everything else (streaming writes, ioctls, socket receives) is
        // unused by the terminal; fail like `Io.failing` does.
        else => return Io.failingOperate(userdata, operation),
    }
}

fn fileSeekBy(_: ?*anyopaque, file: File, offset: i64) File.SeekError!void {
    while (true) {
        const rc = lseek_sym(file.handle, offset, posix.SEEK.CUR);
        switch (posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            .INVAL => return error.Unseekable,
            .OVERFLOW => return error.Unseekable,
            .SPIPE => return error.Unseekable,
            .NXIO => return error.Unseekable,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

fn fileSeekTo(_: ?*anyopaque, file: File, offset: u64) File.SeekError!void {
    while (true) {
        const rc = lseek_sym(file.handle, @bitCast(offset), posix.SEEK.SET);
        switch (posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            .INVAL => return error.Unseekable,
            .OVERFLOW => return error.Unseekable,
            .SPIPE => return error.Unseekable,
            .NXIO => return error.Unseekable,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

fn fileRealPath(
    _: ?*anyopaque,
    file: File,
    out_buffer: []u8,
) File.RealPathError!usize {
    return realPathFd(file.handle, out_buffer);
}

fn realPathFd(fd: posix.fd_t, out_buffer: []u8) File.RealPathError!usize {
    switch (builtin.os.tag) {
        .dragonfly, .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => {
            var sufficient_buffer: [posix.PATH_MAX]u8 = undefined;
            @memset(&sufficient_buffer, 0);
            while (true) {
                switch (posix.errno(posix.system.fcntl(fd, posix.F.GETPATH, &sufficient_buffer))) {
                    .SUCCESS => break,
                    .INTR => continue,
                    .ACCES => return error.AccessDenied,
                    .BADF => return error.FileNotFound,
                    .NOENT => return error.FileNotFound,
                    .NOMEM => return error.SystemResources,
                    .NOSPC => return error.NameTooLong,
                    .RANGE => return error.NameTooLong,
                    else => |err| return posix.unexpectedErrno(err),
                }
            }
            const n = std.mem.indexOfScalar(u8, &sufficient_buffer, 0) orelse sufficient_buffer.len;
            if (n > out_buffer.len) return error.NameTooLong;
            @memcpy(out_buffer[0..n], sufficient_buffer[0..n]);
            return n;
        },

        .linux, .serenity, .illumos => {
            var procfs_buf: ["/proc/self/path/-2147483648\x00".len]u8 = undefined;
            const template = if (builtin.os.tag == .illumos) "/proc/self/path/{d}" else "/proc/self/fd/{d}";
            const proc_path = std.fmt.bufPrintSentinel(&procfs_buf, template, .{fd}, 0) catch unreachable;
            while (true) {
                const rc = posix.system.readlink(proc_path, out_buffer.ptr, out_buffer.len);
                switch (posix.errno(rc)) {
                    .SUCCESS => return @bitCast(rc),
                    .INTR => continue,
                    .ACCES => return error.AccessDenied,
                    .IO => return error.FileSystem,
                    .LOOP => return error.SymLinkLoop,
                    .NAMETOOLONG => return error.NameTooLong,
                    .NOENT => return error.FileNotFound,
                    .NOMEM => return error.SystemResources,
                    .NOTDIR => return error.NotDir,
                    else => |err| return posix.unexpectedErrno(err),
                }
            }
        },

        .freebsd => {
            var k_file: std.c.kinfo_file = undefined;
            k_file.structsize = std.c.KINFO_FILE_SIZE;
            while (true) {
                switch (posix.errno(std.c.fcntl(fd, std.c.F.KINFO, @intFromPtr(&k_file)))) {
                    .SUCCESS => break,
                    .INTR => continue,
                    .BADF => return error.FileNotFound,
                    else => |err| return posix.unexpectedErrno(err),
                }
            }
            const len = std.mem.findScalar(u8, &k_file.path, 0) orelse k_file.path.len;
            if (len == 0) return error.NameTooLong;
            @memcpy(out_buffer[0..len], k_file.path[0..len]);
            return len;
        },

        else => return error.OperationUnsupported,
    }
}

fn dirRealPathFile(
    _: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    out_buffer: []u8,
) Dir.RealPathFileError!usize {
    var path_buffer: [posix.PATH_MAX]u8 = undefined;
    const sub_path_posix = try Threaded.pathToPosix(sub_path, &path_buffer);

    if (builtin.link_libc and dir.handle == posix.AT.FDCWD) {
        if (out_buffer.len < posix.PATH_MAX) return error.NameTooLong;
        while (true) {
            if (std.c.realpath(sub_path_posix, out_buffer.ptr)) |redundant_pointer| {
                std.debug.assert(redundant_pointer == out_buffer.ptr);
                return std.mem.indexOfScalar(u8, out_buffer, 0) orelse out_buffer.len;
            }
            switch (@as(posix.E, @enumFromInt(std.c._errno().*))) {
                .INTR => continue,
                .ACCES => return error.AccessDenied,
                .NOENT => return error.FileNotFound,
                .OPNOTSUPP => return error.OperationUnsupported,
                .NOTDIR => return error.NotDir,
                .NAMETOOLONG => return error.NameTooLong,
                .LOOP => return error.SymLinkLoop,
                .IO => return error.InputOutput,
                else => |err| return posix.unexpectedErrno(err),
            }
        }
    }

    // Fallback: open the path and resolve the fd. Used for non-cwd
    // directory handles (which the terminal itself never passes) and
    // non-libc builds.
    var flags: posix.O = .{};
    if (@hasField(posix.O, "NONBLOCK")) flags.NONBLOCK = true;
    if (@hasField(posix.O, "CLOEXEC")) flags.CLOEXEC = true;
    if (@hasField(posix.O, "PATH")) flags.PATH = true;

    const mode: posix.mode_t = 0;
    const fd: posix.fd_t = while (true) {
        const rc = openat_sym(dir.handle, sub_path_posix, flags, mode);
        switch (posix.errno(rc)) {
            .SUCCESS => break @intCast(rc),
            .INTR => continue,
            .INVAL => return error.BadPathName,
            .ACCES => return error.AccessDenied,
            .LOOP => return error.SymLinkLoop,
            .NAMETOOLONG => return error.NameTooLong,
            .NOENT => return error.FileNotFound,
            .NOMEM => return error.SystemResources,
            .NOTDIR => return error.NotDir,
            .ILSEQ => return error.BadPathName,
            else => |err| return posix.unexpectedErrno(err),
        }
    };
    defer closeFd(fd);

    return realPathFd(fd, out_buffer);
}

fn dirDeleteFile(
    _: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
) Dir.DeleteFileError!void {
    var path_buffer: [posix.PATH_MAX]u8 = undefined;
    const sub_path_posix = try Threaded.pathToPosix(sub_path, &path_buffer);

    while (true) {
        switch (posix.errno(posix.system.unlinkat(dir.handle, sub_path_posix, 0))) {
            .SUCCESS => return,
            .INTR => continue,
            // Some systems return EPERM when trying to delete a directory;
            // stat to disambiguate from a real permission error.
            .PERM => switch (builtin.os.tag) {
                .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos, .freebsd, .netbsd, .dragonfly, .openbsd, .illumos => {
                    var st = std.mem.zeroes(posix.Stat);
                    while (true) {
                        switch (posix.errno(fstatat_sym(
                            dir.handle,
                            sub_path_posix,
                            &st,
                            posix.AT.SYMLINK_NOFOLLOW,
                        ))) {
                            .SUCCESS => break,
                            .INTR => continue,
                            else => return error.PermissionDenied,
                        }
                    }
                    const is_dir = st.mode & posix.S.IFMT == posix.S.IFDIR;
                    return if (is_dir) error.IsDir else error.PermissionDenied;
                },
                else => return error.PermissionDenied,
            },
            .ACCES => return error.AccessDenied,
            .BUSY => return error.FileBusy,
            .IO => return error.FileSystem,
            .ISDIR => return error.IsDir,
            .LOOP => return error.SymLinkLoop,
            .NAMETOOLONG => return error.NameTooLong,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .NOMEM => return error.SystemResources,
            .ROFS => return error.ReadOnlyFileSystem,
            .ILSEQ => return error.BadPathName,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

/// Convert an `Io.Timeout` to relative nanoseconds without consulting a
/// clock. Deadlines can't be resolved without `now` support; treat them
/// as a short poll, which is valid because futex waits are allowed to
/// wake spuriously (callers must re-check their condition and retry).
fn timeoutToNs(timeout: Io.Timeout) ?u64 {
    return switch (timeout) {
        .none => null,
        .duration => |d| @intCast(@max(0, d.raw.toNanoseconds())),
        .deadline => 10 * std.time.ns_per_ms,
    };
}

fn futexWait(
    userdata: ?*anyopaque,
    ptr: *const u32,
    expected: u32,
    timeout: Io.Timeout,
) Io.Cancelable!void {
    _ = userdata;
    futexWaitInner(ptr, expected, timeoutToNs(timeout));
}

fn futexWaitUncancelable(userdata: ?*anyopaque, ptr: *const u32, expected: u32) void {
    _ = userdata;
    futexWaitInner(ptr, expected, null);
}

fn futexWaitInner(ptr: *const u32, expected: u32, timeout_ns: ?u64) void {
    @branchHint(.cold);

    if (builtin.single_threaded) unreachable; // nobody would ever wake us

    switch (builtin.os.tag) {
        .linux => {
            const linux = std.os.linux;
            var ts_buffer: linux.timespec = undefined;
            const ts: ?*linux.timespec = if (timeout_ns) |ns| ts: {
                ts_buffer = .{
                    .sec = @intCast(ns / std.time.ns_per_s),
                    .nsec = @intCast(ns % std.time.ns_per_s),
                };
                break :ts &ts_buffer;
            } else null;
            const rc = linux.futex_4arg(ptr, .{ .cmd = .WAIT, .private = true }, expected, ts);
            switch (linux.errno(rc)) {
                .SUCCESS => {}, // notified by wake
                .INTR => {}, // caller's responsibility to retry
                .AGAIN => {}, // ptr.* != expected
                .INVAL => {}, // possibly timeout overflow
                .TIMEDOUT => {},
                else => {}, // spurious wakeup; caller retries
            }
        },

        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => {
            const c = std.c;
            const flags: c.UL = .{
                .op = .COMPARE_AND_WAIT,
                .NO_ERRNO = true,
            };
            const us: u32 = us: {
                const ns = timeout_ns orelse break :us 0; // 0 means infinite
                const us = std.math.lossyCast(u32, ns / std.time.ns_per_us);
                break :us if (us == 0) 1 else us;
            };
            const status = c.__ulock_wait(flags, ptr, expected, us);
            if (status >= 0) return;
            switch (@as(c.E, @enumFromInt(-status))) {
                .INTR => {}, // spurious wake
                .FAULT => {}, // futex address paged out; caller retries
                .TIMEDOUT => {},
                else => {}, // spurious wakeup; caller retries
            }
        },

        .freebsd => {
            const flags = @intFromEnum(std.c.UMTX_OP.WAIT_UINT_PRIVATE);
            var tm_size: usize = 0;
            var tm: std.c._umtx_time = undefined;
            var tm_ptr: ?*const std.c._umtx_time = null;
            if (timeout_ns) |ns| {
                tm_ptr = &tm;
                tm_size = @sizeOf(@TypeOf(tm));
                tm.flags = 0; // relative time
                tm.clockid = .MONOTONIC;
                tm.timeout = .{
                    .sec = @intCast(ns / std.time.ns_per_s),
                    .nsec = @intCast(ns % std.time.ns_per_s),
                };
            }
            _ = std.c._umtx_op(
                @intFromPtr(ptr),
                flags,
                @as(c_ulong, expected),
                tm_size,
                @intFromPtr(tm_ptr),
            );
        },

        else => {
            // Portable fallback: futex waits may wake spuriously, so a
            // bounded sleep is a valid (if inefficient) implementation.
            // Contention is not expected in libghostty-vt's threading
            // model, so this is effectively never reached.
            if (@atomicLoad(u32, ptr, .seq_cst) != expected) return;
            const ns = @min(timeout_ns orelse std.time.ns_per_ms, std.time.ns_per_ms);
            const ts: posix.timespec = .{
                .sec = 0,
                .nsec = @intCast(ns),
            };
            _ = posix.system.nanosleep(&ts, null);
        },
    }
}

fn futexWake(userdata: ?*anyopaque, ptr: *const u32, max_waiters: u32) void {
    @branchHint(.cold);
    _ = userdata;

    if (builtin.single_threaded) return; // nothing to wake up

    switch (builtin.os.tag) {
        .linux => {
            const linux = std.os.linux;
            _ = linux.futex_3arg(
                ptr,
                .{ .cmd = .WAKE, .private = true },
                @min(max_waiters, std.math.maxInt(i32)),
            );
        },

        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => {
            const c = std.c;
            const flags: c.UL = .{
                .op = .COMPARE_AND_WAIT,
                .NO_ERRNO = true,
                .WAKE_ALL = max_waiters > 1,
            };
            while (true) {
                const status = c.__ulock_wake(flags, ptr, 0);
                if (status >= 0) return;
                switch (@as(c.E, @enumFromInt(-status))) {
                    .INTR, .CANCELED => continue, // spurious wake
                    else => return,
                }
            }
        },

        .freebsd => {
            _ = std.c._umtx_op(
                @intFromPtr(ptr),
                @intFromEnum(std.c.UMTX_OP.WAKE_PRIVATE),
                @min(max_waiters, std.math.maxInt(c_ulong)),
                0,
                0,
            );
        },

        // Portable fallback waiters poll with a timeout; nothing to do.
        else => {},
    }
}

test "read a file through File.Reader" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    const testing = std.testing;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const contents = "hello minimal test_io\n" ** 100;
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "test.txt",
        .data = contents,
    });

    // Open through our Io. The Dir handle is a plain fd, so it is usable
    // across Io implementations.
    const dir: Dir = .{ .handle = tmp_dir.dir.handle };
    var file = try dir.openFile(test_io, "test.txt", .{});
    defer file.close(test_io);

    // Stat through our Io.
    const stat = try file.stat(test_io);
    try testing.expectEqual(@as(u64, contents.len), stat.size);
    try testing.expectEqual(File.Kind.file, stat.kind);

    // fileLength.
    try testing.expectEqual(@as(u64, contents.len), try file.length(test_io));

    // Read it all back through File.Reader (exercises positional reads
    // and streaming fallbacks).
    var buf: [64]u8 = undefined;
    var reader = file.reader(test_io, &buf);
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try reader.interface.appendRemaining(testing.allocator, &list, .unlimited);
    try testing.expectEqualStrings(contents, list.items);
}

test "seek" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    const testing = std.testing;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "seek.txt",
        .data = "0123456789",
    });

    const dir: Dir = .{ .handle = tmp_dir.dir.handle };
    var file = try dir.openFile(test_io, "seek.txt", .{});
    defer file.close(test_io);

    // Exercise our seek and streaming read implementations directly at
    // the vtable level; the higher-level File.Reader seek plumbing has
    // its own buffering behaviors that are independent of the Io
    // implementation.
    var out: [4]u8 = undefined;
    var slices = [_][]u8{&out};

    try test_io.vtable.fileSeekTo(test_io.userdata, file, 6);
    var n = try file.readStreaming(test_io, &slices);
    try testing.expectEqualStrings("6789", out[0..n]);

    // Seek back relative and re-read.
    try test_io.vtable.fileSeekBy(test_io.userdata, file, -8);
    n = try file.readStreaming(test_io, &slices);
    try testing.expectEqualStrings("2345", out[0..n]);

    // Positional reads are independent of the seek position.
    var pslices = [_][]u8{&out};
    n = try test_io.vtable.fileReadPositional(test_io.userdata, file, &pslices, 1);
    try testing.expectEqualStrings("1234", out[0..n]);
}

test "realPath and deleteFile" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    const testing = std.testing;

    // Only platforms with a real implementation.
    switch (builtin.os.tag) {
        .macos, .ios, .linux, .freebsd => {},
        else => return error.SkipZigTest,
    }

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "real.txt",
        .data = "x",
    });

    const dir: Dir = .{ .handle = tmp_dir.dir.handle };
    var file = try dir.openFile(test_io, "real.txt", .{});
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try file.realPath(test_io, &path_buf)];
    try testing.expect(std.mem.endsWith(u8, path, "real.txt"));
    file.close(test_io);

    // dirRealPathFile via absolute path from cwd.
    var path_buf2: [std.fs.max_path_bytes]u8 = undefined;
    const path2 = path_buf2[0..try Dir.cwd().realPathFile(test_io, path, &path_buf2)];
    try testing.expectEqualStrings(path, path2);

    // Delete it through our Io, verify it is gone.
    try dir.deleteFile(test_io, "real.txt");
    try testing.expectError(error.FileNotFound, dir.openFile(test_io, "real.txt", .{}));
}

test "openFile of a directory returns IsDir" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    const testing = std.testing;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDir(testing.io, "sub", .default_dir);
    const dir: Dir = .{ .handle = tmp_dir.dir.handle };
    try testing.expectError(error.IsDir, dir.openFile(test_io, "sub", .{
        .allow_directory = false,
    }));
}

test "Io.Mutex through TinyIo" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    // Contended and uncontended lock/unlock; exercises the futex ops.
    var mutex: Io.Mutex = .init;
    mutex.lockUncancelable(test_io);
    mutex.unlock(test_io);

    // Wake with no waiters must be a no-op.
    var word: u32 = 0;
    test_io.vtable.futexWake(test_io.userdata, &word, 1);

    // Wait with a non-matching expected value must return immediately.
    test_io.vtable.futexWaitUncancelable(test_io.userdata, &word, 1);
}

test "randomSecure fills with fresh entropy" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    const testing = std.testing;

    var a: [32]u8 = @splat(0);
    var b: [32]u8 = @splat(0);
    try test_io.randomSecure(&a);
    try test_io.randomSecure(&b);

    // Non-zero and non-repeating. A zero fill is what `random` does
    // without a source, which would make every one-time password the
    // same; identical draws would mean the same thing.
    try testing.expect(!std.mem.allEqual(u8, &a, 0));
    try testing.expect(!std.mem.allEqual(u8, &b, 0));
    try testing.expect(!std.mem.eql(u8, &a, &b));

    // Zero-length is a no-op.
    try test_io.randomSecure(a[0..0]);
}

test "unused operations fail gracefully" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    const testing = std.testing;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir: Dir = .{ .handle = tmp_dir.dir.handle };
    try testing.expectError(
        error.NoSpaceLeft,
        dir.createFile(test_io, "nope.txt", .{}),
    );
}

test "openFile edge cases" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    const testing = std.testing;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "edge.txt",
        .data = "edge",
    });
    const dir: Dir = .{ .handle = tmp_dir.dir.handle };

    // File locking is unimplemented and must be reported, not ignored.
    try testing.expectError(error.FileLocksUnsupported, dir.openFile(
        test_io,
        "edge.txt",
        .{ .lock = .shared },
    ));

    // NUL bytes never form a valid POSIX path.
    try testing.expectError(error.BadPathName, dir.openFile(
        test_io,
        "bad\x00path",
        .{},
    ));

    // Paths that can't fit in PATH_MAX must not be silently truncated.
    const long_name = "a" ** (std.fs.max_path_bytes + 1);
    try testing.expectError(error.NameTooLong, dir.openFile(
        test_io,
        long_name,
        .{},
    ));

    // A path component that is a file, not a directory.
    try testing.expectError(error.NotDir, dir.openFile(
        test_io,
        "edge.txt/child",
        .{},
    ));

    // Directories may be opened when allowed (the default) and stat
    // reports their kind.
    try tmp_dir.dir.createDir(testing.io, "subdir", .default_dir);
    var dir_file = try dir.openFile(test_io, "subdir", .{});
    const dir_stat = try dir_file.stat(test_io);
    try testing.expectEqual(File.Kind.directory, dir_stat.kind);
    dir_file.close(test_io);

    // Write modes translate to the right ACCMODE flags; TinyIo can't
    // write but opening for write must succeed.
    var wfile = try dir.openFile(test_io, "edge.txt", .{ .mode = .write_only });
    wfile.close(test_io);
    var rwfile = try dir.openFile(test_io, "edge.txt", .{ .mode = .read_write });
    rwfile.close(test_io);
}

test "openFile symlink handling" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    const testing = std.testing;

    // Platforms where we know both symlink creation (via the testing Io)
    // and O_NOFOLLOW behave as expected.
    switch (builtin.os.tag) {
        .macos, .ios, .linux, .freebsd => {},
        else => return error.SkipZigTest,
    }

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "target.txt",
        .data = "target",
    });
    try tmp_dir.dir.symLink(testing.io, "target.txt", "link.txt", .{});
    const dir: Dir = .{ .handle = tmp_dir.dir.handle };

    // Following symlinks (the default) opens the target...
    var file = try dir.openFile(test_io, "link.txt", .{});
    try testing.expectEqual(@as(u64, "target".len), try file.length(test_io));

    // ...and realPath resolves through the link to the target. This is
    // the property the Kitty graphics path validation relies on.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try file.realPath(test_io, &path_buf)];
    try testing.expect(std.mem.endsWith(u8, path, "target.txt"));
    file.close(test_io);

    // Refusing to follow symlinks fails with SymLinkLoop.
    try testing.expectError(error.SymLinkLoop, dir.openFile(
        test_io,
        "link.txt",
        .{ .follow_symlinks = false },
    ));
}

test "positional reads at and beyond EOF return zero" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    const testing = std.testing;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "eof.txt",
        .data = "0123456789",
    });
    const dir: Dir = .{ .handle = tmp_dir.dir.handle };
    var file = try dir.openFile(test_io, "eof.txt", .{});
    defer file.close(test_io);

    var out: [4]u8 = undefined;
    var slices = [_][]u8{&out};

    // At EOF and past EOF: the vtable contract is "returns 0 if reading
    // at or past the end".
    try testing.expectEqual(@as(usize, 0), try test_io.vtable.fileReadPositional(
        test_io.userdata,
        file,
        &slices,
        10,
    ));
    try testing.expectEqual(@as(usize, 0), try test_io.vtable.fileReadPositional(
        test_io.userdata,
        file,
        &slices,
        9999,
    ));

    // No buffers and only-empty buffers read nothing without a syscall.
    try testing.expectEqual(@as(usize, 0), try test_io.vtable.fileReadPositional(
        test_io.userdata,
        file,
        &.{},
        0,
    ));
    var empty = [_][]u8{ &.{}, &.{} };
    try testing.expectEqual(@as(usize, 0), try test_io.vtable.fileReadPositional(
        test_io.userdata,
        file,
        &empty,
        0,
    ));
}

test "vectored reads scatter across buffers" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    const testing = std.testing;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "vec.txt",
        .data = "0123456789abcdef",
    });
    const dir: Dir = .{ .handle = tmp_dir.dir.handle };
    var file = try dir.openFile(test_io, "vec.txt", .{});
    defer file.close(test_io);

    // Scatter a positional read across multiple buffers, with empty
    // buffers interleaved (they must be skipped).
    var a: [4]u8 = undefined;
    var b: [2]u8 = undefined;
    var c: [6]u8 = undefined;
    var slices = [_][]u8{ &a, &.{}, &b, &c };
    const n = try test_io.vtable.fileReadPositional(
        test_io.userdata,
        file,
        &slices,
        0,
    );
    try testing.expectEqual(@as(usize, 12), n);
    try testing.expectEqualStrings("0123", &a);
    try testing.expectEqualStrings("45", &b);
    try testing.expectEqualStrings("6789ab", &c);

    // More buffers than max_iovecs_len: reads are truncated to the
    // first max_iovecs_len non-empty buffers (partial reads are allowed
    // by the vtable contract; callers retry).
    comptime std.debug.assert(Threaded.max_iovecs_len < 16);
    var bytes: [16][1]u8 = undefined;
    var many: [16][]u8 = undefined;
    for (&many, &bytes) |*s, *byte| s.* = byte;
    const n2 = try test_io.vtable.fileReadPositional(
        test_io.userdata,
        file,
        &many,
        0,
    );
    try testing.expectEqual(@as(usize, Threaded.max_iovecs_len), n2);
    for (bytes[0..n2], "0123456789abcdef"[0..n2]) |got, want| {
        try testing.expectEqual(want, got[0]);
    }
}

test "streaming reads: EndOfStream and scatter" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    const testing = std.testing;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "stream.txt",
        .data = "streaming!",
    });
    const dir: Dir = .{ .handle = tmp_dir.dir.handle };
    var file = try dir.openFile(test_io, "stream.txt", .{});
    defer file.close(test_io);

    // Scatter a streaming read.
    var a: [6]u8 = undefined;
    var b: [4]u8 = undefined;
    var slices = [_][]u8{ &a, &b };
    try testing.expectEqual(@as(usize, 10), try file.readStreaming(test_io, &slices));
    try testing.expectEqualStrings("stream", &a);
    try testing.expectEqualStrings("ing!", &b);

    // Reading again at EOF is a stream end, not a zero-length success.
    try testing.expectError(error.EndOfStream, file.readStreaming(test_io, &slices));

    // Empty destinations read nothing.
    try testing.expectEqual(@as(usize, 0), try file.readStreaming(test_io, &.{}));

    // Seeking beyond EOF is legal; the next streaming read hits EOF.
    try test_io.vtable.fileSeekTo(test_io.userdata, file, 9999);
    try testing.expectError(error.EndOfStream, file.readStreaming(test_io, &slices));

    // And seeking back to zero re-reads from the start.
    try test_io.vtable.fileSeekTo(test_io.userdata, file, 0);
    try testing.expectEqual(@as(usize, 10), try file.readStreaming(test_io, &slices));
    try testing.expectEqualStrings("stream", &a);
}

test "pipes: streaming works, positional and seek are Unseekable" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    const testing = std.testing;

    var fds: [2]posix.fd_t = undefined;
    switch (posix.errno(posix.system.pipe(&fds))) {
        .SUCCESS => {},
        else => return error.SkipZigTest,
    }
    defer closeFd(fds[1]);
    const read_end: File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    defer read_end.close(test_io);

    const msg = "through the pipe";
    try testing.expectEqual(
        @as(isize, msg.len),
        @as(isize, @intCast(posix.system.write(fds[1], msg, msg.len))),
    );

    // Streaming reads work on unseekable files; this is the fallback
    // File.Reader depends on when positional reads report Unseekable.
    var buf: [msg.len]u8 = undefined;
    var slices = [_][]u8{&buf};
    try testing.expectEqual(@as(usize, msg.len), try read_end.readStreaming(test_io, &slices));
    try testing.expectEqualStrings(msg, &buf);

    // Positional reads and seeks must report Unseekable so callers can
    // fall back to streaming.
    try testing.expectError(error.Unseekable, test_io.vtable.fileReadPositional(
        test_io.userdata,
        read_end,
        &slices,
        0,
    ));
    try testing.expectError(error.Unseekable, test_io.vtable.fileSeekTo(
        test_io.userdata,
        read_end,
        0,
    ));
    try testing.expectError(error.Unseekable, test_io.vtable.fileSeekBy(
        test_io.userdata,
        read_end,
        1,
    ));
}

test "operate delegates non-read operations to failing stubs" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    const testing = std.testing;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "w.txt",
        .data = "x",
    });
    const dir: Dir = .{ .handle = tmp_dir.dir.handle };
    var file = try dir.openFile(test_io, "w.txt", .{ .mode = .write_only });
    defer file.close(test_io);

    const result = try test_io.vtable.operate(test_io.userdata, .{
        .file_write_streaming = .{
            .file = file,
            .data = &.{"nope"},
        },
    });
    try testing.expectError(error.InputOutput, result.file_write_streaming);
}

test "dirRealPathFile edge cases" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    const testing = std.testing;

    switch (builtin.os.tag) {
        .macos, .ios, .linux, .freebsd => {},
        else => return error.SkipZigTest,
    }

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "real.txt",
        .data = "x",
    });
    const dir: Dir = .{ .handle = tmp_dir.dir.handle };

    // Resolve the canonical path through an open file for reference.
    var file = try dir.openFile(test_io, "real.txt", .{});
    var want_buf: [std.fs.max_path_bytes]u8 = undefined;
    const want = want_buf[0..try file.realPath(test_io, &want_buf)];
    file.close(test_io);

    // A non-cwd directory handle exercises the open-then-resolve
    // fallback branch rather than libc realpath.
    var got_buf: [std.fs.max_path_bytes]u8 = undefined;
    const got = got_buf[0..try test_io.vtable.dirRealPathFile(
        test_io.userdata,
        dir,
        "real.txt",
        &got_buf,
    )];
    try testing.expectEqualStrings(want, got);

    // Missing paths report FileNotFound (libc realpath branch, via an
    // absolute path anchored at cwd).
    var missing_buf: [std.fs.max_path_bytes]u8 = undefined;
    const missing = std.fmt.bufPrint(&missing_buf, "{s}.missing", .{want}) catch
        return error.SkipZigTest;
    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectError(error.FileNotFound, Dir.cwd().realPathFile(
        test_io,
        missing,
        &out_buf,
    ));

    // libc realpath requires a PATH_MAX-sized output buffer; smaller
    // buffers must error rather than risk truncation.
    var small_buf: [8]u8 = undefined;
    try testing.expectError(error.NameTooLong, Dir.cwd().realPathFile(
        test_io,
        want,
        &small_buf,
    ));
}

test "deleteFile edge cases" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    const testing = std.testing;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const dir: Dir = .{ .handle = tmp_dir.dir.handle };

    // Nonexistent files.
    try testing.expectError(error.FileNotFound, dir.deleteFile(test_io, "missing.txt"));

    // NUL bytes never form a valid POSIX path.
    try testing.expectError(error.BadPathName, dir.deleteFile(test_io, "bad\x00path"));

    // Deleting a directory reports IsDir. On BSD-derived systems
    // (including macOS) unlink returns EPERM for directories, which
    // exercises the stat-based disambiguation path.
    try tmp_dir.dir.createDir(testing.io, "subdir", .default_dir);
    try testing.expectError(error.IsDir, dir.deleteFile(test_io, "subdir"));

    // Deleting a symlink removes the link, not its target.
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "target.txt",
        .data = "x",
    });
    try tmp_dir.dir.symLink(testing.io, "target.txt", "link.txt", .{});
    try dir.deleteFile(test_io, "link.txt");
    var file = try dir.openFile(test_io, "target.txt", .{});
    file.close(test_io);
    try testing.expectError(error.FileNotFound, dir.openFile(test_io, "link.txt", .{}));
}

test "dirClose closes the descriptor" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    const testing = std.testing;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDir(testing.io, "subdir", .default_dir);
    const opened = try tmp_dir.dir.openDir(testing.io, "subdir", .{});

    const dir: Dir = .{ .handle = opened.handle };
    test_io.vtable.dirClose(test_io.userdata, &.{dir});

    // Verify with a raw dup that the fd is gone. We check the errno
    // directly rather than going through our Io so no error path prints
    // "unexpected errno" diagnostics in debug test builds. `dup` rather
    // than `fstat` because glibc has no LFS64 `fstat` symbol, so
    // `fstat_sym` doesn't exist on Linux.
    try testing.expectEqual(posix.E.BADF, posix.errno(posix.system.dup(dir.handle)));
}

test "cancel protection operations are benign" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    const testing = std.testing;

    // There is no async, so cancelation can never be requested.
    try test_io.vtable.checkCancel(test_io.userdata);

    // Swap and restore roundtrip like generic std code does around
    // uninterruptible sections.
    const prev = test_io.vtable.swapCancelProtection(test_io.userdata, .blocked);
    _ = test_io.vtable.swapCancelProtection(test_io.userdata, prev);
    test_io.vtable.recancel(test_io.userdata);

    _ = testing;
}

test "async runs inline; concurrency is unavailable" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    const testing = std.testing;

    const S = struct {
        fn work(x: *u32) u32 {
            x.* += 1;
            return x.*;
        }
    };

    // The task must have executed synchronously, before await.
    var state: u32 = 41;
    var future = test_io.async(S.work, .{&state});
    try testing.expectEqual(@as(u32, 42), state);
    try testing.expectEqual(@as(u32, 42), future.await(test_io));

    // Concurrency must be reported as unavailable, not silently run.
    try testing.expectError(
        error.ConcurrencyUnavailable,
        test_io.concurrent(S.work, .{&state}),
    );
    try testing.expectEqual(@as(u32, 42), state);
}

test "futex timed waits return" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();

    // Nobody wakes this futex, so returning at all proves the timeout
    // (or the spurious-wakeup contract) works.
    var word: u32 = 1;
    try test_io.vtable.futexWait(test_io.userdata, &word, 1, .{
        .duration = .{ .raw = .fromNanoseconds(5 * std.time.ns_per_ms), .clock = .awake },
    });

    // Deadlines can't be resolved without a clock; they degrade to a
    // short poll which must also return.
    try test_io.vtable.futexWait(test_io.userdata, &word, 1, .{
        .deadline = .{ .raw = .fromNanoseconds(1), .clock = .awake },
    });

    // A mismatched expected value returns immediately even with no
    // timeout.
    try test_io.vtable.futexWait(test_io.userdata, &word, 2, .none);

    // Waking more than one waiter takes the wake-all path.
    test_io.vtable.futexWake(test_io.userdata, &word, 2);
    test_io.vtable.futexWake(test_io.userdata, &word, std.math.maxInt(u32));
}

test "Io.Mutex under real thread contention" {
    if (comptime !supported) return error.SkipZigTest;
    if (comptime builtin.single_threaded) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    const testing = std.testing;

    // Hammer a mutex from several threads so waiters actually park in
    // futexWait and get released by futexWake.
    const S = struct {
        const iterations = 10_000;

        fn worker(m: *Io.Mutex, io_: Io, counter: *u64) void {
            for (0..iterations) |_| {
                m.lockUncancelable(io_);
                defer m.unlock(io_);
                counter.* += 1;
            }
        }
    };

    var mutex: Io.Mutex = .init;
    var counter: u64 = 0;

    const thread_count = 4;
    var threads: [thread_count]std.Thread = undefined;
    var spawned: usize = 0;
    defer for (threads[0..spawned]) |t| t.join();
    for (&threads) |*t| {
        t.* = std.Thread.spawn(.{}, S.worker, .{ &mutex, test_io, &counter }) catch
            break;
        spawned += 1;
    }
    for (threads[0..spawned]) |t| t.join();
    spawned = 0;

    try testing.expectEqual(@as(u64, S.iterations * thread_count), counter);
}
