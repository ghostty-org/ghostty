//! Exec implements the logic for starting and stopping a subprocess with a
//! pty as well as spinning up the necessary read thread to read from the
//! pty and forward it to the Termio instance.
const Exec = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const posix = std.posix;
const xev = @import("../global.zig").xev;
const build_config = @import("../build_config.zig");
const configpkg = @import("../config.zig");
const crash = @import("../crash/main.zig");
const fastmem = @import("../fastmem.zig");
const internal_os = @import("../os/main.zig");
const renderer = @import("../renderer.zig");
const shell_integration = @import("shell_integration.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const Command = @import("../Command.zig");
const SegmentedPool = @import("../datastruct/main.zig").SegmentedPool;
const ptypkg = @import("../pty.zig");
const Pty = ptypkg.Pty;
const EnvMap = std.process.EnvMap;
const windows = internal_os.windows;

const log = std.log.scoped(.io_exec);

/// The termios poll rate in milliseconds.
const TERMIOS_POLL_MS = 200;

/// The subprocess state for our exec backend.
subprocess: Subprocess,

/// Initialize the exec state. This will NOT start it, this only sets
/// up the internal state necessary to start it later.
pub fn init(
    alloc: Allocator,
    cfg: Config,
) !Exec {
    var subprocess = try Subprocess.init(alloc, cfg);
    errdefer subprocess.deinit();

    return .{ .subprocess = subprocess };
}

pub fn deinit(self: *Exec) void {
    self.subprocess.deinit();
}

/// Call to initialize the terminal state as necessary for this backend.
/// This is called before any termio begins. This should not be called
/// after termio begins because it may put the internal terminal state
/// into a bad state.
pub fn initTerminal(self: *Exec, term: *terminal.Terminal) void {
    // If we have an initial pwd requested by the subprocess, then we
    // set that on the terminal now. This allows rapidly initializing
    // new surfaces to use the proper pwd.
    if (self.subprocess.cwd) |cwd| term.setPwd(cwd) catch |err| {
        log.warn("error setting initial pwd err={}", .{err});
    };

    // Setup our initial grid/screen size from the terminal. This
    // can't fail because the pty should not exist at this point.
    self.resize(.{
        .columns = term.cols,
        .rows = term.rows,
    }, .{
        .width = term.width_px,
        .height = term.height_px,
    }) catch unreachable;
}

pub fn threadEnter(
    self: *Exec,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    // Start our subprocess
    const pty_fds = self.subprocess.start(alloc) catch |err| {
        // If we specifically got this error then we are in the forked
        // process and our child failed to execute. In that case
        if (err != error.Termio) return err;

        // Output an error message about the exec faililng and exit.
        // This generally should NOT happen because we always wrap
        // our command execution either in login (macOS) or /bin/sh
        // (Linux) which are usually guaranteed to exist. Still, we
        // want to handle this scenario.
        execFailedInChild() catch {};
        posix.exit(1);
    };
    errdefer self.subprocess.stop();

    // Get the pid from the subprocess
    const pid = pid: {
        const command = self.subprocess.command orelse return error.ProcessNotStarted;
        break :pid command.pid orelse return error.ProcessNoPid;
    };

    // Track our process start time for abnormal exits
    const process_start = try std.time.Instant.now();

    // Create our pipe that we'll use to kill our read thread.
    // pipe[0] is the read end, pipe[1] is the write end.
    const pipe = try internal_os.pipe();
    errdefer posix.close(pipe[0]);
    errdefer posix.close(pipe[1]);

    // Setup our stream so that we can write.
    var stream = xev.Stream.initFd(pty_fds.write);
    errdefer stream.deinit();

    // Watcher to detect subprocess exit
    var process = try xev.Process.init(pid);
    errdefer process.deinit();

    // Start our timer to read termios state changes. This is used
    // to detect things such as when password input is being done
    // so we can render the terminal in a different way.
    var termios_timer = try xev.Timer.init();
    errdefer termios_timer.deinit();

    // Start our read thread
    const read_thread = try std.Thread.spawn(
        .{},
        if (builtin.os.tag == .windows) ReadThread.threadMainWindows else ReadThread.threadMainPosix,
        .{ pty_fds.read, io, pipe[0] },
    );
    read_thread.setName("io-reader") catch {};

    // Setup our threadata backend state to be our own
    td.backend = .{ .exec = .{
        .start = process_start,
        .abnormal_runtime_threshold_ms = io.config.abnormal_runtime_threshold_ms,
        .wait_after_command = io.config.wait_after_command,
        .write_stream = stream,
        .process = process,
        .read_thread = read_thread,
        .read_thread_pipe = pipe[1],
        .read_thread_fd = pty_fds.read,
        .termios_timer = termios_timer,
    } };

    // Start our process watcher
    process.wait(
        td.loop,
        &td.backend.exec.process_wait_c,
        termio.Termio.ThreadData,
        td,
        processExit,
    );

    // Start our termios timer. We don't support this on Windows.
    // Fundamentally, we could support this on Windows so we're just
    // waiting for someone to implement it.
    if (comptime builtin.os.tag != .windows) {
        termios_timer.run(
            td.loop,
            &td.backend.exec.termios_timer_c,
            TERMIOS_POLL_MS,
            termio.Termio.ThreadData,
            td,
            termiosTimer,
        );
    }
}

pub fn threadExit(self: *Exec, td: *termio.Termio.ThreadData) void {
    assert(td.backend == .exec);
    const exec = &td.backend.exec;

    if (exec.exited) self.subprocess.externalExit();
    self.subprocess.stop();

    // Quit our read thread after exiting the subprocess so that
    // we don't get stuck waiting for data to stop flowing if it is
    // a particularly noisy process.
    _ = posix.write(exec.read_thread_pipe, "x") catch |err| switch (err) {
        // BrokenPipe means that our read thread is closed already,
        // which is completely fine since that is what we were trying
        // to achieve.
        error.BrokenPipe => {},

        else => log.warn(
            "error writing to read thread quit pipe err={}",
            .{err},
        ),
    };

    if (comptime builtin.os.tag == .windows) {
        // Interrupt the blocking read so the thread can see the quit message
        if (windows.kernel32.CancelIoEx(exec.read_thread_fd, null) == 0) {
            switch (windows.kernel32.GetLastError()) {
                .NOT_FOUND => {},
                else => |err| log.warn("error interrupting read thread err={}", .{err}),
            }
        }
    }

    exec.read_thread.join();
}

pub fn focusGained(
    self: *Exec,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = self;

    assert(td.backend == .exec);
    const execdata = &td.backend.exec;

    if (!focused) {
        // Flag the timer to end on the next iteration. This is
        // a lot cheaper than doing full timer cancellation.
        execdata.termios_timer_running = false;
    } else {
        // Always set this to true. There is a race condition if we lose
        // focus and regain focus before the termios timer ticks where
        // if we don't set this unconditionally the timer will end on
        // the next iteration.
        execdata.termios_timer_running = true;

        // If we're focused, we want to start our termios timer. We
        // only do this if it isn't already running. We use the termios
        // callback because that'll trigger an immediate state check AND
        // start the timer.
        if (execdata.termios_timer_c.state() != .active) {
            _ = termiosTimer(td, undefined, undefined, {});
        }
    }
}

pub fn resize(
    self: *Exec,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    return try self.subprocess.resize(grid_size, screen_size);
}

/// Called when the child process exited abnormally but before the surface
/// is notified.
pub fn childExitedAbnormally(
    self: *Exec,
    gpa: Allocator,
    t: *terminal.Terminal,
    exit_code: u32,
    runtime_ms: u64,
) !void {
    var arena = ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Build up our command for the error message
    const command = try std.mem.join(alloc, " ", self.subprocess.args);
    const runtime_str = try std.fmt.allocPrint(alloc, "{d} ms", .{runtime_ms});

    // No matter what move the cursor back to the column 0.
    t.carriageReturn();

    // Reset styles
    try t.setAttribute(.{ .unset = {} });

    // If there is data in the viewport, we want to scroll down
    // a little bit and write a horizontal rule before writing
    // our message. This lets the use see the error message the
    // command may have output.
    const viewport_str = try t.plainString(alloc);
    if (viewport_str.len > 0) {
        try t.linefeed();
        for (0..t.cols) |_| try t.print(0x2501);
        t.carriageReturn();
        try t.linefeed();
        try t.linefeed();
    }

    // Output our error message
    try t.setAttribute(.{ .@"8_fg" = .bright_red });
    try t.setAttribute(.{ .bold = {} });
    try t.printString("Ghostty failed to launch the requested command:");
    try t.setAttribute(.{ .unset = {} });

    t.carriageReturn();
    try t.linefeed();
    try t.linefeed();
    try t.printString(command);
    try t.setAttribute(.{ .unset = {} });

    t.carriageReturn();
    try t.linefeed();
    try t.linefeed();
    try t.printString("Runtime: ");
    try t.setAttribute(.{ .@"8_fg" = .red });
    try t.printString(runtime_str);
    try t.setAttribute(.{ .unset = {} });

    // We don't print this on macOS because the exit code is always 0
    // due to the way we launch the process.
    if (comptime !builtin.target.isDarwin()) {
        const exit_code_str = try std.fmt.allocPrint(alloc, "{d}", .{exit_code});
        t.carriageReturn();
        try t.linefeed();
        try t.printString("Exit Code: ");
        try t.setAttribute(.{ .@"8_fg" = .red });
        try t.printString(exit_code_str);
        try t.setAttribute(.{ .unset = {} });
    }

    t.carriageReturn();
    try t.linefeed();
    try t.linefeed();
    try t.printString("Press any key to close the window.");

    // Hide the cursor
    t.modes.set(.cursor_visible, false);
}

/// This outputs an error message when exec failed and we are the
/// child process. This returns so the caller should probably exit
/// after calling this.
///
/// Note that this usually is only called under very very rare
/// circumstances because we wrap our command execution in login
/// (macOS) or /bin/sh (Linux). So this output can be pretty crude
/// because it should never happen. Notably, this is not the error
/// users see when `command` is invalid.
fn execFailedInChild() !void {
    const stderr = std.io.getStdErr().writer();
    try stderr.writeAll("exec failed\n");
    try stderr.writeAll("press any key to exit\n");

    var buf: [1]u8 = undefined;
    var reader = std.io.getStdIn().reader();
    _ = try reader.read(&buf);
}

fn processExit(
    td_: ?*termio.Termio.ThreadData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Process.WaitError!u32,
) xev.CallbackAction {
    const exit_code = r catch unreachable;

    const td = td_.?;
    assert(td.backend == .exec);
    const execdata = &td.backend.exec;
    execdata.exited = true;

    // Determine how long the process was running for.
    const runtime_ms: ?u64 = runtime: {
        const process_end = std.time.Instant.now() catch break :runtime null;
        const runtime_ns = process_end.since(execdata.start);
        const runtime_ms = runtime_ns / std.time.ns_per_ms;
        break :runtime runtime_ms;
    };
    log.debug(
        "child process exited status={} runtime={}ms",
        .{ exit_code, runtime_ms orelse 0 },
    );

    // If our runtime was below some threshold then we assume that this
    // was an abnormal exit and we show an error message.
    if (runtime_ms) |runtime| runtime: {
        // On macOS, our exit code detection doesn't work, possibly
        // because of our `login` wrapper. More investigation required.
        if (comptime !builtin.target.isDarwin()) {
            // If our exit code is zero, then the command was successful
            // and we don't ever consider it abnormal.
            if (exit_code == 0) break :runtime;
        }

        // Our runtime always has to be under the threshold to be
        // considered abnormal. This is because a user can always
        // manually do something like `exit 1` in their shell to
        // force the exit code to be non-zero. We only want to detect
        // abnormal exits that happen so quickly the user can't react.
        if (runtime > execdata.abnormal_runtime_threshold_ms) break :runtime;
        log.warn("abnormal process exit detected, showing error message", .{});

        // Notify our main writer thread which has access to more
        // information so it can show a better error message.
        td.mailbox.send(.{
            .child_exited_abnormally = .{
                .exit_code = exit_code,
                .runtime_ms = runtime,
            },
        }, null);
        td.mailbox.notify();

        return .disarm;
    }

    // If we're purposely waiting then we just return since the process
    // exited flag is set to true. This allows the terminal window to remain
    // open.
    if (execdata.wait_after_command) {
        // We output a message so that the user knows whats going on and
        // doesn't think their terminal just froze.
        terminal: {
            td.renderer_state.mutex.lock();
            defer td.renderer_state.mutex.unlock();
            const t = td.renderer_state.terminal;
            t.carriageReturn();
            t.linefeed() catch break :terminal;
            t.printString("Process exited. Press any key to close the terminal.") catch
                break :terminal;
            t.modes.set(.cursor_visible, false);
        }

        return .disarm;
    }

    // Notify our surface we want to close
    _ = td.surface_mailbox.push(.{
        .child_exited = {},
    }, .{ .forever = {} });

    return .disarm;
}

fn termiosTimer(
    td_: ?*termio.Termio.ThreadData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    // log.debug("termios timer fired", .{});

    // This should never happen because we guard starting our
    // timer on windows but we want this assertion to fire if
    // we ever do start the timer on windows.
    // TODO: support on windows
    if (comptime builtin.os.tag == .windows) {
        @panic("termios timer not implemented on Windows");
    }

    _ = r catch |err| switch (err) {
        // This is sent when our timer is canceled. That's fine.
        error.Canceled => return .disarm,

        else => {
            log.warn("error in termios timer callback err={}", .{err});
            @panic("crash in termios timer callback");
        },
    };

    const td = td_.?;
    assert(td.backend == .exec);
    const exec = &td.backend.exec;

    // This is kind of hacky but we rebuild a Pty struct to get the
    // termios data.
    const mode: ptypkg.Mode = (Pty{
        .master = exec.read_thread_fd,
        .slave = undefined,
    }).getMode() catch |err| err: {
        log.warn("error getting termios mode err={}", .{err});

        // If we have an error we return the default mode values
        // which are the likely values.
        break :err .{};
    };

    // If the mode changed, then we process it.
    if (!std.meta.eql(mode, exec.termios_mode)) mode_change: {
        log.debug("termios change mode={}", .{mode});
        exec.termios_mode = mode;

        // We assume we're in some sort of password input if we're
        // in canonical mode and not echoing. This is a heuristic.
        const password_input = mode.canonical and !mode.echo;

        // If our password input state changed on the terminal then
        // we notify the surface.
        {
            td.renderer_state.mutex.lock();
            defer td.renderer_state.mutex.unlock();
            const t = td.renderer_state.terminal;
            if (t.flags.password_input == password_input) {
                break :mode_change;
            }
        }

        // We have to notify the surface that we're in password input.
        // We must block on this because the balanced true/false state
        // of this is critical to apprt behavior.
        _ = td.surface_mailbox.push(.{
            .password_input = password_input,
        }, .{ .forever = {} });
    }

    // Repeat the timer
    if (exec.termios_timer_running) {
        exec.termios_timer.run(
            td.loop,
            &exec.termios_timer_c,
            TERMIOS_POLL_MS,
            termio.Termio.ThreadData,
            td,
            termiosTimer,
        );
    }

    return .disarm;
}

pub fn queueWrite(
    self: *Exec,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = self;
    const exec = &td.backend.exec;

    // If our process is exited then we send our surface a message
    // about it but we don't queue any more writes.
    if (exec.exited) {
        _ = td.surface_mailbox.push(.{
            .child_exited = {},
        }, .{ .forever = {} });
        return;
    }

    // We go through and chunk the data if necessary to fit into
    // our cached buffers that we can queue to the stream.
    var i: usize = 0;
    while (i < data.len) {
        const req = try exec.write_req_pool.getGrow(alloc);
        const buf = try exec.write_buf_pool.getGrow(alloc);
        const slice = slice: {
            // The maximum end index is either the end of our data or
            // the end of our buffer, whichever is smaller.
            const max = @min(data.len, i + buf.len);

            // Fast
            if (!linefeed) {
                fastmem.copy(u8, buf, data[i..max]);
                const len = max - i;
                i = max;
                break :slice buf[0..len];
            }

            // Slow, have to replace \r with \r\n
            var buf_i: usize = 0;
            while (i < data.len and buf_i < buf.len - 1) {
                const ch = data[i];
                i += 1;

                if (ch != '\r') {
                    buf[buf_i] = ch;
                    buf_i += 1;
                    continue;
                }

                // CRLF
                buf[buf_i] = '\r';
                buf[buf_i + 1] = '\n';
                buf_i += 2;
            }

            break :slice buf[0..buf_i];
        };

        //for (slice) |b| log.warn("write: {x}", .{b});

        exec.write_stream.queueWrite(
            td.loop,
            &exec.write_queue,
            req,
            .{ .slice = slice },
            termio.Exec.ThreadData,
            exec,
            ttyWrite,
        );
    }
}

fn ttyWrite(
    td_: ?*ThreadData,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.Stream,
    _: xev.WriteBuffer,
    r: xev.WriteError!usize,
) xev.CallbackAction {
    const td = td_.?;
    td.write_req_pool.put();
    td.write_buf_pool.put();

    const d = r catch |err| {
        log.err("write error: {}", .{err});
        return .disarm;
    };
    _ = d;
    //log.info("WROTE: {d}", .{d});

    return .disarm;
}

/// The thread local data for the exec implementation.
pub const ThreadData = struct {
    // The preallocation size for the write request pool. This should be big
    // enough to satisfy most write requests. It must be a power of 2.
    const WRITE_REQ_PREALLOC = std.math.pow(usize, 2, 5);

    /// Process start time and boolean of whether its already exited.
    start: std.time.Instant,
    exited: bool = false,

    /// The number of milliseconds below which we consider a process
    /// exit to be abnormal. This is used to show an error message
    /// when the process exits too quickly.
    abnormal_runtime_threshold_ms: u32,

    /// If true, do not immediately send a child exited message to the
    /// surface to close the surface when the command exits. If this is
    /// false we'll show a process exited message and wait for user input
    /// to close the surface.
    wait_after_command: bool,

    /// The data stream is the main IO for the pty.
    write_stream: xev.Stream,

    /// The process watcher
    process: xev.Process,

    /// This is the pool of available (unused) write requests. If you grab
    /// one from the pool, you must put it back when you're done!
    write_req_pool: SegmentedPool(xev.WriteRequest, WRITE_REQ_PREALLOC) = .{},

    /// The pool of available buffers for writing to the pty.
    write_buf_pool: SegmentedPool([64]u8, WRITE_REQ_PREALLOC) = .{},

    /// The write queue for the data stream.
    write_queue: xev.WriteQueue = .{},

    /// This is used for both waiting for the process to exit and then
    /// subsequently to wait for the data_stream to close.
    process_wait_c: xev.Completion = .{},

    /// Reader thread state
    read_thread: std.Thread,
    read_thread_pipe: posix.fd_t,
    read_thread_fd: posix.fd_t,

    /// The timer to detect termios state changes.
    termios_timer: xev.Timer,
    termios_timer_c: xev.Completion = .{},
    termios_timer_running: bool = true,

    /// The last known termios mode. Used for change detection
    /// to prevent unnecessary locking of expensive mutexes.
    termios_mode: ptypkg.Mode = .{},

    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        posix.close(self.read_thread_pipe);

        // Clear our write pools. We know we aren't ever going to do
        // any more IO since we stop our data stream below so we can just
        // drop this.
        self.write_req_pool.deinit(alloc);
        self.write_buf_pool.deinit(alloc);

        // Stop our process watcher
        self.process.deinit();

        // Stop our write stream
        self.write_stream.deinit();

        // Stop our termios timer
        self.termios_timer.deinit();
    }
};

pub const Config = struct {
    command: ?[]const u8 = null,
    env: EnvMap,
    env_override: configpkg.RepeatableStringMap = .{},
    shell_integration: configpkg.Config.ShellIntegration = .detect,
    shell_integration_features: configpkg.Config.ShellIntegrationFeatures = .{},
    working_directory: ?[]const u8 = null,
    resources_dir: ?[]const u8,
    term: []const u8,
    linux_cgroup: Command.LinuxCgroup = Command.linux_cgroup_default,
};

const Subprocess = struct {
    /// If we build with flatpak support then we have to keep track of
    /// a potential execution on the host.
    const FlatpakHostCommand = if (build_config.flatpak) internal_os.FlatpakHostCommand else void;

    const c = @cImport({
        @cInclude("errno.h");
        @cInclude("signal.h");
        @cInclude("unistd.h");
    });

    arena: std.heap.ArenaAllocator,
    cwd: ?[]const u8,
    env: ?EnvMap,
    args: [][]const u8,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
    pty: ?Pty = null,
    command: ?Command = null,
    flatpak_command: ?FlatpakHostCommand = null,
    linux_cgroup: Command.LinuxCgroup = Command.linux_cgroup_default,

    /// Initialize the subprocess. This will NOT start it, this only sets
    /// up the internal state necessary to start it later.
    pub fn init(gpa: Allocator, cfg: Config) !Subprocess {
        // We have a lot of maybe-allocations that all share the same lifetime
        // so use an arena so we don't end up in an accounting nightmare.
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        // Get our env. If a default env isn't provided by the caller
        // then we get it ourselves.
        var env = cfg.env;

        // If we have a resources dir then set our env var
        if (cfg.resources_dir) |dir| {
            log.info("found Ghostty resources dir: {s}", .{dir});
            try env.put("GHOSTTY_RESOURCES_DIR", dir);
        }

        // Set our TERM var. This is a bit complicated because we want to use
        // the ghostty TERM value but we want to only do that if we have
        // ghostty in the TERMINFO database.
        //
        // For now, we just look up a bundled dir but in the future we should
        // also load the terminfo database and look for it.
        if (cfg.resources_dir) |base| {
            try env.put("TERM", cfg.term);
            try env.put("COLORTERM", "truecolor");

            // Assume that the resources directory is adjacent to the terminfo
            // database
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const dir = try std.fmt.bufPrint(&buf, "{s}/terminfo", .{
                std.fs.path.dirname(base) orelse unreachable,
            });
            try env.put("TERMINFO", dir);
        } else {
            if (comptime builtin.target.isDarwin()) {
                log.warn("ghostty terminfo not found, using xterm-256color", .{});
                log.warn("the terminfo SHOULD exist on macos, please ensure", .{});
                log.warn("you're using a valid app bundle.", .{});
            }

            try env.put("TERM", "xterm-256color");
            try env.put("COLORTERM", "truecolor");
        }

        // Add our binary to the path if we can find it.
        ghostty_path: {
            var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
            const exe_bin_path = std.fs.selfExePath(&exe_buf) catch |err| {
                log.warn("failed to get ghostty exe path err={}", .{err});
                break :ghostty_path;
            };
            const exe_dir = std.fs.path.dirname(exe_bin_path) orelse break :ghostty_path;
            log.debug("appending ghostty bin to path dir={s}", .{exe_dir});

            // We always set this so that if the shell overwrites the path
            // scripts still have a way to find the Ghostty binary when
            // running in Ghostty.
            try env.put("GHOSTTY_BIN_DIR", exe_dir);

            // Append if we have a path. We want to append so that ghostty is
            // the last priority in the path. If we don't have a path set
            // then we just set it to the directory of the binary.
            if (env.get("PATH")) |path| {
                // Verify that our path doesn't already contain this entry
                var it = std.mem.tokenizeScalar(u8, path, std.fs.path.delimiter);
                while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry, exe_dir)) break :ghostty_path;
                }

                try env.put(
                    "PATH",
                    try internal_os.appendEnv(alloc, path, exe_dir),
                );
            } else {
                try env.put("PATH", exe_dir);
            }
        }

        // On macOS, export additional data directories from our
        // application bundle.
        if (comptime builtin.target.isDarwin()) darwin: {
            const resources_dir = cfg.resources_dir orelse break :darwin;

            var buf: [std.fs.max_path_bytes]u8 = undefined;

            const xdg_data_dir_key = "XDG_DATA_DIRS";
            if (std.fmt.bufPrint(&buf, "{s}/..", .{resources_dir})) |data_dir| {
                try env.put(
                    xdg_data_dir_key,
                    try internal_os.appendEnv(
                        alloc,
                        env.get(xdg_data_dir_key) orelse "/usr/local/share:/usr/share",
                        data_dir,
                    ),
                );
            } else |err| {
                log.warn("error building {s}; err={}", .{ xdg_data_dir_key, err });
            }

            const manpath_key = "MANPATH";
            if (std.fmt.bufPrint(&buf, "{s}/../man", .{resources_dir})) |man_dir| {
                // Always append with colon in front, as it mean that if
                // `MANPATH` is empty, then it should be treated as an extra
                // path instead of overriding all paths set by OS.
                try env.put(
                    manpath_key,
                    try internal_os.appendEnvAlways(
                        alloc,
                        env.get(manpath_key) orelse "",
                        man_dir,
                    ),
                );
            } else |err| {
                log.warn("error building {s}; man pages may not be available; err={}", .{ manpath_key, err });
            }
        }

        // Set environment variables used by some programs (such as neovim) to detect
        // which terminal emulator and version they're running under.
        try env.put("TERM_PROGRAM", "ghostty");
        try env.put("TERM_PROGRAM_VERSION", build_config.version_string);

        // VTE_VERSION is set by gnome-terminal and other VTE-based terminals.
        // We don't want our child processes to think we're running under VTE.
        // This is not apprt-specific, so we do it here.
        env.remove("VTE_VERSION");

        // Setup our shell integration, if we can.
        const integrated_shell: ?shell_integration.Shell, const shell_command: []const u8 = shell: {
            const default_shell_command = cfg.command orelse switch (builtin.os.tag) {
                .windows => "cmd.exe",
                else => "sh",
            };

            const force: ?shell_integration.Shell = switch (cfg.shell_integration) {
                .none => {
                    // Even if shell integration is none, we still want to set up the feature env vars
                    try shell_integration.setupFeatures(&env, cfg.shell_integration_features);
                    break :shell .{ null, default_shell_command };
                },
                .detect => null,
                .bash => .bash,
                .elvish => .elvish,
                .fish => .fish,
                .zsh => .zsh,
            };

            const dir = cfg.resources_dir orelse break :shell .{
                null,
                default_shell_command,
            };

            const integration = try shell_integration.setup(
                alloc,
                dir,
                default_shell_command,
                &env,
                force,
                cfg.shell_integration_features,
            ) orelse break :shell .{ null, default_shell_command };

            break :shell .{ integration.shell, integration.command };
        };

        if (integrated_shell) |shell| {
            log.info(
                "shell integration automatically injected shell={}",
                .{shell},
            );
        } else if (cfg.shell_integration != .none) {
            log.warn("shell could not be detected, no automatic shell integration will be injected", .{});
        }

        // Add the environment variables that override any others.
        {
            var it = cfg.env_override.iterator();
            while (it.next()) |entry| try env.put(
                entry.key_ptr.*,
                entry.value_ptr.*,
            );
        }

        // Build our args list
        const args = args: {
            const cap = 9; // the most we'll ever use
            var args = try std.ArrayList([]const u8).initCapacity(alloc, cap);
            defer args.deinit();

            // If we're on macOS, we have to use `login(1)` to get all of
            // the proper environment variables set, a login shell, and proper
            // hushlogin behavior.
            if (comptime builtin.target.isDarwin()) darwin: {
                const passwd = internal_os.passwd.get(alloc) catch |err| {
                    log.warn("failed to read passwd, not using a login shell err={}", .{err});
                    break :darwin;
                };

                const username = passwd.name orelse {
                    log.warn("failed to get username, not using a login shell", .{});
                    break :darwin;
                };

                const hush = if (passwd.home) |home| hush: {
                    var dir = std.fs.openDirAbsolute(home, .{}) catch |err| {
                        log.warn(
                            "failed to open home dir, not checking for hushlogin err={}",
                            .{err},
                        );
                        break :hush false;
                    };
                    defer dir.close();

                    break :hush if (dir.access(".hushlogin", .{})) true else |_| false;
                } else false;

                const cmd = try std.fmt.allocPrint(
                    alloc,
                    "exec -l {s}",
                    .{shell_command},
                );

                // The reason for executing login this way is unclear. This
                // comment will attempt to explain but prepare for a truly
                // unhinged reality.
                //
                // The first major issue is that on macOS, a lot of users
                // put shell configurations in ~/.bash_profile instead of
                // ~/.bashrc (or equivalent for another shell). This file is only
                // loaded for a login shell so macOS users expect all their terminals
                // to be login shells. No other platform behaves this way and its
                // totally braindead but somehow the entire dev community on
                // macOS has cargo culted their way to this reality so we have to
                // do it...
                //
                // To get a login shell, you COULD just prepend argv0 with a `-`
                // but that doesn't fully work because `getlogin()` C API will
                // return the wrong value, SHELL won't be set, and various
                // other login behaviors that macOS users expect.
                //
                // The proper way is to use `login(1)`. But login(1) forces
                // the working directory to change to the home directory,
                // which we may not want. If we specify "-l" then we can avoid
                // this behavior but now the shell isn't a login shell.
                //
                // There is another issue: `login(1)` on macOS 14.3 and earlier
                // checked for ".hushlogin" in the working directory. This means
                // that if we specify "-l" then we won't get hushlogin honored
                // if its in the home directory (which is standard). To get
                // around this, we check for hushlogin ourselves and if present
                // specify the "-q" flag to login(1).
                //
                // So to get all the behaviors we want, we specify "-l" but
                // execute "bash" (which is built-in to macOS). We then use
                // the bash builtin "exec" to replace the process with a login
                // shell ("-l" on exec) with the command we really want.
                //
                // We use "bash" instead of other shells that ship with macOS
                // because as of macOS Sonoma, we found with a microbenchmark
                // that bash can `exec` into the desired command ~2x faster
                // than zsh.
                //
                // To figure out a lot of this logic I read the login.c
                // source code in the OSS distribution Apple provides for
                // macOS.
                //
                // Awesome.
                try args.append("/usr/bin/login");
                if (hush) try args.append("-q");
                try args.append("-flp");

                // We execute bash with "--noprofile --norc" so that it doesn't
                // load startup files so that (1) our shell integration doesn't
                // break and (2) user configuration doesn't mess this process
                // up.
                try args.append(username);
                try args.append("/bin/bash");
                try args.append("--noprofile");
                try args.append("--norc");
                try args.append("-c");
                try args.append(cmd);
                break :args try args.toOwnedSlice();
            }

            if (comptime builtin.os.tag == .windows) {
                // We run our shell wrapped in `cmd.exe` so that we don't have
                // to parse the command line ourselves if it has arguments.

                // Note we don't free any of the memory below since it is
                // allocated in the arena.
                const windir = try std.process.getEnvVarOwned(alloc, "WINDIR");
                const cmd = try std.fs.path.join(alloc, &[_][]const u8{
                    windir,
                    "System32",
                    "cmd.exe",
                });

                try args.append(cmd);
                try args.append("/C");
            } else {
                // We run our shell wrapped in `/bin/sh` so that we don't have
                // to parse the command line ourselves if it has arguments.
                // Additionally, some environments (NixOS, I found) use /bin/sh
                // to setup some environment variables that are important to
                // have set.
                try args.append("/bin/sh");
                if (internal_os.isFlatpak()) try args.append("-l");
                try args.append("-c");
            }

            try args.append(shell_command);
            break :args try args.toOwnedSlice();
        };

        // We have to copy the cwd because there is no guarantee that
        // pointers in full_config remain valid.
        const cwd: ?[]u8 = if (cfg.working_directory) |cwd|
            try alloc.dupe(u8, cwd)
        else
            null;

        // If we have a cgroup, then we copy that into our arena so the
        // memory remains valid when we start.
        const linux_cgroup: Command.LinuxCgroup = cgroup: {
            const default = Command.linux_cgroup_default;
            if (comptime builtin.os.tag != .linux) break :cgroup default;
            const path = cfg.linux_cgroup orelse break :cgroup default;
            break :cgroup try alloc.dupe(u8, path);
        };

        return .{
            .arena = arena,
            .env = env,
            .cwd = cwd,
            .args = args,
            .linux_cgroup = linux_cgroup,

            // Should be initialized with initTerminal call.
            .grid_size = .{},
            .screen_size = .{ .width = 1, .height = 1 },
        };
    }

    /// Clean up the subprocess. This will stop the subprocess if it is started.
    pub fn deinit(self: *Subprocess) void {
        self.stop();
        if (self.pty) |*pty| pty.deinit();
        if (self.env) |*env| env.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    /// Start the subprocess. If the subprocess is already started this
    /// will crash.
    pub fn start(self: *Subprocess, alloc: Allocator) !struct {
        read: Pty.Fd,
        write: Pty.Fd,
    } {
        assert(self.pty == null and self.command == null);

        // Create our pty
        var pty = try Pty.open(.{
            .ws_row = @intCast(self.grid_size.rows),
            .ws_col = @intCast(self.grid_size.columns),
            .ws_xpixel = @intCast(self.screen_size.width),
            .ws_ypixel = @intCast(self.screen_size.height),
        });
        self.pty = pty;
        errdefer {
            if (comptime builtin.os.tag != .windows) {
                _ = posix.close(pty.slave);
            }

            pty.deinit();
            self.pty = null;
        }

        log.debug("starting command command={s}", .{self.args});

        // In flatpak, we use the HostCommand to execute our shell.
        if (internal_os.isFlatpak()) flatpak: {
            if (comptime !build_config.flatpak) {
                log.warn("flatpak detected, but flatpak support not built-in", .{});
                break :flatpak;
            }

            // Flatpak command must have a stable pointer.
            self.flatpak_command = .{
                .argv = self.args,
                .env = &self.env,
                .stdin = pty.slave,
                .stdout = pty.slave,
                .stderr = pty.slave,
            };
            var cmd = &self.flatpak_command.?;
            const pid = try cmd.spawn(alloc);
            errdefer killCommandFlatpak(cmd);

            log.info("started subcommand on host via flatpak API path={s} pid={?}", .{
                self.args[0],
                pid,
            });

            // Once started, we can close the pty child side. We do this after
            // wait right now but that is fine too. This lets us read the
            // parent and detect EOF.
            _ = posix.close(pty.slave);

            return .{
                .read = pty.master,
                .write = pty.master,
            };
        }

        // If we can't access the cwd, then don't set any cwd and inherit.
        // This is important because our cwd can be set by the shell (OSC 7)
        // and we don't want to break new windows.
        const cwd: ?[]const u8 = if (self.cwd) |proposed| cwd: {
            if (std.fs.cwd().access(proposed, .{})) {
                break :cwd proposed;
            } else |err| {
                log.warn("cannot access cwd, ignoring: {}", .{err});
                break :cwd null;
            }
        } else null;

        // Build our subcommand
        var cmd: Command = .{
            .path = self.args[0],
            .args = self.args,
            .env = if (self.env) |*env| env else null,
            .cwd = cwd,
            .stdin = if (builtin.os.tag == .windows) null else .{ .handle = pty.slave },
            .stdout = if (builtin.os.tag == .windows) null else .{ .handle = pty.slave },
            .stderr = if (builtin.os.tag == .windows) null else .{ .handle = pty.slave },
            .pseudo_console = if (builtin.os.tag == .windows) pty.pseudo_console else {},
            .pre_exec = if (builtin.os.tag == .windows) null else (struct {
                fn callback(cmd: *Command) void {
                    const sp = cmd.getData(Subprocess) orelse unreachable;
                    sp.childPreExec() catch |err| log.err(
                        "error initializing child: {}",
                        .{err},
                    );
                }
            }).callback,
            .data = self,
            .linux_cgroup = self.linux_cgroup,
        };
        try cmd.start(alloc);
        errdefer killCommand(&cmd) catch |err| {
            log.warn("error killing command during cleanup err={}", .{err});
        };
        log.info("started subcommand path={s} pid={?}", .{ self.args[0], cmd.pid });
        if (comptime builtin.os.tag == .linux) {
            log.info("subcommand cgroup={s}", .{self.linux_cgroup orelse "-"});
        }

        if (comptime builtin.os.tag != .windows) {
            // Once our subcommand is started we can close the slave
            // side. This prevents the slave fd from being leaked to
            // future children.
            _ = posix.close(pty.slave);
        }

        // Successful start we can clear out some memory.
        if (self.env) |*env| {
            env.deinit();
            self.env = null;
        }

        self.command = cmd;
        return switch (builtin.os.tag) {
            .windows => .{
                .read = pty.out_pipe,
                .write = pty.in_pipe,
            },

            else => .{
                .read = pty.master,
                .write = pty.master,
            },
        };
    }

    /// This should be called after fork but before exec in the child process.
    /// To repeat: this function RUNS IN THE FORKED CHILD PROCESS before
    /// exec is called; it does NOT run in the main Ghostty process.
    fn childPreExec(self: *Subprocess) !void {
        // Setup our pty
        try self.pty.?.childPreExec();
    }

    /// Called to notify that we exited externally so we can unset our
    /// running state.
    pub fn externalExit(self: *Subprocess) void {
        self.command = null;
    }

    /// Stop the subprocess. This is safe to call anytime. This will wait
    /// for the subprocess to register that it has been signalled, but not
    /// for it to terminate, so it will not block.
    /// This does not close the pty.
    pub fn stop(self: *Subprocess) void {
        // Kill our command
        if (self.command) |*cmd| {
            // Note: this will also wait for the command to exit, so
            // DO NOT call cmd.wait
            killCommand(cmd) catch |err|
                log.err("error sending SIGHUP to command, may hang: {}", .{err});
            self.command = null;
        }

        // Kill our Flatpak command
        if (FlatpakHostCommand != void) {
            if (self.flatpak_command) |*cmd| {
                killCommandFlatpak(cmd) catch |err|
                    log.err("error sending SIGHUP to command, may hang: {}", .{err});
                _ = cmd.wait() catch |err|
                    log.err("error waiting for command to exit: {}", .{err});
                self.flatpak_command = null;
            }
        }
    }

    /// Resize the pty subprocess. This is safe to call anytime.
    pub fn resize(
        self: *Subprocess,
        grid_size: renderer.GridSize,
        screen_size: renderer.ScreenSize,
    ) !void {
        self.grid_size = grid_size;
        self.screen_size = screen_size;

        if (self.pty) |*pty| {
            // It is theoretically possible for the grid or screen size to
            // exceed u16, although the terminal in that case isn't very
            // usable. This should be protected upstream but we still clamp
            // in case there is a bad caller which has happened before.
            try pty.setSize(.{
                .ws_row = std.math.cast(u16, grid_size.rows) orelse std.math.maxInt(u16),
                .ws_col = std.math.cast(u16, grid_size.columns) orelse std.math.maxInt(u16),
                .ws_xpixel = std.math.cast(u16, screen_size.width) orelse std.math.maxInt(u16),
                .ws_ypixel = std.math.cast(u16, screen_size.height) orelse std.math.maxInt(u16),
            });
        }
    }

    /// Kill the underlying subprocess. This sends a SIGHUP to the child
    /// process. This also waits for the command to exit and will return the
    /// exit code.
    fn killCommand(command: *Command) !void {
        if (command.pid) |pid| {
            switch (builtin.os.tag) {
                .windows => {
                    if (windows.kernel32.TerminateProcess(pid, 0) == 0) {
                        return windows.unexpectedError(windows.kernel32.GetLastError());
                    }

                    _ = try command.wait(false);
                },

                else => if (getpgid(pid)) |pgid| {
                    // It is possible to send a killpg between the time that
                    // our child process calls setsid but before or simultaneous
                    // to calling execve. In this case, the direct child dies
                    // but grandchildren survive. To work around this, we loop
                    // and repeatedly kill the process group until all
                    // descendents are well and truly dead. We will not rest
                    // until the entire family tree is obliterated.
                    while (true) {
                        switch (posix.errno(c.killpg(pgid, c.SIGHUP))) {
                            .SUCCESS => log.debug("process group killed pgid={}", .{pgid}),
                            else => |err| killpg: {
                                if ((comptime builtin.target.isDarwin()) and
                                    err == .PERM)
                                {
                                    log.debug("killpg failed with EPERM, expected on Darwin and ignoring", .{});
                                    break :killpg;
                                }

                                log.warn("error killing process group pgid={} err={}", .{ pgid, err });
                                return error.KillFailed;
                            },
                        }

                        // See Command.zig wait for why we specify WNOHANG.
                        // The gist is that it lets us detect when children
                        // are still alive without blocking so that we can
                        // kill them again.
                        const res = posix.waitpid(pid, std.c.W.NOHANG);
                        log.debug("waitpid result={}", .{res.pid});
                        if (res.pid != 0) break;
                        std.time.sleep(10 * std.time.ns_per_ms);
                    }
                },
            }
        }
    }

    fn getpgid(pid: c.pid_t) ?c.pid_t {
        // Get our process group ID. Before the child pid calls setsid
        // the pgid will be ours because we forked it. Its possible that
        // we may be calling this before setsid if we are killing a surface
        // VERY quickly after starting it.
        const my_pgid = c.getpgid(0);

        // We loop while pgid == my_pgid. The expectation if we have a valid
        // pid is that setsid will eventually be called because it is the
        // FIRST thing the child process does and as far as I can tell,
        // setsid cannot fail. I'm sure that's not true, but I'd rather
        // have a bug reported than defensively program against it now.
        while (true) {
            const pgid = c.getpgid(pid);
            if (pgid == my_pgid) {
                log.warn("pgid is our own, retrying", .{});
                std.time.sleep(10 * std.time.ns_per_ms);
                continue;
            }

            // Don't know why it would be zero but its not a valid pid
            if (pgid == 0) return null;

            // If the pid doesn't exist then... we're done!
            if (pgid == c.ESRCH) return null;

            // If we have an error we're done.
            if (pgid < 0) {
                log.warn("error getting pgid for kill", .{});
                return null;
            }

            return pgid;
        }
    }

    /// Kill the underlying process started via Flatpak host command.
    /// This sends a signal via the Flatpak API.
    fn killCommandFlatpak(command: *FlatpakHostCommand) !void {
        try command.signal(c.SIGHUP, true);
    }
};

/// The read thread sits in a loop doing the following pseudo code:
///
///   while (true) { blocking_read(); exit_if_eof(); process(); }
///
/// Almost all terminal-modifying activity is from the pty read, so
/// putting this on a dedicated thread keeps performance very predictable
/// while also almost optimal. "Locking is fast, lock contention is slow."
/// and since we rarely have contention, this is fast.
///
/// This is also empirically fast compared to putting the read into
/// an async mechanism like io_uring/epoll because the reads are generally
/// small.
///
/// We use a basic poll syscall here because we are only monitoring two
/// fds and this is still much faster and lower overhead than any async
/// mechanism.
pub const ReadThread = struct {
    fn threadMainPosix(fd: posix.fd_t, io: *termio.Termio, quit: posix.fd_t) void {
        // Always close our end of the pipe when we exit.
        defer posix.close(quit);

        // Setup our crash metadata
        crash.sentry.thread_state = .{
            .type = .io,
            .surface = io.surface_mailbox.surface,
        };
        defer crash.sentry.thread_state = null;

        // First thing, we want to set the fd to non-blocking. We do this
        // so that we can try to read from the fd in a tight loop and only
        // check the quit fd occasionally.
        if (posix.fcntl(fd, posix.F.GETFL, 0)) |flags| {
            _ = posix.fcntl(
                fd,
                posix.F.SETFL,
                flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })),
            ) catch |err| {
                log.warn("read thread failed to set flags err={}", .{err});
                log.warn("this isn't a fatal error, but may cause performance issues", .{});
            };
        } else |err| {
            log.warn("read thread failed to get flags err={}", .{err});
            log.warn("this isn't a fatal error, but may cause performance issues", .{});
        }

        // Build up the list of fds we're going to poll. We are looking
        // for data on the pty and our quit notification.
        var pollfds: [2]posix.pollfd = .{
            .{ .fd = fd, .events = posix.POLL.IN, .revents = undefined },
            .{ .fd = quit, .events = posix.POLL.IN, .revents = undefined },
        };

        var buf: [1024]u8 = undefined;
        while (true) {
            // We try to read from the file descriptor as long as possible
            // to maximize performance. We only check the quit fd if the
            // main fd blocks. This optimizes for the realistic scenario that
            // the data will eventually stop while we're trying to quit. This
            // is always true because we kill the process.
            while (true) {
                const n = posix.read(fd, &buf) catch |err| {
                    switch (err) {
                        // This means our pty is closed. We're probably
                        // gracefully shutting down.
                        error.NotOpenForReading,
                        error.InputOutput,
                        => {
                            log.info("io reader exiting", .{});
                            return;
                        },

                        // No more data, fall back to poll and check for
                        // exit conditions.
                        error.WouldBlock => break,

                        else => {
                            log.err("io reader error err={}", .{err});
                            unreachable;
                        },
                    }
                };

                // This happens on macOS instead of WouldBlock when the
                // child process dies. To be safe, we just break the loop
                // and let our poll happen.
                if (n == 0) break;

                // log.info("DATA: {d}", .{n});
                @call(.always_inline, termio.Termio.processOutput, .{ io, buf[0..n] });
            }

            // Wait for data.
            _ = posix.poll(&pollfds, -1) catch |err| {
                log.warn("poll failed on read thread, exiting early err={}", .{err});
                return;
            };

            // If our quit fd is set, we're done.
            if (pollfds[1].revents & posix.POLL.IN != 0) {
                log.info("read thread got quit signal", .{});
                return;
            }

            // If our pty fd is closed, then we're also done with our
            // read thread.
            if (pollfds[0].revents & posix.POLL.HUP != 0) {
                log.info("pty fd closed, read thread exiting", .{});
                return;
            }
        }
    }

    fn threadMainWindows(fd: posix.fd_t, io: *termio.Termio, quit: posix.fd_t) void {
        // Always close our end of the pipe when we exit.
        defer posix.close(quit);

        // Setup our crash metadata
        crash.sentry.thread_state = .{
            .type = .io,
            .surface = io.surface_mailbox.surface,
        };
        defer crash.sentry.thread_state = null;

        var buf: [1024]u8 = undefined;
        while (true) {
            while (true) {
                var n: windows.DWORD = 0;
                if (windows.kernel32.ReadFile(fd, &buf, buf.len, &n, null) == 0) {
                    const err = windows.kernel32.GetLastError();
                    switch (err) {
                        // Check for a quit signal
                        .OPERATION_ABORTED => break,

                        else => {
                            log.err("io reader error err={}", .{err});
                            unreachable;
                        },
                    }
                }

                @call(.always_inline, termio.Termio.processOutput, .{ io, buf[0..n] });
            }

            var quit_bytes: windows.DWORD = 0;
            if (windows.exp.kernel32.PeekNamedPipe(quit, null, 0, null, &quit_bytes, null) == 0) {
                const err = windows.kernel32.GetLastError();
                log.err("quit pipe reader error err={}", .{err});
                unreachable;
            }

            if (quit_bytes > 0) {
                log.info("read thread got quit signal", .{});
                return;
            }
        }
    }
};
