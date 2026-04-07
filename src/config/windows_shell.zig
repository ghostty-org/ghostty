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

pub const ProfileKind = enum {
    wsl_default,
    wsl_distro,
    pwsh,
    powershell,
    git_bash,
    cmd,
};

pub const Profile = struct {
    kind: ProfileKind,
    key: []const u8,
    label: []const u8,
    command: Command,

    pub fn deinit(self: *Profile, alloc: Allocator) void {
        alloc.free(self.key);
        alloc.free(self.label);
        self.command.deinit(alloc);
    }
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

pub fn listProfiles(alloc: Allocator) ![]Profile {
    const order_hint = detectProfileOrderHint(alloc);
    defer if (order_hint) |value| alloc.free(value);

    return try listProfilesWithLookupAndProbeAndWslListAndOrder(
        alloc,
        lookupExecutable,
        probeWslExecutableCached,
        listWslDistros,
        order_hint,
    );
}

pub fn profileOrderHint(alloc: Allocator) ?[:0]const u8 {
    const raw = detectProfileOrderHint(alloc) orelse return null;
    defer alloc.free(raw);
    return alloc.dupeZ(u8, raw) catch null;
}

pub fn deinitProfiles(alloc: Allocator, profiles: []Profile) void {
    for (profiles) |*profile| profile.deinit(alloc);
    alloc.free(profiles);
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

fn listProfilesWithLookupAndProbeAndWslList(
    alloc: Allocator,
    lookup: anytype,
    probe: anytype,
    list_wsl: anytype,
) ![]Profile {
    return try listProfilesWithLookupAndProbeAndWslListAndOrder(
        alloc,
        lookup,
        probe,
        list_wsl,
        null,
    );
}

fn listProfilesWithLookupAndProbeAndWslListAndOrder(
    alloc: Allocator,
    lookup: anytype,
    probe: anytype,
    list_wsl: anytype,
    order_hint: ?[]const u8,
) ![]Profile {
    var profiles: std.ArrayList(Profile) = .empty;
    errdefer {
        for (profiles.items) |*profile| profile.deinit(alloc);
        profiles.deinit(alloc);
    }

    if (try lookup(alloc, "wsl.exe")) |path| {
        defer alloc.free(path);

        if (try probe(alloc, path)) {
            try appendProfile(
                alloc,
                &profiles,
                .wsl_default,
                "wsl-default",
                "WSL (Default)",
                &.{ path, "~" },
            );

            const distros = try list_wsl(alloc, path);
            defer deinitOwnedStringList(alloc, distros);

            for (distros) |distro| {
                const key = try std.fmt.allocPrint(alloc, "wsl:{s}", .{distro});
                defer alloc.free(key);
                const label = try std.fmt.allocPrint(alloc, "WSL: {s}", .{distro});
                defer alloc.free(label);
                try appendProfile(
                    alloc,
                    &profiles,
                    .wsl_distro,
                    key,
                    label,
                    &.{ path, "-d", distro, "~" },
                );
            }
        }
    }

    try appendProfileIfFound(alloc, &profiles, lookup, .pwsh, "pwsh.exe", "PowerShell");
    try appendProfileIfFound(alloc, &profiles, lookup, .powershell, "powershell.exe", "Windows PowerShell");

    if (try lookupGitBash(alloc, lookup)) |path| {
        defer alloc.free(path);
        try appendProfile(
            alloc,
            &profiles,
            .git_bash,
            "git-bash",
            "Git Bash",
            &.{ path, "--login", "-i" },
        );
    }

    try appendProfileIfFound(alloc, &profiles, lookup, .cmd, "cmd.exe", "Command Prompt");

    if (order_hint) |hint| applyProfileOrderHint(profiles.items, hint);

    return try profiles.toOwnedSlice(alloc);
}

fn appendProfileIfFound(
    alloc: Allocator,
    profiles: *std.ArrayList(Profile),
    lookup: anytype,
    kind: ProfileKind,
    exe: []const u8,
    label: []const u8,
) !void {
    if (try lookup(alloc, exe)) |path| {
        defer alloc.free(path);
        try appendProfile(alloc, profiles, kind, exe, label, &.{path});
    }
}

fn appendProfile(
    alloc: Allocator,
    profiles: *std.ArrayList(Profile),
    kind: ProfileKind,
    key: []const u8,
    label: []const u8,
    argv: []const []const u8,
) !void {
    try profiles.append(alloc, .{
        .kind = kind,
        .key = try alloc.dupe(u8, key),
        .label = try alloc.dupe(u8, label),
        .command = try directCommand(alloc, argv),
    });
}

fn detectProfileOrderHint(alloc: Allocator) ?[]u8 {
    const raw = std.process.getEnvVarOwned(alloc, "WINGHOSTTY_WIN32_PROFILE_ORDER") catch
        return null;
    errdefer alloc.free(raw);

    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) {
        alloc.free(raw);
        return null;
    }

    if (trimmed.ptr == raw.ptr and trimmed.len == raw.len) return raw;

    const copy = alloc.dupe(u8, trimmed) catch return null;
    alloc.free(raw);
    return copy;
}

fn applyProfileOrderHint(profiles: []Profile, order_hint: []const u8) void {
    if (profiles.len <= 1 or order_hint.len == 0) return;

    var i: usize = 1;
    while (i < profiles.len) : (i += 1) {
        var j = i;
        while (j > 0 and shouldProfileSortBefore(order_hint, profiles[j], profiles[j - 1])) : (j -= 1) {
            std.mem.swap(Profile, &profiles[j], &profiles[j - 1]);
        }
    }
}

fn shouldProfileSortBefore(order_hint: []const u8, lhs: Profile, rhs: Profile) bool {
    const lhs_rank = profileOrderRank(order_hint, lhs);
    const rhs_rank = profileOrderRank(order_hint, rhs);
    if (lhs_rank != rhs_rank) return lhs_rank < rhs_rank;
    return false;
}

fn profileOrderRank(order_hint: []const u8, profile: Profile) usize {
    var index: usize = 0;
    var it = std.mem.splitAny(u8, order_hint, ",;");
    while (it.next()) |raw_token| {
        const token = std.mem.trim(u8, raw_token, " \t\r\n");
        if (token.len == 0) continue;
        if (profileOrderTokenMatches(token, profile)) return index;
        index += 1;
    }
    return std.math.maxInt(usize);
}

fn profileOrderTokenMatches(token: []const u8, profile: Profile) bool {
    if (std.ascii.eqlIgnoreCase(token, profile.key)) return true;
    if (std.ascii.eqlIgnoreCase(token, profile.label)) return true;
    if (profile.kind == .wsl_distro) {
        if (profile.key.len > 4 and std.ascii.eqlIgnoreCase(profile.key[0..4], "wsl:")) {
            if (std.ascii.eqlIgnoreCase(token, profile.key[4..])) return true;
        }
        if (profile.label.len > 5 and std.ascii.eqlIgnoreCase(profile.label[0..5], "WSL: ")) {
            if (std.ascii.eqlIgnoreCase(token, profile.label[5..])) return true;
        }
    }

    return switch (profile.kind) {
        .wsl_default => std.ascii.eqlIgnoreCase(token, "wsl") or
            std.ascii.eqlIgnoreCase(token, "wsl-default") or
            std.ascii.eqlIgnoreCase(token, "default-wsl"),
        .wsl_distro => std.ascii.eqlIgnoreCase(token, "wsl-distro") or
            std.ascii.eqlIgnoreCase(token, "distro") or
            std.ascii.eqlIgnoreCase(token, "wsl"),
        .pwsh => std.ascii.eqlIgnoreCase(token, "pwsh") or
            std.ascii.eqlIgnoreCase(token, "powershell-7") or
            std.ascii.eqlIgnoreCase(token, "powershell-core"),
        .powershell => std.ascii.eqlIgnoreCase(token, "powershell") or
            std.ascii.eqlIgnoreCase(token, "windows-powershell") or
            std.ascii.eqlIgnoreCase(token, "ps"),
        .git_bash => std.ascii.eqlIgnoreCase(token, "git-bash") or
            std.ascii.eqlIgnoreCase(token, "gitbash") or
            std.ascii.eqlIgnoreCase(token, "git"),
        .cmd => std.ascii.eqlIgnoreCase(token, "cmd") or
            std.ascii.eqlIgnoreCase(token, "cmd.exe") or
            std.ascii.eqlIgnoreCase(token, "command-prompt"),
    };
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

fn lookupGitBash(alloc: Allocator, lookup: anytype) !?[]u8 {
    if (try lookup(alloc, "bash.exe")) |path| return path;

    if (try lookup(alloc, "git.exe")) |git_path| {
        defer alloc.free(git_path);

        const git_dir = std.fs.path.dirname(git_path) orelse return null;
        const root = std.fs.path.dirname(git_dir) orelse return null;
        const candidate = try std.fs.path.join(alloc, &.{ root, "bin", "bash.exe" });
        errdefer alloc.free(candidate);

        std.fs.accessAbsolute(candidate, .{}) catch return null;
        return candidate;
    }

    return null;
}

fn listWslDistros(alloc: Allocator, exe_path: []const u8) ![][]u8 {
    var child = std.process.Child.init(&.{ exe_path, "-l", "-q" }, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.create_no_window = true;

    try child.spawn();
    errdefer {
        _ = child.kill() catch {};
    }

    const stdout = child.stdout orelse {
        _ = child.kill() catch {};
        return error.Unexpected;
    };

    const output = try stdout.readToEndAlloc(alloc, 64 * 1024);
    defer alloc.free(output);

    _ = try child.wait();

    var result: std.ArrayList([]u8) = .empty;
    errdefer {
        deinitOwnedStringList(alloc, result.items);
        result.deinit(alloc);
    }

    var it = std.mem.splitAny(u8, output, "\r\n");
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        try result.append(alloc, try alloc.dupe(u8, line));
    }

    return try result.toOwnedSlice(alloc);
}

fn deinitOwnedStringList(alloc: Allocator, values: []const []u8) void {
    for (values) |value| alloc.free(value);
    alloc.free(values);
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

test "lookupGitBash infers Git Bash from git.exe" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const path = (try lookupGitBash(alloc, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "bash.exe")) return null;
            if (std.mem.eql(u8, exe, "git.exe")) return try a.dupe(u8, "C:\\Program Files\\Git\\cmd\\git.exe");
            return null;
        }
    }.lookup)).?;
    defer alloc.free(path);

    try testing.expectEqualStrings("C:\\Program Files\\Git\\bin\\bash.exe", path);
}

test "listProfilesWithLookupAndProbeAndWslList enumerates windows profiles" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const profiles = try listProfilesWithLookupAndProbeAndWslList(alloc, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "wsl.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\wsl.exe");
            if (std.mem.eql(u8, exe, "pwsh.exe")) return try a.dupe(u8, "C:\\Program Files\\PowerShell\\7\\pwsh.exe");
            if (std.mem.eql(u8, exe, "powershell.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe");
            if (std.mem.eql(u8, exe, "bash.exe")) return try a.dupe(u8, "C:\\Program Files\\Git\\bin\\bash.exe");
            if (std.mem.eql(u8, exe, "cmd.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\cmd.exe");
            return null;
        }
    }.lookup, struct {
        fn probe(_: Allocator, exe: []const u8) !bool {
            try testing.expectEqualStrings("C:\\Windows\\System32\\wsl.exe", exe);
            return true;
        }
    }.probe, struct {
        fn list(alloc_: Allocator, exe: []const u8) ![][]u8 {
            try testing.expectEqualStrings("C:\\Windows\\System32\\wsl.exe", exe);
            var values: std.ArrayList([]u8) = .empty;
            try values.append(alloc_, try alloc_.dupe(u8, "Ubuntu"));
            try values.append(alloc_, try alloc_.dupe(u8, "Debian"));
            return try values.toOwnedSlice(alloc_);
        }
    }.list);
    defer deinitProfiles(alloc, profiles);

    try testing.expectEqual(@as(usize, 7), profiles.len);
    try testing.expectEqual(ProfileKind.wsl_default, profiles[0].kind);
    try testing.expectEqualStrings("WSL (Default)", profiles[0].label);
    try testing.expectEqual(@as(usize, 2), profiles[0].command.direct.len);
    try testing.expectEqualStrings("~", profiles[0].command.direct[1]);

    try testing.expectEqual(ProfileKind.wsl_distro, profiles[1].kind);
    try testing.expectEqualStrings("WSL: Ubuntu", profiles[1].label);
    try testing.expectEqual(@as(usize, 4), profiles[1].command.direct.len);
    try testing.expectEqualStrings("-d", profiles[1].command.direct[1]);
    try testing.expectEqualStrings("Ubuntu", profiles[1].command.direct[2]);

    try testing.expectEqual(ProfileKind.wsl_distro, profiles[2].kind);
    try testing.expectEqualStrings("WSL: Debian", profiles[2].label);
    try testing.expectEqual(ProfileKind.pwsh, profiles[3].kind);
    try testing.expectEqual(ProfileKind.powershell, profiles[4].kind);
    try testing.expectEqual(ProfileKind.git_bash, profiles[5].kind);
    try testing.expectEqual(ProfileKind.cmd, profiles[6].kind);
}

test "profileOrderTokenMatches supports Windows profile aliases" {
    const testing = std.testing;

    try testing.expect(profileOrderTokenMatches("pwsh", .{
        .kind = .pwsh,
        .key = "pwsh.exe",
        .label = "PowerShell",
        .command = .{ .direct = &.{"pwsh.exe"} },
    }));
    try testing.expect(profileOrderTokenMatches("git", .{
        .kind = .git_bash,
        .key = "git-bash",
        .label = "Git Bash",
        .command = .{ .direct = &.{"bash.exe"} },
    }));
    try testing.expect(profileOrderTokenMatches("windows-powershell", .{
        .kind = .powershell,
        .key = "powershell.exe",
        .label = "Windows PowerShell",
        .command = .{ .direct = &.{"powershell.exe"} },
    }));
    try testing.expect(profileOrderTokenMatches("Ubuntu", .{
        .kind = .wsl_distro,
        .key = "Ubuntu",
        .label = "WSL: Ubuntu",
        .command = .{ .direct = &.{ "wsl.exe", "-d", "Ubuntu", "~" } },
    }));
    try testing.expect(!profileOrderTokenMatches("cmd", .{
        .kind = .pwsh,
        .key = "pwsh.exe",
        .label = "PowerShell",
        .command = .{ .direct = &.{"pwsh.exe"} },
    }));
}

test "listProfilesWithLookupAndProbeAndWslListAndOrder reorders windows profiles" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const profiles = try listProfilesWithLookupAndProbeAndWslListAndOrder(alloc, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "wsl.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\wsl.exe");
            if (std.mem.eql(u8, exe, "pwsh.exe")) return try a.dupe(u8, "C:\\Program Files\\PowerShell\\7\\pwsh.exe");
            if (std.mem.eql(u8, exe, "powershell.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe");
            if (std.mem.eql(u8, exe, "bash.exe")) return try a.dupe(u8, "C:\\Program Files\\Git\\bin\\bash.exe");
            if (std.mem.eql(u8, exe, "cmd.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\cmd.exe");
            return null;
        }
    }.lookup, struct {
        fn probe(_: Allocator, _: []const u8) !bool {
            return true;
        }
    }.probe, struct {
        fn list(alloc_: Allocator, _: []const u8) ![][]u8 {
            var values: std.ArrayList([]u8) = .empty;
            try values.append(alloc_, try alloc_.dupe(u8, "Ubuntu"));
            try values.append(alloc_, try alloc_.dupe(u8, "Debian"));
            return try values.toOwnedSlice(alloc_);
        }
    }.list, "git,pwsh,Ubuntu,cmd");
    defer deinitProfiles(alloc, profiles);

    try testing.expectEqual(@as(usize, 7), profiles.len);
    try testing.expectEqual(ProfileKind.git_bash, profiles[0].kind);
    try testing.expectEqual(ProfileKind.pwsh, profiles[1].kind);
    try testing.expectEqualStrings("WSL: Ubuntu", profiles[2].label);
    try testing.expectEqual(ProfileKind.cmd, profiles[3].kind);
    try testing.expectEqual(ProfileKind.wsl_default, profiles[4].kind);
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
