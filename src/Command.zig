//! Command launches sub-processes. This is an alternate implementation to the
//! Zig std.process.Child since at the time of authoring this, std.process.Child
//! didn't support the options necessary to spawn a shell attached to a pty.
//!
//! Consequently, I didn't implement a lot of features that std.process.Child
//! supports because we didn't need them. Cross-platform subprocessing is not
//! a trivial thing to implement (I've done it in three separate languages now)
//! so if we want to replatform onto std.process.Child I'd love to do that.
//! This was just the fastest way to get something built.
//!
//! Issues with std.process.Child:
//!
//!   * No pre_exec callback for logic after fork but before exec.
//!   * posix_spawn is used for Mac, but doesn't support the necessary
//!     features for tty setup.
//!
const Command = @This();

const std = @import("std");
const builtin = @import("builtin");
const configpkg = @import("config.zig");
const global_state = &@import("global.zig").state;
const internal_os = @import("os/main.zig");
const windows = internal_os.windows;
const TempDir = internal_os.TempDir;
const mem = std.mem;
const linux = std.os.linux;
const posix = std.posix;
const debug = std.debug;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const File = std.fs.File;
const EnvMap = std.process.EnvMap;
const apprt = @import("apprt.zig");

/// Function prototype for a function executed /in the child process/ after the
/// fork, but before exec'ing the command. If the function returns a u8, the
/// child process will be exited with that error code.
const PreExecFn = fn (*Command) ?u8;

/// Allowable set of errors that can be returned by a post fork function. Any
/// errors will result in the failure to create the surface.
pub const PostForkError = error{PostForkError};

/// Function prototype for a function executed /in the parent process/
/// after the fork.
const PostForkFn = fn (*Command) PostForkError!void;

/// Path to the command to run. This doesn't have to be an absolute path,
/// because use exec functions that search the PATH, if necessary.
///
/// This field is null-terminated to avoid a copy for the sake of
/// adding a null terminator since POSIX systems are so common.
path: [:0]const u8,

/// Command-line arguments. It is the responsibility of the caller to set
/// args[0] to the command. If args is empty then args[0] will automatically
/// be set to equal path.
args: []const [:0]const u8,

/// Environment variables for the child process. If this is null, inherits
/// the environment variables from this process. These are the exact
/// environment variables to set; these are /not/ merged.
env: ?*const EnvMap = null,

/// Working directory to change to in the child process. If not set, the
/// working directory of the calling process is preserved.
cwd: ?[]const u8 = null,

/// The file handle to set for stdin/out/err. If this isn't set, we do
/// nothing explicitly so it is up to the behavior of the operating system.
stdin: ?File = null,
stdout: ?File = null,
stderr: ?File = null,

/// If set, this will be executed /in the child process/ after fork but
/// before exec. This is useful to setup some state in the child before the
/// exec process takes over, such as signal handlers, setsid, setuid, etc.
os_pre_exec: ?*const PreExecFn,

/// If set, this will be executed /in the child process/ after fork but
/// before exec. This is useful to setup some state in the child before the
/// exec process takes over, such as signal handlers, setsid, setuid, etc.
rt_pre_exec: ?*const PreExecFn,

/// Configuration information needed by the apprt pre exec function. Note
/// that this should be a trivially copyable struct and not require any
/// allocation/deallocation.
rt_pre_exec_info: RtPreExecInfo,

/// If set, this will be executed in the /in the parent process/ after the fork.
rt_post_fork: ?*const PostForkFn,

/// Configuration information needed by the apprt post fork function. Note
/// that this should be a trivially copyable struct and not require any
/// allocation/deallocation.
rt_post_fork_info: RtPostForkInfo,

/// If set, then the process will be created attached to this pseudo console.
/// `stdin`, `stdout`, and `stderr` will be ignored if set.
pseudo_console: if (builtin.os.tag == .windows) ?windows.exp.HPCON else void =
    if (builtin.os.tag == .windows) null else {},

/// User data that is sent to the callback. Set with setData and getData
/// for a more user-friendly API.
data: ?*anyopaque = null,

/// Process ID is set after start is called.
pid: ?posix.pid_t = null,

/// The various methods a process may exit.
pub const Exit = if (builtin.os.tag == .windows) union(enum) {
    Exited: u32,
} else union(enum) {
    /// Exited by normal exit call, value is exit status
    Exited: u8,

    /// Exited by a signal, value is the signal
    Signal: u32,

    /// Exited by a stop signal, value is signal
    Stopped: u32,

    /// Unknown exit reason, value is the status from waitpid
    Unknown: u32,

    pub fn init(status: u32) Exit {
        return if (posix.W.IFEXITED(status))
            Exit{ .Exited = posix.W.EXITSTATUS(status) }
        else if (posix.W.IFSIGNALED(status))
            Exit{ .Signal = posix.W.TERMSIG(status) }
        else if (posix.W.IFSTOPPED(status))
            Exit{ .Stopped = posix.W.STOPSIG(status) }
        else
            Exit{ .Unknown = status };
    }
};

/// Configuration information needed by the apprt pre exec function. Note
/// that this should be a trivially copyable struct and not require any
/// allocation/deallocation.
pub const RtPreExecInfo = if (@hasDecl(apprt.runtime, "pre_exec")) apprt.runtime.pre_exec.PreExecInfo else struct {
    pub inline fn init(_: *const configpkg.Config) @This() {
        return .{};
    }
};

/// Configuration information needed by the apprt post fork function. Note
/// that this should be a trivially copyable struct and not require any
/// allocation/deallocation.
pub const RtPostForkInfo = if (@hasDecl(apprt.runtime, "post_fork")) apprt.runtime.post_fork.PostForkInfo else struct {
    pub inline fn init(_: *const configpkg.Config) @This() {
        return .{};
    }
};

/// Start the subprocess. This returns immediately once the child is started.
///
/// After this is successful, self.pid is available.
pub fn start(self: *Command, alloc: Allocator) !void {
    // Use an arena allocator for the temporary allocations we need in this func.
    // IMPORTANT: do all allocation prior to the fork(). I believe it is undefined
    // behavior if you malloc between fork and exec. The source of the Zig
    // stdlib seems to verify this as well as Go.
    var arena_allocator = std.heap.ArenaAllocator.init(alloc);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    switch (builtin.os.tag) {
        .windows => try self.startWindows(arena),
        else => try self.startPosix(arena),
    }
}

fn startPosix(self: *Command, arena: Allocator) !void {
    // Null-terminate all our arguments
    const argsZ = try arena.allocSentinel(?[*:0]const u8, self.args.len, null);
    for (self.args, 0..) |arg, i| argsZ[i] = arg.ptr;

    // Determine our env vars
    const envp = if (self.env) |env_map|
        (try createNullDelimitedEnvMap(arena, env_map)).ptr
    else if (builtin.link_libc)
        std.c.environ
    else
        @compileError("missing env vars");

    // Fork.
    const pid = try posix.fork();

    if (pid != 0) {
        // Parent, return immediately.
        self.pid = @intCast(pid);
        if (self.rt_post_fork) |f| try f(self);
        return;
    }

    // We are the child.

    // Setup our file descriptors for std streams.
    if (self.stdin) |f| setupFd(f.handle, posix.STDIN_FILENO) catch
        return error.ExecFailedInChild;
    if (self.stdout) |f| setupFd(f.handle, posix.STDOUT_FILENO) catch
        return error.ExecFailedInChild;
    if (self.stderr) |f| setupFd(f.handle, posix.STDERR_FILENO) catch
        return error.ExecFailedInChild;

    // Setup our working directory
    if (self.cwd) |cwd| posix.chdir(cwd) catch {
        // This can fail if we don't have permission to go to
        // this directory or if due to race conditions it doesn't
        // exist or any various other reasons. We don't want to
        // crash the entire process if this fails so we ignore it.
        // We don't log because that'll show up in the output.
    };

    // Restore any rlimits that were set by Ghostty. This might fail but
    // any failures are ignored (its best effort).
    global_state.rlimits.restore();

    // If there are pre exec callbacks, call them now.
    if (self.os_pre_exec) |f| if (f(self)) |exitcode| posix.exit(exitcode);
    if (self.rt_pre_exec) |f| if (f(self)) |exitcode| posix.exit(exitcode);

    // Finally, replace our process.
    // Note: we must use the "p"-variant of exec here because we
    // do not guarantee our command is looked up already in the path.
    const err = posix.execvpeZ(self.path, argsZ, envp);

    // If we are executing this code, the exec failed. We're in the
    // child process so there isn't much we can do. We try to output
    // something reasonable. Its important to note we MUST NOT return
    // any other error condition from here on out.
    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;
    switch (err) {
        error.FileNotFound => stderr.print(
            \\Requested executable not found. Please verify the command is on
            \\the PATH and try again.
            \\
        ,
            .{},
        ) catch {},

        else => stderr.print(
            \\exec syscall failed with unexpected error: {}
            \\
        ,
            .{err},
        ) catch {},
    }
    stderr.flush() catch {};

    // We return a very specific error that can be detected to determine
    // we're in the child.
    return error.ExecFailedInChild;
}

fn startWindows(self: *Command, arena: Allocator) !void {
    const application_w = try std.unicode.utf8ToUtf16LeAllocZ(arena, self.path);
    const cwd_w = if (self.cwd) |cwd| try std.unicode.utf8ToUtf16LeAllocZ(arena, cwd) else null;
    const command_line_w = if (self.args.len > 0) b: {
        const command_line = try windowsCreateCommandLine(arena, self.args);
        break :b try std.unicode.utf8ToUtf16LeAllocZ(arena, command_line);
    } else null;
    const env_w = if (self.env) |env_map| try createWindowsEnvBlock(arena, env_map) else null;

    const any_null_fd = self.stdin == null or self.stdout == null or self.stderr == null;
    const null_fd = if (any_null_fd) try windows.OpenFile(
        &[_]u16{ '\\', 'D', 'e', 'v', 'i', 'c', 'e', '\\', 'N', 'u', 'l', 'l' },
        .{
            .access_mask = windows.GENERIC_READ | windows.SYNCHRONIZE,
            .share_access = windows.FILE_SHARE_READ,
            .creation = windows.OPEN_EXISTING,
        },
    ) else null;
    defer if (null_fd) |fd| posix.close(fd);

    // TODO: In the case of having FDs instead of pty, need to set up
    // attributes such that the child process only inherits these handles,
    // then set bInheritsHandles below.

    const attribute_list, const stdin, const stdout, const stderr = if (self.pseudo_console) |pseudo_console| b: {
        var attribute_list_size: usize = undefined;
        _ = windows.exp.kernel32.InitializeProcThreadAttributeList(
            null,
            1,
            0,
            &attribute_list_size,
        );

        const attribute_list_buf = try arena.alloc(u8, attribute_list_size);
        if (windows.exp.kernel32.InitializeProcThreadAttributeList(
            attribute_list_buf.ptr,
            1,
            0,
            &attribute_list_size,
        ) == 0) return windows.unexpectedError(windows.kernel32.GetLastError());

        if (windows.exp.kernel32.UpdateProcThreadAttribute(
            attribute_list_buf.ptr,
            0,
            windows.exp.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
            pseudo_console,
            @sizeOf(windows.exp.HPCON),
            null,
            null,
        ) == 0) return windows.unexpectedError(windows.kernel32.GetLastError());

        break :b .{ attribute_list_buf.ptr, null, null, null };
    } else b: {
        const stdin = if (self.stdin) |f| f.handle else null_fd.?;
        const stdout = if (self.stdout) |f| f.handle else null_fd.?;
        const stderr = if (self.stderr) |f| f.handle else null_fd.?;
        break :b .{ null, stdin, stdout, stderr };
    };

    var startup_info_ex = windows.exp.STARTUPINFOEX{
        .StartupInfo = .{
            .cb = if (attribute_list != null) @sizeOf(windows.exp.STARTUPINFOEX) else @sizeOf(windows.STARTUPINFOW),
            .hStdError = stderr,
            .hStdOutput = stdout,
            .hStdInput = stdin,
            .dwFlags = windows.STARTF_USESTDHANDLES,
            .lpReserved = null,
            .lpDesktop = null,
            .lpTitle = null,
            .dwX = 0,
            .dwY = 0,
            .dwXSize = 0,
            .dwYSize = 0,
            .dwXCountChars = 0,
            .dwYCountChars = 0,
            .dwFillAttribute = 0,
            .wShowWindow = 0,
            .cbReserved2 = 0,
            .lpReserved2 = null,
        },
        .lpAttributeList = attribute_list,
    };

    var flags: windows.DWORD = windows.exp.CREATE_UNICODE_ENVIRONMENT;
    if (attribute_list != null) flags |= windows.exp.EXTENDED_STARTUPINFO_PRESENT;

    var process_information: windows.PROCESS_INFORMATION = undefined;
    if (windows.exp.kernel32.CreateProcessW(
        application_w.ptr,
        if (command_line_w) |w| w.ptr else null,
        null,
        null,
        windows.TRUE,
        flags,
        if (env_w) |w| w.ptr else null,
        if (cwd_w) |w| w.ptr else null,
        @ptrCast(&startup_info_ex.StartupInfo),
        &process_information,
    ) == 0) return windows.unexpectedError(windows.kernel32.GetLastError());

    self.pid = process_information.hProcess;
}

fn setupFd(src: File.Handle, target: i32) !void {
    switch (builtin.os.tag) {
        .linux => {
            // We use dup3 so that we can clear CLO_ON_EXEC. We do NOT want this
            // file descriptor to be closed on exec since we're exactly exec-ing after
            // this.
            while (true) {
                const rc = linux.dup3(src, target, 0);
                switch (posix.errno(rc)) {
                    .SUCCESS => break,
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
                    else => |err| return posix.unexpectedErrno(err),
                }
            }
        },
        .freebsd, .ios, .macos => {
            // Mac doesn't support dup3 so we use dup2. We purposely clear
            // CLO_ON_EXEC for this fd.
            const flags = try posix.fcntl(src, posix.F.GETFD, 0);
            if (flags & posix.FD_CLOEXEC != 0) {
                _ = try posix.fcntl(src, posix.F.SETFD, flags & ~@as(u32, posix.FD_CLOEXEC));
            }

            try posix.dup2(src, target);
        },
        else => @compileError("unsupported platform"),
    }
}

/// Wait for the command to exit and return information about how it exited.
pub fn wait(self: Command, block: bool) !Exit {
    if (comptime builtin.os.tag == .windows) {
        // Block until the process exits. This returns immediately if the
        // process already exited.
        const result = windows.kernel32.WaitForSingleObject(self.pid.?, windows.INFINITE);
        if (result == windows.WAIT_FAILED) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }

        var exit_code: windows.DWORD = undefined;
        const has_code = windows.kernel32.GetExitCodeProcess(self.pid.?, &exit_code) != 0;
        if (!has_code) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }

        return .{ .Exited = exit_code };
    }

    const res = if (block) posix.waitpid(self.pid.?, 0) else res: {
        // We specify NOHANG because its not our fault if the process we launch
        // for the tty doesn't properly waitpid its children. We don't want
        // to hang the terminal over it.
        // When NOHANG is specified, waitpid will return a pid of 0 if the process
        // doesn't have a status to report. When that happens, it is as though the
        // wait call has not been performed, so we need to keep trying until we get
        // a non-zero pid back, otherwise we end up with zombie processes.
        while (true) {
            const res = posix.waitpid(self.pid.?, std.c.W.NOHANG);
            if (res.pid != 0) break :res res;
        }
    };

    return .init(res.status);
}

/// Sets command->data to data.
pub fn setData(self: *Command, pointer: ?*anyopaque) void {
    self.data = pointer;
}

/// Returns command->data.
pub fn getData(self: Command, comptime DT: type) ?*DT {
    return if (self.data) |ptr| @ptrCast(@alignCast(ptr)) else null;
}

// Copied from Zig. This is a publicly exported function but there is no
// way to get it from the std package.
fn createNullDelimitedEnvMap(arena: mem.Allocator, env_map: *const EnvMap) ![:null]?[*:0]u8 {
    const envp_count = env_map.count();
    const envp_buf = try arena.allocSentinel(?[*:0]u8, envp_count, null);

    var it = env_map.iterator();
    var i: usize = 0;
    while (it.next()) |pair| : (i += 1) {
        const env_buf = try arena.allocSentinel(u8, pair.key_ptr.len + pair.value_ptr.len + 1, 0);
        @memcpy(env_buf[0..pair.key_ptr.len], pair.key_ptr.*);
        env_buf[pair.key_ptr.len] = '=';
        @memcpy(env_buf[pair.key_ptr.len + 1 ..], pair.value_ptr.*);
        envp_buf[i] = env_buf.ptr;
    }
    std.debug.assert(i == envp_count);

    return envp_buf;
}

// Copied from Zig. This is a publicly exported function but there is no
// way to get it from the std package.
fn createWindowsEnvBlock(allocator: mem.Allocator, env_map: *const EnvMap) ![]u16 {
    // count bytes needed
    const max_chars_needed = x: {
        var max_chars_needed: usize = 4; // 4 for the final 4 null bytes
        var it = env_map.iterator();
        while (it.next()) |pair| {
            // +1 for '='
            // +1 for null byte
            max_chars_needed += pair.key_ptr.len + pair.value_ptr.len + 2;
        }
        break :x max_chars_needed;
    };
    const result = try allocator.alloc(u16, max_chars_needed);
    errdefer allocator.free(result);

    var it = env_map.iterator();
    var i: usize = 0;
    while (it.next()) |pair| {
        i += try std.unicode.utf8ToUtf16Le(result[i..], pair.key_ptr.*);
        result[i] = '=';
        i += 1;
        i += try std.unicode.utf8ToUtf16Le(result[i..], pair.value_ptr.*);
        result[i] = 0;
        i += 1;
    }
    result[i] = 0;
    i += 1;
    result[i] = 0;
    i += 1;
    result[i] = 0;
    i += 1;
    result[i] = 0;
    i += 1;
    return try allocator.realloc(result, i);
}

/// Copied from Zig. This function could be made public in child_process.zig instead.
fn windowsCreateCommandLine(allocator: mem.Allocator, argv: []const []const u8) ![:0]u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const writer = &buf.writer;

    for (argv, 0..) |arg, arg_i| {
        if (arg_i != 0) try writer.writeByte(' ');
        if (mem.indexOfAny(u8, arg, " \t\n\"") == null) {
            try writer.writeAll(arg);
            continue;
        }
        try writer.writeByte('"');
        var backslash_count: usize = 0;
        for (arg) |byte| {
            switch (byte) {
                '\\' => backslash_count += 1,
                '"' => {
                    try writer.splatByteAll('\\', backslash_count * 2 + 1);
                    try writer.writeByte('"');
                    backslash_count = 0;
                },
                else => {
                    try writer.splatByteAll('\\', backslash_count);
                    try writer.writeByte(byte);
                    backslash_count = 0;
                },
            }
        }
        try writer.splatByteAll('\\', backslash_count * 2);
        try writer.writeByte('"');
    }

    return buf.toOwnedSliceSentinel(0);
}

test "createNullDelimitedEnvMap" {
    const allocator = testing.allocator;
    var envmap = EnvMap.init(allocator);
    defer envmap.deinit();

    try envmap.put("HOME", "/home/ifreund");
    try envmap.put("WAYLAND_DISPLAY", "wayland-1");
    try envmap.put("DISPLAY", ":1");
    try envmap.put("DEBUGINFOD_URLS", " ");
    try envmap.put("XCURSOR_SIZE", "24");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const environ = try createNullDelimitedEnvMap(arena.allocator(), &envmap);

    try testing.expectEqual(@as(usize, 5), environ.len);

    inline for (.{
        "HOME=/home/ifreund",
        "WAYLAND_DISPLAY=wayland-1",
        "DISPLAY=:1",
        "DEBUGINFOD_URLS= ",
        "XCURSOR_SIZE=24",
    }) |target| {
        for (environ) |variable| {
            if (mem.eql(u8, mem.span(variable orelse continue), target)) break;
        } else {
            try testing.expect(false); // Environment variable not found
        }
    }
}

test "Command: os pre exec 1" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var cmd: Command = .{
        .path = "/bin/sh",
        .args = &.{ "/bin/sh", "-v" },
        .os_pre_exec = (struct {
            fn do(_: *Command) ?u8 {
                // This runs in the child, so we can exit and it won't
                // kill the test runner.
                posix.exit(42);
            }
        }).do,
        .rt_pre_exec = null,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };

    try cmd.testingStart();
    try testing.expect(cmd.pid != null);
    const exit = try cmd.wait(true);
    try testing.expect(exit == .Exited);
    try testing.expect(exit.Exited == 42);
}

test "Command: os pre exec 2" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var cmd: Command = .{
        .path = "/bin/sh",
        .args = &.{ "/bin/sh", "-v" },
        .os_pre_exec = (struct {
            fn do(_: *Command) ?u8 {
                // This runs in the child, so we can exit and it won't
                // kill the test runner.
                return 42;
            }
        }).do,
        .rt_pre_exec = null,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };

    try cmd.testingStart();
    try testing.expect(cmd.pid != null);
    const exit = try cmd.wait(true);
    try testing.expect(exit == .Exited);
    try testing.expect(exit.Exited == 42);
}

test "Command: rt pre exec 1" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var cmd: Command = .{
        .path = "/bin/sh",
        .args = &.{ "/bin/sh", "-v" },
        .os_pre_exec = null,
        .rt_pre_exec = (struct {
            fn do(_: *Command) ?u8 {
                // This runs in the child, so we can exit and it won't
                // kill the test runner.
                posix.exit(42);
            }
        }).do,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };

    try cmd.testingStart();
    try testing.expect(cmd.pid != null);
    const exit = try cmd.wait(true);
    try testing.expect(exit == .Exited);
    try testing.expect(exit.Exited == 42);
}

test "Command: rt pre exec 2" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var cmd: Command = .{
        .path = "/bin/sh",
        .args = &.{ "/bin/sh", "-v" },
        .os_pre_exec = null,
        .rt_pre_exec = (struct {
            fn do(_: *Command) ?u8 {
                // This runs in the child, so we can exit and it won't
                // kill the test runner.
                return 42;
            }
        }).do,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };

    try cmd.testingStart();
    try testing.expect(cmd.pid != null);
    const exit = try cmd.wait(true);
    try testing.expect(exit == .Exited);
    try testing.expect(exit.Exited == 42);
}

test "Command: rt post fork 1" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var cmd: Command = .{
        .path = "/bin/sh",
        .args = &.{ "/bin/sh", "-c", "sleep 1" },
        .os_pre_exec = null,
        .rt_pre_exec = null,
        .rt_post_fork = (struct {
            fn do(_: *Command) PostForkError!void {
                return error.PostForkError;
            }
        }).do,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };

    try testing.expectError(error.PostForkError, cmd.testingStart());
}

fn createTestStdout(dir: std.fs.Dir) !File {
    const file = try dir.createFile("stdout.txt", .{ .read = true });
    if (builtin.os.tag == .windows) {
        try windows.SetHandleInformation(
            file.handle,
            windows.HANDLE_FLAG_INHERIT,
            windows.HANDLE_FLAG_INHERIT,
        );
    }

    return file;
}

fn createTestStderr(dir: std.fs.Dir) !File {
    const file = try dir.createFile("stderr.txt", .{ .read = true });
    if (builtin.os.tag == .windows) {
        try windows.SetHandleInformation(
            file.handle,
            windows.HANDLE_FLAG_INHERIT,
            windows.HANDLE_FLAG_INHERIT,
        );
    }

    return file;
}

test "Command: redirect stdout to file" {
    var td = try TempDir.init();
    defer td.deinit();
    var stdout = try createTestStdout(td.dir);
    defer stdout.close();

    var cmd: Command = if (builtin.os.tag == .windows) .{
        .path = "C:\\Windows\\System32\\whoami.exe",
        .args = &.{"C:\\Windows\\System32\\whoami.exe"},
        .stdout = stdout,
    } else .{
        .path = "/bin/sh",
        .args = &.{ "/bin/sh", "-c", "echo hello" },
        .stdout = stdout,
        .os_pre_exec = null,
        .rt_pre_exec = null,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };

    try cmd.testingStart();
    try testing.expect(cmd.pid != null);
    const exit = try cmd.wait(true);
    try testing.expect(exit == .Exited);
    try testing.expectEqual(@as(u32, 0), @as(u32, exit.Exited));

    // Read our stdout
    try stdout.seekTo(0);
    const contents = try stdout.readToEndAlloc(testing.allocator, 1024 * 128);
    defer testing.allocator.free(contents);
    try testing.expect(contents.len > 0);
}

test "Command: custom env vars" {
    var td = try TempDir.init();
    defer td.deinit();
    var stdout = try createTestStdout(td.dir);
    defer stdout.close();

    var env = EnvMap.init(testing.allocator);
    defer env.deinit();
    try env.put("VALUE", "hello");

    var cmd: Command = if (builtin.os.tag == .windows) .{
        .path = "C:\\Windows\\System32\\cmd.exe",
        .args = &.{ "C:\\Windows\\System32\\cmd.exe", "/C", "echo %VALUE%" },
        .stdout = stdout,
        .env = &env,
        .os_pre_exec = null,
        .rt_pre_exec = null,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    } else .{
        .path = "/bin/sh",
        .args = &.{ "/bin/sh", "-c", "echo $VALUE" },
        .stdout = stdout,
        .env = &env,
        .os_pre_exec = null,
        .rt_pre_exec = null,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };

    try cmd.testingStart();
    try testing.expect(cmd.pid != null);
    const exit = try cmd.wait(true);
    try testing.expect(exit == .Exited);
    try testing.expect(exit.Exited == 0);

    // Read our stdout
    try stdout.seekTo(0);
    const contents = try stdout.readToEndAlloc(testing.allocator, 4096);
    defer testing.allocator.free(contents);

    if (builtin.os.tag == .windows) {
        try testing.expectEqualStrings("hello\r\n", contents);
    } else {
        try testing.expectEqualStrings("hello\n", contents);
    }
}

test "Command: custom working directory" {
    var td = try TempDir.init();
    defer td.deinit();
    var stdout = try createTestStdout(td.dir);
    defer stdout.close();

    var cmd: Command = if (builtin.os.tag == .windows) .{
        .path = "C:\\Windows\\System32\\cmd.exe",
        .args = &.{ "C:\\Windows\\System32\\cmd.exe", "/C", "cd" },
        .stdout = stdout,
        .cwd = "C:\\Windows\\System32",
        .os_pre_exec = null,
        .rt_pre_exec = null,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    } else .{
        .path = "/bin/sh",
        .args = &.{ "/bin/sh", "-c", "pwd" },
        .stdout = stdout,
        .cwd = "/tmp",
        .os_pre_exec = null,
        .rt_pre_exec = null,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };

    try cmd.testingStart();
    try testing.expect(cmd.pid != null);
    const exit = try cmd.wait(true);
    try testing.expect(exit == .Exited);
    try testing.expect(exit.Exited == 0);

    // Read our stdout
    try stdout.seekTo(0);
    const contents = try stdout.readToEndAlloc(testing.allocator, 4096);
    defer testing.allocator.free(contents);

    if (builtin.os.tag == .windows) {
        try testing.expectEqualStrings("C:\\Windows\\System32\r\n", contents);
    } else if (builtin.os.tag == .macos) {
        try testing.expectEqualStrings("/private/tmp\n", contents);
    } else {
        try testing.expectEqualStrings("/tmp\n", contents);
    }
}

// Test validate an execveZ failure correctly terminates when error.ExecFailedInChild is correctly handled
//
// Incorrectly handling an error.ExecFailedInChild results in a second copy of the test process running.
// Duplicating the test process leads to weird behavior
// zig build test will hang
// test binary created via -Demit-test-exe will run 2 copies of the test suite
test "Command: posix fork handles execveZ failure" {
    if (builtin.os.tag == .windows) {
        return error.SkipZigTest;
    }
    var td = try TempDir.init();
    defer td.deinit();
    var stdout = try createTestStdout(td.dir);
    defer stdout.close();
    var stderr = try createTestStderr(td.dir);
    defer stderr.close();

    var cmd: Command = .{
        .path = "/not/a/binary",
        .args = &.{ "/not/a/binary", "" },
        .stdout = stdout,
        .stderr = stderr,
        .cwd = "/bin",
        .os_pre_exec = null,
        .rt_pre_exec = null,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };

    try cmd.testingStart();
    try testing.expect(cmd.pid != null);
    const exit = try cmd.wait(true);
    try testing.expect(exit == .Exited);
    try testing.expect(exit.Exited == 1);
}

// If cmd.start fails with error.ExecFailedInChild it's the _child_ process that is running. If it does not
// terminate in response to that error both the parent and child will continue as if they _are_ the test suite
// process.
fn testingStart(self: *Command) !void {
    self.start(testing.allocator) catch |err| {
        if (err == error.ExecFailedInChild) {
            // I am a child process, I must not get confused and continue running the rest of the test suite.
            posix.exit(1);
        }
        return err;
    };
}
