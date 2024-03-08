const std = @import("std");
const builtin = @import("builtin");
const windows = @import("os/main.zig").windows;
const winsize = std.os.winsize;

const log = std.log.scoped(.pty);

pub const Pty = switch (builtin.os.tag) {
    .windows => WindowsPty,
    .ios => NullPty,
    else => PosixPty,
};

// A pty implementation that does nothing.
//
// TODO: This should be removed. This is only temporary until we have
// a termio that doesn't use a pty. This isn't used in any user-facing
// artifacts, this is just a stopgap to get compilation to work on iOS.
const NullPty = struct {
    pub const Fd = std.os.fd_t;

    master: Fd,
    slave: Fd,

    pub fn open(size: winsize) !Pty {
        _ = size;
        return .{ .master = 0, .slave = 0 };
    }

    pub fn deinit(self: *Pty) void {
        _ = self;
    }

    pub fn setSize(self: *Pty, size: winsize) !void {
        _ = self;
        _ = size;
    }

    pub fn childPreExec(self: Pty) !void {
        _ = self;
    }
};

/// Linux PTY creation and management. This is just a thin layer on top
/// of Linux syscalls. The caller is responsible for detail-oriented handling
/// of the returned file handles.
const PosixPty = struct {
    pub const Fd = std.os.fd_t;

    const TIOCSCTTY = std.os.T.IOCSCTTY;
    const TIOCSWINSZ = std.os.T.IOCSWINSZ;
    const TIOCGWINSZ = std.os.T.IOCGWINSZ;
    extern "c" fn setsid() std.c.pid_t;
    const c = struct {
        usingnamespace switch (builtin.os.tag) {
            .macos => @cImport({
                @cInclude("sys/ioctl.h"); // ioctl and constants
                @cInclude("util.h"); // openpty()
            }),
            else => @cImport({
                @cInclude("sys/ioctl.h"); // ioctl and constants
                @cInclude("pty.h");
            }),
        };
    };

    /// The file descriptors for the master and slave side of the pty.
    master: Fd,
    slave: Fd,

    /// Open a new PTY with the given initial size.
    pub fn open(size: winsize) !Pty {
        // Need to copy so that it becomes non-const.
        var sizeCopy = size;

        var master_fd: Fd = undefined;
        var slave_fd: Fd = undefined;
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
    pub fn setSize(self: *Pty, size: winsize) !void {
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
};

/// Windows PTY creation and management.
const WindowsPty = struct {
    pub const Fd = windows.HANDLE;

    // Process-wide counter for pipe names
    var pipe_name_counter = std.atomic.Value(u32).init(1);

    out_pipe: windows.HANDLE,
    in_pipe: windows.HANDLE,
    out_pipe_pty: windows.HANDLE,
    in_pipe_pty: windows.HANDLE,
    pseudo_console: windows.exp.HPCON,
    size: winsize,

    /// Open a new PTY with the given initial size.
    pub fn open(size: winsize) !Pty {
        var pty: Pty = undefined;

        var pipe_path_buf: [128]u8 = undefined;
        var pipe_path_buf_w: [128]u16 = undefined;
        const pipe_path = std.fmt.bufPrintZ(
            &pipe_path_buf,
            "\\\\.\\pipe\\LOCAL\\ghostty-pty-{d}-{d}",
            .{
                windows.kernel32.GetCurrentProcessId(),
                pipe_name_counter.fetchAdd(1, .Monotonic),
            },
        ) catch unreachable;

        const pipe_path_w_len = std.unicode.utf8ToUtf16Le(
            &pipe_path_buf_w,
            pipe_path,
        ) catch unreachable;
        pipe_path_buf_w[pipe_path_w_len] = 0;
        const pipe_path_w = pipe_path_buf_w[0..pipe_path_w_len :0];

        const security_attributes = windows.SECURITY_ATTRIBUTES{
            .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
            .bInheritHandle = windows.FALSE,
            .lpSecurityDescriptor = null,
        };

        pty.in_pipe = windows.kernel32.CreateNamedPipeW(
            pipe_path_w.ptr,
            windows.PIPE_ACCESS_OUTBOUND |
                windows.exp.FILE_FLAG_FIRST_PIPE_INSTANCE |
                windows.FILE_FLAG_OVERLAPPED,
            windows.PIPE_TYPE_BYTE,
            1,
            4096,
            4096,
            0,
            &security_attributes,
        );
        if (pty.in_pipe == windows.INVALID_HANDLE_VALUE) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
        errdefer _ = windows.kernel32.CloseHandle(pty.in_pipe);

        var security_attributes_read = security_attributes;
        pty.in_pipe_pty = windows.kernel32.CreateFileW(
            pipe_path_w.ptr,
            windows.GENERIC_READ,
            0,
            &security_attributes_read,
            windows.OPEN_EXISTING,
            windows.FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (pty.in_pipe_pty == windows.INVALID_HANDLE_VALUE) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
        errdefer _ = windows.kernel32.CloseHandle(pty.in_pipe_pty);

        // The in_pipe needs to be created as a named pipe, since anonymous
        // pipes created with CreatePipe do not support overlapped operations,
        // and the IOCP backend of libxev only uses overlapped operations on files.
        //
        // It would be ideal to use CreatePipe here, so that our pipe isn't
        // visible to any other processes.

        // if (windows.exp.kernel32.CreatePipe(&pty.in_pipe_pty, &pty.in_pipe, null, 0) == 0) {
        //     return windows.unexpectedError(windows.kernel32.GetLastError());
        // }
        // errdefer {
        //     _ = windows.kernel32.CloseHandle(pty.in_pipe_pty);
        //     _ = windows.kernel32.CloseHandle(pty.in_pipe);
        // }

        if (windows.exp.kernel32.CreatePipe(&pty.out_pipe, &pty.out_pipe_pty, null, 0) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
        errdefer {
            _ = windows.kernel32.CloseHandle(pty.out_pipe);
            _ = windows.kernel32.CloseHandle(pty.out_pipe_pty);
        }

        try windows.SetHandleInformation(pty.in_pipe, windows.HANDLE_FLAG_INHERIT, 0);
        try windows.SetHandleInformation(pty.in_pipe_pty, windows.HANDLE_FLAG_INHERIT, 0);
        try windows.SetHandleInformation(pty.out_pipe, windows.HANDLE_FLAG_INHERIT, 0);
        try windows.SetHandleInformation(pty.out_pipe_pty, windows.HANDLE_FLAG_INHERIT, 0);

        const result = windows.exp.kernel32.CreatePseudoConsole(
            .{ .X = @intCast(size.ws_col), .Y = @intCast(size.ws_row) },
            pty.in_pipe_pty,
            pty.out_pipe_pty,
            0,
            &pty.pseudo_console,
        );
        if (result != windows.S_OK) return error.Unexpected;

        pty.size = size;
        return pty;
    }

    pub fn deinit(self: *Pty) void {
        _ = windows.kernel32.CloseHandle(self.in_pipe_pty);
        _ = windows.kernel32.CloseHandle(self.in_pipe);
        _ = windows.kernel32.CloseHandle(self.out_pipe_pty);
        _ = windows.kernel32.CloseHandle(self.out_pipe);
        _ = windows.exp.kernel32.ClosePseudoConsole(self.pseudo_console);
        self.* = undefined;
    }

    /// Return the size of the pty.
    pub fn getSize(self: Pty) !winsize {
        return self.size;
    }

    /// Set the size of the pty.
    pub fn setSize(self: *Pty, size: winsize) !void {
        const result = windows.exp.kernel32.ResizePseudoConsole(
            self.pseudo_console,
            .{ .X = @intCast(size.ws_col), .Y = @intCast(size.ws_row) },
        );

        if (result != windows.S_OK) return error.ResizeFailed;
        self.size = size;
    }
};

test {
    const testing = std.testing;
    var ws: winsize = .{
        .ws_row = 50,
        .ws_col = 80,
        .ws_xpixel = 1,
        .ws_ypixel = 1,
    };

    var pty = try Pty.open(ws);
    defer pty.deinit();

    // Initialize size should match what we gave it
    try testing.expectEqual(ws, try pty.getSize());

    // Can set and read new sizes
    ws.ws_row *= 2;
    try pty.setSize(ws);
    try testing.expectEqual(ws, try pty.getSize());
}
