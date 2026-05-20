//! Code taken from 0.15.2 `std.posix`. See README.md for license and details.
const builtin = @import("builtin");
const std = @import("std");

const native_os = builtin.os.tag;

pub const ChangeCurDirError = error{
    AccessDenied,
    FileSystem,
    SymLinkLoop,
    NameTooLong,
    FileNotFound,
    SystemResources,
    NotDir,
    BadPathName,
    /// WASI-only; file paths must be valid UTF-8.
    InvalidUtf8,
    /// Windows-only; file paths provided by the user must be valid WTF-8.
    /// https://simonsapin.github.io/wtf-8/
    InvalidWtf8,
} || std.posix.UnexpectedError;

/// Changes the current working directory of the calling process.
/// On Windows, `dir_path` should be encoded as [WTF-8](https://simonsapin.github.io/wtf-8/).
/// On WASI, `dir_path` should be encoded as valid UTF-8.
/// On other platforms, `dir_path` is an opaque sequence of bytes with no particular encoding.
pub fn chdir(dir_path: []const u8) ChangeCurDirError!void {
    if (native_os == .wasi and !builtin.link_libc) {
        @compileError("WASI does not support os.chdir");
    } else if (native_os == .windows) {
        var wtf16_dir_path: [std.os.windows.PATH_MAX_WIDE]u16 = undefined;
        if (try std.unicode.checkWtf8ToWtf16LeOverflow(dir_path, &wtf16_dir_path)) {
            return error.NameTooLong;
        }
        const len = try std.unicode.wtf8ToWtf16Le(&wtf16_dir_path, dir_path);
        return chdirW(wtf16_dir_path[0..len]);
    } else {
        const dir_path_c = try std.posix.toPosixPath(dir_path);
        return chdirZ(&dir_path_c);
    }
}

/// Same as `chdir` except the parameter is null-terminated.
/// On Windows, `dir_path` should be encoded as [WTF-8](https://simonsapin.github.io/wtf-8/).
/// On WASI, `dir_path` should be encoded as valid UTF-8.
/// On other platforms, `dir_path` is an opaque sequence of bytes with no particular encoding.
pub fn chdirZ(dir_path: [*:0]const u8) ChangeCurDirError!void {
    if (native_os == .windows) {
        const dir_path_span = std.mem.span(dir_path);
        var wtf16_dir_path: [std.os.windows.PATH_MAX_WIDE]u16 = undefined;
        if (try std.unicode.checkWtf8ToWtf16LeOverflow(dir_path_span, &wtf16_dir_path)) {
            return error.NameTooLong;
        }
        const len = try std.unicode.wtf8ToWtf16Le(&wtf16_dir_path, dir_path_span);
        return chdirW(wtf16_dir_path[0..len]);
    } else if (native_os == .wasi and !builtin.link_libc) {
        return chdir(std.mem.span(dir_path));
    }
    switch (std.posix.errno(std.posix.system.chdir(dir_path))) {
        .SUCCESS => return,
        .ACCES => return error.AccessDenied,
        .FAULT => unreachable,
        .IO => return error.FileSystem,
        .LOOP => return error.SymLinkLoop,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.FileNotFound,
        .NOMEM => return error.SystemResources,
        .NOTDIR => return error.NotDir,
        .ILSEQ => |err| if (native_os == .wasi)
            return error.InvalidUtf8
        else
            return std.posix.unexpectedErrno(err),
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

/// Windows-only. Same as `chdir` except the parameter is WTF16 LE encoded.
pub fn chdirW(dir_path: []const u16) ChangeCurDirError!void {
    std.posix.windows.SetCurrentDirectory(dir_path) catch |err| switch (err) {
        error.NoDevice => return error.FileSystem,
        else => |e| return e,
    };
}
