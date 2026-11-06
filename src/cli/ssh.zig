const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const cli_args = @import("args.zig");
const diagnostics = @import("diagnostics.zig");
const Action = @import("ghostty.zig").Action;
const DiskCache = @import("ssh_cache.zig").DiskCache;
const internal_os = @import("../os/main.zig");
const terminfopkg = @import("../terminfo/main.zig");
const global = @import("../global.zig");

const log = std.log.scoped(.ssh);

const usage =
    \\Usage: ghostty +ssh [flags] [--] <ssh args...>
    \\
    \\Flags:
    \\  --forward-env[=bool]  Send Ghostty env vars to the remote. Default: true.
    \\  --terminfo[=bool]     Install Ghostty terminfo on first connect. Default: true.
    \\  --cache[=bool]        Use the terminfo install cache. Default: true.
    \\  --ssh=<path>          Path to the ssh binary. Default: first `ssh` on PATH.
    \\  --verbose             Print +ssh status lines to stderr.
    \\  --help                Show full help.
    \\
    \\ssh flags and the destination go after +ssh's own flags (or after `--`).
    \\
;

pub const Options = struct {
    /// Set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    /// Send `COLORTERM`, `TERM_PROGRAM`, and `TERM_PROGRAM_VERSION` to
    /// the remote host. Maps to the `ssh-env` shell integration feature.
    @"forward-env": bool = true,

    /// Install Ghostty's terminfo on the remote host and use
    /// `xterm-ghostty` as `TERM` when it's available. Maps to the
    /// `ssh-terminfo` shell integration feature.
    terminfo: bool = true,

    /// When false, both cache read and write are bypassed.
    cache: bool = true,

    /// The wrapped `ssh` binary.
    /// `/`-containing values are treated as paths; otherwise resolved via PATH.
    ssh: []const u8 = "ssh",

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
/// Before it starts `ssh`, `+ssh` can do two pieces of setup. Both are
/// on by default, and each has its own flag:
///
///   1. **Forward Ghostty's environment** (`--forward-env`). Asks `ssh` to
///      send `COLORTERM`, `TERM_PROGRAM`, and `TERM_PROGRAM_VERSION` to the
///      remote host using `SendEnv`. Programs on the remote host can use
///      these to tell that they're running inside Ghostty. The remote
///      server only accepts them if its `sshd_config` allows them:
///
///          AcceptEnv COLORTERM TERM_PROGRAM TERM_PROGRAM_VERSION
///
///   2. **Install Ghostty's terminfo** (`--terminfo`). The first time you
///      connect to a host, `+ssh` copies Ghostty's terminfo entry to it and
///      compiles it with `tic`. This teaches programs on the remote host
///      how to use the `xterm-ghostty` terminal type. Successful installs
///      are cached (see `ghostty +ssh-cache`), so later connections to the
///      same host skip this step.
///
/// SSH authentication messages remain visible during setup, including
/// keyboard-interactive prompts and instructions. Remote installer stderr
/// stays quiet unless `--verbose` is enabled.
///
/// When either flag is enabled, `+ssh` also sets `TERM` for the remote
/// session:
///
///   * `xterm-ghostty` if the terminfo entry was just installed, or if the
///     host is already in the cache.
///
///   * `xterm-256color` in every other case. This includes
///     `--terminfo=false` and installs that fail, for example because the
///     remote host has no `tic`. A failed install prints a warning, and the
///     connection continues. Almost every system knows `xterm-256color`,
///     so it's a safe fallback.
///
/// `+ssh` skips the install when `ssh` won't open a remote terminal, which
/// is the only place `TERM` is used. For example: `ssh host cmd` without
/// `-t`, `ssh -N`, `ssh -W`, or `SessionType none` in your ssh config.
///
/// `+ssh` sets `TERM` in the environment of the `ssh` process instead of
/// passing `-o SetEnv=TERM=...`. `ssh` always sends `TERM` when it opens a
/// remote terminal, so the server doesn't need to allow it with
/// `AcceptEnv`. This also keeps any `SetEnv` lines in your `~/.ssh/config`
/// working. `ssh` only uses the first `SetEnv` it finds, so a `SetEnv` on
/// the command line would quietly replace yours.
///
/// When both flags are disabled, `+ssh` leaves `TERM` alone and runs
/// `ssh` with your environment unchanged.
///
/// Flags:
///
///   * `--forward-env=<bool>`: Send `COLORTERM`, `TERM_PROGRAM`, and
///     `TERM_PROGRAM_VERSION` to the remote host. Default: `true`.
///
///   * `--terminfo=<bool>`: Install Ghostty's terminfo on the first
///     connection to each host, and use `xterm-ghostty` as `TERM` when it's
///     available. Default: `true`.
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
///   * `--verbose`: Print +ssh status lines to stderr, and surface
///     remote stderr during the terminfo install.
///
/// Examples:
///
///     # Basic invocation using defaults:
///     ghostty +ssh user@example.com
///
///     # Forward Ghostty env vars but skip the terminfo install.
///     # The remote session uses TERM=xterm-256color:
///     ghostty +ssh --terminfo=false user@example.com
///
///     # Install terminfo but don't send any extra env vars:
///     ghostty +ssh --forward-env=false user@example.com
///
///     # SetEnv lines in your ssh config still apply. With this entry in
///     # ~/.ssh/config:
///     #
///     #   Host dev
///     #       SetEnv EDITOR=vim
///     #
///     # ssh still sends EDITOR=vim, along with the TERM chosen by +ssh:
///     ghostty +ssh dev
///
///     # `ssh` flags (short-form `-p`, etc.) pass through unchanged:
///     ghostty +ssh -p 2222 -i ~/.ssh/id_ed25519 user@example.com
///
///     # Use `--` explicitly if your ssh args might collide with our flags:
///     ghostty +ssh -- --some-rare-ssh-arg user@example.com
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

    const result = runInner(alloc_gpa, &opts, stderr);

    stderr.flush() catch {};
    return result;
}

fn runInner(
    gpa: Allocator,
    opts: *const Options,
    stderr: *std.Io.Writer,
) !u8 {
    var arena = ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    if (opts._ssh_args.items.len == 0) {
        try stderr.print("Error: no ssh arguments provided.\n\n{s}", .{usage});
        return 2;
    }

    const session: struct {
        term: []const u8,
        to_cache: ?struct { cache: DiskCache, dest: []const u8 } = null,
    } = session: {
        if (!opts.terminfo) break :session .{ .term = "xterm-256color" };

        const connection_args = ConnectionArgs.parse(opts._ssh_args.items);
        if (!connection_args.session) {
            verbosePrint(opts, stderr, "no remote session; skipping terminfo install", .{});
            break :session .{ .term = "xterm-256color" };
        }

        const config = Configuration.resolve(alloc, opts.ssh, opts._ssh_args.items) orelse {
            warnPrint(stderr, "could not resolve ssh destination; skipping terminfo install", .{});
            break :session .{ .term = "xterm-256color" };
        };
        const dest = config.destination;

        const stdin_tty = std.Io.File.stdin().isTty(global.io()) catch false;
        if (!config.opensTerminal(connection_args.command, stdin_tty)) {
            verbosePrint(opts, stderr, "no remote terminal; skipping terminfo install", .{});
            break :session .{ .term = "xterm-256color" };
        }

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

        installRemoteTerminfo(
            alloc,
            opts,
            connection_args.args,
            config.remote_command,
            stderr,
        ) catch |err| {
            warnPrint(stderr, "failed to install terminfo: {t}", .{err});
            break :session .{ .term = "xterm-256color" };
        };
        break :session .{
            .term = "xterm-ghostty",
            .to_cache = if (cache) |c| .{ .cache = c, .dest = dest } else null,
        };
    };

    // Set TERM in ssh's own environment instead of passing
    // `-o SetEnv=TERM=...`. ssh only uses the first SetEnv it finds, so a
    // SetEnv on the command line would replace every SetEnv in the user's
    // ssh config. ssh sends TERM on its own when it opens a remote
    // terminal, so the server doesn't need `AcceptEnv TERM` either.
    //
    // We do this whenever either feature is on, not only --forward-env.
    // Otherwise a failed install with --forward-env=false would leave the
    // inherited TERM=xterm-ghostty on a host that can't use it.
    var environ_map: ?std.process.Environ.Map = if (opts.@"forward-env" or opts.terminfo)
        try global.environMap()
    else
        null;
    defer if (environ_map) |*m| m.deinit();
    if (environ_map) |*m| try m.put("TERM", session.term);

    // Build the full argv: [ssh, ...our opts, ...user args]
    const env_opts: []const []const u8 = if (opts.@"forward-env") &.{
        "-o", "SendEnv=COLORTERM",
        "-o", "SendEnv=TERM_PROGRAM",
        "-o", "SendEnv=TERM_PROGRAM_VERSION",
    } else &.{};
    const argv = try std.mem.concat(alloc, []const u8, &.{
        &.{opts.ssh},
        env_opts,
        opts._ssh_args.items,
    });
    verbosePrint(opts, stderr, "exec: {f}", .{Joined{ .items = argv }});

    const exit_code = childExec(argv, if (environ_map) |*m| m else null) catch |err| {
        try stderr.print("Error: failed to run {s}: {t}\n", .{ argv[0], err });
        return 1;
    };
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

/// ssh options that take a value: the `x:` letters in the getopt() string
/// in OpenSSH's ssh.c, as of OpenSSH 10.5.
const ssh_value_options = "BbcDEeFIiJLlmOoPpQRSWw";

/// ssh options that don't open a remote session: they print and exit
/// (-G, -Q, -V) or send a command to a control master (-O). `ssh -G`
/// output doesn't reflect these.
const ssh_sessionless_options = "GOQV";

const ConnectionArgs = struct {
    /// The leading args that define the connection, without the remote
    /// command, if any.
    args: []const []const u8,

    /// True when a remote command follows the connection args.
    command: bool = false,

    /// False when an option means ssh won't open a remote session.
    session: bool = true,

    /// Whether `args` produce a remote command. ssh joins the args with spaces
    /// and treats an empty result as no command, so a lone `""` doesn't count.
    fn hasCommand(args: []const []const u8) bool {
        return args.len > 1 or (args.len == 1 and args[0].len > 0);
    }

    /// Parse `args` the way ssh does: options can appear before and after
    /// the destination, and the command starts at the next non-option
    /// argument or after `--`.
    fn parse(args: []const []const u8) ConnectionArgs {
        var result: ConnectionArgs = .{ .args = args };
        var found_dest = false;
        var skip_value = false;
        for (args, 0..) |arg, i| {
            if (skip_value) {
                skip_value = false;
                continue;
            }
            if (std.mem.eql(u8, arg, "--")) {
                const rest = args[i + 1 ..];
                if (found_dest) {
                    // Drop a `--` after the destination so options can follow.
                    result.args = args[0..i];
                    result.command = hasCommand(rest);
                } else {
                    result.args = args[0 .. i + 1 + @min(rest.len, 1)];
                    result.command = hasCommand(rest[@min(rest.len, 1)..]);
                }
                return result;
            }
            if (arg.len < 2 or arg[0] != '-') {
                if (found_dest) {
                    result.args = args[0..i];
                    result.command = hasCommand(args[i..]);
                    return result;
                }
                found_dest = true;
                continue;
            }

            // In a cluster like `-vp22` or `-vp 22`, the first option that
            // takes a value consumes the rest of the arg, or else the next one.
            for (arg[1..], 2..) |c, end| {
                if (std.mem.indexOfScalar(u8, ssh_sessionless_options, c) != null) {
                    result.session = false;
                }
                if (std.mem.indexOfScalar(u8, ssh_value_options, c) != null) {
                    skip_value = end == arg.len;
                    break;
                }
            }
        }
        return result;
    }
};

/// The parts of `ssh -G` output that `+ssh` uses. This assumes OpenSSH 8.7
/// or newer; older clients omit some of these keys, which then keep their
/// defaults.
const Configuration = struct {
    /// `user@hostname`, or `user@hostname:port` when the port isn't the
    /// default 22 (`user@[hostname]:port` for an IPv6 address).
    destination: []const u8 = "",

    session_type: []const u8 = "default",
    request_tty: []const u8 = "auto",
    stdin_null: bool = false,
    fork_after_authentication: bool = false,
    remote_command: bool = false,

    /// Whether ssh will open a remote terminal, and so send `TERM`.
    /// `command` is whether the args include a remote command, and
    /// `stdin_tty` whether our stdin is a terminal.
    fn opensTerminal(self: Configuration, command: bool, stdin_tty: bool) bool {
        if (!std.mem.eql(u8, self.session_type, "default")) return false;
        if (self.fork_after_authentication) return false;

        // This mirrors ssh's RequestTTY handling.
        const tty = stdin_tty and !self.stdin_null;
        if (std.mem.eql(u8, self.request_tty, "force")) return true;
        if (std.mem.eql(u8, self.request_tty, "true")) return tty;
        if (std.mem.eql(u8, self.request_tty, "auto")) {
            return tty and !command and !self.remote_command;
        }
        return false;
    }

    /// Parse `ssh -G` output. Returns null if user or hostname is missing
    /// or formatting the destination fails.
    fn parse(alloc: Allocator, stdout: []const u8) ?Configuration {
        var config: Configuration = .{};
        var user: []const u8 = "";
        var host: []const u8 = "";
        var port: []const u8 = "";
        var it = std.mem.tokenizeScalar(u8, stdout, '\n');
        while (it.next()) |line| {
            const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const key = line[0..space];
            const value = line[space + 1 ..];
            if (std.mem.eql(u8, key, "user")) {
                user = value;
            } else if (std.mem.eql(u8, key, "hostname")) {
                host = value;
            } else if (std.mem.eql(u8, key, "port")) {
                port = value;
            } else if (std.mem.eql(u8, key, "sessiontype")) {
                config.session_type = value;
            } else if (std.mem.eql(u8, key, "requesttty")) {
                config.request_tty = value;
            } else if (std.mem.eql(u8, key, "stdinnull")) {
                config.stdin_null = std.mem.eql(u8, value, "yes");
            } else if (std.mem.eql(u8, key, "forkafterauthentication")) {
                config.fork_after_authentication = std.mem.eql(u8, value, "yes");
            } else if (std.mem.eql(u8, key, "remotecommand")) {
                config.remote_command = true;
            }
        }

        if (user.len == 0) {
            log.warn("ssh -G output missing user", .{});
            return null;
        }
        if (host.len == 0) {
            log.warn("ssh -G output missing hostname", .{});
            return null;
        }

        config.destination = (if (port.len == 0 or std.mem.eql(u8, port, "22"))
            alloc.print("{s}@{s}", .{ user, host })
        else if (std.mem.indexOfScalar(u8, host, ':') != null)
            alloc.print("{s}@[{s}]:{s}", .{ user, host, port })
        else
            alloc.print("{s}@{s}:{s}", .{ user, host, port })) catch return null;
        return config;
    }

    /// Run `ssh -G <args>` and parse its output. Returns null if ssh fails
    /// or the destination could not be resolved.
    fn resolve(
        alloc: Allocator,
        ssh: []const u8,
        args: []const []const u8,
    ) ?Configuration {
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
        return parse(alloc, result.stdout);
    }
};

/// Install Ghostty's terminfo on the remote host over a short-lived SSH
/// ControlMaster connection. The master tears down with the client
/// (`ControlPersist=no`) so no socket lingers.
fn installRemoteTerminfo(
    alloc: Allocator,
    opts: *const Options,
    connection_args: []const []const u8,
    remote_command: bool,
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
    const control_path_opt = try alloc.print(
        "ControlPath={s}",
        .{control_path},
    );

    // Keep SSH authentication messages visible, including keyboard-interactive
    // instructions while stdin carries terminfo. Only remote installer stderr
    // is suppressed unless --verbose.
    //
    // The remote login shell may not be POSIX (e.g. tcsh, nushell, elvish),
    // so run under sh. Use a single line to avoid quoting+newline issues.
    const remote_script = if (opts.verbose)
        "sh -c 'tic -x -o ~/.terminfo - && infocmp -x xterm-ghostty >/dev/null'"
    else
        "sh -c 'tic -x -o ~/.terminfo - 2>/dev/null && infocmp -x xterm-ghostty >/dev/null 2>&1'";

    // Set up an SSH ControlMaster scoped to this single install:
    //   - ControlMaster=yes makes our client also act as the master.
    //   - ControlPersist=no tears the master down when our client
    //     exits; no socket lingers on the remote side.
    //
    // ClearAllForwardings=yes leaves the user's -L/-R/-D forwards to the
    // real session.
    //
    // RemoteCommand=none overrides a RemoteCommand from ssh_config, which ssh
    // refuses to combine with our command. It's only passed when needed
    // because OpenSSH before 7.6 rejects the option.
    //
    // -T follows the user's args to override any -t: a remote tty never
    // passes on the end of stdin, so tic would wait forever under -tt.
    const remote_command_opts: []const []const u8 = if (remote_command)
        &.{ "-o", "RemoteCommand=none" }
    else
        &.{};
    const argv = try std.mem.concat(alloc, []const u8, &.{
        &.{opts.ssh},
        &.{
            "-o", "ControlMaster=yes",
            "-o", "ControlPersist=no",
            "-o", control_path_opt,
            "-o", "ClearAllForwardings=yes",
        },
        remote_command_opts,
        connection_args,
        &.{ "-T", remote_script },
    });
    verbosePrint(opts, stderr, "exec: {f}", .{Joined{ .items = argv }});

    var child = std.process.spawn(global.io(), .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .inherit,
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

/// Run `argv` with the terminal's stdin, stdout, and stderr, and wait for
/// it to exit. When `environ_map` is null, the child inherits our
/// environment. Otherwise, it replaces the environment entirely.
///
/// Returns the child's exit code, or `128 + signum` if a signal killed it,
/// matching shell convention.
fn childExec(
    argv: []const []const u8,
    environ_map: ?*const std.process.Environ.Map,
) !u8 {
    var child = try std.process.spawn(global.io(), .{
        .argv = argv,
        .environ_map = environ_map,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });

    const term = try child.wait(global.io());
    return switch (term) {
        .exited => |rc| rc,
        .signal => |sig| @as(u8, 128) + @as(u8, @intCast(@min(@backingInt(sig), 127))),
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

test "ConnectionArgs.parse" {
    const testing = std.testing;
    const cases = [_]struct {
        args: []const []const u8,
        len: usize,
        command: bool = false,
        session: bool = true,
    }{
        .{ .args = &.{}, .len = 0 },
        .{ .args = &.{"host"}, .len = 1 },
        .{ .args = &.{ "host", "ls", "-la" }, .len = 1, .command = true },
        .{ .args = &.{ "-p", "2222", "host", "vim" }, .len = 3, .command = true },
        .{ .args = &.{ "host", "-p", "2222", "vim" }, .len = 3, .command = true },
        .{ .args = &.{ "host", "-t", "vim", "-p", "2222" }, .len = 2, .command = true },
        .{ .args = &.{ "-vp2222", "host", "ls" }, .len = 2, .command = true },
        .{ .args = &.{ "-vp", "2222", "host", "ls" }, .len = 3, .command = true },
        .{ .args = &.{ "-o", "User=bob", "host", "ls" }, .len = 3, .command = true },
        .{ .args = &.{ "--", "host", "-p", "2222" }, .len = 2, .command = true },
        .{ .args = &.{ "--", "host" }, .len = 2 },
        .{ .args = &.{ "host", "--", "-p", "2222" }, .len = 1, .command = true },
        .{ .args = &.{ "host", "--" }, .len = 1 },
        .{ .args = &.{ "host", "" }, .len = 1 },
        .{ .args = &.{ "host", "", "" }, .len = 1, .command = true },
        .{ .args = &.{ "host", "--", "" }, .len = 1 },
        .{ .args = &.{"--"}, .len = 1 },
        .{ .args = &.{"-p"}, .len = 1 },
        .{ .args = &.{ "-G", "host" }, .len = 2, .session = false },
        .{ .args = &.{ "-O", "check", "host" }, .len = 3, .session = false },
        .{ .args = &.{"-V"}, .len = 1, .session = false },
        .{ .args = &.{ "host", "ls", "-G" }, .len = 1, .command = true },
        .{ .args = &.{ "-lG", "host" }, .len = 2 },
    };
    for (cases) |case| {
        const got = ConnectionArgs.parse(case.args);
        try testing.expectEqual(case.len, got.args.len);
        try testing.expectEqual(case.command, got.command);
        try testing.expectEqual(case.session, got.session);
    }
}

test "Configuration.parse: session settings" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stdout =
        \\user alice
        \\hostname example.com
        \\requesttty force
        \\sessiontype none
        \\stdinnull yes
        \\forkafterauthentication yes
        \\remotecommand tmux new -A
        \\
    ;
    const config = Configuration.parse(arena.allocator(), stdout).?;
    try testing.expectEqualStrings("force", config.request_tty);
    try testing.expectEqualStrings("none", config.session_type);
    try testing.expect(config.stdin_null);
    try testing.expect(config.fork_after_authentication);
    try testing.expect(config.remote_command);
}

test "Configuration.opensTerminal" {
    const testing = std.testing;
    const cases = [_]struct {
        config: Configuration,
        command: bool = false,
        stdin_tty: bool = true,
        opens: bool,
    }{
        .{ .config = .{}, .opens = true },
        .{ .config = .{}, .command = true, .opens = false },
        .{ .config = .{}, .stdin_tty = false, .opens = false },
        .{ .config = .{ .request_tty = "true" }, .command = true, .opens = true },
        .{ .config = .{ .request_tty = "true" }, .stdin_tty = false, .opens = false },
        .{ .config = .{ .request_tty = "force" }, .stdin_tty = false, .opens = true },
        .{ .config = .{ .request_tty = "false" }, .opens = false },
        .{ .config = .{ .session_type = "none" }, .opens = false },
        .{ .config = .{ .session_type = "subsystem" }, .opens = false },
        .{ .config = .{ .fork_after_authentication = true }, .opens = false },
        .{ .config = .{ .stdin_null = true }, .opens = false },
        .{ .config = .{ .stdin_null = true, .request_tty = "force" }, .opens = true },
        .{ .config = .{ .remote_command = true }, .opens = false },
        .{ .config = .{ .remote_command = true, .request_tty = "true" }, .opens = true },
    };
    for (cases) |case| {
        try testing.expectEqual(case.opens, case.config.opensTerminal(case.command, case.stdin_tty));
    }
}

test "Configuration.parse: typical ssh -G output" {
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
    const result = Configuration.parse(arena.allocator(), stdout);
    try testing.expectEqualStrings("alice@example.com", result.?.destination);
}

test "Configuration.parse: hostname before user" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stdout =
        \\hostname example.com
        \\port 22
        \\user alice
        \\
    ;
    const result = Configuration.parse(arena.allocator(), stdout);
    try testing.expectEqualStrings("alice@example.com", result.?.destination);
}

test "Configuration.parse: missing hostname returns null" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stdout = "user alice\nport 22\n";
    try testing.expect(Configuration.parse(arena.allocator(), stdout) == null);
}

test "Configuration.parse: missing user returns null" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stdout = "hostname example.com\nport 22\n";
    try testing.expect(Configuration.parse(arena.allocator(), stdout) == null);
}

test "Configuration.parse: empty input returns null" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect(Configuration.parse(arena.allocator(), "") == null);
}

test "Configuration.parse: IPv6 hostname" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stdout = "user alice\nhostname ::1\n";
    const result = Configuration.parse(arena.allocator(), stdout);
    try testing.expectEqualStrings("alice@::1", result.?.destination);
}

test "Configuration.parse: non-default port" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stdout =
        \\user alice
        \\hostname example.com
        \\port 2222
        \\
    ;
    const result = Configuration.parse(arena.allocator(), stdout);
    try testing.expectEqualStrings("alice@example.com:2222", result.?.destination);
}

test "Configuration.parse: port before hostname" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stdout = "port 2222\nuser alice\nhostname example.com\n";
    const result = Configuration.parse(arena.allocator(), stdout);
    try testing.expectEqualStrings("alice@example.com:2222", result.?.destination);
}

test "Configuration.parse: IPv6 hostname with non-default port" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stdout = "user alice\nhostname ::1\nport 2222\n";
    const result = Configuration.parse(arena.allocator(), stdout);
    try testing.expectEqualStrings("alice@[::1]:2222", result.?.destination);
}

test "Configuration.parse: result is a valid cache key" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const outputs = [_][]const u8{
        "user alice\nhostname example.com\nport 22\n",
        "user alice\nhostname example.com\nport 2222\n",
        "user alice\nhostname 2001:db8::1\nport 22\n",
        "user alice\nhostname 2001:db8::1\nport 2222\n",
    };
    for (outputs) |stdout| {
        const result = Configuration.parse(arena.allocator(), stdout).?.destination;
        try testing.expect(DiskCache.isValidCacheKey(result));
    }
}
