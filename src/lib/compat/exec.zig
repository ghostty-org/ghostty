//! Code taken from 0.15.2 `std.posix`. See README.md for license and details.
const builtin = @import("builtin");
const std = @import("std");

const env = @import("env.zig");

const native_os = builtin.os.tag;

pub const ExecveError = error{
    SystemResources,
    AccessDenied,
    PermissionDenied,
    InvalidExe,
    FileSystem,
    IsDir,
    FileNotFound,
    NotDir,
    FileBusy,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    NameTooLong,
} || std.posix.UnexpectedError;

pub const Arg0Expand = enum {
    expand,
    no_expand,
};

/// This function ignores PATH environment variable. See `execvpeZ` for that.
pub fn execveZ(
    path: [*:0]const u8,
    child_argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) ExecveError {
    switch (std.posix.errno(std.posix.system.execve(path, child_argv, envp))) {
        .SUCCESS => unreachable,
        .FAULT => unreachable,
        .@"2BIG" => return error.SystemResources,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NAMETOOLONG => return error.NameTooLong,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOMEM => return error.SystemResources,
        .ACCES => return error.AccessDenied,
        .PERM => return error.PermissionDenied,
        .INVAL => return error.InvalidExe,
        .NOEXEC => return error.InvalidExe,
        .IO => return error.FileSystem,
        .LOOP => return error.FileSystem,
        .ISDIR => return error.IsDir,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .TXTBSY => return error.FileBusy,
        else => |err| switch (native_os) {
            .macos, .ios, .tvos, .watchos, .visionos => switch (err) {
                .BADEXEC => return error.InvalidExe,
                .BADARCH => return error.InvalidExe,
                else => return std.posix.unexpectedErrno(err),
            },
            .linux => switch (err) {
                .LIBBAD => return error.InvalidExe,
                else => return std.posix.unexpectedErrno(err),
            },
            else => return std.posix.unexpectedErrno(err),
        },
    }
}

/// Like `execvpeZ` except if `arg0_expand` is `.expand`, then `argv` is mutable,
/// and `argv[0]` is expanded to be the same absolute path that is passed to the execve syscall.
/// If this function returns with an error, `argv[0]` will be restored to the value it was when it was passed in.
pub fn execvpeZ_expandArg0(
    comptime arg0_expand: Arg0Expand,
    file: [*:0]const u8,
    child_argv: switch (arg0_expand) {
        .expand => [*:null]?[*:0]const u8,
        .no_expand => [*:null]const ?[*:0]const u8,
    },
    envp: [*:null]const ?[*:0]const u8,
) ExecveError {
    const file_slice = std.mem.sliceTo(file, 0);
    if (std.mem.indexOfScalar(u8, file_slice, '/') != null) return execveZ(file, child_argv, envp);

    const PATH = env.getenvZ("PATH") orelse "/usr/local/bin:/bin/:/usr/bin";
    // Use of PATH_MAX here is valid as the path_buf will be passed
    // directly to the operating system in execveZ.
    var path_buf: [std.posix.PATH_MAX]u8 = undefined;
    var it = std.mem.tokenizeScalar(u8, PATH, ':');
    var seen_eacces = false;
    var err: ExecveError = error.FileNotFound;

    // In case of expanding arg0 we must put it back if we return with an error.
    const prev_arg0 = child_argv[0];
    defer switch (arg0_expand) {
        .expand => child_argv[0] = prev_arg0,
        .no_expand => {},
    };

    while (it.next()) |search_path| {
        const path_len = search_path.len + file_slice.len + 1;
        if (path_buf.len < path_len + 1) return error.NameTooLong;
        @memcpy(path_buf[0..search_path.len], search_path);
        path_buf[search_path.len] = '/';
        @memcpy(path_buf[search_path.len + 1 ..][0..file_slice.len], file_slice);
        path_buf[path_len] = 0;
        const full_path = path_buf[0..path_len :0].ptr;
        switch (arg0_expand) {
            .expand => child_argv[0] = full_path,
            .no_expand => {},
        }
        err = execveZ(full_path, child_argv, envp);
        switch (err) {
            error.AccessDenied => seen_eacces = true,
            error.FileNotFound, error.NotDir => {},
            else => |e| return e,
        }
    }
    if (seen_eacces) return error.AccessDenied;
    return err;
}

/// This function also uses the PATH environment variable to get the full path to the executable.
/// If `file` is an absolute path, this is the same as `execveZ`.
pub fn execvpeZ(
    file: [*:0]const u8,
    argv_ptr: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) ExecveError {
    return execvpeZ_expandArg0(.no_expand, file, argv_ptr, envp);
}

/// Get an environment variable.
/// See also `getenvZ`.
pub fn getenv(key: []const u8) ?[:0]const u8 {
    if (native_os == .windows) {
        @compileError("std.posix.getenv is unavailable for Windows because environment strings are in WTF-16 format. See std.process.getEnvVarOwned for a cross-platform API or std.process.getenvW for a Windows-specific API.");
    }
    if (std.mem.indexOfScalar(u8, key, '=') != null) {
        return null;
    }
    if (builtin.link_libc) {
        var ptr = std.c.environ;
        while (ptr[0]) |line| : (ptr += 1) {
            var line_i: usize = 0;
            while (line[line_i] != 0) : (line_i += 1) {
                if (line_i == key.len) break;
                if (line[line_i] != key[line_i]) break;
            }
            if ((line_i != key.len) or (line[line_i] != '=')) continue;

            return std.mem.sliceTo(line + line_i + 1, 0);
        }
        return null;
    }
    if (native_os == .wasi) {
        @compileError("std.posix.getenv is unavailable for WASI. See std.process.getEnvMap or std.process.getEnvVarOwned for a cross-platform API.");
    }
    if (env.os_environ) |environ| {
        for (environ) |ptr| {
            var line_i: usize = 0;
            while (ptr[line_i] != 0) : (line_i += 1) {
                if (line_i == key.len) break;
                if (ptr[line_i] != key[line_i]) break;
            }
            if ((line_i != key.len) or (ptr[line_i] != '=')) continue;

            return std.mem.sliceTo(ptr + line_i + 1, 0);
        }
    }
    return null;
}
