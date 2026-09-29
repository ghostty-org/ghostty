//! TinyIo: a tiny, blocking `std.Io` implementation optimized for
//! binary size.
//!
//! Compared to `std.Io.Threaded`, the binary cost is roughly ~100KB to
//! ~200KB (macOS vs Linux) smaller, and the runtime cost is ~300KB (256KB
//! of TLS plus the ~20KB threaded structure) smaller. On Windows the
//! DLL is ~370KB smaller (ReleaseFast) because Threaded's Windows logic
//! has Winsock, AFD and process creation.
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
//! The platform arms live in `tinyio/`: `posix.zig` is direct syscalls
//! cribbed from Zig's std.posix, and `windows.zig` is direct ntdll and
//! kernel32 calls modeled on the Windows arms of `std.Io.Threaded`, so
//! the library never links Threaded's vtable there either. Shared tests
//! are in `tinyio/test.zig`.

const TinyIo = @This();

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// True if this platform has a real TinyIo implementation. On
/// unsupported platforms `io()` still works but every operation fails
/// like `std.Io.failing`.
pub const supported: bool = switch (builtin.os.tag) {
    .wasi, .freestanding, .other, .uefi => false,
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
    .dirOpenFile = impl.dirOpenFile,
    .dirClose = impl.dirClose,
    .dirRead = Io.noDirRead,
    .dirRealPath = Io.failingDirRealPath,
    .dirRealPathFile = impl.dirRealPathFile,
    .dirDeleteFile = impl.dirDeleteFile,
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

    .fileStat = impl.fileStat,
    .fileLength = impl.fileLength,
    .fileClose = impl.fileClose,
    .fileWritePositional = Io.failingFileWritePositional,
    .fileWriteFileStreaming = Io.noFileWriteFileStreaming,
    .fileWriteFilePositional = Io.noFileWriteFilePositional,
    .fileReadPositional = impl.fileReadPositional,
    .fileSeekBy = impl.fileSeekBy,
    .fileSeekTo = impl.fileSeekTo,
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
    .fileRealPath = impl.fileRealPath,
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

/// The platform arm behind the vtable. Each arm exports the same set of
/// operations; only the selected one is ever analyzed, and `supported`
/// gates the vtable so unsupported targets never resolve either.
const impl = switch (builtin.os.tag) {
    .windows => @import("tinyio/windows.zig"),
    else => @import("tinyio/posix.zig"),
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
    return impl.randomSecure(buffer);
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
            .file_read_streaming = impl.fileReadStreaming(o.file, o.data),
        },

        // Everything else (streaming writes, ioctls, socket receives) is
        // unused by the terminal; fail like `Io.failing` does.
        else => return Io.failingOperate(userdata, operation),
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
    impl.futexWaitInner(ptr, expected, timeoutToNs(timeout));
}

fn futexWaitUncancelable(userdata: ?*anyopaque, ptr: *const u32, expected: u32) void {
    _ = userdata;
    impl.futexWaitInner(ptr, expected, null);
}

fn futexWake(userdata: ?*anyopaque, ptr: *const u32, max_waiters: u32) void {
    return impl.futexWake(userdata, ptr, max_waiters);
}

test {
    _ = @import("tinyio/test.zig");
}
