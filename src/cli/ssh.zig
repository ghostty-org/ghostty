const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const cli_args = @import("args.zig");
const diagnostics = @import("diagnostics.zig");
const Action = @import("ghostty.zig").Action;
const DiskCache = @import("ssh_cache.zig").DiskCache;
const internal_os = @import("../os/main.zig");
const string_encoding = @import("../os/string_encoding.zig");
const terminfopkg = @import("../terminfo/main.zig");
const global = @import("../global.zig");

const log = std.log.scoped(.ssh);

const RemoteAgent = enum {
    codex,
    claude,
    pi,
    qoder,
    reasonix,
    omp,
    opencode,
    amp,
    antigravity,
    cline,
    copilot,
    crush,
    cursor,
    droid,
    grok,
    hermes,
    kimi,
    qwen,

    fn commandName(self: RemoteAgent) []const u8 {
        return switch (self) {
            .qoder => "qodercli",
            .antigravity => "agy",
            .cursor => "cursor-agent",
            else => @tagName(self),
        };
    }

    fn parse(value: []const u8) ?RemoteAgent {
        inline for (std.meta.fields(RemoteAgent)) |field| {
            if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }
};

const usage =
    \\Usage: ghostty +ssh [flags] [--] <ssh args...>
    \\
    \\Flags:
    \\  --forward-env[=bool]  Enable TERM / SendEnv forwarding. Default: true.
    \\  --terminfo[=bool]     Install Ghostty terminfo on first connect. Default: true.
    \\  --cache[=bool]        Use the terminfo install cache. Default: true.
    \\  --ssh=<path>          Path to the ssh binary. Default: first `ssh` on PATH.
    \\  --remote-working-directory=<path>
    \\                        Start a replayed interactive Fish session in path.
    \\  --remote-agent=<allowlisted-agent>
    \\                        Start an allowlisted agent after connecting.
    \\  --remote-agent-session=<id>
    \\                        Resume that agent's validated conversation ID.
    \\  --verbose             Print +ssh status lines to stderr.
    \\  --help                Show full help.
    \\
    \\ssh flags and the destination go after +ssh's own flags (or after `--`).
    \\
;

pub const Options = struct {
    /// Set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    /// Maps to the `ssh-env` shell integration feature.
    @"forward-env": bool = true,

    /// Maps to the `ssh-terminfo` shell integration feature.
    terminfo: bool = true,

    /// When false, both cache read and write are bypassed.
    cache: bool = true,

    /// The wrapped `ssh` binary.
    /// `/`-containing values are treated as paths; otherwise resolved via PATH.
    ssh: []const u8 = "ssh",

    /// Optional initial remote cwd used by OMG when replaying an SSH split.
    @"remote-working-directory": ?[]const u8 = null,

    /// Optional allowlisted agent launched by a restored SSH Surface.
    @"remote-agent": ?[]const u8 = null,

    /// Optional validated conversation ID for the restored remote agent.
    @"remote-agent-session": ?[]const u8 = null,

    /// When true, print verbose output to stderr.
    verbose: bool = false,

    /// Arguments passed through to `ssh` verbatim. Populated by
    /// `parseManuallyHook` when we reach the first non-flag argument (or
    /// an explicit `--`).
    _ssh_args: std.ArrayList([]const u8) = .empty,

    /// Enables arg parsing diagnostics so unknown flags become
    /// diagnostics rather than fatal errors.
    _diagnostics: diagnostics.DiagnosticList = .{},

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }

    /// Enables `-h` and `--help` to work.
    pub fn help(_: Options) !void {
        return Action.help_error;
    }

    /// Manual parse hook. For each argument:
    ///   - If it's a literal `--`, consume everything after it as ssh
    ///     args and stop parsing.
    ///   - If it doesn't start with `--`, this is the start of the ssh
    ///     argv. Consume this arg and everything after as ssh args and
    ///     stop parsing.
    ///   - Otherwise (a `--foo` arg), return true so the generic parser
    ///     handles it as one of our own flags.
    pub fn parseManuallyHook(
        self: *Options,
        alloc: Allocator,
        arg: []const u8,
        iter: anytype,
    ) Allocator.Error!bool {
        if (std.mem.eql(u8, arg, "--")) {
            while (iter.next()) |rest| {
                try self._ssh_args.append(alloc, try alloc.dupe(u8, rest));
            }
            return false;
        }

        if (!std.mem.startsWith(u8, arg, "--")) {
            try self._ssh_args.append(alloc, try alloc.dupe(u8, arg));
            while (iter.next()) |rest| {
                try self._ssh_args.append(alloc, try alloc.dupe(u8, rest));
            }
            return false;
        }

        return true;
    }
};

/// Wrap `ssh` to automatically configure Ghostty terminal integration on
/// remote hosts.
///
/// Any arguments that aren't recognized as `+ssh` flags are passed to
/// the real `ssh` binary unchanged. You can use `--` as an explicit
/// disambiguator if needed, though it's almost never required: `ssh`
/// has no long flags, and `+ssh` defines no short flags, so there's
/// nothing to collide.
///
/// This is typically called via Ghostty's shell integration. When
/// `shell-integration-features` includes `ssh-env` or `ssh-terminfo`,
/// each shell defines an `ssh` function that runs:
///
///     ghostty +ssh <flags> -- "$@"
///
/// You can also run `ghostty +ssh` directly, or alias it yourself (e.g.
/// `alias ssh='ghostty +ssh --'`) if you prefer not to use the shell
/// integration.
///
/// `+ssh` performs up to two pieces of setup before launching `ssh`:
///
///   1. **Environment forwarding** (`--forward-env`). Sets `TERM` to
///      `xterm-256color` and requests `SendEnv` forwarding of
///      `COLORTERM`, `TERM_PROGRAM`, and `TERM_PROGRAM_VERSION` so the
///      remote shell can still detect that it's running inside Ghostty.
///      The remote `sshd_config` must list these in `AcceptEnv` for
///      forwarding to succeed.
///
///   2. **Terminfo install** (`--terminfo`). On the first connection to a
///      given destination, installs Ghostty's embedded terminfo entry on the
///      remote host using `ssh tic -x -` over a shared `ControlMaster`
///      connection. Successful installs are cached
///      (see `ghostty +ssh-cache`) so subsequent connections skip this
///      step. When terminfo is successfully installed or already cached,
///      `TERM` is set to `xterm-ghostty` instead of `xterm-256color`.
///
/// If `--terminfo` install fails (e.g. `tic` not available on the
/// remote, filesystem permissions), a warning is logged and the
/// connection continues with `TERM=xterm-256color`.
///
/// Flags:
///
///   * `--forward-env=<bool>`: Enable `TERM` / `SendEnv` environment
///     forwarding. Default: `true`.
///
///   * `--terminfo=<bool>`: Enable automatic terminfo install on first
///     connection. Default: `true`.
///
///   * `--cache=<bool>`: Use the terminfo install cache. Default: `true`.
///     When `false`, both the cache read (skip-if-installed) and the
///     cache write (record-on-success) are bypassed, and every
///     connection performs the install. To one-shot reinstall a single
///     host while keeping the cache in use, prefer `ghostty +ssh-cache
///     --remove=<host>` followed by a normal connection.
///
///   * `--ssh=<path>`: Path to the `ssh` binary to execute. Default: the
///     first `ssh` found on `PATH`.
///
///   * `--remote-working-directory=<path>`: Start an interactive Fish
///     destination in this remote directory. OMG uses this only when replaying
///     an active SSH connection into a new split.
///
///   * `--remote-agent=<allowlisted-agent>` and
///     `--remote-agent-session=<id>`: Restore an allowlisted agent session.
///     These options never accept arbitrary remote commands.
///
///   * `--verbose`: Print +ssh status lines to stderr, and surface
///     remote stderr during the terminfo install.
///
/// Examples:
///
///   # Basic invocation using defaults:
///   ghostty +ssh user@example.com
///
///   # Forward Ghostty env vars but skip the terminfo install:
///   ghostty +ssh --terminfo=false user@example.com
///
///   # `ssh` flags (short-form `-p`, etc.) pass through unchanged:
///   ghostty +ssh -p 2222 -i ~/.ssh/id_ed25519 user@example.com
///
///   # Use `--` explicitly if your ssh args might collide with our flags:
///   ghostty +ssh -- --some-rare-ssh-arg user@example.com
///
/// Pass `--verbose` to see what `+ssh` is doing. For cache inspection
/// and management, see `ghostty +ssh-cache`.
///
/// Available since: 1.4.0
pub fn run(alloc_gpa: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try cli_args.argsIterator(alloc_gpa, global.args());
        defer iter.deinit();
        try cli_args.parse(Options, alloc_gpa, &opts, &iter);
    }

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file: std.Io.File = .stdout();
    var stdout_writer = stdout_file.writer(global.io(), &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file: std.Io.File = .stderr();
    var stderr_writer = stderr_file.writer(global.io(), &stderr_buffer);
    const stderr = &stderr_writer.interface;

    // Any diagnostic from the arg parser is an unknown flag or bad
    // value. Reject loudly — silently forwarding `--typo` to ssh would
    // produce confusing downstream errors.
    if (!opts._diagnostics.empty()) {
        for (opts._diagnostics.items()) |diag| {
            if (diag.key.len > 0) {
                stderr.print(
                    "Error: unknown flag `--{s}`.\n",
                    .{diag.key},
                ) catch {};
            } else {
                stderr.print("Error: {s}\n", .{diag.message}) catch {};
            }
        }
        stderr.print("\n{s}", .{usage}) catch {};
        stderr.flush() catch {};
        return 2;
    }

    const result = runInner(alloc_gpa, &opts, stdout, stderr);

    stdout.flush() catch {};
    stderr.flush() catch {};
    return result;
}

fn runInner(
    gpa: Allocator,
    opts: *const Options,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    var arena = ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    if (opts._ssh_args.items.len == 0) {
        try stderr.print("Error: no ssh arguments provided.\n\n{s}", .{usage});
        return 2;
    }

    // A pane-scoped capability is injected only by the native GUI. Let its
    // helper classify arguments before any SSH setup or remote process launch.
    if (opts.@"remote-agent" == null) {
        var handoff_env = try global.environMap();
        defer handoff_env.deinit();
        if (handoff_env.get("OMG_SSH_HANDOFF_HELPER")) |inherited_helper| {
            var helper = inherited_helper;
            // Persistent local shells may still name a helper from an older
            // runtime. The current CLI and GUI negotiate the current handoff.
            if (global.resourcesDir().app()) |resources| {
                const bundled = try std.fs.path.resolve(alloc, &.{ resources, "..", "session-runtime", "omgd" });
                if (std.Io.Dir.accessAbsolute(global.io(), bundled, .{})) {
                    helper = bundled;
                } else |_| {}
            }
            const token = handoff_env.get("OMG_SSH_HANDOFF_TOKEN") orelse "";
            const directory = handoff_env.get("OMG_SSH_HANDOFF_DIRECTORY") orelse "";
            if (helper.len > 0 and token.len > 0 and directory.len > 0) {
                const check = try std.mem.concat(alloc, []const u8, &.{ &.{ helper, "handoff-check" }, opts._ssh_args.items });
                if ((childExec(check) catch 64) == 0) {
                    const prefix: []const []const u8 = if (opts.@"remote-working-directory") |cwd|
                        &.{ helper, "handoff-cwd", opts.ssh, cwd }
                    else
                        &.{ helper, "handoff", opts.ssh };
                    const request = try std.mem.concat(alloc, []const u8, &.{ prefix, opts._ssh_args.items });
                    return try childExec(request);
                }
            }
        }
    }

    const remote_agent: ?RemoteAgent = if (opts.@"remote-agent") |value|
        RemoteAgent.parse(value) orelse {
            try stderr.print("Error: invalid --remote-agent `{s}`.\n", .{value});
            return 2;
        }
    else
        null;
    if (opts.@"remote-agent-session") |value| {
        if (remote_agent == null) {
            try stderr.writeAll("Error: --remote-agent-session requires --remote-agent.\n");
            return 2;
        }
        if (!validAgentSessionID(value)) {
            try stderr.writeAll("Error: invalid --remote-agent-session.\n");
            return 2;
        }
    }

    const session: struct {
        term: []const u8,
        to_cache: ?struct { cache: DiskCache, dest: []const u8 } = null,
    } = session: {
        if (!opts.terminfo) break :session .{ .term = "xterm-256color" };

        const dest = resolveDestination(alloc, opts.ssh, opts._ssh_args.items) orelse {
            warnPrint(stderr, "could not resolve ssh destination; skipping terminfo install", .{});
            break :session .{ .term = "xterm-256color" };
        };

        const cache: ?DiskCache = if (opts.cache) cache: {
            const path = DiskCache.defaultPath(alloc, "ghostty") catch |err| {
                warnPrint(stderr, "ghostty terminfo cache unavailable: {t}", .{err});
                break :session .{ .term = "xterm-256color" };
            };
            break :cache .{ .path = path };
        } else null;

        if (cache) |c| {
            const cached = c.contains(
                alloc,
                dest,
                terminfopkg.version,
            ) catch |err| cached: {
                if (DiskCache.isFailure(err)) warnPrint(
                    stderr,
                    "unable to read the cache '{s}': {t}",
                    .{ c.path, err },
                );
                break :cached false;
            };

            if (cached) {
                verbosePrint(opts, stderr, "dest: {s} (cached, skipping install)", .{dest});
                break :session .{ .term = "xterm-ghostty" };
            } else {
                verbosePrint(opts, stderr, "dest: {s} (not cached, will install)", .{dest});
            }
        } else {
            verbosePrint(opts, stderr, "dest: {s} (cache disabled, will install)", .{dest});
        }

        stderr.print("Setting up xterm-ghostty terminfo on {s}...\n", .{dest}) catch {};
        stderr.flush() catch {};

        installRemoteTerminfo(alloc, opts, stderr) catch |err| {
            warnPrint(stderr, "failed to install terminfo: {t}", .{err});
            break :session .{ .term = "xterm-256color" };
        };
        break :session .{
            .term = "xterm-ghostty",
            .to_cache = if (cache) |c| .{ .cache = c, .dest = dest } else null,
        };
    };

    // A simple interactive Fish, bash, or zsh destination can provide a typed
    // pane lifecycle, remote cwd, and OSC 133 command boundaries without a
    // remote OMG service or persistent installation. +ssh owns the final
    // OpenSSH child lifetime; its transient remote startup hooks only annotate
    // that one terminal connection.
    const lifecycle: ?struct {
        id: []const u8,
        label: []const u8,
        local_cwd: []const u8,
        remote_command: []const u8,
        replay_path: ?[]const u8,
    } = if (interactiveSSHDestination(opts._ssh_args.items)) |destination| lifecycle: {
        const label = sshDestinationLabel(destination) orelse
            break :lifecycle null;
        const id = std.fmt.allocPrint(
            alloc,
            "omg-ssh-{d}",
            .{std.Io.Timestamp.now(global.io(), .real).toNanoseconds()},
        ) catch break :lifecycle null;
        const remote_command = remoteShellCommand(
            alloc,
            label,
            id,
            opts.@"remote-working-directory",
            remote_agent,
            opts.@"remote-agent-session",
        ) orelse break :lifecycle null;
        const local_cwd = std.Io.Dir.cwd().realPathFileAlloc(
            global.io(),
            ".",
            alloc,
        ) catch break :lifecycle null;
        break :lifecycle .{
            .id = id,
            .label = label,
            .local_cwd = local_cwd,
            .remote_command = remote_command,
            .replay_path = writeReplayDescriptor(alloc, opts, id),
        };
    } else null;
    const remote_command = if (lifecycle) |value| value.remote_command else null;

    // Build the full argv: [ssh, ...our opts, ...user args, ...remote command]
    const env_opts: []const []const u8 = if (opts.@"forward-env") env_opts: {
        const set_term = try std.fmt.allocPrint(
            alloc,
            "SetEnv=TERM={s}",
            .{session.term},
        );
        break :env_opts &.{
            "-o", set_term,
            "-o", "SendEnv=COLORTERM",
            "-o", "SendEnv=TERM_PROGRAM",
            "-o", "SendEnv=TERM_PROGRAM_VERSION",
        };
    } else &.{};
    const remote_opts: []const []const u8 = if (remote_command) |command|
        &.{ "-tt", command }
    else
        &.{};
    const argv = try std.mem.concat(alloc, []const u8, &.{
        &.{opts.ssh},
        env_opts,
        opts._ssh_args.items,
        remote_opts,
    });
    verbosePrint(opts, stderr, "exec: {f}", .{Joined{ .items = argv }});

    var exit_code: u8 = 1;
    var lifecycle_ended = false;
    if (lifecycle) |value| {
        writeSessionStart(stdout, value.id, value.label, value.local_cwd) catch {};
        stdout.flush() catch {};
    }
    defer if (!lifecycle_ended) if (lifecycle) |value| {
        writeSessionEnd(stdout, value.id, exit_code, value.local_cwd) catch {};
        stdout.flush() catch {};
        if (value.replay_path) |path| deleteReplayDescriptor(path);
    };

    exit_code = childExec(argv) catch |err| {
        try stderr.print("Error: failed to run {s}: {t}\n", .{ argv[0], err });
        return 1;
    };
    if (lifecycle) |value| {
        writeSessionEnd(stdout, value.id, exit_code, value.local_cwd) catch {};
        stdout.flush() catch {};
        if (value.replay_path) |path| deleteReplayDescriptor(path);
        lifecycle_ended = true;
    }
    verbosePrint(opts, stderr, "exit: {d}", .{exit_code});

    // Attempt to cache (if needed) on a successful ssh execution.
    if (exit_code == 0) if (session.to_cache) |entry| {
        if (entry.cache.add(
            alloc,
            entry.dest,
            terminfopkg.version,
            std.Io.Timestamp.now(global.io(), .real).toSeconds(),
        )) |_| {
            verbosePrint(opts, stderr, "cache: wrote {s}", .{entry.dest});
        } else |err| {
            if (DiskCache.isFailure(err)) {
                warnPrint(
                    stderr,
                    "unable to add '{s}' to the cache '{s}': {t}",
                    .{ entry.dest, entry.cache.path, err },
                );
            } else {
                verbosePrint(
                    opts,
                    stderr,
                    "cache: skipped {s}: {t}",
                    .{ entry.dest, err },
                );
            }
        }
    };

    return exit_code;
}

/// Log to `.ssh` and, if `--verbose`, also print to stderr.
fn verbosePrint(
    opts: *const Options,
    stderr: *std.Io.Writer,
    comptime fmt: []const u8,
    args: anytype,
) void {
    log.debug(fmt, args);
    if (!opts.verbose) return;
    stderr.print("+ssh: " ++ fmt ++ "\n", args) catch return;
    stderr.flush() catch return;
}

/// Log a warning and also print a `Warning: <msg>` line to stderr.
fn warnPrint(
    stderr: *std.Io.Writer,
    comptime fmt: []const u8,
    args: anytype,
) void {
    log.warn(fmt, args);
    stderr.print("Warning: " ++ fmt ++ "\n", args) catch return;
    stderr.flush() catch return;
}

/// Space-joined items, formattable as `{f}`.
const Joined = struct {
    items: []const []const u8,

    pub fn format(self: Joined, writer: *std.Io.Writer) !void {
        for (self.items, 0..) |a, i| {
            if (i > 0) try writer.writeByte(' ');
            try writer.writeAll(a);
        }
    }

    test {
        const testing = std.testing;
        var buf: [128]u8 = undefined;
        {
            var w: std.Io.Writer = .fixed(&buf);
            try w.print("{f}", .{Joined{ .items = &.{} }});
            try testing.expectEqualStrings("", buf[0..w.end]);
        }
        {
            var w: std.Io.Writer = .fixed(&buf);
            try w.print("{f}", .{Joined{ .items = &.{"only"} }});
            try testing.expectEqualStrings("only", buf[0..w.end]);
        }
        {
            var w: std.Io.Writer = .fixed(&buf);
            try w.print("{f}", .{Joined{ .items = &.{ "a", "b", "c" } }});
            try testing.expectEqualStrings("a b c", buf[0..w.end]);
        }
    }
};

fn checkExit(term: std.process.Child.Term, label: []const u8) error{ChildFailed}!void {
    switch (term) {
        .exited => |rc| if (rc != 0) {
            log.warn("{s} exited with non-zero status: {d}", .{ label, rc });
            return error.ChildFailed;
        },
        else => {
            log.warn("{s} terminated abnormally: {}", .{ label, term });
            return error.ChildFailed;
        },
    }
}

const ReplayDescriptor = struct {
    version: u8 = 1,
    ssh: []const u8,
    forward_env: bool,
    terminfo: bool,
    cache: bool,
    args: []const []const u8,
};

fn replaySupportName(channel: ?[]const u8) []const u8 {
    if (channel) |value| {
        if (std.mem.eql(u8, value, "debug")) return "OMG Dev";
        if (std.mem.eql(u8, value, "debug-workspace")) return "OMG Dev Workspace";
        if (std.mem.eql(u8, value, "debug-pty")) return "OMG Dev PTY";
    }
    return "OMG";
}

fn shouldWriteReplayDescriptor(
    session_id: ?[]const u8,
    channel: ?[]const u8,
) bool {
    return session_id != null or channel != null;
}

fn writeReplayDescriptor(
    alloc: Allocator,
    opts: *const Options,
    context_id: []const u8,
) ?[]const u8 {
    if (comptime builtin.os.tag != .macos) return null;

    var env = global.environMap() catch return null;
    defer env.deinit();
    const channel = env.get("OH_MY_GHOSTTY_CHANNEL");
    if (!shouldWriteReplayDescriptor(
        env.get("OH_MY_GHOSTTY_SESSION"),
        channel,
    )) return null;
    const home = env.get("HOME") orelse return null;
    const directory_path = std.fs.path.join(alloc, &.{
        home,
        "Library",
        "Application Support",
        replaySupportName(channel),
        "SSHReplay",
    }) catch return null;
    std.Io.Dir.cwd().createDirPath(global.io(), directory_path) catch return null;
    var directory = std.Io.Dir.openDirAbsolute(
        global.io(),
        directory_path,
        .{},
    ) catch return null;
    defer directory.close(global.io());

    const filename = std.fmt.allocPrint(alloc, "{s}.json", .{context_id}) catch return null;
    var buffer: [1024]u8 = undefined;
    var atomic_file = directory.createFileAtomic(global.io(), filename, .{
        .permissions = if (std.posix.mode_t != u0)
            .fromMode(0o600)
        else
            .default_file,
        .replace = true,
    }) catch return null;
    defer atomic_file.deinit(global.io());
    var writer = atomic_file.file.writer(global.io(), &buffer);
    writer.interface.print("{f}", .{std.json.fmt(ReplayDescriptor{
        .ssh = opts.ssh,
        .forward_env = opts.@"forward-env",
        .terminfo = opts.terminfo,
        .cache = opts.cache,
        .args = opts._ssh_args.items,
    }, .{})}) catch return null;
    writer.interface.flush() catch return null;
    atomic_file.replace(global.io()) catch return null;
    return std.fs.path.join(alloc, &.{ directory_path, filename }) catch null;
}

fn deleteReplayDescriptor(path: []const u8) void {
    const directory_path = std.fs.path.dirname(path) orelse return;
    const filename = std.fs.path.basename(path);
    var directory = std.Io.Dir.openDirAbsolute(
        global.io(),
        directory_path,
        .{},
    ) catch return;
    defer directory.close(global.io());
    directory.deleteFile(global.io(), filename) catch {};
}

fn interactiveSSHDestination(args: []const []const u8) ?[]const u8 {
    const options_with_value = "BbcDEeFIiJLlmOoPpQRSWw";
    const noninteractive_options = "GNOQTVWfn";
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            break;
        }
        if (arg.len == 0 or arg[0] != '-' or std.mem.eql(u8, arg, "-")) break;
        const first_option = arg[1];
        if (std.mem.indexOfScalar(u8, noninteractive_options, first_option) != null) {
            return null;
        }
        if (std.mem.indexOfScalar(u8, options_with_value, first_option) != null) {
            if (arg.len == 2) {
                index += 1;
                if (index >= args.len) return null;
            }
            index += 1;
            continue;
        }
        for (arg[1..]) |option| {
            if (std.mem.indexOfScalar(u8, noninteractive_options, option) != null) {
                return null;
            }
        }
        index += 1;
    }
    if (index >= args.len) return null;
    const destination = args[index];
    return if (index + 1 == args.len) destination else null;
}

fn sshDestinationLabel(destination: []const u8) ?[]const u8 {
    const label = if (std.mem.lastIndexOfScalar(u8, destination, '@')) |index|
        destination[index + 1 ..]
    else
        destination;
    if (label.len == 0) return null;
    for (label) |char| switch (char) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => {},
        else => return null,
    };
    return label;
}

fn validAgentSessionID(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => {},
        else => return false,
    };
    return true;
}

fn remoteShellCommand(
    alloc: Allocator,
    label: []const u8,
    context_id: []const u8,
    remote_working_directory: ?[]const u8,
    remote_agent: ?RemoteAgent,
    remote_agent_session: ?[]const u8,
) ?[]const u8 {
    const fish = remoteFishCommand(
        alloc,
        label,
        context_id,
        remote_working_directory,
        remote_agent,
        remote_agent_session,
    ) orelse return null;
    defer alloc.free(fish);
    const bash = remoteStartupFileCommand(
        alloc,
        "bash",
        label,
        context_id,
        remote_working_directory,
        remote_agent,
        remote_agent_session,
    ) orelse return null;
    defer alloc.free(bash);
    const zsh = remoteStartupFileCommand(
        alloc,
        "zsh",
        label,
        context_id,
        remote_working_directory,
        remote_agent,
        remote_agent_session,
    ) orelse return null;
    defer alloc.free(zsh);

    var script: std.Io.Writer.Allocating = .init(alloc);
    defer script.deinit();
    if (remote_working_directory) |cwd| {
        script.writer.writeAll("OMG_REMOTE_CWD=") catch return null;
        writeShellSingleQuoted(&script.writer, cwd) catch return null;
        script.writer.writeAll("\nexport OMG_REMOTE_CWD\n") catch return null;
    }
    @import("ssh_shell_integration.zig").writeRemoteOMG(&script.writer, context_id) catch return null;
    script.writer.writeAll(
        \\__omg_server_id=''
        \\if command -v ssh-keygen >/dev/null 2>&1 && command -v awk >/dev/null 2>&1; then
        \\  for __omg_host_key in /etc/ssh/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_ecdsa_key.pub /etc/ssh/ssh_host_rsa_key.pub; do
        \\    [ -r "$__omg_host_key" ] || continue
        \\    __omg_fingerprint=$(ssh-keygen -lf "$__omg_host_key" -E sha256 2>/dev/null | awk 'NR == 1 { print $2 }')
        \\    case "$__omg_fingerprint" in SHA256:*) __omg_server_id="hostkey-$__omg_fingerprint"; break ;; esac
        \\  done
        \\fi
        \\if [ -z "$__omg_server_id" ]; then
        \\  for __omg_machine_file in /etc/machine-id /var/lib/dbus/machine-id; do
        \\    [ -r "$__omg_machine_file" ] || continue
        \\    IFS= read -r __omg_machine_id < "$__omg_machine_file"
        \\    case "$__omg_machine_id" in ''|*[!A-Fa-f0-9-]*) continue ;; esac
        \\    __omg_server_id="machine-$__omg_machine_id"
        \\    break
        \\  done
        \\fi
        \\export OMG_SSH_SERVER_ID="$__omg_server_id"
        \\
        \\case ${SHELL##*/} in
        \\fish)
    ) catch return null;
    script.writer.writeAll(fish) catch return null;
    script.writer.writeAll(" ;;\nbash) ") catch return null;
    script.writer.writeAll(bash) catch return null;
    script.writer.writeAll("\n;;\nzsh) ") catch return null;
    script.writer.writeAll(zsh) catch return null;
    script.writer.writeAll(
        \\
        \\;;
        \\*) if [ -n "${OMG_REMOTE_CWD-}" ]; then cd -- "$OMG_REMOTE_CWD" 2>/dev/null || true; unset OMG_REMOTE_CWD; fi; exec "${SHELL:-/bin/sh}" -l ;;
        \\esac
    ) catch return null;

    var command: std.Io.Writer.Allocating = .init(alloc);
    defer command.deinit();
    command.writer.writeAll("exec /bin/sh -c ") catch return null;
    writeEncodedBootstrapArgument(&command.writer, script.written()) catch return null;
    return command.toOwnedSlice() catch null;
}

fn remoteFishCommand(
    alloc: Allocator,
    label: []const u8,
    context_id: []const u8,
    remote_working_directory: ?[]const u8,
    remote_agent: ?RemoteAgent,
    remote_agent_session: ?[]const u8,
) ?[]const u8 {
    var fish_command: std.Io.Writer.Allocating = .init(alloc);
    defer fish_command.deinit();
    if (remote_working_directory != null) {
        fish_command.writer.writeAll(
            "test -n \"$OMG_REMOTE_CWD\"; and cd -- \"$OMG_REMOTE_CWD\" 2>/dev/null; set -e OMG_REMOTE_CWD; ",
        ) catch return null;
    }
    fish_command.writer.print(
        "function __omg_report_pwd --on-event fish_prompt; set -l __omg_cwd (string escape --style=url \"$PWD\"); set -l __omg_tty (tty); printf \"\\e]3008;start={s};type=remote;targethost={s};serverid=%s;cwd=%s;tty=%s\\a\\e]7;file://localhost%s\\a\" \"$OMG_SSH_SERVER_ID\" \"$__omg_cwd\" \"$__omg_tty\" \"$__omg_cwd\"; end",
        .{ context_id, label },
    ) catch return null;
    fish_command.writer.writeByte('\n') catch return null;
    fish_command.writer.writeAll(@import("ssh_shell_integration.zig").fish_remote_setup) catch return null;
    fish_command.writer.writeAll(@import("ssh_shell_integration.zig").fish) catch return null;
    // Same deferred point as local Fish: initialize after the user's theme,
    // before the first prompt, with an event that preserves status/pipestatus.
    fish_command.writer.writeAll(
        "\nfunction __omg_history_setup --on-event fish_prompt; " ++
            "functions -e __omg_history_setup; " ++
            "if not set -q __ghostty_command_markers_initialized; " ++
            "set -g __ghostty_prompt_start_mark '\\e]133;A\\a'; " ++
            "__ghostty_command_markers_init; __ghostty_mark_prompt_start; end; end",
    ) catch return null;
    writeRemoteAgentWrappers(&fish_command.writer, .fish) catch return null;
    if (remote_agent) |agent| {
        fish_command.writer.writeAll("; __omg_report_pwd; ") catch return null;
        writeRemoteAgentInvocation(
            &fish_command.writer,
            agent,
            remote_agent_session,
            .fish,
        ) catch return null;
    }

    var command: std.Io.Writer.Allocating = .init(alloc);
    defer command.deinit();
    command.writer.writeAll("exec fish -l -C ") catch return null;
    writeShellSingleQuoted(&command.writer, fish_command.written()) catch return null;
    return command.toOwnedSlice() catch null;
}

const RemoteQuoteStyle = enum { fish, shell };

/// Transient identity fallback for agents without reliable remote startup hooks.
/// Do not replace user aliases/functions. Native hooks remain authoritative for
/// task state; returning to the shell clears all remote agent contexts.
fn writeRemoteAgentWrappers(writer: *std.Io.Writer, style: RemoteQuoteStyle) !void {
    inline for (std.meta.tags(RemoteAgent)) |agent| {
        const name = agent.commandName();
        const id = @tagName(agent);
        switch (style) {
            .fish => {
                try writer.print("; if not functions -q {s}; function {s}; ", .{ name, name });
                try writer.print(
                    "printf \"\\e]3008;start=omg-agent-{s}-%s;type=app;omg_agent={s};omg_scope=remote;omg_state=idle\\a\" $fish_pid; ",
                    .{ id, id },
                );
                try writer.print("command {s} $argv; set -l __omg_result $status; __omg_report_pwd; return $__omg_result; end; end", .{name});
            },
            .shell => {
                try writer.print("if ! typeset -f {s} >/dev/null 2>&1 && ! alias {s} >/dev/null 2>&1; then\nfunction {s} {{\n", .{ name, name, name });
                try writer.print(
                    "  printf '\\033]3008;start=omg-agent-{s}-%s;type=app;omg_agent={s};omg_scope=remote;omg_state=idle\\007' \"$$\"\n",
                    .{ id, id },
                );
                try writer.print("  local __omg_result=0\n  command {s} \"$@\" || __omg_result=$?\n  __omg_report_pwd\n  return \"$__omg_result\"\n}}\nfi\n", .{name});
            },
        }
    }
}

fn writeRemoteAgentInvocation(
    writer: *std.Io.Writer,
    agent: RemoteAgent,
    session_id: ?[]const u8,
    quote_style: RemoteQuoteStyle,
) !void {
    try writer.writeAll(agent.commandName());
    if (session_id) |session| {
        switch (agent) {
            .codex => try writer.writeAll(" resume "),
            .claude, .grok, .hermes, .qoder, .qwen, .reasonix => try writer.writeAll(" --resume "),
            .pi => try writer.writeAll(" --session-id "),
            .omp => try writer.writeAll(" --resume="),
            .opencode => try writer.writeAll(" --session "),
            .amp, .antigravity, .cline, .copilot, .crush, .cursor, .droid, .kimi => return error.UnsupportedAgentResume,
        }
        switch (quote_style) {
            .fish => try writer.print("\"{s}\"", .{session}),
            .shell => try writeShellSingleQuoted(writer, session),
        }
    }
}

fn writeRemotePromptFunction(
    writer: *std.Io.Writer,
    context_id: []const u8,
    label: []const u8,
) !void {
    try writer.writeAll(
        \\__omg_report_pwd() {
        \\  local __omg_hex __omg_uri='' __omg_byte
        \\  __omg_hex=$(printf '%s' "$PWD" | od -An -tx1 | tr -d ' \n')
        \\  for __omg_byte in $(printf '%s' "$PWD" | od -An -tx1); do
        \\    if [ "$__omg_byte" = 2f ]; then
        \\      __omg_uri="${__omg_uri}/"
        \\    else
        \\      __omg_uri="${__omg_uri}%${__omg_byte}"
        \\    fi
        \\  done
        \\  printf '\033]3008;start=
    );
    try writer.writeAll(context_id);
    try writer.writeAll(";type=remote;targethost=");
    try writer.writeAll(label);
    try writer.writeAll(
        \\;serverid=%s;cwdhex=%s;tty=%s\007\033]7;file://localhost%s\007' "$OMG_SSH_SERVER_ID" "$__omg_hex" "$(tty)" "$__omg_uri"
        \\}
        \\
    );
}

fn remoteStartupFileCommand(
    alloc: Allocator,
    shell_name: []const u8,
    label: []const u8,
    context_id: []const u8,
    remote_working_directory: ?[]const u8,
    remote_agent: ?RemoteAgent,
    remote_agent_session: ?[]const u8,
) ?[]const u8 {
    var startup: std.Io.Writer.Allocating = .init(alloc);
    defer startup.deinit();

    if (std.mem.eql(u8, shell_name, "bash")) {
        startup.writer.writeAll(
            \\__omg_bootstrap_rc=$OMG_SSH_RC
            \\if [ -r "$HOME/.bashrc" ]; then . "$HOME/.bashrc"; fi
            \\
        ) catch return null;
        writeRemotePromptFunction(&startup.writer, context_id, label) catch return null;
        startup.writer.writeAll(
            \\# Leave PROMPT_COMMAND ownership to the shared shell integration.
            \\# Appending after bash-preexec's interactive sentinel loses C events.
            \\__ghostty_prompt_callbacks+=(__omg_report_pwd)
            \\
        ) catch return null;
        startup.writer.writeAll(
            \\if [[ ${_ghostty_bash_initialized-} != 1 ]]; then
            \\  GHOSTTY_SHELL_FEATURES=''
            \\  builtin source "${__omg_bootstrap_rc%/*}/ghostty.bash"
            \\fi
            \\
        ) catch return null;
    } else {
        startup.writer.writeAll(
            \\__omg_bootstrap_dir=$OMG_SSH_ZDOTDIR
            \\__omg_bootstrap_root=${TMPDIR:-/tmp}
            \\ZDOTDIR=$OMG_ORIGINAL_ZDOTDIR
            \\export ZDOTDIR
            \\if [[ -r "$ZDOTDIR/.zshrc" ]]; then source "$ZDOTDIR/.zshrc"; fi
            \\
        ) catch return null;
        writeRemotePromptFunction(&startup.writer, context_id, label) catch return null;
        startup.writer.writeAll(
            \\typeset -ga precmd_functions
            \\if (( ${precmd_functions[(I)__omg_report_pwd]} == 0 )); then
            \\  precmd_functions+=(__omg_report_pwd)
            \\fi
            \\
        ) catch return null;
        startup.writer.writeAll(
            \\if (( ! $+_ghostty_state )); then
            \\  GHOSTTY_SHELL_FEATURES=''
            \\  builtin source "$__omg_bootstrap_dir/ghostty-integration"
            \\fi
            \\
        ) catch return null;
    }

    startup.writer.writeAll(
        \\if [ -n "${OMG_REMOTE_CWD-}" ]; then
        \\  cd -- "$OMG_REMOTE_CWD" 2>/dev/null || true
        \\  unset OMG_REMOTE_CWD
        \\fi
        \\
    ) catch return null;
    if (std.mem.eql(u8, shell_name, "bash")) {
        startup.writer.writeAll(
            \\__omg_bootstrap_dir=${__omg_bootstrap_rc%/*}
            \\if [[ -d "$__omg_bootstrap_dir" && -O "$__omg_bootstrap_dir" &&
            \\      "$__omg_bootstrap_dir" == "${TMPDIR:-/tmp}"/omg-ssh.* ]]; then
            \\  rm -rf -- "$__omg_bootstrap_dir"
            \\fi
            \\unset OMG_SSH_RC __omg_bootstrap_rc __omg_bootstrap_dir
            \\
        ) catch return null;
    } else {
        startup.writer.writeAll(
            \\if [[ -d "$__omg_bootstrap_dir" && -O "$__omg_bootstrap_dir" &&
            \\      "$__omg_bootstrap_dir" == "$__omg_bootstrap_root"/omg-ssh.* ]]; then
            \\  rm -rf -- "$__omg_bootstrap_dir"
            \\fi
            \\unset OMG_ORIGINAL_ZDOTDIR OMG_SSH_ZDOTDIR __omg_bootstrap_dir __omg_bootstrap_root
            \\
        ) catch return null;
    }
    startup.writer.writeAll(@import("ssh_shell_integration.zig").shell_remote_setup) catch return null;
    writeRemoteAgentWrappers(&startup.writer, .shell) catch return null;
    if (remote_agent) |agent| {
        startup.writer.writeAll("__omg_report_pwd\n") catch return null;
        writeRemoteAgentInvocation(
            &startup.writer,
            agent,
            remote_agent_session,
            .shell,
        ) catch return null;
        startup.writer.writeByte('\n') catch return null;
    }

    var command: std.Io.Writer.Allocating = .init(alloc);
    defer command.deinit();
    command.writer.writeAll("umask 077; ") catch return null;
    if (remote_working_directory) |cwd| {
        command.writer.writeAll("OMG_REMOTE_CWD=") catch return null;
        writeShellSingleQuoted(&command.writer, cwd) catch return null;
        command.writer.writeAll("; export OMG_REMOTE_CWD; ") catch return null;
    }
    if (std.mem.eql(u8, shell_name, "bash")) {
        command.writer.writeAll(
            "__omg_dir=$(mktemp -d \"${TMPDIR:-/tmp}/omg-ssh.XXXXXX\") || exit 1; " ++
                "__omg_rc=$__omg_dir/rc; OMG_SSH_RC=$__omg_rc; export OMG_SSH_RC;\n",
        ) catch return null;
        @import("ssh_shell_integration.zig").writeBashFiles(&command.writer) catch return null;
        command.writer.writeAll(
            "cat > \"$__omg_rc\" <<'__OMG_BASHRC__'\n",
        ) catch return null;
        command.writer.writeAll(startup.written()) catch return null;
        command.writer.writeAll(
            "__OMG_BASHRC__\nexec bash --rcfile \"$__omg_rc\" -i",
        ) catch return null;
    } else {
        command.writer.writeAll(
            "__omg_dir=$(mktemp -d \"${TMPDIR:-/tmp}/omg-ssh.XXXXXX\") || exit 1; " ++
                "OMG_ORIGINAL_ZDOTDIR=${ZDOTDIR:-$HOME}; OMG_SSH_ZDOTDIR=$__omg_dir; " ++
                "export OMG_ORIGINAL_ZDOTDIR OMG_SSH_ZDOTDIR;\n",
        ) catch return null;
        @import("ssh_shell_integration.zig").writeZshFile(&command.writer) catch return null;
        command.writer.writeAll(
            "cat > \"$__omg_dir/.zshrc\" <<'__OMG_ZSHRC__'\n",
        ) catch return null;
        command.writer.writeAll(startup.written()) catch return null;
        command.writer.writeAll(
            "__OMG_ZSHRC__\nZDOTDIR=$__omg_dir; export ZDOTDIR; exec zsh -l",
        ) catch return null;
    }
    return command.toOwnedSlice() catch null;
}

fn writeFishSingleQuoted(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('\'');
    for (value) |byte| {
        if (byte == '\\' or byte == '\'') try writer.writeByte('\\');
        try writer.writeByte(byte);
    }
    try writer.writeByte('\'');
}

/// sshd first parses the command using the account's login Shell. Fish 3.1
/// misparses deeply concatenated quoting around the embedded Bash/Zsh sources
/// (for example ${BASH_SOURCE[0]}). Keep their syntax opaque until /bin/sh.
/// Command substitution reads only the decoder pipe, not the interactive PTY.
fn writeEncodedBootstrapArgument(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeAll("'command -v base64 >/dev/null 2>&1 || { echo \"OMG SSH bootstrap requires base64\" >&2; exit 127; }; __omg_bootstrap=$(printf %s ");
    try std.base64.standard.Encoder.encodeWriter(writer, value);
    try writer.writeAll(" | base64 -d) || exit 1; exec /bin/sh -c \"$__omg_bootstrap\"'");
}

fn writeShellSingleQuoted(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('\'');
    for (value) |byte| {
        if (byte == '\'') try writer.writeAll("'\\''") else try writer.writeByte(byte);
    }
    try writer.writeByte('\'');
}

// SSH cannot relay a remote TUI's cleanup after a broken transport. Reset only
// mouse reporting/encoding at connection boundaries, not screen contents or
// unrelated terminal modes. Also repair modes inherited from a previous login.
const reset_mouse_modes = "\x1b[?9;1000;1002;1003;1005;1006;1015;1016l";

fn writeSessionStart(
    writer: *std.Io.Writer,
    context_id: []const u8,
    label: []const u8,
    local_cwd: []const u8,
) !void {
    try writer.writeAll(reset_mouse_modes);
    try writer.print(
        "\x1b]3008;start={s};type=remote;targethost={s};localcwd=",
        .{ context_id, label },
    );
    try string_encoding.urlPercentEncode(writer, local_cwd);
    try writer.writeByte('\x07');
}

fn writeSessionEnd(
    writer: *std.Io.Writer,
    context_id: []const u8,
    exit_code: u8,
    local_cwd: []const u8,
) !void {
    try writer.writeAll(reset_mouse_modes);
    try writer.print(
        "\x1b]3008;end={s};exit={s};status={d};cwd=",
        .{ context_id, if (exit_code == 0) "success" else "failure", exit_code },
    );
    try string_encoding.urlPercentEncode(writer, local_cwd);
    try writer.writeAll("\x07\x1b]7;file://localhost");
    try string_encoding.urlPercentEncode(writer, local_cwd);
    try writer.writeByte('\x07');
}

test interactiveSSHDestination {
    const testing = std.testing;
    try testing.expectEqualStrings("cloud", interactiveSSHDestination(&.{"cloud"}).?);
    try testing.expectEqualStrings(
        "user@example.com",
        interactiveSSHDestination(&.{ "-p", "2222", "-J", "jump", "user@example.com" }).?,
    );
    try testing.expectEqualStrings(
        "cloud",
        interactiveSSHDestination(&.{ "-C", "-v", "cloud" }).?,
    );
    try testing.expectEqualStrings(
        "cloud",
        interactiveSSHDestination(&.{ "-oProxyCommand=jump proxy", "cloud" }).?,
    );
    try testing.expect(interactiveSSHDestination(&.{ "cloud", "uptime" }) == null);
    try testing.expect(interactiveSSHDestination(&.{ "-p", "2222" }) == null);
    try testing.expect(interactiveSSHDestination(&.{ "-N", "cloud" }) == null);
    try testing.expect(interactiveSSHDestination(&.{ "-W", "host:22", "cloud" }) == null);
    try testing.expect(interactiveSSHDestination(&.{ "-O", "check", "cloud" }) == null);
    try testing.expect(interactiveSSHDestination(&.{ "-T", "cloud" }) == null);
}

test "remoteAgentWrappers" {
    const testing = std.testing;
    inline for (.{ RemoteQuoteStyle.fish, RemoteQuoteStyle.shell }) |style| {
        var output: std.Io.Writer.Allocating = .init(testing.allocator);
        defer output.deinit();
        try writeRemoteAgentWrappers(&output.writer, style);
        const script = output.written();
        try testing.expect(std.mem.indexOf(u8, script, "omg_agent=antigravity;omg_scope=remote;omg_state=idle") != null);
        try testing.expect(std.mem.indexOf(u8, script, "omg_agent=codex;omg_scope=remote;omg_state=idle") != null);
        try testing.expect(std.mem.indexOf(u8, script, "command agy") != null);
        try testing.expect(std.mem.indexOf(u8, script, "command codex") != null);
        try testing.expect(std.mem.indexOf(u8, script, "__omg_report_pwd") != null);
        try testing.expect(std.mem.indexOf(u8, script, "return ") != null);
        try testing.expect(std.mem.indexOf(u8, script, "omg_state=done") == null);
    }
}

test remoteShellCommand {
    const testing = std.testing;
    try testing.expect(sshDestinationLabel("user@cloud").?.len == "cloud".len);
    try testing.expect(sshDestinationLabel("bad;host") == null);
    const bash_command = remoteStartupFileCommand(
        testing.allocator,
        "bash",
        "vps-jump",
        "omg-ssh-bash",
        "/home/user/project's code",
        .codex,
        "019f-session_1",
    ).?;
    defer testing.allocator.free(bash_command);
    try testing.expect(std.mem.indexOf(u8, bash_command, "__OMG_BASHRC__") != null);
    try testing.expect(std.mem.indexOf(u8, bash_command, "__ghostty_prompt_callbacks+=(__omg_report_pwd)") != null);
    try testing.expect(std.mem.indexOf(u8, bash_command, "ghostty.bash") != null);
    try testing.expect(std.mem.indexOf(u8, bash_command, "bash-preexec.sh") != null);
    try testing.expect(std.mem.indexOf(u8, bash_command, "__omg_semantic_debug") == null);
    try testing.expect(std.mem.indexOf(u8, bash_command, "133;B") != null);
    try testing.expect(std.mem.indexOf(u8, bash_command, "133;C") != null);
    try testing.expect(std.mem.indexOf(u8, bash_command, "cwdhex=%s") != null);
    try testing.expect(std.mem.indexOf(u8, bash_command, "serverid=%s") != null);
    try testing.expect(std.mem.indexOf(u8, bash_command, "tty=%s") != null);
    try testing.expect(std.mem.indexOf(u8, bash_command, "targethost=vps-jump") != null);
    try testing.expect(std.mem.indexOf(u8, bash_command, "codex resume") != null);
    try testing.expect(std.mem.indexOf(u8, bash_command, "project'\\''s code") != null);

    const zsh_command = remoteStartupFileCommand(
        testing.allocator,
        "zsh",
        "train",
        "omg-ssh-zsh",
        null,
        null,
        null,
    ).?;
    defer testing.allocator.free(zsh_command);
    try testing.expect(std.mem.indexOf(u8, zsh_command, "__OMG_ZSHRC__") != null);
    try testing.expect(std.mem.indexOf(u8, zsh_command, "precmd_functions") != null);
    try testing.expect(std.mem.indexOf(u8, zsh_command, "ghostty-integration") != null);
    try testing.expect(std.mem.indexOf(u8, zsh_command, "__omg_semantic_preexec") == null);
    try testing.expect(std.mem.indexOf(u8, zsh_command, "133;B") != null);
    try testing.expect(std.mem.indexOf(u8, zsh_command, "133;C") != null);
    try testing.expect(std.mem.indexOf(u8, zsh_command, "targethost=train") != null);
    try testing.expect(std.mem.indexOf(u8, zsh_command, "-O") != null);
    try testing.expect(std.mem.indexOf(u8, zsh_command, "rm -rf --") != null);

    const encoded_command = remoteShellCommand(
        testing.allocator,
        "cloud",
        "omg-ssh-1",
        null,
        null,
        null,
    ).?;
    defer testing.allocator.free(encoded_command);
    try testing.expect(std.mem.startsWith(u8, encoded_command, "exec /bin/sh -c '"));
    try testing.expect(std.mem.indexOf(u8, encoded_command, "BASH_SOURCE") == null);
    const command = try decodeBootstrapForTest(testing.allocator, encoded_command);
    defer testing.allocator.free(command);
    try testing.expect(std.mem.indexOf(u8, command, "case ${SHELL##*/}") != null);
    try testing.expect(std.mem.indexOf(u8, command, "__ghostty_command_markers_init") != null);
    try testing.expect(std.mem.indexOf(u8, command, "cmdline_url=%s") != null);
    try testing.expect(std.mem.indexOf(u8, command, "]3008;start=omg-ssh-1") != null);
    try testing.expect(std.mem.indexOf(u8, command, "ssh_host_ed25519_key.pub") != null);
    try testing.expect(std.mem.indexOf(u8, command, "/etc/machine-id") != null);
    try testing.expect(std.mem.indexOf(u8, command, "targethost=cloud") != null);
    try testing.expect(std.mem.indexOf(u8, command, "serverid=%s") != null);
    try testing.expect(std.mem.indexOf(u8, command, "]7;") != null);
    try testing.expect(std.mem.indexOf(u8, command, "file://localhost") != null);

    const cwd_command = remoteFishCommand(
        testing.allocator,
        "cloud",
        "omg-ssh-2",
        "/home/user/project's code",
        .codex,
        "019f-session_1",
    ).?;
    defer testing.allocator.free(cwd_command);
    try testing.expect(std.mem.indexOf(u8, cwd_command, "cd --") != null);
    try testing.expect(std.mem.indexOf(u8, cwd_command, "OMG_REMOTE_CWD") != null);
    try testing.expect(std.mem.indexOf(u8, cwd_command, "__ghostty_mark_output_start") != null);
    try testing.expect(std.mem.indexOf(u8, cwd_command, "__omg_report_pwd; codex resume") != null);
    try testing.expect(std.mem.indexOf(u8, cwd_command, "019f-session_1") != null);
    try testing.expect(validAgentSessionID("019f-session_1"));
    try testing.expect(!validAgentSessionID("bad session"));
    try testing.expect(!validAgentSessionID("../escape"));

    const encoded_cwd_command = remoteShellCommand(
        testing.allocator,
        "cloud",
        "omg-ssh-cwd",
        "/home/user/project's code",
        null,
        null,
    ).?;
    defer testing.allocator.free(encoded_cwd_command);
    const full_cwd_command = try decodeBootstrapForTest(testing.allocator, encoded_cwd_command);
    defer testing.allocator.free(full_cwd_command);
    try testing.expect(std.mem.indexOf(u8, full_cwd_command, "OMG_REMOTE_CWD=") != null);
    try testing.expect(std.mem.indexOf(u8, full_cwd_command, "project") != null);
    try testing.expect(std.mem.indexOf(u8, full_cwd_command, "export OMG_REMOTE_CWD") != null);

    var fish_buffer: [128]u8 = undefined;
    var fish_writer: std.Io.Writer = .fixed(&fish_buffer);
    try writeFishSingleQuoted(&fish_writer, "/home/user/project's code");
    try testing.expectEqualStrings(
        "'/home/user/project\\'s code'",
        fish_buffer[0..fish_writer.end],
    );
}

fn decodeBootstrapForTest(alloc: Allocator, command: []const u8) ![]u8 {
    const prefix = "__omg_bootstrap=$(printf %s ";
    const start = (std.mem.indexOf(u8, command, prefix) orelse return error.MissingPayload) + prefix.len;
    const end = std.mem.indexOfPos(u8, command, start, " | base64 -d)") orelse return error.MissingPayload;
    const encoded = command[start..end];
    const data = try alloc.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(encoded));
    errdefer alloc.free(data);
    try std.base64.standard.Decoder.decode(data, encoded);
    return data;
}

test "SSH encoded bootstrap protects shell metacharacters" {
    const text = "\n'quoted' \\ backslash ${BASH_SOURCE[0]} $(dirname foo)\n你好\n";
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeEncodedBootstrapArgument(&output.writer, text);
    const decoded = try decodeBootstrapForTest(std.testing.allocator, output.written());
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings(text, decoded);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "BASH_SOURCE") == null);
}

test "replay support directory is isolated by application channel" {
    try std.testing.expectEqualStrings("OMG", replaySupportName(null));
    try std.testing.expectEqualStrings("OMG", replaySupportName("release"));
    try std.testing.expectEqualStrings("OMG Dev", replaySupportName("debug"));
    try std.testing.expectEqualStrings("OMG Dev Workspace", replaySupportName("debug-workspace"));
    try std.testing.expectEqualStrings("OMG Dev PTY", replaySupportName("debug-pty"));

    try std.testing.expect(shouldWriteReplayDescriptor("tab-id", null));
    try std.testing.expect(shouldWriteReplayDescriptor(null, "debug"));
    try std.testing.expect(!shouldWriteReplayDescriptor(null, null));
}

test "session start carries the pre-SSH local cwd" {
    const testing = std.testing;
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeSessionStart(
        &writer,
        "omg-ssh-1",
        "cloud",
        "/Users/test/my project",
    );
    const output = buffer[0..writer.end];
    try testing.expect(std.mem.startsWith(u8, output, reset_mouse_modes));
    try testing.expect(std.mem.indexOf(u8, output, "]3008;start=omg-ssh-1") != null);
    try testing.expect(std.mem.indexOf(u8, output, "targethost=cloud") != null);
    try testing.expect(std.mem.indexOf(u8, output, "localcwd=/Users/test/my%20project") != null);
}

test "session end emits typed lifecycle and local cwd resync" {
    const testing = std.testing;
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeSessionEnd(&writer, "omg-ssh-1", 255, "/Users/test/my project");
    const output = buffer[0..writer.end];
    try testing.expect(std.mem.startsWith(u8, output, reset_mouse_modes));
    try testing.expect(std.mem.indexOf(u8, output, "]3008;end=omg-ssh-1") != null);
    try testing.expect(std.mem.indexOf(u8, output, "exit=failure;status=255") != null);
    try testing.expect(std.mem.indexOf(u8, output, "cwd=/Users/test/my%20project") != null);
    try testing.expect(std.mem.indexOf(u8, output, "]7;file://localhost/Users/test/my%20project") != null);
}

test "session boundaries clear abandoned remote mouse modes" {
    const testing = std.testing;
    const terminal = @import("../terminal/main.zig");
    var t = try terminal.Terminal.init(testing.io, testing.allocator, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(testing.allocator);
    var stream = t.vtStream();
    defer stream.deinit();

    inline for (.{ false, true }) |ending| {
        // A disconnected remote application left all-motion SGR reporting on.
        stream.nextSlice("\x1b[?1003;1006h");
        try testing.expect(t.modes.get(.mouse_event_any));
        try testing.expect(t.modes.get(.mouse_format_sgr));
        var buffer: [512]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        if (ending) {
            try writeSessionEnd(&writer, "omg-ssh-1", 255, "/tmp");
        } else {
            try writeSessionStart(&writer, "omg-ssh-1", "cloud", "/tmp");
        }
        stream.nextSlice(buffer[0..writer.end]);
        inline for (.{
            .mouse_event_x10,    .mouse_event_normal,      .mouse_event_button,
            .mouse_event_any,    .mouse_format_utf8,       .mouse_format_sgr,
            .mouse_format_urxvt, .mouse_format_sgr_pixels,
        }) |mode| {
            try testing.expect(!t.modes.get(mode));
        }
    }
}

fn resolveDestination(
    alloc: Allocator,
    ssh: []const u8,
    args: []const []const u8,
) ?[]const u8 {
    const argv = std.mem.concat(alloc, []const u8, &.{
        &.{ ssh, "-G" },
        args,
    }) catch return null;
    const result = std.process.run(
        alloc,
        global.io(),
        .{ .argv = argv },
    ) catch |err| {
        log.warn("ssh -G spawn failed: {}", .{err});
        return null;
    };
    checkExit(result.term, "ssh -G") catch return null;
    return parseDestination(alloc, result.stdout);
}

/// Parse `ssh -G` output for `user` and `hostname` and return the
/// formatted `user@hostname`. Returns null if either key is missing
/// or formatting fails.
fn parseDestination(alloc: Allocator, stdout: []const u8) ?[]const u8 {
    var user: []const u8 = "";
    var host: []const u8 = "";
    var it = std.mem.tokenizeScalar(u8, stdout, '\n');
    while (it.next()) |line| {
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const key = line[0..space];
        const value = line[space + 1 ..];
        if (std.mem.eql(u8, key, "user")) {
            user = value;
        } else if (std.mem.eql(u8, key, "hostname")) {
            host = value;
        }
        if (user.len > 0 and host.len > 0) break;
    }

    if (user.len == 0) {
        log.warn("ssh -G output missing user", .{});
        return null;
    }
    if (host.len == 0) {
        log.warn("ssh -G output missing hostname", .{});
        return null;
    }

    return std.fmt.allocPrint(alloc, "{s}@{s}", .{ user, host }) catch null;
}

/// Install Ghostty's terminfo on the remote host over a short-lived SSH
/// ControlMaster connection. The master tears down with the client
/// (`ControlPersist=no`) so no socket lingers.
fn installRemoteTerminfo(
    alloc: Allocator,
    opts: *const Options,
    stderr: *std.Io.Writer,
) !void {
    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try terminfopkg.ghostty.encode(&buf.writer);
    const terminfo = buf.written();

    // ControlPath is in TMPDIR with a short, random basename. ssh uses
    // ControlPath as the bind address for a Unix domain socket; macOS
    // limits sockaddr_un.sun_path to ~104 bytes, so keeping the path
    // short leaves margin.
    const control_path = try internal_os.randomTmpPath(alloc, "ghostty-ssh-");
    const control_path_opt = try std.fmt.allocPrint(
        alloc,
        "ControlPath={s}",
        .{control_path},
    );

    // Under --verbose, let remote stderr through (the `tic` step is
    // the most common failure source) and inherit ssh's stderr so it
    // reaches the user's terminal. Other steps stay quiet either way.
    const remote_script = if (opts.verbose)
        \\command -v tic >/dev/null 2>&1 || exit 1
        \\mkdir -p ~/.terminfo 2>/dev/null && tic -x - && exit 0
        \\exit 1
    else
        \\command -v tic >/dev/null 2>&1 || exit 1
        \\mkdir -p ~/.terminfo 2>/dev/null && tic -x - 2>/dev/null && exit 0
        \\exit 1
    ;

    // Set up an SSH ControlMaster scoped to this single install:
    //   - ControlMaster=yes makes our client also act as the master.
    //   - ControlPersist=no tears the master down when our client
    //     exits; no socket lingers on the remote side.
    const argv = try std.mem.concat(alloc, []const u8, &.{
        &.{opts.ssh},
        &.{
            "-o", "ControlMaster=yes",
            "-o", "ControlPersist=no",
            "-o", control_path_opt,
        },
        opts._ssh_args.items,
        &.{remote_script},
    });
    verbosePrint(opts, stderr, "exec: {f}", .{Joined{ .items = argv }});

    var child = std.process.spawn(global.io(), .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = if (opts.verbose) .inherit else .ignore,
    }) catch |err| {
        log.warn("terminfo install spawn failed: {}", .{err});
        return error.InstallFailed;
    };

    if (child.stdin) |stdin| {
        stdin.writeStreamingAll(global.io(), terminfo) catch {};
        stdin.close(global.io());
        child.stdin = null;
    }

    const term = child.wait(global.io()) catch |err| {
        log.warn("terminfo install wait failed: {}", .{err});
        return error.InstallFailed;
    };
    checkExit(term, "terminfo install") catch return error.InstallFailed;
}

/// Returns `128 + signum` for signal-killed children, matching shell convention.
fn childExec(argv: []const []const u8) !u8 {
    var child = try std.process.spawn(global.io(), .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });

    const term = try child.wait(global.io());
    return switch (term) {
        .exited => |rc| rc,
        .signal => |sig| @as(u8, 128) + @as(u8, @intCast(@min(@intFromEnum(sig), 127))),
        .stopped, .unknown => 1,
    };
}

fn parseTestArgs(alloc: Allocator, opts: *Options, line: []const u8) !void {
    var iter = try std.process.Args.IteratorGeneral(.{}).init(alloc, line);
    defer iter.deinit();
    try cli_args.parse(Options, alloc, opts, &iter);
}

test "parseManuallyHook: bare destination starts ssh args" {
    const testing = std.testing;
    var opts: Options = .{};
    defer opts.deinit();
    try parseTestArgs(testing.allocator, &opts, "--terminfo=false user@example.com");
    try testing.expectEqual(false, opts.terminfo);
    try testing.expectEqual(true, opts.@"forward-env");
    try testing.expectEqual(@as(usize, 1), opts._ssh_args.items.len);
    try testing.expectEqualStrings("user@example.com", opts._ssh_args.items[0]);
}

test "parseManuallyHook: short ssh flags pass through verbatim" {
    const testing = std.testing;
    var opts: Options = .{};
    defer opts.deinit();
    try parseTestArgs(testing.allocator, &opts, "-p 2222 user@example.com");
    try testing.expectEqual(@as(usize, 3), opts._ssh_args.items.len);
    try testing.expectEqualStrings("-p", opts._ssh_args.items[0]);
    try testing.expectEqualStrings("2222", opts._ssh_args.items[1]);
    try testing.expectEqualStrings("user@example.com", opts._ssh_args.items[2]);
}

test "parseManuallyHook: explicit -- separator" {
    const testing = std.testing;
    var opts: Options = .{};
    defer opts.deinit();
    try parseTestArgs(
        testing.allocator,
        &opts,
        "--verbose -- --some-rare-ssh-arg user@example.com",
    );
    try testing.expectEqual(true, opts.verbose);
    try testing.expectEqual(@as(usize, 2), opts._ssh_args.items.len);
    try testing.expectEqualStrings("--some-rare-ssh-arg", opts._ssh_args.items[0]);
    try testing.expectEqualStrings("user@example.com", opts._ssh_args.items[1]);
}

test "parseDestination: typical ssh -G output" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stdout =
        \\user alice
        \\hostname example.com
        \\port 22
        \\identityfile ~/.ssh/id_ed25519
        \\
    ;
    const result = parseDestination(arena.allocator(), stdout);
    try testing.expectEqualStrings("alice@example.com", result.?);
}

test "parseDestination: hostname before user" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stdout =
        \\hostname example.com
        \\port 22
        \\user alice
        \\
    ;
    const result = parseDestination(arena.allocator(), stdout);
    try testing.expectEqualStrings("alice@example.com", result.?);
}

test "parseDestination: missing hostname returns null" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stdout = "user alice\nport 22\n";
    try testing.expectEqual(@as(?[]const u8, null), parseDestination(arena.allocator(), stdout));
}

test "parseDestination: missing user returns null" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stdout = "hostname example.com\nport 22\n";
    try testing.expectEqual(@as(?[]const u8, null), parseDestination(arena.allocator(), stdout));
}

test "parseDestination: empty input returns null" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(?[]const u8, null), parseDestination(arena.allocator(), ""));
}

test "parseDestination: IPv6 hostname" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stdout = "user alice\nhostname ::1\n";
    const result = parseDestination(arena.allocator(), stdout);
    try testing.expectEqualStrings("alice@::1", result.?);
}
