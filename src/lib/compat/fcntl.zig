//! Code taken from 0.15.2 `std.posix`. See README.md for license and details.
const std = @import("std");

pub const FcntlError = error{
    PermissionDenied,
    FileBusy,
    ProcessFdQuotaExceeded,
    Locked,
    DeadLock,
    LockedRegionLimitExceeded,
} || std.posix.UnexpectedError;

pub fn fcntl(fd: std.posix.fd_t, cmd: i32, arg: usize) FcntlError!usize {
    while (true) {
        const rc = std.posix.system.fcntl(fd, cmd, arg);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN, .ACCES => return error.Locked,
            .BADF => unreachable,
            .BUSY => return error.FileBusy,
            .INVAL => unreachable, // invalid parameters
            .PERM => return error.PermissionDenied,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NOTDIR => unreachable, // invalid parameter
            .DEADLK => return error.DeadLock,
            .NOLCK => return error.LockedRegionLimitExceeded,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}
