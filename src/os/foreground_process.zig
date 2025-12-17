const std = @import("std");
const builtin = @import("builtin");

const posix = std.posix;

const c = if (builtin.os.tag == .windows) struct {} else @cImport({
    @cInclude("sys/ioctl.h");
    @cInclude("sys/sysctl.h");
    @cInclude("errno.h");
});

// macOS: process name lookup helper (libproc).
extern fn proc_name(pid: c_int, buffer: [*]u8, buffersize: u32) callconv(.c) c_int;

pub fn isAgentCliFromPtyMaster(pty_master_fd: posix.fd_t) bool {
    const pgid = foregroundProcessGroupIdFromPtyMaster(pty_master_fd) orelse return false;
    return isAgentCliPid(pgid);
}

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

    const pgid = foregroundProcessGroupIdFromPtyMaster(pty_master_fd) orelse return null;
    return processName(pgid, buf);
}

pub fn foregroundProcessGroupIdFromPtyMaster(pty_master_fd: posix.fd_t) ?std.c.pid_t {
    if (comptime builtin.os.tag == .windows) return null;
    if (comptime builtin.os.tag == .ios) return null;

    var pgid: std.c.pid_t = 0;
    if (c.ioctl(pty_master_fd, c.TIOCGPGRP, @intFromPtr(&pgid)) < 0) return null;
    if (pgid <= 0) return null;
    return pgid;
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
    const known_prefixes = [_][]const u8{
        // Common binary names (and variants) for the CLIs we care about.
        //
        // Note: these are prefix matches (case-insensitive) because many
        // package managers install with suffixes like `-cli` or `-code`.
        "gemini",
        "gemini-cli",
        "codex",
        "openai-codex",
        "claude",
        "claude-code",
    };

    for (known_prefixes) |k| {
        if (std.ascii.startsWithIgnoreCase(name, k)) return true;
    }

    return false;
}

fn isAgentCliPid(pid: std.c.pid_t) bool {
    var name_buf: [256]u8 = undefined;
    if (processName(pid, name_buf[0..])) |name| {
        if (isAgentCliProcessName(name)) return true;
    }

    var cmdline_buf: [16 * 1024]u8 = undefined;
    const cmdline = processCommandLine(pid, cmdline_buf[0..]) orelse return false;
    return isAgentCliCmdline(cmdline);
}

fn isAgentCliCmdline(cmdline: []const u8) bool {
    return switch (comptime builtin.os.tag) {
        .linux => isAgentCliNullSeparatedArgs(cmdline, null),
        .macos => isAgentCliMacosProcargs(cmdline),
        else => false,
    };
}

fn isAgentCliNullSeparatedArgs(data: []const u8, max_args: ?usize) bool {
    var count: usize = 0;
    var i: usize = 0;
    while (i < data.len) {
        // Skip NUL separators.
        while (i < data.len and data[i] == 0) i += 1;
        if (i >= data.len) break;

        const start = i;
        while (i < data.len and data[i] != 0) i += 1;
        const arg = data[start..i];
        if (arg.len != 0 and isAgentCliArg(arg)) return true;

        count += 1;
        if (max_args) |m| if (count >= m) break;
    }

    return false;
}

fn isAgentCliMacosProcargs(data: []const u8) bool {
    if (data.len < @sizeOf(c_int)) return false;

    // Format: int argc; exec_path\0 ... argv[0]\0 argv[1]\0 ... env...
    const argc: usize = @intCast(std.mem.readInt(
        c_int,
        data[0..@sizeOf(c_int)],
        builtin.cpu.arch.endian(),
    ));
    var i: usize = @sizeOf(c_int);

    // exec path
    const exec_start = i;
    while (i < data.len and data[i] != 0) i += 1;
    if (i > exec_start) {
        const exec_path = data[exec_start..i];
        if (isAgentCliArg(exec_path)) return true;
    }

    // Skip NUL padding to argv region
    while (i < data.len and data[i] == 0) i += 1;

    // Parse argv strings (bounded by argc)
    return isAgentCliNullSeparatedArgs(data[i..], argc);
}

fn isAgentCliArg(arg: []const u8) bool {
    const base = std.fs.path.basename(arg);
    return isAgentCliProcessName(base);
}

fn processCommandLine(pid: std.c.pid_t, buf: []u8) ?[]const u8 {
    if (buf.len == 0) return null;
    if (pid <= 0) return null;

    return switch (comptime builtin.os.tag) {
        .linux => linuxCmdline(pid, buf),
        .macos => macosProcargs(pid, buf),
        else => null,
    };
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

fn linuxCmdline(pid: std.c.pid_t, buf: []u8) ?[]const u8 {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/cmdline", .{pid}) catch return null;

    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    const n = file.readAll(buf) catch return null;
    if (n == 0) return null;
    return buf[0..n];
}

fn macosProcargs(pid: std.c.pid_t, buf: []u8) ?[]const u8 {
    var mib = [_]c_int{
        c.CTL_KERN,
        c.KERN_PROCARGS2,
        @intCast(pid),
    };

    var size: usize = buf.len;
    if (c.sysctl(&mib, mib.len, buf.ptr, &size, null, 0) != 0) return null;
    if (size == 0) return null;
    return buf[0..size];
}
