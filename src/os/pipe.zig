const std = @import("std");
const builtin = @import("builtin");
const windows = @import("windows.zig");
const posix = std.posix;

/// pipe() that works on Windows and POSIX. For POSIX systems, this sets
/// CLOEXEC on the file descriptors.
pub fn pipe() ![2]posix.fd_t {
    switch (builtin.os.tag) {
        else => {
            var fds: [2]posix.fd_t = undefined;
            switch (posix.errno(posix.system.pipe2(&fds, .{ .CLOEXEC = true }))) {
                .SUCCESS => return fds,
                .INVAL => unreachable, // Invalid flags
                .FAULT => unreachable, // Invalid fds pointer
                .NFILE => return error.SystemFdQuotaExceeded,
                .MFILE => return error.ProcessFdQuotaExceeded,
                else => |err| return posix.unexpectedErrno(err),
            }
        },
        .windows => {
            var read: windows.HANDLE = undefined;
            var write: windows.HANDLE = undefined;
            if (windows.exp.kernel32.CreatePipe(&read, &write, null, 0) == 0) {
                return windows.unexpectedError(windows.kernel32.GetLastError());
            }

            return .{ read, write };
        },
    }
}
