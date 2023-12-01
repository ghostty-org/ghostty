//! Command launches sub-processes. This is an alternate implementation to the
//! Zig std.ChildProcess since at the time of authoring this, ChildProcess
//! didn't support the options necessary to spawn a shell attached to a pty.
//!
//! Consequently, I didn't implement a lot of features that std.ChildProcess
//! supports because we didn't need them. Cross-platform subprocessing is not
//! a trivial thing to implement (I've done it in three separate languages now)
//! so if we want to replatform onto std.ChildProcess I'd love to do that.
//! This was just the fastest way to get something built.
//!
//! Issues with std.ChildProcess:
//!
//!   * No pre_exec callback for logic after fork but before exec.
//!   * posix_spawn is used for Mac, but doesn't support the necessary
//!     features for tty setup.
//!
const Command = @This();

const std = @import("std");
const builtin = @import("builtin");
const internal_os = @import("os/main.zig");
const windows = internal_os.windows;
const TempDir = internal_os.TempDir;
const mem = std.mem;
const os = std.os;
const debug = std.debug;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const File = std.fs.File;
const EnvMap = std.process.EnvMap;

const PreExecFn = fn (*Command) void;

/// Path to the command to run. This must be an absolute path. This
/// library does not do PATH lookup.
path: []const u8,

/// Command-line arguments. It is the responsibility of the caller to set
/// args[0] to the command. If args is empty then args[0] will automatically
/// be set to equal path.
args: []const []const u8,

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
pre_exec: ?*const PreExecFn = null,

/// If set, then the process will be created attached to this pseudo console.
/// `stdin`, `stdout`, and `stderr` will be ignored if set.
pseudo_console: if (builtin.os.tag == .windows) ?windows.exp.HPCON else void =
    if (builtin.os.tag == .windows) null else {},

/// User data that is sent to the callback. Set with setData and getData
/// for a more user-friendly API.
data: ?*anyopaque = null,

/// Process ID is set after start is called.
pid: ?os.pid_t = null,

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
        return if (os.W.IFEXITED(status))
            Exit{ .Exited = os.W.EXITSTATUS(status) }
        else if (os.W.IFSIGNALED(status))
            Exit{ .Signal = os.W.TERMSIG(status) }
        else if (os.W.IFSTOPPED(status))
            Exit{ .Stopped = os.W.STOPSIG(status) }
        else
            Exit{ .Unknown = status };
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
    const pathZ = try arena.dupeZ(u8, self.path);
    const argsZ = try arena.allocSentinel(?[*:0]u8, self.args.len, null);
    for (self.args, 0..) |arg, i| argsZ[i] = (try arena.dupeZ(u8, arg)).ptr;

    // Determine our env vars
    const envp = if (self.env) |env_map|
        (try createNullDelimitedEnvMap(arena, env_map)).ptr
    else if (builtin.link_libc)
        std.c.environ
    else
        @compileError("missing env vars");

    // Fork
    const pid = try std.os.fork();
    if (pid != 0) {
        // Parent, return immediately.
        self.pid = @intCast(pid);
        return;
    }

    // We are the child.

    // Setup our file descriptors for std streams.
    if (self.stdin) |f| try setupFd(f.handle, os.STDIN_FILENO);
    if (self.stdout) |f| try setupFd(f.handle, os.STDOUT_FILENO);
    if (self.stderr) |f| try setupFd(f.handle, os.STDERR_FILENO);

    // Setup our working directory
    if (self.cwd) |cwd| try os.chdir(cwd);

    // If the user requested a pre exec callback, call it now.
    if (self.pre_exec) |f| f(self);

    // Finally, replace our process.
    _ = std.os.execveZ(pathZ, argsZ, envp) catch null;
}

fn startWindows(self: *Command, arena: Allocator) !void {
    const application_w = try std.unicode.utf8ToUtf16LeWithNull(arena, self.path);
    const cwd_w = if (self.cwd) |cwd| try std.unicode.utf8ToUtf16LeWithNull(arena, cwd) else null;
    const command_line_w = if (self.args.len > 0) b: {
        const command_line = try windowsCreateCommandLine(arena, self.args);
        break :b try std.unicode.utf8ToUtf16LeWithNull(arena, command_line);
    } else null;
    const env_w = if (self.env) |env_map| try createWindowsEnvBlock(arena, env_map) else null;

    const any_null_fd = self.stdin == null or self.stdout == null or self.stderr == null;
    const null_fd = if (any_null_fd) try windows.OpenFile(
        &[_]u16{ '\\', 'D', 'e', 'v', 'i', 'c', 'e', '\\', 'N', 'u', 'l', 'l' },
        .{
            .access_mask = windows.GENERIC_READ | windows.SYNCHRONIZE,
            .share_access = windows.FILE_SHARE_READ,
            .creation = windows.OPEN_EXISTING,
            .io_mode = .blocking,
        },
    ) else null;
    defer if (null_fd) |fd| std.os.close(fd);

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
                const rc = os.linux.dup3(src, target, 0);
                switch (os.errno(rc)) {
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
                    else => |err| return os.unexpectedErrno(err),
                }
            }
        },
        .macos => {
            // Mac doesn't support dup3 so we use dup2. We purposely clear
            // CLO_ON_EXEC for this fd.
            const flags = try os.fcntl(src, os.F.GETFD, 0);
            if (flags & os.FD_CLOEXEC != 0) {
                _ = try os.fcntl(src, os.F.SETFD, flags & ~@as(u32, os.FD_CLOEXEC));
            }

            try os.dup2(src, target);
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

    const res = if (block) std.os.waitpid(self.pid.?, 0) else res: {
        // We specify NOHANG because its not our fault if the process we launch
        // for the tty doesn't properly waitpid its children. We don't want
        // to hang the terminal over it.
        // When NOHANG is specified, waitpid will return a pid of 0 if the process
        // doesn't have a status to report. When that happens, it is as though the
        // wait call has not been performed, so we need to keep trying until we get
        // a non-zero pid back, otherwise we end up with zombie processes.
        while (true) {
            const res = std.os.waitpid(self.pid.?, std.c.W.NOHANG);
            if (res.pid != 0) break :res res;
        }
    };

    return Exit.init(res.status);
}

/// Sets command->data to data.
pub fn setData(self: *Command, pointer: ?*anyopaque) void {
    self.data = pointer;
}

/// Returns command->data.
pub fn getData(self: Command, comptime DT: type) ?*DT {
    return if (self.data) |ptr| @ptrCast(@alignCast(ptr)) else null;
}

/// Search for "cmd" in the PATH and return the absolute path. This will
/// always allocate if there is a non-null result. The caller must free the
/// resulting value.
pub fn expandPath(alloc: Allocator, cmd: []const u8) !?[]u8 {
    // If the command already contains a slash, then we return it as-is
    // because it is assumed to be absolute or relative.
    if (std.mem.indexOfScalar(u8, cmd, '/') != null) {
        return try alloc.dupe(u8, cmd);
    }

    const PATH = switch (builtin.os.tag) {
        .windows => blk: {
            const win_path = os.getenvW(std.unicode.utf8ToUtf16LeStringLiteral("PATH")) orelse return null;
            const path = try std.unicode.utf16leToUtf8Alloc(alloc, win_path);
            break :blk path;
        },
        else => os.getenvZ("PATH") orelse return null,
    };
    defer if (builtin.os.tag == .windows) alloc.free(PATH);

    var path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    var it = std.mem.tokenize(u8, PATH, &[_]u8{std.fs.path.delimiter});
    var seen_eacces = false;
    while (it.next()) |search_path| {
        // We need enough space in our path buffer to store this
        const path_len = search_path.len + cmd.len + 1;
        if (path_buf.len < path_len) return error.PathTooLong;

        // Copy in the full path
        @memcpy(path_buf[0..search_path.len], search_path);
        path_buf[search_path.len] = std.fs.path.sep;
        @memcpy(path_buf[search_path.len + 1 ..][0..cmd.len], cmd);
        path_buf[path_len] = 0;
        const full_path = path_buf[0..path_len :0];

        // Stat it
        const f = std.fs.cwd().openFile(
            full_path,
            .{},
        ) catch |err| switch (err) {
            error.FileNotFound => continue,
            error.AccessDenied => {
                // Accumulate this and return it later so we can try other
                // paths that we have access to.
                seen_eacces = true;
                continue;
            },
            else => return err,
        };
        defer f.close();
        const stat = try f.stat();
        if (stat.kind != .directory and isExecutable(stat.mode)) {
            return try alloc.dupe(u8, full_path);
        }
    }

    if (seen_eacces) return error.AccessDenied;

    return null;
}

fn isExecutable(mode: std.fs.File.Mode) bool {
    if (builtin.os.tag == .windows) return true;
    return mode & 0o0111 != 0;
}

// `hostname` is present on both *nix and windows
test "expandPath: hostname" {
    const executable = if (builtin.os.tag == .windows) "hostname.exe" else "hostname";
    const path = (try expandPath(testing.allocator, executable)).?;
    defer testing.allocator.free(path);
    try testing.expect(path.len > executable.len);
}

test "expandPath: does not exist" {
    const path = try expandPath(testing.allocator, "thisreallyprobablydoesntexist123");
    try testing.expect(path == null);
}

test "expandPath: slash" {
    const path = (try expandPath(testing.allocator, "foo/env")).?;
    defer testing.allocator.free(path);
    try testing.expect(path.len == 7);
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
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    for (argv, 0..) |arg, arg_i| {
        if (arg_i != 0) try buf.append(' ');
        if (mem.indexOfAny(u8, arg, " \t\n\"") == null) {
            try buf.appendSlice(arg);
            continue;
        }
        try buf.append('"');
        var backslash_count: usize = 0;
        for (arg) |byte| {
            switch (byte) {
                '\\' => backslash_count += 1,
                '"' => {
                    try buf.appendNTimes('\\', backslash_count * 2 + 1);
                    try buf.append('"');
                    backslash_count = 0;
                },
                else => {
                    try buf.appendNTimes('\\', backslash_count);
                    try buf.append(byte);
                    backslash_count = 0;
                },
            }
        }
        try buf.appendNTimes('\\', backslash_count * 2);
        try buf.append('"');
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

test "Command: pre exec" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var cmd: Command = .{
        .path = "/usr/bin/env",
        .args = &.{ "/usr/bin/env", "-v" },
        .pre_exec = (struct {
            fn do(_: *Command) void {
                // This runs in the child, so we can exit and it won't
                // kill the test runner.
                os.exit(42);
            }
        }).do,
    };

    try cmd.start(testing.allocator);
    try testing.expect(cmd.pid != null);
    const exit = try cmd.wait(true);
    try testing.expect(exit == .Exited);
    try testing.expect(exit.Exited == 42);
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
        .path = "/usr/bin/env",
        .args = &.{ "/usr/bin/env", "-v" },
        .stdout = stdout,
    };

    try cmd.start(testing.allocator);
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
    } else .{
        .path = "/usr/bin/env",
        .args = &.{ "/usr/bin/env", "sh", "-c", "echo $VALUE" },
        .stdout = stdout,
        .env = &env,
    };

    try cmd.start(testing.allocator);
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
    } else .{
        .path = "/usr/bin/env",
        .args = &.{ "/usr/bin/env", "sh", "-c", "pwd" },
        .stdout = stdout,
        .cwd = "/usr/bin",
    };

    try cmd.start(testing.allocator);
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
    } else {
        try testing.expectEqualStrings("/usr/bin\n", contents);
    }
}
