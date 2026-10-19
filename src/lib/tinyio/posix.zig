//! POSIX impl of TinyIo: plain blocking syscalls cribbed from
//! std.posix and the POSIX impls of `std.Io.Threaded`.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const Threaded = std.Io.Threaded;

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

pub fn randomSecure(buffer: []u8) Io.RandomSecureError!void {
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

pub fn closeFd(fd: posix.fd_t) void {
    // Never retry close on EINTR: POSIX leaves the fd state unspecified
    // and Linux always closes it, so retrying risks closing an unrelated
    // fd opened by another thread.
    _ = posix.system.close(fd);
}

pub fn dirOpenFile(
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

pub fn dirClose(_: ?*anyopaque, dirs: []const Dir) void {
    for (dirs) |dir| closeFd(dir.handle);
}

pub fn fileClose(_: ?*anyopaque, files: []const File) void {
    for (files) |file| closeFd(file.handle);
}

pub fn fileStat(_: ?*anyopaque, file: File) File.StatError!File.Stat {
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

pub fn fileLength(userdata: ?*anyopaque, file: File) File.LengthError!u64 {
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

pub fn fileReadPositional(
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

pub fn fileReadStreaming(
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

pub fn fileSeekBy(_: ?*anyopaque, file: File, offset: i64) File.SeekError!void {
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

pub fn fileSeekTo(_: ?*anyopaque, file: File, offset: u64) File.SeekError!void {
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

pub fn fileRealPath(
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

pub fn dirRealPathFile(
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

pub fn dirDeleteFile(
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

pub fn futexWaitInner(ptr: *const u32, expected: u32, timeout_ns: ?u64) void {
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

pub fn futexWake(userdata: ?*anyopaque, ptr: *const u32, max_waiters: u32) void {
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
