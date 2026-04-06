const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const internal_os = @import("../os/main.zig");
const Command = @import("command.zig").Command;
const log = std.log.scoped(.windows_shell);
const windows = std.os.windows;

const wsl_probe_timeout_ms: windows.DWORD = 1500;
var wsl_probe_mutex: std.Thread.Mutex = .{};
var wsl_probe_cache: ?bool = null;

pub const DefaultShell = enum {
    wsl,
    pwsh,
    powershell,
    cmd,
};

/// Determine the default shell order for Windows:
/// WSL -> pwsh -> powershell -> cmd.
pub fn defaultShell(alloc: Allocator) !DefaultShell {
    return try defaultShellWithLookupAndProbe(alloc, lookupExecutable, probeWslExecutableCached);
}

/// Build the default Windows command. This intentionally returns a direct
/// command so we avoid the extra `cmd.exe /C` trampoline on the hot path.
pub fn defaultCommand(alloc: Allocator) !Command {
    return try defaultCommandWithLookupAndProbe(alloc, lookupExecutable, probeWslExecutableCached);
}

/// Build a safe default Windows command that explicitly skips WSL.
/// This is used by the Win32 preview runtime while the WSL startup path
/// is being stabilized independently from renderer bring-up.
pub fn defaultCommandNoWsl(alloc: Allocator) !Command {
    return try defaultCommandNoWslWithLookup(alloc, lookupExecutable);
}

/// Build a conservative preview command for the Win32 runtime.
/// This prefers `cmd.exe` first because its startup semantics are simpler
/// than PowerShell while the native Windows runtime is still under bring-up.
pub fn previewCommand(alloc: Allocator) !Command {
    return try previewCommandWithLookup(alloc, lookupExecutable);
}

/// Prepare a command for Windows spawning. Today this only special-cases WSL
/// so that inherited or explicit working directories become `wsl.exe --cd ...`
/// launches without paying a shell trampoline cost.
pub fn prepareCommand(
    alloc: Allocator,
    command: Command,
    cwd: ?[]const u8,
    working_directory_home: bool,
) !Command {
    return try prepareCommandWithLookup(
        alloc,
        command,
        cwd,
        working_directory_home,
        lookupExecutable,
    );
}

/// Determine a safe Windows host cwd for launching a command. This is
/// primarily needed for WSL, where the terminal cwd may be a WSL path or
/// `home` while CreateProcess still requires a Windows-local directory.
pub fn spawnCwd(
    alloc: Allocator,
    cwd: ?[]const u8,
    working_directory_home: bool,
) !?[]const u8 {
    if (cwd) |v| {
        if (isWindowsUriPath(v)) return try uriPathToWindows(alloc, v);
        if (isDriveAbsolutePath(v)) return try alloc.dupe(u8, v);
        if (isWslPath(v)) return try defaultWindowsHome(alloc);
        return try defaultWindowsHome(alloc);
    }

    _ = working_directory_home;
    return try defaultWindowsHome(alloc);
}

/// Determine a safe shell-visible PWD for Windows launches.
///
/// Non-WSL shells should only receive native Windows paths. WSL launches can
/// receive normalized WSL-style paths or the home sentinel. Obviously invalid
/// Windows cwd values such as `\\` are dropped entirely.
pub fn shellPwd(
    alloc: Allocator,
    cwd: ?[]const u8,
    is_wsl: bool,
) !?[]const u8 {
    const value = cwd orelse return null;

    if (isWindowsUriPath(value)) return try uriPathToWindows(alloc, value);
    if (isDriveAbsolutePath(value)) return try alloc.dupe(u8, value);
    if (!is_wsl) return null;
    if (std.mem.eql(u8, value, "~")) return try alloc.dupe(u8, value);
    if (isWslPath(value)) return try normalizeWslPath(alloc, value);
    log.warn("dropping unsupported windows shell pwd cwd={s} is_wsl={}", .{ value, is_wsl });
    return null;
}

/// Determine a safe CreateProcess cwd for Windows launches while preserving
/// inherit semantics when the caller did not request a specific cwd.
pub fn safeCurrentDirectory(
    alloc: Allocator,
    cwd: ?[]const u8,
    working_directory_home: bool,
    is_wsl: bool,
) !?[]const u8 {
    const current = try currentWindowsDirectory(alloc);
    defer if (current) |value| alloc.free(value);

    return try safeCurrentDirectoryWithCurrent(
        alloc,
        cwd,
        working_directory_home,
        is_wsl,
        current,
    );
}

fn safeCurrentDirectoryWithCurrent(
    alloc: Allocator,
    cwd: ?[]const u8,
    working_directory_home: bool,
    is_wsl: bool,
    current: ?[]const u8,
) !?[]const u8 {
    if (cwd) |value| {
        if (isWindowsUriPath(value)) return try uriPathToWindows(alloc, value);
        if (isDriveAbsolutePath(value)) return try alloc.dupe(u8, value);
        if (is_wsl or isWslPath(value) or isObviouslyInvalidWindowsCurrentDirectory(value)) {
            log.warn("falling back to windows home for unsafe cwd cwd={s} is_wsl={}", .{ value, is_wsl });
            return try defaultWindowsHome(alloc);
        }

        log.warn("falling back to windows home for unsupported cwd cwd={s} is_wsl={}", .{ value, is_wsl });
        return try defaultWindowsHome(alloc);
    }

    if (current) |value| {
        defer alloc.free(value);

        if (isDriveAbsolutePath(value)) return try alloc.dupe(u8, value);
        if (isWindowsUriPath(value)) return try uriPathToWindows(alloc, value);
        if (isObviouslyInvalidWindowsCurrentDirectory(value)) {
            log.warn("falling back to windows home for inherited unsafe cwd cwd={s} is_wsl={}", .{ value, is_wsl });
            return try defaultWindowsHome(alloc);
        }

        log.warn("using inherited windows cwd cwd={s} is_wsl={}", .{ value, is_wsl });
        return try alloc.dupe(u8, value);
    }

    if (working_directory_home or is_wsl) return try defaultWindowsHome(alloc);
    return null;
}

fn currentWindowsDirectory(alloc: Allocator) !?[]const u8 {
    return std.process.getCwdAlloc(alloc) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            log.warn("failed to read current windows cwd err={}", .{err});
            return null;
        },
    };
}

fn prepareCommandWithLookup(
    alloc: Allocator,
    command: Command,
    cwd: ?[]const u8,
    working_directory_home: bool,
    lookup: anytype,
) !Command {
    if (!isWslCommand(command)) return try command.clone(alloc);

    const target_cwd: ?[]const u8 = cwd_: {
        if (cwd) |v| break :cwd_ try pathToWsl(alloc, v);
        if (working_directory_home) break :cwd_ try alloc.dupe(u8, "~");
        break :cwd_ null;
    };
    defer if (target_cwd) |v| alloc.free(v);

    return switch (command) {
        .direct => |argv| try prepareWslDirect(alloc, argv, target_cwd, lookup),

        // We only auto-rewrite WSL direct launches. A shell command is assumed
        // to be user-authored and remains untouched.
        .shell => try command.clone(alloc),
    };
}

pub fn isWslCommand(command: Command) bool {
    return switch (command) {
        .direct => |argv| isWslArgv(argv),
        .shell => false,
    };
}

pub fn isWslArgv(argv: []const []const u8) bool {
    if (argv.len == 0) return false;
    return isExecutableName(argv[0], "wsl") or isExecutableName(argv[0], "wsl.exe");
}

pub fn isWslPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/") or
        std.mem.startsWith(u8, path, "\\\\wsl.localhost\\") or
        std.mem.startsWith(u8, path, "\\\\wsl$\\");
}

/// Convert a local path coming from OSC 7 into a Windows-local path string.
/// WSL paths stay WSL-style so they can be inherited into later WSL shells.
pub fn osc7PathToLocal(alloc: Allocator, path: []const u8) ![]const u8 {
    if (isWindowsUriPath(path)) return try uriPathToWindows(alloc, path);
    if (isWslPath(path)) return try normalizeWslPath(alloc, path);
    return try alloc.dupe(u8, path);
}

/// Translate a Windows or WSL-style path into a WSL path. Returns `null` for
/// paths we can't confidently map.
pub fn pathToWsl(alloc: Allocator, path: []const u8) !?[]const u8 {
    if (path.len == 0) return null;
    if (isWindowsUriPath(path)) return try pathToWsl(alloc, path[1..]);
    if (isWslPath(path)) return try normalizeWslPath(alloc, path);

    if (!isDriveAbsolutePath(path)) return null;

    const rest = trimLeadingSeparators(path[2..]);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try buf.appendSlice(alloc, "/mnt/");
    try buf.append(alloc, std.ascii.toLower(path[0]));
    if (rest.len == 0) {
        return try buf.toOwnedSlice(alloc);
    }

    try buf.append(alloc, '/');
    try appendNormalizedPath(&buf, alloc, rest);
    return try buf.toOwnedSlice(alloc);
}

fn defaultShellWithLookup(
    alloc: Allocator,
    lookup: anytype,
) !DefaultShell {
    return try defaultShellWithLookupAndProbe(alloc, lookup, probeWslExecutableAlwaysTrue);
}

fn defaultShellWithLookupAndProbe(
    alloc: Allocator,
    lookup: anytype,
    probe: anytype,
) !DefaultShell {
    for (default_shell_candidates) |candidate| {
        const found = try lookup(alloc, candidate.exe);
        defer if (found) |path| alloc.free(path);
        if (found) |path| {
            if (candidate.shell == .wsl and !try probe(alloc, path)) continue;
            return candidate.shell;
        }
    }

    return .cmd;
}

fn defaultCommandWithLookup(
    alloc: Allocator,
    lookup: anytype,
) !Command {
    return try defaultCommandWithLookupAndProbe(alloc, lookup, probeWslExecutableAlwaysTrue);
}

fn defaultCommandWithLookupAndProbe(
    alloc: Allocator,
    lookup: anytype,
    probe: anytype,
) !Command {
    for (default_shell_candidates) |candidate| {
        const found = try lookup(alloc, candidate.exe);
        if (found) |path| {
            defer alloc.free(path);
            if (candidate.shell == .wsl and !try probe(alloc, path)) continue;
            return switch (candidate.shell) {
                .wsl => try directCommand(alloc, &.{ path, "~" }),
                else => try directCommand(alloc, &.{path}),
            };
        }
    }

    if (try lookup(alloc, "cmd.exe")) |path| {
        defer alloc.free(path);
        return try directCommand(alloc, &.{path});
    }

    return try directCommand(alloc, &.{"cmd.exe"});
}

fn defaultCommandNoWslWithLookup(
    alloc: Allocator,
    lookup: anytype,
) !Command {
    inline for (default_shell_candidates_no_wsl) |candidate| {
        const found = try lookup(alloc, candidate.exe);
        if (found) |path| {
            defer alloc.free(path);
            return try directCommand(alloc, &.{path});
        }
    }

    if (try lookup(alloc, "cmd.exe")) |path| {
        defer alloc.free(path);
        return try directCommand(alloc, &.{path});
    }

    return try directCommand(alloc, &.{"cmd.exe"});
}

fn previewCommandWithLookup(
    alloc: Allocator,
    lookup: anytype,
) !Command {
    if (try lookup(alloc, "cmd.exe")) |path| {
        defer alloc.free(path);
        return try directCommand(alloc, &.{path});
    }

    return try defaultCommandNoWslWithLookup(alloc, lookup);
}

fn probeWslExecutableAlwaysTrue(_: Allocator, _: []const u8) !bool {
    return true;
}

fn probeWslExecutableCached(alloc: Allocator, exe_path: []const u8) !bool {
    if (builtin.os.tag != .windows) return true;

    wsl_probe_mutex.lock();
    defer wsl_probe_mutex.unlock();

    if (wsl_probe_cache) |cached| return cached;

    const result = try probeWslExecutable(alloc, exe_path);
    wsl_probe_cache = result;
    return result;
}

fn probeWslExecutable(alloc: Allocator, exe_path: []const u8) !bool {
    if (builtin.os.tag != .windows) return true;

    var child = std.process.Child.init(&.{ exe_path, "--status" }, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.create_no_window = true;

    child.spawn() catch |err| {
        log.warn("failed to probe wsl responsiveness exe={s} err={}", .{ exe_path, err });
        return false;
    };
    errdefer {
        _ = child.kill() catch {};
    }

    windows.WaitForSingleObjectEx(child.id, wsl_probe_timeout_ms, false) catch |err| switch (err) {
        error.WaitTimeOut => {
            log.warn("skipping unresponsive wsl default shell exe={s} timeout_ms={}", .{
                exe_path,
                wsl_probe_timeout_ms,
            });
            _ = child.kill() catch {};
            return false;
        },

        else => {
            log.warn("wsl probe wait failed exe={s} err={}", .{ exe_path, err });
            _ = child.kill() catch {};
            return false;
        },
    };

    _ = child.wait() catch |err| {
        log.warn("wsl probe wait cleanup failed exe={s} err={}", .{ exe_path, err });
        return false;
    };
    return true;
}

const default_shell_candidates = [_]struct {
    shell: DefaultShell,
    exe: []const u8,
}{
    .{ .shell = .wsl, .exe = "wsl.exe" },
    .{ .shell = .pwsh, .exe = "pwsh.exe" },
    .{ .shell = .powershell, .exe = "powershell.exe" },
};

const default_shell_candidates_no_wsl = [_]struct {
    shell: DefaultShell,
    exe: []const u8,
}{
    .{ .shell = .pwsh, .exe = "pwsh.exe" },
    .{ .shell = .powershell, .exe = "powershell.exe" },
};

fn prepareWslDirect(
    alloc: Allocator,
    argv: []const [:0]const u8,
    target_cwd: ?[]const u8,
    lookup: anytype,
) !Command {
    const resolved_exe = try resolveExecutableForArgv0(alloc, argv, lookup);
    defer if (resolved_exe) |path| alloc.free(path);
    const target_home = if (target_cwd) |cwd| std.mem.eql(u8, cwd, "~") else false;

    if (argv.len == 0) {
        if (resolved_exe) |path| return try directCommand(alloc, &.{path});
        return try directCommand(alloc, &.{"wsl.exe"});
    }

    var count: usize = 1;
    var need_home_arg = target_home;
    if (target_cwd != null and !target_home) count += 2;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        if (isCdFlag(argv[i])) {
            if (std.mem.eql(u8, argv[i], "--cd") and i + 1 < argv.len) i += 1;
            continue;
        }

        if (std.mem.eql(u8, argv[i], "~")) {
            if (target_home) {
                need_home_arg = false;
                count += 1;
            }
            continue;
        }

        count += 1;
    }

    const args = try alloc.alloc([:0]const u8, count);
    var j: usize = 0;
    if (resolved_exe) |path| {
        args[j] = try alloc.dupeZ(u8, path);
    } else {
        args[j] = try alloc.dupeZ(u8, argv[0]);
    }
    j += 1;

    if (target_cwd) |cwd| {
        if (target_home) {
            if (need_home_arg) {
                args[j] = try alloc.dupeZ(u8, "~");
                j += 1;
            }
        } else {
            args[j] = try alloc.dupeZ(u8, "--cd");
            j += 1;
            args[j] = try alloc.dupeZ(u8, cwd);
            j += 1;
        }
    }

    i = 1;
    while (i < argv.len) : (i += 1) {
        if (isCdFlag(argv[i])) {
            if (std.mem.eql(u8, argv[i], "--cd") and i + 1 < argv.len) i += 1;
            continue;
        }

        if (std.mem.eql(u8, argv[i], "~")) {
            if (target_home) {
                args[j] = try alloc.dupeZ(u8, argv[i]);
                j += 1;
            }
            continue;
        }

        args[j] = try alloc.dupeZ(u8, argv[i]);
        j += 1;
    }

    return .{ .direct = args };
}

fn resolveExecutableForArgv0(
    alloc: Allocator,
    argv: []const [:0]const u8,
    lookup: anytype,
) !?[]u8 {
    if (argv.len == 0) return try lookup(alloc, "wsl.exe");
    if (!isExecutableName(argv[0], "wsl") and !isExecutableName(argv[0], "wsl.exe")) return null;
    if (std.fs.path.isAbsolute(argv[0])) return try alloc.dupe(u8, argv[0]);
    return try lookup(alloc, "wsl.exe");
}

fn directCommand(alloc: Allocator, argv: []const []const u8) !Command {
    const args = try alloc.alloc([:0]const u8, argv.len);
    for (argv, 0..) |arg, i| args[i] = try alloc.dupeZ(u8, arg);
    return .{ .direct = args };
}

fn lookupExecutable(alloc: Allocator, exe: []const u8) !?[]u8 {
    return try internal_os.path.expand(alloc, exe);
}

fn defaultWindowsHome(alloc: Allocator) !?[]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (try internal_os.windows.knownFolderPathUtf8(
        &internal_os.windows.FOLDERID_Profile,
        &buf,
    )) |path| {
        return try alloc.dupe(u8, path);
    }

    return null;
}

fn isExecutableName(path: []const u8, exe: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.fs.path.basename(path), exe);
}

fn isCdFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--cd") or std.mem.startsWith(u8, arg, "--cd=");
}

fn isWindowsUriPath(path: []const u8) bool {
    return path.len >= 4 and
        path[0] == '/' and
        std.ascii.isAlphabetic(path[1]) and
        path[2] == ':' and
        isSeparator(path[3]);
}

fn isDriveAbsolutePath(path: []const u8) bool {
    return path.len >= 3 and
        std.ascii.isAlphabetic(path[0]) and
        path[1] == ':' and
        isSeparator(path[2]);
}

fn isObviouslyInvalidWindowsCurrentDirectory(path: []const u8) bool {
    return path.len == 0 or
        std.mem.eql(u8, path, "\\") or
        std.mem.eql(u8, path, "\\\\") or
        std.mem.eql(u8, path, "/") or
        std.mem.startsWith(u8, path, "\\\\wsl.localhost\\") or
        std.mem.startsWith(u8, path, "\\\\wsl$\\");
}

fn isSeparator(c: u8) bool {
    return c == '/' or c == '\\';
}

fn trimLeadingSeparators(path: []const u8) []const u8 {
    return std.mem.trimLeft(u8, path, "/\\");
}

fn normalizeWslPath(alloc: Allocator, path: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, path, "/")) return try alloc.dupe(u8, path);

    for ([_][]const u8{
        "\\\\wsl.localhost\\",
        "\\\\wsl$\\",
    }) |prefix| {
        if (!std.mem.startsWith(u8, path, prefix)) continue;

        const rest = path[prefix.len..];
        const distro_sep = std.mem.indexOfAny(u8, rest, "/\\") orelse return try alloc.dupe(u8, "/");
        const distro_rest = trimLeadingSeparators(rest[distro_sep..]);
        if (distro_rest.len == 0) return try alloc.dupe(u8, "/");

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        try buf.append(alloc, '/');
        try appendNormalizedPath(&buf, alloc, distro_rest);
        return try buf.toOwnedSlice(alloc);
    }

    return try alloc.dupe(u8, path);
}

fn uriPathToWindows(alloc: Allocator, path: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try buf.append(alloc, path[1]);
    try buf.appendSlice(alloc, ":\\");
    try appendWindowsPath(&buf, alloc, trimLeadingSeparators(path[3..]));
    return try buf.toOwnedSlice(alloc);
}

fn appendNormalizedPath(
    buf: *std.ArrayList(u8),
    alloc: Allocator,
    path: []const u8,
) !void {
    for (path) |c| try buf.append(alloc, if (c == '\\') '/' else c);
}

fn appendWindowsPath(
    buf: *std.ArrayList(u8),
    alloc: Allocator,
    path: []const u8,
) !void {
    for (path) |c| try buf.append(alloc, if (c == '/') '\\' else c);
}

test "defaultShellWithLookup prefers wsl first" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const shell = try defaultShellWithLookup(alloc, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "wsl.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\wsl.exe");
            if (std.mem.eql(u8, exe, "pwsh.exe")) return try a.dupe(u8, "C:\\Program Files\\PowerShell\\7\\pwsh.exe");
            return null;
        }
    }.lookup);

    try testing.expectEqual(.wsl, shell);
}

test "defaultShellWithLookupAndProbe falls back when wsl probe fails" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const shell = try defaultShellWithLookupAndProbe(alloc, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "wsl.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\wsl.exe");
            if (std.mem.eql(u8, exe, "pwsh.exe")) return try a.dupe(u8, "C:\\Program Files\\PowerShell\\7\\pwsh.exe");
            return null;
        }
    }.lookup, struct {
        fn probe(_: Allocator, exe: []const u8) !bool {
            try testing.expectEqualStrings("C:\\Windows\\System32\\wsl.exe", exe);
            return false;
        }
    }.probe);

    try testing.expectEqual(.pwsh, shell);
}

test "defaultShellWithLookup falls back to cmd" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const shell = try defaultShellWithLookup(alloc, struct {
        fn lookup(_: Allocator, _: []const u8) !?[]u8 {
            return null;
        }
    }.lookup);

    try testing.expectEqual(.cmd, shell);
}

test "defaultCommandWithLookup prefers absolute wsl path" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const command = try defaultCommandWithLookup(alloc, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "wsl.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\wsl.exe");
            return null;
        }
    }.lookup);
    defer command.deinit(alloc);

    try testing.expect(command == .direct);
    try testing.expectEqual(@as(usize, 2), command.direct.len);
    try testing.expectEqualStrings("C:\\Windows\\System32\\wsl.exe", command.direct[0]);
    try testing.expectEqualStrings("~", command.direct[1]);
}

test "defaultCommandWithLookupAndProbe falls back when wsl probe fails" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const command = try defaultCommandWithLookupAndProbe(alloc, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "wsl.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\wsl.exe");
            if (std.mem.eql(u8, exe, "pwsh.exe")) return try a.dupe(u8, "C:\\Program Files\\PowerShell\\7\\pwsh.exe");
            return null;
        }
    }.lookup, struct {
        fn probe(_: Allocator, exe: []const u8) !bool {
            try testing.expectEqualStrings("C:\\Windows\\System32\\wsl.exe", exe);
            return false;
        }
    }.probe);
    defer command.deinit(alloc);

    try testing.expect(command == .direct);
    try testing.expectEqual(@as(usize, 1), command.direct.len);
    try testing.expectEqualStrings("C:\\Program Files\\PowerShell\\7\\pwsh.exe", command.direct[0]);
}

test "defaultCommandNoWslWithLookup skips wsl and prefers pwsh" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const command = try defaultCommandNoWslWithLookup(alloc, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "wsl.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\wsl.exe");
            if (std.mem.eql(u8, exe, "pwsh.exe")) return try a.dupe(u8, "C:\\Program Files\\PowerShell\\7\\pwsh.exe");
            return null;
        }
    }.lookup);
    defer command.deinit(alloc);

    try testing.expect(command == .direct);
    try testing.expectEqual(@as(usize, 1), command.direct.len);
    try testing.expectEqualStrings("C:\\Program Files\\PowerShell\\7\\pwsh.exe", command.direct[0]);
}

test "previewCommandWithLookup prefers cmd over powershell" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const command = try previewCommandWithLookup(alloc, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "cmd.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\cmd.exe");
            if (std.mem.eql(u8, exe, "pwsh.exe")) return try a.dupe(u8, "C:\\Program Files\\PowerShell\\7\\pwsh.exe");
            return null;
        }
    }.lookup);
    defer command.deinit(alloc);

    try testing.expect(command == .direct);
    try testing.expectEqual(@as(usize, 1), command.direct.len);
    try testing.expectEqualStrings("C:\\Windows\\System32\\cmd.exe", command.direct[0]);
}

test "pathToWsl converts windows drive path" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = (try pathToWsl(alloc, "C:\\Users\\aman\\src")).?;
    defer alloc.free(result);

    try testing.expectEqualStrings("/mnt/c/Users/aman/src", result);
}

test "pathToWsl converts wsl unc path" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = (try pathToWsl(alloc, "\\\\wsl.localhost\\Ubuntu\\home\\aman\\src")).?;
    defer alloc.free(result);

    try testing.expectEqualStrings("/home/aman/src", result);
}

test "osc7PathToLocal converts windows file uri path" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = try osc7PathToLocal(alloc, "/C:/Users/aman/src");
    defer alloc.free(result);

    try testing.expectEqualStrings("C:\\Users\\aman\\src", result);
}

test "shellPwd drops invalid non-wsl cwd roots" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = try shellPwd(alloc, "\\\\", false);
    try testing.expectEqual(@as(?[]const u8, null), result);
}

test "shellPwd preserves normalized wsl pwd for wsl launches" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = (try shellPwd(alloc, "\\\\wsl.localhost\\Ubuntu\\home\\aman", true)).?;
    defer alloc.free(result);

    try testing.expectEqualStrings("/home/aman", result);
}

test "safeCurrentDirectory keeps inherit semantics for non-wsl shells" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = (try safeCurrentDirectoryWithCurrent(alloc, null, false, false, try alloc.dupe(u8, "C:\\Users\\amant"))).?;
    defer alloc.free(result);

    try testing.expectEqualStrings("C:\\Users\\amant", result);
}

test "safeCurrentDirectory falls back to home for invalid cwd" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = (try safeCurrentDirectory(alloc, "\\\\", false, false)).?;
    defer alloc.free(result);

    try testing.expect(result.len > 2);
    try testing.expect(std.ascii.isAlphabetic(result[0]));
    try testing.expectEqual(@as(u8, ':'), result[1]);
}

test "safeCurrentDirectory falls back to home for inherited invalid cwd" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = (try safeCurrentDirectoryWithCurrent(alloc, null, false, false, try alloc.dupe(u8, "\\\\"))).?;
    defer alloc.free(result);

    try testing.expect(result.len > 2);
    try testing.expect(std.ascii.isAlphabetic(result[0]));
    try testing.expectEqual(@as(u8, ':'), result[1]);
}

test "prepareCommand injects translated cwd for wsl direct command" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const command = try directCommand(alloc, &.{"wsl.exe"});
    defer command.deinit(alloc);
    const prepared = try prepareCommandWithLookup(alloc, command, "D:\\work\\winghostty", false, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "wsl.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\wsl.exe");
            return null;
        }
    }.lookup);
    defer prepared.deinit(alloc);

    try testing.expect(prepared == .direct);
    try testing.expectEqual(@as(usize, 3), prepared.direct.len);
    try testing.expectEqualStrings("C:\\Windows\\System32\\wsl.exe", prepared.direct[0]);
    try testing.expectEqualStrings("--cd", prepared.direct[1]);
    try testing.expectEqualStrings("/mnt/d/work/winghostty", prepared.direct[2]);
}

test "prepareCommand replaces default wsl home sentinel with explicit cwd" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const command = try directCommand(alloc, &.{ "wsl.exe", "~" });
    defer command.deinit(alloc);
    const prepared = try prepareCommandWithLookup(alloc, command, "D:\\work\\winghostty", false, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "wsl.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\wsl.exe");
            return null;
        }
    }.lookup);
    defer prepared.deinit(alloc);

    try testing.expect(prepared == .direct);
    try testing.expectEqual(@as(usize, 3), prepared.direct.len);
    try testing.expectEqualStrings("C:\\Windows\\System32\\wsl.exe", prepared.direct[0]);
    try testing.expectEqualStrings("--cd", prepared.direct[1]);
    try testing.expectEqualStrings("/mnt/d/work/winghostty", prepared.direct[2]);
}

test "prepareCommand preserves bare wsl home sentinel when cwd is home" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const command = try directCommand(alloc, &.{ "wsl.exe", "~" });
    defer command.deinit(alloc);
    const prepared = try prepareCommandWithLookup(alloc, command, null, true, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "wsl.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\wsl.exe");
            return null;
        }
    }.lookup);
    defer prepared.deinit(alloc);

    try testing.expect(prepared == .direct);
    try testing.expectEqual(@as(usize, 2), prepared.direct.len);
    try testing.expectEqualStrings("C:\\Windows\\System32\\wsl.exe", prepared.direct[0]);
    try testing.expectEqualStrings("~", prepared.direct[1]);
}

test "prepareCommand replaces existing wsl --cd" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const command = try directCommand(alloc, &.{ "wsl.exe", "--cd", "~", "--", "bash" });
    defer command.deinit(alloc);
    const prepared = try prepareCommandWithLookup(alloc, command, "/home/aman/src", false, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "wsl.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\wsl.exe");
            return null;
        }
    }.lookup);
    defer prepared.deinit(alloc);

    try testing.expect(prepared == .direct);
    try testing.expectEqual(@as(usize, 5), prepared.direct.len);
    try testing.expectEqualStrings("C:\\Windows\\System32\\wsl.exe", prepared.direct[0]);
    try testing.expectEqualStrings("--cd", prepared.direct[1]);
    try testing.expectEqualStrings("/home/aman/src", prepared.direct[2]);
    try testing.expectEqualStrings("--", prepared.direct[3]);
    try testing.expectEqualStrings("bash", prepared.direct[4]);
}

test "spawnCwd uses home for wsl-style cwd" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = try spawnCwd(alloc, "\\\\wsl.localhost\\Ubuntu\\home\\aman", false);
    defer if (result) |v| alloc.free(v);

    if (builtin.os.tag == .windows) {
        try testing.expect(result != null);
    }
}

test "spawnCwd preserves drive cwd" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = try spawnCwd(alloc, "C:\\Users\\aman\\src", false);
    defer if (result) |v| alloc.free(v);

    try testing.expect(result != null);
    try testing.expectEqualStrings("C:\\Users\\aman\\src", result.?);
}

test "spawnCwd uses home when cwd is unset" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = try spawnCwd(alloc, null, false);
    defer if (result) |v| alloc.free(v);

    if (builtin.os.tag == .windows) {
        try testing.expect(result != null);
    }
}

test "spawnCwd uses home for non-absolute cwd" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = try spawnCwd(alloc, "\\\\", false);
    defer if (result) |v| alloc.free(v);

    if (builtin.os.tag == .windows) {
        try testing.expect(result != null);
    }
}
