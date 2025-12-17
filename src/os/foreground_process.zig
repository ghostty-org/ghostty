const std = @import("std");
const builtin = @import("builtin");

const posix = std.posix;

const c = if (builtin.os.tag == .windows) struct {} else @cImport({
    @cInclude("sys/ioctl.h");
});

// macOS: process name lookup helper (libproc).
extern fn proc_name(pid: c_int, buffer: [*]u8, buffersize: u32) callconv(.c) c_int;

/// Returns the basename of the process that is currently in the foreground
/// process group for the PTY associated with `pty_master_fd`.
///
/// This is best-effort: if we can't query it on the current platform (or due to
/// permissions), this returns `null` rather than erroring.
pub fn foregroundProcessNameFromPtyMaster(
    pty_master_fd: posix.fd_t,
    buf: []u8,
) ?[]const u8 {
    if (comptime builtin.os.tag == .windows) return null;
    if (comptime builtin.os.tag == .ios) return null;
    if (buf.len == 0) return null;

    var pgid: std.c.pid_t = 0;
    if (c.ioctl(pty_master_fd, c.TIOCGPGRP, @intFromPtr(&pgid)) < 0) return null;
    if (pgid <= 0) return null;

    return processName(pgid, buf);
}

/// Returns the basename of the process with the given pid, if it can be
/// determined.
///
/// The returned slice is always a subslice of `buf`.
pub fn processName(pid: std.c.pid_t, buf: []u8) ?[]const u8 {
    if (buf.len == 0) return null;
    if (pid <= 0) return null;

    return switch (comptime builtin.os.tag) {
        .linux => linuxProcessName(pid, buf),
        .macos => macosProcessName(pid, buf),
        else => null,
    };
}

pub fn isAgentCliProcessName(name: []const u8) bool {
    // Keep this intentionally small and explicit; we'll expand to per-agent
    // icons later.
    const known = [_][]const u8{
        "gemini",
        "codex",
        "claude",
    };

    for (known) |k| {
        if (std.ascii.eqlIgnoreCase(name, k)) return true;
    }

    return false;
}

fn linuxProcessName(pid: std.c.pid_t, buf: []u8) ?[]const u8 {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{pid}) catch return null;

    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    const n = file.readAll(buf) catch return null;
    if (n == 0) return null;

    return std.mem.trimRight(u8, buf[0..n], "\r\n");
}

fn macosProcessName(pid: std.c.pid_t, buf: []u8) ?[]const u8 {
    const rc = proc_name(@intCast(pid), buf.ptr, @intCast(buf.len));
    if (rc <= 0) return null;

    return std.mem.sliceTo(buf[0..@intCast(rc)], 0);
}
