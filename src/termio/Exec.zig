//! Implementation of IO that uses child exec to talk to the child process.
pub const Exec = @This();

const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const EnvMap = std.process.EnvMap;
const termio = @import("../termio.zig");
const Command = @import("../Command.zig");
const Pty = @import("../Pty.zig");
const SegmentedPool = @import("../segmented_pool.zig").SegmentedPool;
const terminal = @import("../terminal/main.zig");
const xev = @import("xev");
const renderer = @import("../renderer.zig");
const tracy = @import("tracy");
const trace = tracy.trace;
const apprt = @import("../apprt.zig");
const fastmem = @import("../fastmem.zig");
const internal_os = @import("../os/main.zig");
const configpkg = @import("../config.zig");
const shell_integration = @import("shell_integration.zig");

const log = std.log.scoped(.io_exec);

const c = @cImport({
    @cInclude("errno.h");
    @cInclude("signal.h");
    @cInclude("unistd.h");
});

/// Allocator
alloc: Allocator,

/// This is the pty fd created for the subcommand.
subprocess: Subprocess,

/// The terminal emulator internal state. This is the abstract "terminal"
/// that manages input, grid updating, etc. and is renderer-agnostic. It
/// just stores internal state about a grid.
terminal: terminal.Terminal,

/// The stream parser. This parses the stream of escape codes and so on
/// from the child process and calls callbacks in the stream handler.
terminal_stream: terminal.Stream(StreamHandler),

/// The shared render state
renderer_state: *renderer.State,

/// A handle to wake up the renderer. This hints to the renderer that that
/// a repaint should happen.
renderer_wakeup: xev.Async,

/// The mailbox for notifying the renderer of things.
renderer_mailbox: *renderer.Thread.Mailbox,

/// The mailbox for communicating with the surface.
surface_mailbox: apprt.surface.Mailbox,

/// The cached grid size whenever a resize is called.
grid_size: renderer.GridSize,

/// The data associated with the currently running thread.
data: ?*EventData,

/// The configuration for this IO that is derived from the main
/// configuration. This must be exported so that we don't need to
/// pass around Config pointers which makes memory management a pain.
pub const DerivedConfig = struct {
    palette: terminal.color.Palette,

    pub fn init(
        alloc_gpa: Allocator,
        config: *const configpkg.Config,
    ) !DerivedConfig {
        _ = alloc_gpa;

        return .{
            .palette = config.palette.value,
        };
    }

    pub fn deinit(self: *DerivedConfig) void {
        _ = self;
    }
};

/// Initialize the exec implementation. This will also start the child
/// process.
pub fn init(alloc: Allocator, opts: termio.Options) !Exec {
    // Clean up our derived config because we don't need it after this.
    var config = opts.config;
    defer config.deinit();

    // Create our terminal
    var term = try terminal.Terminal.init(
        alloc,
        opts.grid_size.columns,
        opts.grid_size.rows,
    );
    errdefer term.deinit(alloc);
    term.color_palette = opts.config.palette;

    var subprocess = try Subprocess.init(alloc, opts);
    errdefer subprocess.deinit();

    return Exec{
        .alloc = alloc,
        .terminal = term,
        .terminal_stream = undefined,
        .subprocess = subprocess,
        .renderer_state = opts.renderer_state,
        .renderer_wakeup = opts.renderer_wakeup,
        .renderer_mailbox = opts.renderer_mailbox,
        .surface_mailbox = opts.surface_mailbox,
        .grid_size = opts.grid_size,
        .data = null,
    };
}

pub fn deinit(self: *Exec) void {
    self.subprocess.deinit();

    // Clean up our other members
    self.terminal.deinit(self.alloc);
}

pub fn threadEnter(self: *Exec, thread: *termio.Thread) !ThreadData {
    assert(self.data == null);
    const alloc = self.alloc;

    // Start our subprocess
    const master_fd = try self.subprocess.start(alloc);
    errdefer self.subprocess.stop();
    const pid = pid: {
        const command = self.subprocess.command orelse return error.ProcessNotStarted;
        break :pid command.pid orelse return error.ProcessNoPid;
    };

    // Setup our data that is used for callbacks
    var ev_data_ptr = try alloc.create(EventData);
    errdefer alloc.destroy(ev_data_ptr);

    // Setup our stream so that we can write.
    var stream = xev.Stream.initFd(master_fd);
    errdefer stream.deinit();

    // Wakeup watcher for the writer thread.
    var wakeup = try xev.Async.init();
    errdefer wakeup.deinit();

    // Watcher to detect subprocess exit
    var process = try xev.Process.init(pid);
    errdefer process.deinit();

    // Setup our event data before we start
    ev_data_ptr.* = .{
        .writer_mailbox = thread.mailbox,
        .writer_wakeup = thread.wakeup,
        .surface_mailbox = self.surface_mailbox,
        .renderer_state = self.renderer_state,
        .renderer_wakeup = self.renderer_wakeup,
        .renderer_mailbox = self.renderer_mailbox,
        .process = process,
        .data_stream = stream,
        .loop = &thread.loop,
        .terminal_stream = .{
            .handler = .{
                .alloc = self.alloc,
                .ev = ev_data_ptr,
                .terminal = &self.terminal,
                .grid_size = &self.grid_size,
            },
        },
    };
    errdefer ev_data_ptr.deinit(self.alloc);

    // Store our data so our callbacks can access it
    self.data = ev_data_ptr;
    errdefer self.data = null;

    // Start our process watcher
    process.wait(
        ev_data_ptr.loop,
        &ev_data_ptr.process_wait_c,
        EventData,
        ev_data_ptr,
        processExit,
    );

    // Start our reader thread
    const read_thread = try std.Thread.spawn(
        .{},
        ReadThread.threadMain,
        .{ master_fd, ev_data_ptr },
    );
    read_thread.setName("io-reader") catch {};

    // Return our thread data
    return ThreadData{
        .alloc = alloc,
        .ev = ev_data_ptr,
        .read_thread = read_thread,
    };
}

pub fn threadExit(self: *Exec, data: ThreadData) void {
    // Clear out our data since we're not active anymore.
    self.data = null;

    // Stop our subprocess
    if (data.ev.process_exited) self.subprocess.externalExit();
    self.subprocess.stop();

    // Wait for our reader thread to end
    data.read_thread.join();
}

/// Update the configuration.
pub fn changeConfig(self: *Exec, config: *DerivedConfig) !void {
    defer config.deinit();

    // Update the configuration that we know about.
    //
    // Specific things we don't update:
    //   - command, working-directory: we never restart the underlying
    //   process so we don't care or need to know about these.

    // Update the palette. Note this will only apply to new colors drawn
    // since we decode all palette colors to RGB on usage.
    self.terminal.color_palette = config.palette;
}

/// Resize the terminal.
pub fn resize(
    self: *Exec,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
    padding: renderer.Padding,
) !void {
    // Update the size of our pty
    const padded_size = screen_size.subPadding(padding);
    try self.subprocess.resize(grid_size, padded_size);

    // Update our cached grid size
    self.grid_size = grid_size;

    // Enter the critical area that we want to keep small
    {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();

        // Update the size of our terminal state
        try self.terminal.resize(self.alloc, grid_size.columns, grid_size.rows);
    }
}

/// Clear the screen.
pub fn clearScreen(self: *Exec, history: bool) !void {
    {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();

        // If we're on the alternate screen, we do not clear. Since this is an
        // emulator-level screen clear, this messes up the running programs
        // knowledge of where the cursor is and causes rendering issues. So,
        // for alt screen, we do nothing.
        if (self.terminal.active_screen == .alternate) return;

        // Clear our scrollback
        if (history) try self.terminal.screen.clear(.history);

        // If we're not at a prompt, we clear the screen manually using
        // the terminal screen state. If we are at a prompt, we send
        // form-feed so that the shell can repaint the entire screen.
        if (!self.terminal.cursorIsAtPrompt()) {
            // Clear above the cursor
            try self.terminal.screen.clear(.above_cursor);

            // Exit
            return;
        }
    }

    // If we reached here it means we're at a prompt, so we send a form-feed.
    assert(self.terminal.cursorIsAtPrompt());
    try self.queueWrite(&[_]u8{0x0C});
}

/// Jump the viewport to the prompt.
pub fn jumpToPrompt(self: *Exec, delta: isize) !void {
    const wakeup: bool = wakeup: {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();
        break :wakeup self.terminal.screen.jump(.{
            .prompt_delta = delta,
        });
    };

    if (wakeup) {
        try self.renderer_wakeup.notify();
    }
}

pub inline fn queueWrite(self: *Exec, data: []const u8) !void {
    const ev = self.data.?;

    // We go through and chunk the data if necessary to fit into
    // our cached buffers that we can queue to the stream.
    var i: usize = 0;
    while (i < data.len) {
        const req = try ev.write_req_pool.getGrow(self.alloc);
        const buf = try ev.write_buf_pool.getGrow(self.alloc);
        const end = @min(data.len, i + buf.len);
        fastmem.copy(u8, buf, data[i..end]);
        ev.data_stream.queueWrite(
            ev.loop,
            &ev.write_queue,
            req,
            .{ .slice = buf[0..(end - i)] },
            EventData,
            ev,
            ttyWrite,
        );

        i = end;
    }
}

const ThreadData = struct {
    /// Allocator used for the event data
    alloc: Allocator,

    /// The data that is attached to the callbacks.
    ev: *EventData,

    /// Our read thread
    read_thread: std.Thread,

    pub fn deinit(self: *ThreadData) void {
        self.ev.deinit(self.alloc);
        self.alloc.destroy(self.ev);
        self.* = undefined;
    }
};

const EventData = struct {
    // The preallocation size for the write request pool. This should be big
    // enough to satisfy most write requests. It must be a power of 2.
    const WRITE_REQ_PREALLOC = std.math.pow(usize, 2, 5);

    /// Mailbox for data to the writer thread.
    writer_mailbox: *termio.Mailbox,
    writer_wakeup: xev.Async,

    /// Mailbox for the surface.
    surface_mailbox: apprt.surface.Mailbox,

    /// The stream parser. This parses the stream of escape codes and so on
    /// from the child process and calls callbacks in the stream handler.
    terminal_stream: terminal.Stream(StreamHandler),

    /// The shared render state
    renderer_state: *renderer.State,

    /// A handle to wake up the renderer. This hints to the renderer that that
    /// a repaint should happen.
    renderer_wakeup: xev.Async,

    /// The mailbox for notifying the renderer of things.
    renderer_mailbox: *renderer.Thread.Mailbox,

    /// The process watcher
    process: xev.Process,
    process_exited: bool = false,

    /// This is used for both waiting for the process to exit and then
    /// subsequently to wait for the data_stream to close.
    process_wait_c: xev.Completion = .{},

    /// The data stream is the main IO for the pty.
    data_stream: xev.Stream,

    /// The event loop,
    loop: *xev.Loop,

    /// The write queue for the data stream.
    write_queue: xev.Stream.WriteQueue = .{},

    /// This is the pool of available (unused) write requests. If you grab
    /// one from the pool, you must put it back when you're done!
    write_req_pool: SegmentedPool(xev.Stream.WriteRequest, WRITE_REQ_PREALLOC) = .{},

    /// The pool of available buffers for writing to the pty.
    write_buf_pool: SegmentedPool([64]u8, WRITE_REQ_PREALLOC) = .{},

    /// Last time the cursor was reset. This is used to prevent message
    /// flooding with cursor resets.
    last_cursor_reset: i64 = 0,

    /// This is set to true when we've seen a title escape sequence. We use
    /// this to determine if we need to default the window title.
    seen_title: bool = false,

    pub fn deinit(self: *EventData, alloc: Allocator) void {
        // Clear our write pools. We know we aren't ever going to do
        // any more IO since we stop our data stream below so we can just
        // drop this.
        self.write_req_pool.deinit(alloc);
        self.write_buf_pool.deinit(alloc);

        // Stop our data stream
        self.data_stream.deinit();

        // Stop our process watcher
        self.process.deinit();
    }

    /// This queues a render operation with the renderer thread. The render
    /// isn't guaranteed to happen immediately but it will happen as soon as
    /// practical.
    inline fn queueRender(self: *EventData) !void {
        try self.renderer_wakeup.notify();
    }
};

fn processExit(
    ev_: ?*EventData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Process.WaitError!u32,
) xev.CallbackAction {
    const code = r catch unreachable;
    log.debug("child process exited status={}", .{code});

    const ev = ev_.?;
    ev.process_exited = true;

    // Notify our surface we want to close
    _ = ev.surface_mailbox.push(.{
        .child_exited = {},
    }, .{ .forever = {} });

    return .disarm;
}

fn ttyWrite(
    ev_: ?*EventData,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.Stream,
    _: xev.WriteBuffer,
    r: xev.Stream.WriteError!usize,
) xev.CallbackAction {
    const ev = ev_.?;
    ev.write_req_pool.put();
    ev.write_buf_pool.put();

    const d = r catch |err| {
        log.err("write error: {}", .{err});
        return .disarm;
    };
    _ = d;
    //log.info("WROTE: {d}", .{status});

    return .disarm;
}

/// Subprocess manages the lifecycle of the shell subprocess.
const Subprocess = struct {
    /// If we build with flatpak support then we have to keep track of
    /// a potential execution on the host.
    const FlatpakHostCommand = if (build_config.flatpak) internal_os.FlatpakHostCommand else void;

    arena: std.heap.ArenaAllocator,
    cwd: ?[]const u8,
    env: EnvMap,
    path: []const u8,
    args: [][]const u8,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
    pty: ?Pty = null,
    command: ?Command = null,
    flatpak_command: ?FlatpakHostCommand = null,

    /// Initialize the subprocess. This will NOT start it, this only sets
    /// up the internal state necessary to start it later.
    pub fn init(gpa: Allocator, opts: termio.Options) !Subprocess {
        // We have a lot of maybe-allocations that all share the same lifetime
        // so use an arena so we don't end up in an accounting nightmare.
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        // Determine the path to the binary we're executing
        const path = (try Command.expandPath(alloc, opts.full_config.command orelse "sh")) orelse
            return error.CommandNotFound;

        // On macOS, we launch the program as a login shell. This is a Mac-specific
        // behavior (see other terminals). Terminals in general should NOT be
        // spawning login shells because well... we're not "logging in." The solution
        // is to put dotfiles in "rc" variants rather than "_login" variants. But,
        // history!
        const argv0_override: ?[]const u8 = if (comptime builtin.target.isDarwin()) argv0: {
            // Get rid of the path
            const argv0 = if (std.mem.lastIndexOf(u8, path, "/")) |idx|
                path[idx + 1 ..]
            else
                path;

            // Copy it with a hyphen so its a login shell
            const argv0_buf = try alloc.alloc(u8, argv0.len + 1);
            argv0_buf[0] = '-';
            std.mem.copy(u8, argv0_buf[1..], argv0);
            break :argv0 argv0_buf;
        } else null;

        // Set our env vars. For Flatpak builds running in Flatpak we don't
        // inherit our environment because the login shell on the host side
        // will get it.
        var env = env: {
            if (comptime build_config.flatpak) {
                if (internal_os.isFlatpak()) {
                    break :env std.process.EnvMap.init(alloc);
                }
            }

            break :env try std.process.getEnvMap(alloc);
        };
        errdefer env.deinit();

        // Get our bundled resources directory, if it exists. We use this
        // for terminfo, shell-integration, etc.
        const resources_key = "GHOSTTY_RESOURCES_DIR";
        const resources_dir = dir: {
            if (env.get(resources_key)) |dir| {
                if (dir.len > 0) {
                    log.info("using Ghostty resources dir from env var: {s}", .{dir});
                    break :dir dir;
                }
            }

            if (try resourcesDir(alloc)) |dir| {
                log.info("found Ghostty resources dir: {s}", .{dir});
                try env.put(resources_key, dir);
                break :dir dir;
            }

            log.warn("Ghostty resources dir not found, some features disabled", .{});
            break :dir null;
        };

        // Set our TERM var. This is a bit complicated because we want to use
        // the ghostty TERM value but we want to only do that if we have
        // ghostty in the TERMINFO database.
        //
        // For now, we just look up a bundled dir but in the future we should
        // also load the terminfo database and look for it.
        if (try terminfoDir(alloc, resources_dir)) |dir| {
            try env.put("TERM", "xterm-ghostty");
            try env.put("COLORTERM", "truecolor");
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

        // When embedding in macOS and running via XCode, XCode injects
        // a bunch of things that break our shell process. We remove those.
        if (comptime builtin.target.isDarwin() and build_config.artifact == .lib) {
            if (env.get("__XCODE_BUILT_PRODUCTS_DIR_PATHS") != null) {
                env.remove("__XCODE_BUILT_PRODUCTS_DIR_PATHS");
                env.remove("__XPC_DYLD_LIBRARY_PATH");
                env.remove("DYLD_FRAMEWORK_PATH");
                env.remove("DYLD_INSERT_LIBRARIES");
                env.remove("DYLD_LIBRARY_PATH");
                env.remove("LD_LIBRARY_PATH");
                env.remove("SECURITYSESSIONID");
                env.remove("XPC_SERVICE_NAME");
            }
        }

        // If we're NOT in a flatpak (usually!), then we just exec the
        // process directly. If we are in a flatpak, we use flatpak-spawn
        // to escape the sandbox.
        const args = if (!internal_os.isFlatpak()) try alloc.dupe(
            []const u8,
            &[_][]const u8{argv0_override orelse path},
        ) else args: {
            var args = try std.ArrayList([]const u8).initCapacity(alloc, 8);
            defer args.deinit();

            // We run our shell wrapped in a /bin/sh login shell because
            // some systems do not properly initialize the env vars unless
            // we start this way (NixOS!)
            try args.append("/bin/sh");
            try args.append("-l");
            try args.append("-c");
            try args.append(path);

            break :args try args.toOwnedSlice();
        };

        // We have to copy the cwd because there is no guarantee that
        // pointers in full_config remain valid.
        var cwd: ?[]u8 = if (opts.full_config.@"working-directory") |cwd|
            try alloc.dupe(u8, cwd)
        else
            null;

        // The execution path
        const final_path = if (internal_os.isFlatpak()) args[0] else path;

        // Setup our shell integration, if we can.
        const shell_integrated: ?shell_integration.Shell = shell: {
            const force: ?shell_integration.Shell = switch (opts.full_config.@"shell-integration") {
                .none => break :shell null,
                .detect => null,
                .fish => .fish,
                .zsh => .zsh,
            };

            const dir = resources_dir orelse break :shell null;
            break :shell try shell_integration.setup(
                dir,
                final_path,
                &env,
                force,
            );
        };
        if (shell_integrated) |shell| {
            log.info(
                "shell integration automatically injected shell={}",
                .{shell},
            );
        } else if (opts.full_config.@"shell-integration" != .none) {
            log.warn("shell could not be detected, no automatic shell integration will be injected", .{});
        }

        return .{
            .arena = arena,
            .env = env,
            .cwd = cwd,
            .path = final_path,
            .args = args,
            .grid_size = opts.grid_size,
            .screen_size = opts.screen_size,
        };
    }

    /// Clean up the subprocess. This will stop the subprocess if it is started.
    pub fn deinit(self: *Subprocess) void {
        self.stop();
        self.arena.deinit();
        self.* = undefined;
    }

    /// Start the subprocess. If the subprocess is already started this
    /// will crash.
    pub fn start(self: *Subprocess, alloc: Allocator) !std.os.fd_t {
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
            pty.deinit();
            self.pty = null;
        }

        log.debug("starting command path={s} args={s}", .{
            self.path,
            self.args,
        });

        // In flatpak, we use the HostCommand to execute our shell.
        if (internal_os.isFlatpak()) flatpak: {
            if (comptime !build_config.flatpak) {
                log.warn("flatpak detected, but flatpak support not built-in", .{});
                break :flatpak;
            }

            // For flatpak our path and argv[0] must match because that is
            // used for execution by the dbus API.
            assert(std.mem.eql(u8, self.path, self.args[0]));

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
                self.path,
                pid,
            });

            // Once started, we can close the pty child side. We do this after
            // wait right now but that is fine too. This lets us read the
            // parent and detect EOF.
            _ = std.os.close(pty.slave);

            return pty.master;
        }

        // If we can't access the cwd, then don't set any cwd and inherit.
        // This is important because our cwd can be set by the shell (OSC 7)
        // and we don't want to break new windows.
        const cwd: ?[]const u8 = if (self.cwd) |proposed| cwd: {
            if (std.fs.accessAbsolute(proposed, .{})) {
                break :cwd proposed;
            } else |err| {
                log.warn("cannot access cwd, ignoring: {}", .{err});
                break :cwd null;
            }
        } else null;

        // Build our subcommand
        var cmd: Command = .{
            .path = self.path,
            .args = self.args,
            .env = &self.env,
            .cwd = cwd,
            .stdin = .{ .handle = pty.slave },
            .stdout = .{ .handle = pty.slave },
            .stderr = .{ .handle = pty.slave },
            .pre_exec = (struct {
                fn callback(cmd: *Command) void {
                    const p = cmd.getData(Pty) orelse unreachable;
                    p.childPreExec() catch |err|
                        log.err("error initializing child: {}", .{err});
                }
            }).callback,
            .data = &self.pty.?,
        };
        try cmd.start(alloc);
        errdefer killCommand(cmd);
        log.info("started subcommand path={s} pid={?}", .{ self.path, cmd.pid });

        self.command = cmd;
        return pty.master;
    }

    /// Called to notify that we exited externally so we can unset our
    /// running state.
    pub fn externalExit(self: *Subprocess) void {
        self.command = null;
    }

    /// Stop the subprocess. This is safe to call anytime. This will wait
    /// for the subprocess to end so it will block.
    pub fn stop(self: *Subprocess) void {
        // Kill our command
        if (self.command) |*cmd| {
            killCommand(cmd) catch |err|
                log.err("error sending SIGHUP to command, may hang: {}", .{err});
            _ = cmd.wait(false) catch |err|
                log.err("error waiting for command to exit: {}", .{err});
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

        // Close our PTY. We do this after killing our command because on
        // macOS, close will block until all blocking operations read/write
        // are done with it and our reader thread is probably still alive.
        if (self.pty) |*pty| {
            pty.deinit();
            self.pty = null;
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

        if (self.pty) |pty| {
            try pty.setSize(.{
                .ws_row = @intCast(grid_size.rows),
                .ws_col = @intCast(grid_size.columns),
                .ws_xpixel = @intCast(screen_size.width),
                .ws_ypixel = @intCast(screen_size.height),
            });
        }
    }

    /// Kill the underlying subprocess. This sends a SIGHUP to the child
    /// process. This doesn't wait for the child process to be exited.
    fn killCommand(command: *Command) !void {
        if (command.pid) |pid| {
            const pgid_: ?c.pid_t = pgid: {
                const pgid = c.getpgid(pid);

                // Don't know why it would be zero but its not a valid pid
                if (pgid == 0) break :pgid null;

                // If the pid doesn't exist then... okay.
                if (pgid == c.ESRCH) break :pgid null;

                // If we have an error...
                if (pgid < 0) {
                    log.warn("error getting pgid for kill", .{});
                    break :pgid null;
                }

                break :pgid pgid;
            };

            if (pgid_) |pgid| {
                if (c.killpg(pgid, c.SIGHUP) < 0) {
                    log.warn("error killing process group pgid={}", .{pgid});
                    return error.KillFailed;
                }
            }
        }
    }

    /// Kill the underlying process started via Flatpak host command.
    /// This sends a signal via the Flatpak API.
    fn killCommandFlatpak(command: *FlatpakHostCommand) !void {
        try command.signal(c.SIGHUP, true);
    }

    /// Gets the directory to the terminfo database, if it can be detected.
    /// The memory returned can't be easily freed so the alloc should be
    /// an arena or something similar.
    fn terminfoDir(alloc: Allocator, base: ?[]const u8) !?[]const u8 {
        const dir = base orelse return null;
        return try tryDir(alloc, dir, "terminfo", "");
    }

    /// Gets the directory to the bundled resources directory, if it
    /// exists (not all platforms or packages have it).
    ///
    /// The memory returned can't be easily freed so the alloc should be
    /// an arena or something similar.
    fn resourcesDir(alloc: Allocator) !?[]const u8 {
        // This is the sentinel value we look for in the path to know
        // we've found the resources directory.
        const sentinel = "terminfo/67/ghostty";

        // Get the path to our running binary
        var exe_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        var exe: []const u8 = std.fs.selfExePath(&exe_buf) catch return null;

        // We have an exe path! Climb the tree looking for the terminfo
        // bundle as we expect it.
        while (std.fs.path.dirname(exe)) |dir| {
            exe = dir;

            // On MacOS, we look for the app bundle path.
            if (comptime builtin.target.isDarwin()) {
                if (try tryDir(alloc, dir, "Contents/Resources", sentinel)) |v| {
                    return v;
                }
            }

            // On all platforms, we look for a /usr/share style path. This
            // is valid even on Mac since there is nothing that requires
            // Ghostty to be in an app bundle.
            if (try tryDir(alloc, dir, "share", sentinel)) |v| {
                return v;
            }
        }

        return null;
    }

    /// Little helper to check if the "base/sub/suffix" directory exists and
    /// if so, duplicate the "base/sub" path and return it.
    fn tryDir(
        alloc: Allocator,
        base: []const u8,
        sub: []const u8,
        suffix: []const u8,
    ) !?[]const u8 {
        var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "{s}/{s}/{s}", .{ base, sub, suffix });

        if (std.fs.accessAbsolute(path, .{})) {
            const len = path.len - suffix.len - 1;
            return try alloc.dupe(u8, path[0..len]);
        } else |_| {
            // Folder doesn't exist. If a different error happens its okay
            // we just ignore it and move on.
        }

        return null;
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
const ReadThread = struct {
    /// The main entrypoint for the thread.
    fn threadMain(fd: std.os.fd_t, ev: *EventData) void {
        var buf: [1024]u8 = undefined;
        while (true) {
            const n = std.os.read(fd, &buf) catch |err| {
                switch (err) {
                    // This means our pty is closed. We're probably
                    // gracefully shutting down.
                    error.NotOpenForReading,
                    error.InputOutput,
                    => log.info("io reader exiting", .{}),

                    else => {
                        log.err("io reader error err={}", .{err});
                        unreachable;
                    },
                }
                return;
            };

            // log.info("DATA: {d}", .{n});
            @call(.always_inline, process, .{ ev, buf[0..n] });
        }
    }

    fn process(
        ev: *EventData,
        buf: []const u8,
    ) void {
        const zone = trace(@src());
        defer zone.end();

        // log.info("DATA: {d}", .{n});
        // log.info("DATA: {any}", .{buf[0..@intCast(usize, n)]});

        // Whenever a character is typed, we ensure the cursor is in the
        // non-blink state so it is rendered if visible. If we're under
        // HEAVY read load, we don't want to send a ton of these so we
        // use a timer under the covers
        const now = ev.loop.now();
        if (now - ev.last_cursor_reset > 500) {
            ev.last_cursor_reset = now;
            _ = ev.renderer_mailbox.push(.{
                .reset_cursor_blink = {},
            }, .{ .forever = {} });
        }

        // We are modifying terminal state from here on out
        ev.renderer_state.mutex.lock();
        defer ev.renderer_state.mutex.unlock();

        // Schedule a render
        ev.queueRender() catch unreachable;

        // Process the terminal data. This is an extremely hot part of the
        // terminal emulator, so we do some abstraction leakage to avoid
        // function calls and unnecessary logic.
        //
        // The ground state is the only state that we can see and print/execute
        // ASCII, so we only execute this hot path if we're already in the ground
        // state.
        //
        // Empirically, this alone improved throughput of large text output by ~20%.
        var i: usize = 0;
        const end = buf.len;
        if (ev.terminal_stream.parser.state == .ground) {
            for (buf[i..end]) |ch| {
                switch (terminal.parse_table.table[ch][@intFromEnum(terminal.Parser.State.ground)].action) {
                    // Print, call directly.
                    .print => ev.terminal_stream.handler.print(@intCast(ch)) catch |err|
                        log.err("error processing terminal data: {}", .{err}),

                    // C0 execute, let our stream handle this one but otherwise
                    // continue since we're guaranteed to be back in ground.
                    .execute => ev.terminal_stream.execute(ch) catch |err|
                        log.err("error processing terminal data: {}", .{err}),

                    // Otherwise, break out and go the slow path until we're
                    // back in ground. There is a slight optimization here where
                    // could try to find the next transition to ground but when
                    // I implemented that it didn't materially change performance.
                    else => break,
                }

                i += 1;
            }
        }

        if (i < end) {
            ev.terminal_stream.nextSlice(buf[i..end]) catch |err|
                log.err("error processing terminal data: {}", .{err});
        }

        // If our stream handling caused messages to be sent to the writer
        // thread, then we need to wake it up so that it processes them.
        if (ev.terminal_stream.handler.writer_messaged) {
            ev.terminal_stream.handler.writer_messaged = false;
            ev.writer_wakeup.notify() catch |err| {
                log.warn("failed to wake up writer thread err={}", .{err});
            };
        }
    }
};

/// This is used as the handler for the terminal.Stream type. This is
/// stateful and is expected to live for the entire lifetime of the terminal.
/// It is NOT VALID to stop a stream handler, create a new one, and use that
/// unless all of the member fields are copied.
const StreamHandler = struct {
    ev: *EventData,
    alloc: Allocator,
    grid_size: *renderer.GridSize,
    terminal: *terminal.Terminal,

    /// This is set to true when a message was written to the writer
    /// mailbox. This can be used by callers to determine if they need
    /// to wake up the writer.
    writer_messaged: bool = false,

    inline fn queueRender(self: *StreamHandler) !void {
        try self.ev.queueRender();
    }

    inline fn messageWriter(self: *StreamHandler, msg: termio.Message) void {
        _ = self.ev.writer_mailbox.push(msg, .{ .forever = {} });
        self.writer_messaged = true;
    }

    pub fn print(self: *StreamHandler, ch: u21) !void {
        try self.terminal.print(ch);
    }

    pub fn printRepeat(self: *StreamHandler, count: usize) !void {
        try self.terminal.printRepeat(count);
    }

    pub fn bell(self: StreamHandler) !void {
        _ = self;
        log.info("BELL", .{});
    }

    pub fn backspace(self: *StreamHandler) !void {
        self.terminal.backspace();
    }

    pub fn horizontalTab(self: *StreamHandler, count: u16) !void {
        for (0..count) |_| {
            const x = self.terminal.screen.cursor.x;
            try self.terminal.horizontalTab();
            if (x == self.terminal.screen.cursor.x) break;
        }
    }

    pub fn horizontalTabBack(self: *StreamHandler, count: u16) !void {
        for (0..count) |_| {
            const x = self.terminal.screen.cursor.x;
            try self.terminal.horizontalTabBack();
            if (x == self.terminal.screen.cursor.x) break;
        }
    }

    pub fn linefeed(self: *StreamHandler) !void {
        // Small optimization: call index instead of linefeed because they're
        // identical and this avoids one layer of function call overhead.
        try self.terminal.index();
    }

    pub fn carriageReturn(self: *StreamHandler) !void {
        self.terminal.carriageReturn();
    }

    pub fn setCursorLeft(self: *StreamHandler, amount: u16) !void {
        self.terminal.cursorLeft(amount);
    }

    pub fn setCursorRight(self: *StreamHandler, amount: u16) !void {
        self.terminal.cursorRight(amount);
    }

    pub fn setCursorDown(self: *StreamHandler, amount: u16) !void {
        self.terminal.cursorDown(amount);
    }

    pub fn setCursorUp(self: *StreamHandler, amount: u16) !void {
        self.terminal.cursorUp(amount);
    }

    pub fn setCursorCol(self: *StreamHandler, col: u16) !void {
        self.terminal.setCursorColAbsolute(col);
    }

    pub fn setCursorRow(self: *StreamHandler, row: u16) !void {
        if (self.terminal.modes.origin) {
            // TODO
            log.err("setCursorRow: implement origin mode", .{});
            unreachable;
        }

        self.terminal.setCursorPos(row, self.terminal.screen.cursor.x + 1);
    }

    pub fn setCursorPos(self: *StreamHandler, row: u16, col: u16) !void {
        self.terminal.setCursorPos(row, col);
    }

    pub fn eraseDisplay(self: *StreamHandler, mode: terminal.EraseDisplay) !void {
        if (mode == .complete) {
            // Whenever we erase the full display, scroll to bottom.
            try self.terminal.scrollViewport(.{ .bottom = {} });
            try self.queueRender();
        }

        self.terminal.eraseDisplay(mode);
    }

    pub fn eraseLine(self: *StreamHandler, mode: terminal.EraseLine) !void {
        self.terminal.eraseLine(mode);
    }

    pub fn deleteChars(self: *StreamHandler, count: usize) !void {
        try self.terminal.deleteChars(count);
    }

    pub fn eraseChars(self: *StreamHandler, count: usize) !void {
        self.terminal.eraseChars(count);
    }

    pub fn insertLines(self: *StreamHandler, count: usize) !void {
        try self.terminal.insertLines(count);
    }

    pub fn insertBlanks(self: *StreamHandler, count: usize) !void {
        self.terminal.insertBlanks(count);
    }

    pub fn deleteLines(self: *StreamHandler, count: usize) !void {
        try self.terminal.deleteLines(count);
    }

    pub fn reverseIndex(self: *StreamHandler) !void {
        try self.terminal.reverseIndex();
    }

    pub fn index(self: *StreamHandler) !void {
        try self.terminal.index();
    }

    pub fn nextLine(self: *StreamHandler) !void {
        self.terminal.carriageReturn();
        try self.terminal.index();
    }

    pub fn setTopAndBottomMargin(self: *StreamHandler, top: u16, bot: u16) !void {
        self.terminal.setScrollingRegion(top, bot);
    }

    pub fn setMode(self: *StreamHandler, mode: terminal.Mode, enabled: bool) !void {
        // Note: this function doesn't need to grab the render state or
        // terminal locks because it is only called from process() which
        // grabs the lock.

        switch (mode) {
            .cursor_keys => {
                self.terminal.modes.cursor_keys = enabled;
            },

            .insert => {
                self.terminal.modes.insert = enabled;
            },

            .reverse_colors => {
                self.terminal.modes.reverse_colors = enabled;

                // Schedule a render since we changed colors
                try self.queueRender();
            },

            .origin => {
                self.terminal.modes.origin = enabled;
                self.terminal.setCursorPos(1, 1);
            },

            .autowrap => {
                self.terminal.modes.autowrap = enabled;
            },

            .cursor_visible => {
                self.ev.renderer_state.cursor.visible = enabled;
            },

            .alt_screen_save_cursor_clear_enter => {
                const opts: terminal.Terminal.AlternateScreenOptions = .{
                    .cursor_save = true,
                    .clear_on_enter = true,
                };

                if (enabled)
                    self.terminal.alternateScreen(opts)
                else
                    self.terminal.primaryScreen(opts);

                // Schedule a render since we changed screens
                try self.queueRender();
            },

            .bracketed_paste => self.terminal.modes.bracketed_paste = enabled,

            .enable_mode_3 => {
                // Disable deccolm
                self.terminal.setDeccolmSupported(enabled);

                // Force resize back to the window size
                self.terminal.resize(self.alloc, self.grid_size.columns, self.grid_size.rows) catch |err|
                    log.err("error updating terminal size: {}", .{err});
            },

            .@"132_column" => try self.terminal.deccolm(
                self.alloc,
                if (enabled) .@"132_cols" else .@"80_cols",
            ),

            .mouse_event_x10 => self.terminal.modes.mouse_event = if (enabled) .x10 else .none,
            .mouse_event_normal => self.terminal.modes.mouse_event = if (enabled) .normal else .none,
            .mouse_event_button => self.terminal.modes.mouse_event = if (enabled) .button else .none,
            .mouse_event_any => self.terminal.modes.mouse_event = if (enabled) .any else .none,

            .mouse_format_utf8 => self.terminal.modes.mouse_format = if (enabled) .utf8 else .x10,
            .mouse_format_sgr => self.terminal.modes.mouse_format = if (enabled) .sgr else .x10,
            .mouse_format_urxvt => self.terminal.modes.mouse_format = if (enabled) .urxvt else .x10,
            .mouse_format_sgr_pixels => self.terminal.modes.mouse_format = if (enabled) .sgr_pixels else .x10,

            .mouse_alternate_scroll => self.terminal.modes.mouse_alternate_scroll = enabled,

            .focus_event => self.terminal.modes.focus_event = enabled,

            else => if (enabled) log.warn("unimplemented mode: {}", .{mode}),
        }
    }

    pub fn setAttribute(self: *StreamHandler, attr: terminal.Attribute) !void {
        switch (attr) {
            .unknown => |unk| log.warn("unimplemented or unknown SGR attribute: {any}", .{unk}),

            else => self.terminal.setAttribute(attr) catch |err|
                log.warn("error setting attribute {}: {}", .{ attr, err }),
        }
    }

    pub fn deviceAttributes(
        self: *StreamHandler,
        req: terminal.DeviceAttributeReq,
        params: []const u16,
    ) !void {
        _ = params;

        switch (req) {
            // VT220
            .primary => self.messageWriter(.{ .write_stable = "\x1B[?62;c" }),
            else => log.warn("unimplemented device attributes req: {}", .{req}),
        }
    }

    pub fn deviceStatusReport(
        self: *StreamHandler,
        req: terminal.DeviceStatusReq,
    ) !void {
        switch (req) {
            .operating_status => self.messageWriter(.{ .write_stable = "\x1B[0n" }),

            .cursor_position => {
                const pos: struct {
                    x: usize,
                    y: usize,
                } = if (self.terminal.modes.origin) .{
                    // TODO: what do we do if cursor is outside scrolling region?
                    .x = self.terminal.screen.cursor.x,
                    .y = self.terminal.screen.cursor.y -| self.terminal.scrolling_region.top,
                } else .{
                    .x = self.terminal.screen.cursor.x,
                    .y = self.terminal.screen.cursor.y,
                };

                // Response always is at least 4 chars, so this leaves the
                // remainder for the row/column as base-10 numbers. This
                // will support a very large terminal.
                var msg: termio.Message = .{ .write_small = .{} };
                const resp = try std.fmt.bufPrint(&msg.write_small.data, "\x1B[{};{}R", .{
                    pos.y + 1,
                    pos.x + 1,
                });
                msg.write_small.len = @intCast(resp.len);

                self.messageWriter(msg);
            },

            else => log.warn("unimplemented device status req: {}", .{req}),
        }
    }

    pub fn setCursorStyle(
        self: *StreamHandler,
        style: terminal.CursorStyle,
    ) !void {
        self.ev.renderer_state.cursor.style = style;
    }

    pub fn decaln(self: *StreamHandler) !void {
        try self.terminal.decaln();
    }

    pub fn tabClear(self: *StreamHandler, cmd: terminal.TabClear) !void {
        self.terminal.tabClear(cmd);
    }

    pub fn tabSet(self: *StreamHandler) !void {
        self.terminal.tabSet();
    }

    pub fn saveCursor(self: *StreamHandler) !void {
        self.terminal.saveCursor();
    }

    pub fn restoreCursor(self: *StreamHandler) !void {
        self.terminal.restoreCursor();
    }

    pub fn enquiry(self: *StreamHandler) !void {
        self.messageWriter(.{ .write_stable = "" });
    }

    pub fn scrollDown(self: *StreamHandler, count: usize) !void {
        try self.terminal.scrollDown(count);
    }

    pub fn scrollUp(self: *StreamHandler, count: usize) !void {
        try self.terminal.scrollUp(count);
    }

    pub fn setActiveStatusDisplay(
        self: *StreamHandler,
        req: terminal.StatusDisplay,
    ) !void {
        self.terminal.status_display = req;
    }

    pub fn configureCharset(
        self: *StreamHandler,
        slot: terminal.CharsetSlot,
        set: terminal.Charset,
    ) !void {
        self.terminal.configureCharset(slot, set);
    }

    pub fn invokeCharset(
        self: *StreamHandler,
        active: terminal.CharsetActiveSlot,
        slot: terminal.CharsetSlot,
        single: bool,
    ) !void {
        self.terminal.invokeCharset(active, slot, single);
    }

    pub fn fullReset(
        self: *StreamHandler,
    ) !void {
        self.terminal.fullReset();
    }

    //-------------------------------------------------------------------------
    // OSC

    pub fn changeWindowTitle(self: *StreamHandler, title: []const u8) !void {
        var buf: [256]u8 = undefined;
        if (title.len >= buf.len) {
            log.warn("change title requested larger than our buffer size, ignoring", .{});
            return;
        }

        std.mem.copy(u8, &buf, title);
        buf[title.len] = 0;

        // Mark that we've seen a title
        self.ev.seen_title = true;

        _ = self.ev.surface_mailbox.push(.{
            .set_title = buf,
        }, .{ .forever = {} });
    }

    pub fn clipboardContents(self: *StreamHandler, kind: u8, data: []const u8) !void {
        // Note: we ignore the "kind" field and always use the primary clipboard.
        // iTerm also appears to do this but other terminals seem to only allow
        // certain. Let's investigate more.

        // Get clipboard contents
        if (data.len == 1 and data[0] == '?') {
            _ = self.ev.surface_mailbox.push(.{
                .clipboard_read = kind,
            }, .{ .forever = {} });
            return;
        }

        // Write clipboard contents
        _ = self.ev.surface_mailbox.push(.{
            .clipboard_write = try apprt.surface.Message.WriteReq.init(
                self.alloc,
                data,
            ),
        }, .{ .forever = {} });
    }

    pub fn promptStart(self: *StreamHandler, aid: ?[]const u8, redraw: bool) !void {
        _ = aid;
        self.terminal.markSemanticPrompt(.prompt);
        self.terminal.modes.shell_redraws_prompt = redraw;
    }

    pub fn promptEnd(self: *StreamHandler) !void {
        self.terminal.markSemanticPrompt(.input);
    }

    pub fn endOfInput(self: *StreamHandler) !void {
        self.terminal.markSemanticPrompt(.command);
    }

    pub fn reportPwd(self: *StreamHandler, url: []const u8) !void {
        const uri = std.Uri.parse(url) catch |e| {
            log.warn("invalid url in OSC 7: {}", .{e});
            return;
        };

        if (!std.mem.eql(u8, "file", uri.scheme) and
            !std.mem.eql(u8, "kitty-shell-cwd", uri.scheme))
        {
            log.warn("OSC 7 scheme must be file, got: {s}", .{uri.scheme});
            return;
        }

        // OSC 7 is a little sketchy because anyone can send any value from
        // any host (such an SSH session). The best practice terminals follow
        // is to valid the hostname to be local.
        const host_valid = host_valid: {
            const host = uri.host orelse break :host_valid false;

            // Empty or localhost is always good
            if (host.len == 0 or std.mem.eql(u8, "localhost", host)) {
                break :host_valid true;
            }

            // Otherwise, it must match our hostname.
            var buf: [std.os.HOST_NAME_MAX]u8 = undefined;
            const hostname = std.os.gethostname(&buf) catch |err| {
                log.warn("failed to get hostname for OSC 7 validation: {}", .{err});
                break :host_valid false;
            };

            break :host_valid std.mem.eql(u8, host, hostname);
        };
        if (!host_valid) {
            log.warn("OSC 7 host must be local", .{});
            return;
        }

        log.debug("terminal pwd: {s}", .{uri.path});
        try self.terminal.setPwd(uri.path);

        // If we haven't seen a title, use our pwd as the title.
        if (!self.ev.seen_title) {
            try self.changeWindowTitle(uri.path);
            self.ev.seen_title = false;
        }
    }
};
