//! Linux PTY creation and management. This is just a thin layer on top
//! of Linux syscalls. The caller is responsible for detail-oriented handling
//! of the returned file handles.
const Pty = @This();

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const fd_t = std.os.fd_t;

const c = switch (builtin.os.tag) {
    .macos => @cImport({
        @cInclude("sys/ioctl.h"); // ioctl and constants
        @cInclude("util.h"); // openpty()
    }),
    else => @cImport({
        @cInclude("sys/ioctl.h"); // ioctl and constants
        @cInclude("pty.h");
    }),
};

const log = std.log.scoped(.pty);

// https://github.com/ziglang/zig/issues/13277
// Once above is fixed, use `c.TIOCSCTTY`
const TIOCSCTTY = if (builtin.os.tag == .macos) 536900705 else c.TIOCSCTTY;
const TIOCSWINSZ = if (builtin.os.tag == .macos) 2148037735 else c.TIOCSWINSZ;
const TIOCGWINSZ = if (builtin.os.tag == .macos) 1074295912 else c.TIOCGWINSZ;

/// Redeclare this winsize struct so we can just use a Zig struct. This
/// layout should be correct on all tested platforms. The defaults on this
/// are some reasonable screen size but you should probably not use them.
const winsize = extern struct {
    ws_row: u16 = 100,
    ws_col: u16 = 80,
    ws_xpixel: u16 = 800,
    ws_ypixel: u16 = 600,
};

pub extern "c" fn setsid() std.c.pid_t;

/// The file descriptors for the master and slave side of the pty.
master: fd_t,
slave: fd_t,

/// Open a new PTY with the given initial size.
pub fn open(size: winsize) !Pty {
    // Need to copy so that it becomes non-const.
    var sizeCopy = size;

    var master_fd: fd_t = undefined;
    var slave_fd: fd_t = undefined;
    if (c.openpty(
        &master_fd,
        &slave_fd,
        null,
        null,
        @ptrCast(&sizeCopy),
    ) < 0)
        return error.OpenptyFailed;
    errdefer {
        _ = std.os.system.close(master_fd);
        _ = std.os.system.close(slave_fd);
    }

    // Enable UTF-8 mode. I think this is on by default on Linux but it
    // is NOT on by default on macOS so we ensure that it is always set.
    var attrs: c.termios = undefined;
    if (c.tcgetattr(master_fd, &attrs) != 0)
        return error.OpenptyFailed;
    attrs.c_iflag |= c.IUTF8;
    if (c.tcsetattr(master_fd, c.TCSANOW, &attrs) != 0)
        return error.OpenptyFailed;

    return Pty{
        .master = master_fd,
        .slave = slave_fd,
    };
}

pub fn deinit(self: *Pty) void {
    _ = std.os.system.close(self.master);
    _ = std.os.system.close(self.slave);
    self.* = undefined;
}

/// Return the size of the pty.
pub fn getSize(self: Pty) !winsize {
    var ws: winsize = undefined;
    if (c.ioctl(self.master, TIOCGWINSZ, @intFromPtr(&ws)) < 0)
        return error.IoctlFailed;

    return ws;
}

/// Set the size of the pty.
pub fn setSize(self: Pty, size: winsize) !void {
    if (c.ioctl(self.master, TIOCSWINSZ, @intFromPtr(&size)) < 0)
        return error.IoctlFailed;
}

/// This should be called prior to exec in the forked child process
/// in order to setup the tty properly.
pub fn childPreExec(self: Pty) !void {
    // Create a new process group
    if (setsid() < 0) return error.ProcessGroupFailed;

    // Set controlling terminal
    switch (std.os.system.getErrno(c.ioctl(self.slave, TIOCSCTTY, @as(c_ulong, 0)))) {
        .SUCCESS => {},
        else => |err| {
            log.err("error setting controlling terminal errno={}", .{err});
            return error.SetControllingTerminalFailed;
        },
    }

    // Can close master/slave pair now
    std.os.close(self.slave);
    std.os.close(self.master);

    // TODO: reset signals
}

test {
    var ws: winsize = .{
        .ws_row = 50,
        .ws_col = 80,
        .ws_xpixel = 1,
        .ws_ypixel = 1,
    };

    var pty = try open(ws);
    defer pty.deinit();

    // Initialize size should match what we gave it
    try testing.expectEqual(ws, try pty.getSize());

    // Can set and read new sizes
    ws.ws_row *= 2;
    try pty.setSize(ws);
    try testing.expectEqual(ws, try pty.getSize());
}
