//! Code taken from 0.15.2 and `std.fs.file`. See README.md for license and
//! details.
const std = @import("std");

pub const PipeError = error{
    SystemFdQuotaExceeded,
    ProcessFdQuotaExceeded,
} || std.posix.UnexpectedError;

pub fn close(fd: std.posix.fd_t) void {
    switch (std.posix.errno(std.posix.system.close(fd))) {
        .BADF => unreachable, // Always a race condition
        else => {}, // Includes EINTR, see std.posix source in 0.15.2
    }
}

pub fn pipe() PipeError![2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    switch (std.posix.errno(std.posix.system.pipe(&fds))) {
        .SUCCESS => return fds,
        .INVAL => unreachable, // Invalid parameters to pipe()
        .FAULT => unreachable, // Invalid fds pointer
        .NFILE => return error.SystemFdQuotaExceeded,
        .MFILE => return error.ProcessFdQuotaExceeded,
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

pub fn pipe2(flags: std.posix.O) PipeError![2]std.posix.fd_t {
    if (@TypeOf(std.posix.system.pipe2) != void) {
        var fds: [2]std.posix.fd_t = undefined;
        switch (std.posix.errno(std.posix.system.pipe2(&fds, flags))) {
            .SUCCESS => return fds,
            .INVAL => unreachable, // Invalid flags
            .FAULT => unreachable, // Invalid fds pointer
            .NFILE => return error.SystemFdQuotaExceeded,
            .MFILE => return error.ProcessFdQuotaExceeded,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }

    const fds: [2]std.posix.fd_t = try pipe();
    errdefer {
        close(fds[0]);
        close(fds[1]);
    }

    // https://github.com/ziglang/zig/issues/18882
    if (@as(u32, @bitCast(flags)) == 0)
        return fds;

    // CLOEXEC is special, it's a file descriptor flag and must be set using
    // F.SETFD.
    if (flags.CLOEXEC) {
        for (fds) |fd| {
            switch (std.posix.errno(std.posix.system.fcntl(fd, std.posix.F.SETFD, @as(u32, std.posix.FD_CLOEXEC)))) {
                .SUCCESS => {},
                .INVAL => unreachable, // Invalid flags
                .BADF => unreachable, // Always a race condition
                else => |err| return std.posix.unexpectedErrno(err),
            }
        }
    }

    const new_flags: u32 = f: {
        var new_flags = flags;
        new_flags.CLOEXEC = false;
        break :f @bitCast(new_flags);
    };
    // Set every other flag affecting the file status using F.SETFL.
    if (new_flags != 0) {
        for (fds) |fd| {
            switch (std.posix.errno(std.posix.system.fcntl(fd, std.posix.F.SETFL, new_flags))) {
                .SUCCESS => {},
                .INVAL => unreachable, // Invalid flags
                .BADF => unreachable, // Always a race condition
                else => |err| return std.posix.unexpectedErrno(err),
            }
        }
    }

    return fds;
}
