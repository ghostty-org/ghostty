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
const Pty = @import("../pty.zig").Pty;
const SegmentedPool = @import("../segmented_pool.zig").SegmentedPool;
const terminal = @import("../terminal/main.zig");
const terminfo = @import("../terminfo/main.zig");
const xev = @import("xev");
const renderer = @import("../renderer.zig");
const tracy = @import("tracy");
const trace = tracy.trace;
const apprt = @import("../apprt.zig");
const fastmem = @import("../fastmem.zig");
const internal_os = @import("../os/main.zig");
const windows = internal_os.windows;
const configpkg = @import("../config.zig");
const shell_integration = @import("shell_integration.zig");

const log = std.log.scoped(.io_exec);

const c = @cImport({
    @cInclude("errno.h");
    @cInclude("signal.h");
    @cInclude("unistd.h");
});

/// True if we should disable the kitty keyboard protocol. We have to
/// disable this on GLFW because GLFW input events don't support the
/// correct granularity of events.
const disable_kitty_keyboard_protocol = apprt.runtime == apprt.glfw;

/// Allocator
alloc: Allocator,

/// This is the pty fd created for the subcommand.
subprocess: Subprocess,

/// The terminal emulator internal state. This is the abstract "terminal"
/// that manages input, grid updating, etc. and is renderer-agnostic. It
/// just stores internal state about a grid.
terminal: terminal.Terminal,

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

/// The default cursor style. We need to know this so that we can set
/// it when a CSI q with default is called.
default_cursor_style: terminal.Cursor.Style,
default_cursor_blink: ?bool,
default_cursor_color: ?terminal.color.RGB,

/// Actual cursor color
cursor_color: ?terminal.color.RGB,

/// Default foreground color as set by the config file
default_foreground_color: terminal.color.RGB,

/// Default background color as set by the config file
default_background_color: terminal.color.RGB,

/// Actual foreground color
foreground_color: terminal.color.RGB,

/// Actual background color
background_color: terminal.color.RGB,

/// The OSC 10/11 reply style.
osc_color_report_format: configpkg.Config.OSCColorReportFormat,

/// The data associated with the currently running thread.
data: ?*EventData,

/// The configuration for this IO that is derived from the main
/// configuration. This must be exported so that we don't need to
/// pass around Config pointers which makes memory management a pain.
pub const DerivedConfig = struct {
    palette: terminal.color.Palette,
    image_storage_limit: usize,
    cursor_style: terminal.Cursor.Style,
    cursor_blink: ?bool,
    cursor_color: ?configpkg.Config.Color,
    foreground: configpkg.Config.Color,
    background: configpkg.Config.Color,
    osc_color_report_format: configpkg.Config.OSCColorReportFormat,
    term: []const u8,

    pub fn init(
        alloc_gpa: Allocator,
        config: *const configpkg.Config,
    ) !DerivedConfig {
        _ = alloc_gpa;

        return .{
            .palette = config.palette.value,
            .image_storage_limit = config.@"image-storage-limit",
            .cursor_style = config.@"cursor-style",
            .cursor_blink = config.@"cursor-style-blink",
            .cursor_color = config.@"cursor-color",
            .foreground = config.foreground,
            .background = config.background,
            .osc_color_report_format = config.@"osc-color-report-format",
            .term = config.term,
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
    term.default_palette = opts.config.palette;
    term.color_palette.colors = opts.config.palette;

    // Set the image size limits
    try term.screen.kitty_images.setLimit(alloc, opts.config.image_storage_limit);
    try term.secondary_screen.kitty_images.setLimit(alloc, opts.config.image_storage_limit);

    // Set default cursor blink settings
    term.modes.set(
        .cursor_blinking,
        opts.config.cursor_blink orelse true,
    );

    var subprocess = try Subprocess.init(alloc, opts);
    errdefer subprocess.deinit();

    // If we have an initial pwd requested by the subprocess, then we
    // set that on the terminal now. This allows rapidly initializing
    // new surfaces to use the proper pwd.
    if (subprocess.cwd) |cwd| term.setPwd(cwd) catch |err| {
        log.warn("error setting initial pwd err={}", .{err});
    };

    // Initial width/height based on subprocess
    term.width_px = subprocess.screen_size.width;
    term.height_px = subprocess.screen_size.height;

    return Exec{
        .alloc = alloc,
        .terminal = term,
        .subprocess = subprocess,
        .renderer_state = opts.renderer_state,
        .renderer_wakeup = opts.renderer_wakeup,
        .renderer_mailbox = opts.renderer_mailbox,
        .surface_mailbox = opts.surface_mailbox,
        .grid_size = opts.grid_size,
        .default_cursor_style = opts.config.cursor_style,
        .default_cursor_blink = opts.config.cursor_blink,
        .default_cursor_color = if (opts.config.cursor_color) |col|
            col.toTerminalRGB()
        else
            null,
        .cursor_color = if (opts.config.cursor_color) |col|
            col.toTerminalRGB()
        else
            null,
        .default_foreground_color = config.foreground.toTerminalRGB(),
        .default_background_color = config.background.toTerminalRGB(),
        .foreground_color = config.foreground.toTerminalRGB(),
        .background_color = config.background.toTerminalRGB(),
        .osc_color_report_format = config.osc_color_report_format,
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
    const pty_fds = try self.subprocess.start(alloc);
    errdefer self.subprocess.stop();
    const pid = pid: {
        const command = self.subprocess.command orelse return error.ProcessNotStarted;
        break :pid command.pid orelse return error.ProcessNoPid;
    };

    // Create our pipe that we'll use to kill our read thread.
    // pipe[0] is the read end, pipe[1] is the write end.
    const pipe = try internal_os.pipe();
    errdefer std.os.close(pipe[0]);
    errdefer std.os.close(pipe[1]);

    // Setup our data that is used for callbacks
    var ev_data_ptr = try alloc.create(EventData);
    errdefer alloc.destroy(ev_data_ptr);

    // Setup our stream so that we can write.
    var stream = xev.Stream.initFd(pty_fds.write);
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
                .default_cursor_style = self.default_cursor_style,
                .default_cursor_blink = self.default_cursor_blink,
                .default_cursor_color = self.default_cursor_color,
                .cursor_color = self.cursor_color,
                .default_foreground_color = self.default_foreground_color,
                .default_background_color = self.default_background_color,
                .foreground_color = self.foreground_color,
                .background_color = self.background_color,
                .osc_color_report_format = self.osc_color_report_format,
            },

            .parser = .{
                .osc_parser = .{
                    // Populate the OSC parser allocator (optional) because
                    // we want to support large OSC payloads such as OSC 52.
                    .alloc = self.alloc,
                },
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
        if (builtin.os.tag == .windows) ReadThread.threadMainWindows else ReadThread.threadMainPosix,
        .{ pty_fds.read, ev_data_ptr, pipe[0] },
    );
    read_thread.setName("io-reader") catch {};

    // Return our thread data
    return ThreadData{
        .alloc = alloc,
        .ev = ev_data_ptr,
        .read_thread = read_thread,
        .read_thread_pipe = pipe[1],
        .read_thread_fd = if (builtin.os.tag == .windows) pty_fds.read else {},
    };
}

pub fn threadExit(self: *Exec, data: ThreadData) void {
    // Clear out our data since we're not active anymore.
    self.data = null;

    // Stop our subprocess
    if (data.ev.process_exited) self.subprocess.externalExit();
    self.subprocess.stop();

    // Quit our read thread after exiting the subprocess so that
    // we don't get stuck waiting for data to stop flowing if it is
    // a particularly noisy process.
    _ = std.os.write(data.read_thread_pipe, "x") catch |err|
        log.warn("error writing to read thread quit pipe err={}", .{err});

    if (comptime builtin.os.tag == .windows) {
        // Interrupt the blocking read so the thread can see the quit message
        if (windows.kernel32.CancelIoEx(data.read_thread_fd, null) == 0) {
            switch (windows.kernel32.GetLastError()) {
                .NOT_FOUND => {},
                else => |err| log.warn("error interrupting read thread err={}", .{err}),
            }
        }
    }

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

    // Update the default palette. Note this will only apply to new colors drawn
    // since we decode all palette colors to RGB on usage.
    self.terminal.default_palette = config.palette;

    // Update the active palette, except for any colors that were modified with
    // OSC 4
    for (0..config.palette.len) |i| {
        if (!self.terminal.color_palette.mask.isSet(i)) {
            self.terminal.color_palette.colors[i] = config.palette[i];
        }
    }

    // Update our default cursor style
    self.default_cursor_style = config.cursor_style;
    self.default_cursor_blink = config.cursor_blink;
    self.default_cursor_color = if (config.cursor_color) |col|
        col.toTerminalRGB()
    else
        null;

    // Update default foreground and background colors
    self.default_foreground_color = config.foreground.toTerminalRGB();
    self.default_background_color = config.background.toTerminalRGB();

    // If we have event data, then update our active stream too
    if (self.data) |data| {
        data.terminal_stream.handler.changeDefaultCursor(
            config.cursor_style,
            config.cursor_blink,
        );
    }

    // Set the image size limits
    try self.terminal.screen.kitty_images.setLimit(
        self.alloc,
        config.image_storage_limit,
    );
    try self.terminal.secondary_screen.kitty_images.setLimit(
        self.alloc,
        config.image_storage_limit,
    );
}

/// Resize the terminal.
pub fn resize(
    self: *Exec,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
    padding: renderer.Padding,
) !void {
    // Update the size of our pty.
    const padded_size = screen_size.subPadding(padding);
    try self.subprocess.resize(grid_size, padded_size);

    // Update our cached grid size
    self.grid_size = grid_size;

    // Enter the critical area that we want to keep small
    {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();

        // Update the size of our terminal state
        try self.terminal.resize(
            self.alloc,
            grid_size.columns,
            grid_size.rows,
        );

        // Update our pixel sizes
        self.terminal.width_px = padded_size.width;
        self.terminal.height_px = padded_size.height;

        // Disable synchronized output mode so that we show changes
        // immediately for a resize. This is allowed by the spec.
        self.terminal.modes.set(.synchronized_output, false);

        // Wake up our renderer so any changes will be shown asap
        self.renderer_wakeup.notify() catch {};
    }
}

/// Reset the synchronized output mode. This is usually called by timer
/// expiration from the termio thread.
pub fn resetSynchronizedOutput(self: *Exec) void {
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();
    self.terminal.modes.set(.synchronized_output, false);
    self.renderer_wakeup.notify() catch {};
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
        if (history) self.terminal.eraseDisplay(self.alloc, .scrollback, false);

        // If we're not at a prompt, we just delete above the cursor.
        if (!self.terminal.cursorIsAtPrompt()) {
            try self.terminal.screen.clear(.above_cursor);
            return;
        }

        // At a prompt, we want to first fully clear the screen, and then after
        // send a FF (0x0C) to the shell so that it can repaint the screen.
        // Mark the current row as a not a prompt so we can properly
        // clear the full screen in the next eraseDisplay call.
        self.terminal.markSemanticPrompt(.command);
        assert(!self.terminal.cursorIsAtPrompt());
        self.terminal.eraseDisplay(self.alloc, .complete, false);
    }

    // If we reached here it means we're at a prompt, so we send a form-feed.
    try self.queueWrite(&[_]u8{0x0C}, false);
}

/// Scroll the viewport
pub fn scrollViewport(self: *Exec, scroll: terminal.Terminal.ScrollViewport) !void {
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();
    try self.terminal.scrollViewport(scroll);
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

pub inline fn queueWrite(self: *Exec, data: []const u8, linefeed: bool) !void {
    const ev = self.data.?;

    // We go through and chunk the data if necessary to fit into
    // our cached buffers that we can queue to the stream.
    var i: usize = 0;
    while (i < data.len) {
        const req = try ev.write_req_pool.getGrow(self.alloc);
        const buf = try ev.write_buf_pool.getGrow(self.alloc);
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

        ev.data_stream.queueWrite(
            ev.loop,
            &ev.write_queue,
            req,
            .{ .slice = slice },
            EventData,
            ev,
            ttyWrite,
        );
    }
}

const ThreadData = struct {
    /// Allocator used for the event data
    alloc: Allocator,

    /// The data that is attached to the callbacks.
    ev: *EventData,

    /// Our read thread
    read_thread: std.Thread,
    read_thread_pipe: std.os.fd_t,
    read_thread_fd: if (builtin.os.tag == .windows) std.os.fd_t else void,

    pub fn deinit(self: *ThreadData) void {
        std.os.close(self.read_thread_pipe);
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

        // Clear any StreamHandler state
        self.terminal_stream.handler.deinit();
        self.terminal_stream.deinit();
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
    //log.info("WROTE: {d}", .{d});

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
        const default_path = switch (builtin.os.tag) {
            .windows => "cmd.exe",
            else => "sh",
        };
        const path = try Command.expandPath(
            alloc,
            opts.full_config.command orelse default_path,
        ) orelse path: {
            // If we had a command specified, try to at least fall
            // back to a default value like "sh" so that Ghostty
            // launches.
            if (opts.full_config.command) |command| {
                log.warn("unable to find command, fallbacking back to default command={s}", .{command});
                if (try Command.expandPath(
                    alloc,
                    default_path,
                )) |path| break :path path;
            }

            log.warn("unable to find default command to launch, exiting", .{});
            return error.CommandNotFound;
        };

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
            @memcpy(argv0_buf[1..], argv0);
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

        // If we have a resources dir then set our env var
        const resources_key = "GHOSTTY_RESOURCES_DIR";
        if (opts.resources_dir) |dir| {
            log.info("found Ghostty resources dir: {s}", .{dir});
            try env.put(resources_key, dir);
        }

        // Set our TERM var. This is a bit complicated because we want to use
        // the ghostty TERM value but we want to only do that if we have
        // ghostty in the TERMINFO database.
        //
        // For now, we just look up a bundled dir but in the future we should
        // also load the terminfo database and look for it.
        if (opts.resources_dir) |base| {
            var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
            const dir = try std.fmt.bufPrint(&buf, "{s}/terminfo", .{base});
            try env.put("TERM", opts.config.term);
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

        // Set environment variables used by some programs (such as neovim) to detect
        // which terminal emulator and version they're running under.
        try env.put("TERM_PROGRAM", "ghostty");
        try env.put("TERM_PROGRAM_VERSION", build_config.version_string);

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

            // Remove this so that running `ghostty` within Ghostty works.
            env.remove("GHOSTTY_MAC_APP");
        }

        // Build our args list
        const args = args: {
            const cap = 1 + opts.full_config.@"command-arg".list.items.len;
            var args = try std.ArrayList([]const u8).initCapacity(alloc, cap);
            defer args.deinit();

            if (!internal_os.isFlatpak()) {
                try args.append(argv0_override orelse path);
            } else {
                // We run our shell wrapped in a /bin/sh login shell because
                // some systems do not properly initialize the env vars unless
                // we start this way (NixOS!)
                try args.append("/bin/sh");
                try args.append("-l");
                try args.append("-c");
                try args.append(path);
            }

            try args.appendSlice(opts.full_config.@"command-arg".list.items);
            break :args try args.toOwnedSlice();
        };

        // We have to copy the cwd because there is no guarantee that
        // pointers in full_config remain valid.
        const cwd: ?[]u8 = if (opts.full_config.@"working-directory") |cwd|
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

            const dir = opts.resources_dir orelse break :shell null;
            break :shell try shell_integration.setup(
                dir,
                final_path,
                &env,
                force,
                opts.full_config.@"shell-integration-features",
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

        // Our screen size should be our padded size
        const padded_size = opts.screen_size.subPadding(opts.padding);

        return .{
            .arena = arena,
            .env = env,
            .cwd = cwd,
            .path = final_path,
            .args = args,
            .grid_size = opts.grid_size,
            .screen_size = padded_size,
        };
    }

    /// Clean up the subprocess. This will stop the subprocess if it is started.
    pub fn deinit(self: *Subprocess) void {
        self.stop();
        if (self.pty) |*pty| pty.deinit();
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

            return .{
                .read = pty.master,
                .write = pty.master,
            };
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
            .stdin = if (builtin.os.tag == .windows) null else .{ .handle = pty.slave },
            .stdout = if (builtin.os.tag == .windows) null else .{ .handle = pty.slave },
            .stderr = if (builtin.os.tag == .windows) null else .{ .handle = pty.slave },
            .pseudo_console = if (builtin.os.tag == .windows) pty.pseudo_console else {},
            .pre_exec = if (builtin.os.tag == .windows) null else (struct {
                fn callback(cmd: *Command) void {
                    const p = cmd.getData(Pty) orelse unreachable;
                    p.childPreExec() catch |err|
                        log.err("error initializing child: {}", .{err});
                }
            }).callback,
            .data = &self.pty.?,
        };
        try cmd.start(alloc);
        errdefer killCommand(&cmd) catch |err| {
            log.warn("error killing command during cleanup err={}", .{err});
        };
        log.info("started subcommand path={s} pid={?}", .{ self.path, cmd.pid });

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
            switch (builtin.os.tag) {
                .windows => {
                    if (windows.kernel32.TerminateProcess(pid, 0) == 0) {
                        return windows.unexpectedError(windows.kernel32.GetLastError());
                    }
                },

                else => {
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
                },
            }
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
const ReadThread = struct {
    fn threadMainPosix(fd: std.os.fd_t, ev: *EventData, quit: std.os.fd_t) void {
        // Always close our end of the pipe when we exit.
        defer std.os.close(quit);

        // First thing, we want to set the fd to non-blocking. We do this
        // so that we can try to read from the fd in a tight loop and only
        // check the quit fd occasionally.
        if (std.os.fcntl(fd, std.os.F.GETFL, 0)) |flags| {
            _ = std.os.fcntl(fd, std.os.F.SETFL, flags | std.os.O.NONBLOCK) catch |err| {
                log.warn("read thread failed to set flags err={}", .{err});
                log.warn("this isn't a fatal error, but may cause performance issues", .{});
            };
        } else |err| {
            log.warn("read thread failed to get flags err={}", .{err});
            log.warn("this isn't a fatal error, but may cause performance issues", .{});
        }

        // Build up the list of fds we're going to poll. We are looking
        // for data on the pty and our quit notification.
        var pollfds: [2]std.os.pollfd = .{
            .{ .fd = fd, .events = std.os.POLL.IN, .revents = undefined },
            .{ .fd = quit, .events = std.os.POLL.IN, .revents = undefined },
        };

        var buf: [1024]u8 = undefined;
        while (true) {
            // We try to read from the file descriptor as long as possible
            // to maximize performance. We only check the quit fd if the
            // main fd blocks. This optimizes for the realistic scenario that
            // the data will eventually stop while we're trying to quit. This
            // is always true because we kill the process.
            while (true) {
                const n = std.os.read(fd, &buf) catch |err| {
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
                @call(.always_inline, process, .{ ev, buf[0..n] });
            }

            // Wait for data.
            _ = std.os.poll(&pollfds, -1) catch |err| {
                log.warn("poll failed on read thread, exiting early err={}", .{err});
                return;
            };

            // If our quit fd is set, we're done.
            if (pollfds[1].revents & std.os.POLL.IN != 0) {
                log.info("read thread got quit signal", .{});
                return;
            }
        }
    }

    fn threadMainWindows(fd: std.os.fd_t, ev: *EventData, quit: std.os.fd_t) void {
        // Always close our end of the pipe when we exit.
        defer std.os.close(quit);

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

                @call(.always_inline, process, .{ ev, buf[0..n] });
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

        // If we have an inspector, we enter SLOW MODE because we need to
        // process a byte at a time alternating between the inspector handler
        // and the termio handler. This is very slow compared to our optimizations
        // below but at least users only pay for it if they're using the inspector.
        if (ev.renderer_state.inspector) |insp| {
            for (buf, 0..) |byte, i| {
                insp.recordPtyRead(buf[i .. i + 1]) catch |err| {
                    log.err("error recording pty read in inspector err={}", .{err});
                };

                ev.terminal_stream.next(byte) catch |err|
                    log.err("error processing terminal data: {}", .{err});
            }
        } else {
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

    /// The APC command handler maintains the APC state. APC is like
    /// CSI or OSC, but it is a private escape sequence that is used
    /// to send commands to the terminal emulator. This is used by
    /// the kitty graphics protocol.
    apc: terminal.apc.Handler = .{},

    /// The DCS handler maintains DCS state. DCS is like CSI or OSC,
    /// but requires more stateful parsing. This is used by functionality
    /// such as XTGETTCAP.
    dcs: terminal.dcs.Handler = .{},

    /// This is set to true when a message was written to the writer
    /// mailbox. This can be used by callers to determine if they need
    /// to wake up the writer.
    writer_messaged: bool = false,

    /// The default cursor state. This is used with CSI q. This is
    /// set to true when we're currently in the default cursor state.
    default_cursor: bool = true,
    default_cursor_style: terminal.Cursor.Style,
    default_cursor_blink: ?bool,
    default_cursor_color: ?terminal.color.RGB,

    /// Actual cursor color. This can be changed with OSC 12.
    cursor_color: ?terminal.color.RGB,

    /// The default foreground and background color are those set by the user's
    /// config file. These can be overridden by terminal applications using OSC
    /// 10 and OSC 11, respectively.
    default_foreground_color: terminal.color.RGB,
    default_background_color: terminal.color.RGB,

    /// The actual foreground and background color. Normally this will be the
    /// same as the default foreground and background color, unless changed by a
    /// terminal application.
    foreground_color: terminal.color.RGB,
    background_color: terminal.color.RGB,

    osc_color_report_format: configpkg.Config.OSCColorReportFormat,

    pub fn deinit(self: *StreamHandler) void {
        self.apc.deinit();
        self.dcs.deinit();
    }

    inline fn queueRender(self: *StreamHandler) !void {
        try self.ev.queueRender();
    }

    inline fn messageWriter(self: *StreamHandler, msg: termio.Message) void {
        // Try to write to the mailbox with an instant timeout. This is the
        // fast path because we can queue without a lock.
        if (self.ev.writer_mailbox.push(msg, .{ .instant = {} }) == 0) {
            // If we enter this conditional, the mailbox is full. We wake up
            // the writer thread so that it can process messages to clear up
            // space. However, the writer thread may require the renderer
            // lock so we need to unlock.
            self.ev.writer_wakeup.notify() catch |err| {
                log.warn("failed to wake up writer, data will be dropped err={}", .{err});
                return;
            };

            // Unlock the renderer state so the writer thread can acquire it.
            // Then try to queue our message before continuing. This is a very
            // slow path because we are having a lot of contention for data.
            // But this only gets triggered in certain pathological cases.
            //
            // Note that writes themselves don't require a lock, but there
            // are other messages in the writer mailbox (resize, focus) that
            // could acquire the lock. This is why we have to release our lock
            // here.
            self.ev.renderer_state.mutex.unlock();
            defer self.ev.renderer_state.mutex.lock();
            _ = self.ev.writer_mailbox.push(msg, .{ .forever = {} });
        }

        // Normally, we just flag this true to wake up the writer thread
        // once per batch of data.
        self.writer_messaged = true;
    }

    pub fn changeDefaultCursor(
        self: *StreamHandler,
        style: terminal.Cursor.Style,
        blink: ?bool,
    ) void {
        self.default_cursor_style = style;
        self.default_cursor_blink = blink;

        // If our cursor is the default, then we update it immediately.
        if (self.default_cursor) self.setCursorStyle(.default) catch |err| {
            log.warn("failed to set default cursor style: {}", .{err});
            return;
        };
    }

    pub fn dcsHook(self: *StreamHandler, dcs: terminal.DCS) !void {
        self.dcs.hook(self.alloc, dcs);
    }

    pub fn dcsPut(self: *StreamHandler, byte: u8) !void {
        self.dcs.put(byte);
    }

    pub fn dcsUnhook(self: *StreamHandler) !void {
        var cmd = self.dcs.unhook() orelse return;
        defer cmd.deinit();

        // log.warn("DCS command: {}", .{cmd});
        switch (cmd) {
            .xtgettcap => |*gettcap| {
                const map = comptime terminfo.ghostty.xtgettcapMap();
                while (gettcap.next()) |key| {
                    const response = map.get(key) orelse continue;
                    self.messageWriter(.{ .write_stable = response });
                }
            },
        }
    }

    pub fn apcStart(self: *StreamHandler) !void {
        self.apc.start();
    }

    pub fn apcPut(self: *StreamHandler, byte: u8) !void {
        self.apc.feed(self.alloc, byte);
    }

    pub fn apcEnd(self: *StreamHandler) !void {
        var cmd = self.apc.end() orelse return;
        defer cmd.deinit(self.alloc);

        // log.warn("APC command: {}", .{cmd});
        switch (cmd) {
            .kitty => |*kitty_cmd| {
                if (self.terminal.kittyGraphics(self.alloc, kitty_cmd)) |resp| {
                    var buf: [1024]u8 = undefined;
                    var buf_stream = std.io.fixedBufferStream(&buf);
                    try resp.encode(buf_stream.writer());
                    const final = buf_stream.getWritten();
                    if (final.len > 2) {
                        // log.warn("kitty graphics response: {s}", .{std.fmt.fmtSliceHexLower(final)});
                        self.messageWriter(try termio.Message.writeReq(self.alloc, final));
                    }
                }
            },
        }
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

    pub fn setCursorDown(self: *StreamHandler, amount: u16, carriage: bool) !void {
        self.terminal.cursorDown(amount);
        if (carriage) self.terminal.carriageReturn();
    }

    pub fn setCursorUp(self: *StreamHandler, amount: u16, carriage: bool) !void {
        self.terminal.cursorUp(amount);
        if (carriage) self.terminal.carriageReturn();
    }

    pub fn setCursorCol(self: *StreamHandler, col: u16) !void {
        self.terminal.setCursorPos(self.terminal.screen.cursor.y + 1, col);
    }

    pub fn setCursorColRelative(self: *StreamHandler, offset: u16) !void {
        self.terminal.setCursorPos(
            self.terminal.screen.cursor.y + 1,
            self.terminal.screen.cursor.x + 1 + offset,
        );
    }

    pub fn setCursorRow(self: *StreamHandler, row: u16) !void {
        self.terminal.setCursorPos(row, self.terminal.screen.cursor.x + 1);
    }

    pub fn setCursorRowRelative(self: *StreamHandler, offset: u16) !void {
        self.terminal.setCursorPos(
            self.terminal.screen.cursor.y + 1 + offset,
            self.terminal.screen.cursor.x + 1,
        );
    }

    pub fn setCursorPos(self: *StreamHandler, row: u16, col: u16) !void {
        self.terminal.setCursorPos(row, col);
    }

    pub fn eraseDisplay(self: *StreamHandler, mode: terminal.EraseDisplay, protected: bool) !void {
        if (mode == .complete) {
            // Whenever we erase the full display, scroll to bottom.
            try self.terminal.scrollViewport(.{ .bottom = {} });
            try self.queueRender();
        }

        self.terminal.eraseDisplay(self.alloc, mode, protected);
    }

    pub fn eraseLine(self: *StreamHandler, mode: terminal.EraseLine, protected: bool) !void {
        self.terminal.eraseLine(mode, protected);
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
        try self.terminal.index();
        self.terminal.carriageReturn();
    }

    pub fn setTopAndBottomMargin(self: *StreamHandler, top: u16, bot: u16) !void {
        self.terminal.setTopAndBottomMargin(top, bot);
    }

    pub fn setLeftAndRightMargin(self: *StreamHandler, left: u16, right: u16) !void {
        self.terminal.setLeftAndRightMargin(left, right);
    }

    pub fn setModifyKeyFormat(self: *StreamHandler, format: terminal.ModifyKeyFormat) !void {
        self.terminal.flags.modify_other_keys_2 = false;
        switch (format) {
            .other_keys => |v| switch (v) {
                .numeric => self.terminal.flags.modify_other_keys_2 = true,
                else => {},
            },
            else => {},
        }
    }

    pub fn requestMode(self: *StreamHandler, mode_raw: u16, ansi: bool) !void {
        // Get the mode value and respond.
        const code: u8 = code: {
            const mode = terminal.modes.modeFromInt(mode_raw, ansi) orelse break :code 0;
            if (self.terminal.modes.get(mode)) break :code 1;
            break :code 2;
        };

        var msg: termio.Message = .{ .write_small = .{} };
        const resp = try std.fmt.bufPrint(
            &msg.write_small.data,
            "\x1B[{s}{};{}$y",
            .{
                if (ansi) "" else "?",
                mode_raw,
                code,
            },
        );
        msg.write_small.len = @intCast(resp.len);
        self.messageWriter(msg);
    }

    pub fn saveMode(self: *StreamHandler, mode: terminal.Mode) !void {
        // log.debug("save mode={}", .{mode});
        self.terminal.modes.save(mode);
    }

    pub fn restoreMode(self: *StreamHandler, mode: terminal.Mode) !void {
        // For restore mode we have to restore but if we set it, we
        // always have to call setMode because setting some modes have
        // side effects and we want to make sure we process those.
        const v = self.terminal.modes.restore(mode);
        // log.debug("restore mode={} v={}", .{ mode, v });
        try self.setMode(mode, v);
    }

    pub fn setMode(self: *StreamHandler, mode: terminal.Mode, enabled: bool) !void {
        // Note: this function doesn't need to grab the render state or
        // terminal locks because it is only called from process() which
        // grabs the lock.

        // If we are setting cursor blinking, we ignore it if we have
        // a default cursor blink setting set. This is a really weird
        // behavior so this comment will go deep into trying to explain it.
        //
        // There are two ways to set cursor blinks: DECSCUSR (CSI _ q)
        // and DEC mode 12. DECSCUSR is the modern approach and has a
        // way to revert to the "default" (as defined by the terminal)
        // cursor style and blink by doing "CSI 0 q". DEC mode 12 controls
        // blinking and is either on or off and has no way to set a
        // default. DEC mode 12 is also the more antiquated approach.
        //
        // The problem is that if the user specifies a desired default
        // cursor blink with `cursor-style-blink`, the moment a running
        // program uses DEC mode 12, the cursor blink can never be reset
        // to the default without an explicit DECSCUSR. But if a program
        // is using mode 12, it is by definition not using DECSCUSR.
        // This makes for somewhat annoying interactions where a poorly
        // (or legacy) behaved program will stop blinking, and it simply
        // never restarts.
        //
        // To get around this, we have a special case where if the user
        // specifies some explicit default cursor blink desire, we ignore
        // DEC mode 12. We allow DECSCUSR to still set the cursor blink
        // because programs using DECSCUSR usually are well behaved and
        // reset the cursor blink to the default when they exit.
        //
        // To be extra safe, users can also add a manual `CSI 0 q` to
        // their shell config when they render prompts to ensure the
        // cursor is exactly as they request.
        if (mode == .cursor_blinking and
            self.default_cursor_blink != null)
        {
            return;
        }

        // We first always set the raw mode on our mode state.
        self.terminal.modes.set(mode, enabled);

        // And then some modes require additional processing.
        switch (mode) {
            // Just noting here that autorepeat has no effect on
            // the terminal. xterm ignores this mode and so do we.
            // We know about just so that we don't log that it is
            // an unknown mode.
            .autorepeat => {},

            // Schedule a render since we changed colors
            .reverse_colors => try self.queueRender(),

            // Origin resets cursor pos. This is called whether or not
            // we're enabling or disabling origin mode and whether or
            // not the value changed.
            .origin => self.terminal.setCursorPos(1, 1),

            .enable_left_and_right_margin => if (!enabled) {
                // When we disable left/right margin mode we need to
                // reset the left/right margins.
                self.terminal.scrolling_region.left = 0;
                self.terminal.scrolling_region.right = self.terminal.cols - 1;
            },

            .alt_screen_save_cursor_clear_enter => {
                const opts: terminal.Terminal.AlternateScreenOptions = .{
                    .cursor_save = true,
                    .clear_on_enter = true,
                };

                if (enabled)
                    self.terminal.alternateScreen(self.alloc, opts)
                else
                    self.terminal.primaryScreen(self.alloc, opts);

                // Schedule a render since we changed screens
                try self.queueRender();
            },

            // Force resize back to the window size
            .enable_mode_3 => self.terminal.resize(
                self.alloc,
                self.grid_size.columns,
                self.grid_size.rows,
            ) catch |err| {
                log.err("error updating terminal size: {}", .{err});
            },

            .@"132_column" => try self.terminal.deccolm(
                self.alloc,
                if (enabled) .@"132_cols" else .@"80_cols",
            ),

            // We need to start a timer to prevent the emulator being hung
            // forever.
            .synchronized_output => {
                if (enabled) self.messageWriter(.{ .start_synchronized_output = {} });
                try self.queueRender();
            },

            .linefeed => {
                self.messageWriter(.{ .linefeed_mode = enabled });
            },

            .mouse_event_x10 => {
                if (enabled) {
                    self.terminal.flags.mouse_event = .x10;
                    try self.setMouseShape(.default);
                } else {
                    self.terminal.flags.mouse_event = .none;
                    try self.setMouseShape(.text);
                }
            },
            .mouse_event_normal => {
                if (enabled) {
                    self.terminal.flags.mouse_event = .normal;
                    try self.setMouseShape(.default);
                } else {
                    self.terminal.flags.mouse_event = .none;
                    try self.setMouseShape(.text);
                }
            },
            .mouse_event_button => {
                if (enabled) {
                    self.terminal.flags.mouse_event = .button;
                    try self.setMouseShape(.default);
                } else {
                    self.terminal.flags.mouse_event = .none;
                    try self.setMouseShape(.text);
                }
            },
            .mouse_event_any => {
                if (enabled) {
                    self.terminal.flags.mouse_event = .any;
                    try self.setMouseShape(.default);
                } else {
                    self.terminal.flags.mouse_event = .none;
                    try self.setMouseShape(.text);
                }
            },

            .mouse_format_utf8 => self.terminal.flags.mouse_format = if (enabled) .utf8 else .x10,
            .mouse_format_sgr => self.terminal.flags.mouse_format = if (enabled) .sgr else .x10,
            .mouse_format_urxvt => self.terminal.flags.mouse_format = if (enabled) .urxvt else .x10,
            .mouse_format_sgr_pixels => self.terminal.flags.mouse_format = if (enabled) .sgr_pixels else .x10,

            else => {},
        }
    }

    pub fn setMouseShiftCapture(self: *StreamHandler, v: bool) !void {
        self.terminal.flags.mouse_shift_capture = if (v) .true else .false;
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

        // For the below, we quack as a VT220. We don't quack as
        // a 420 because we don't support DCS sequences.
        switch (req) {
            .primary => self.messageWriter(.{
                .write_stable = "\x1B[?62;22c",
            }),

            .secondary => self.messageWriter(.{
                .write_stable = "\x1B[>1;10;0c",
            }),

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
                } = if (self.terminal.modes.get(.origin)) .{
                    .x = self.terminal.screen.cursor.x -| self.terminal.scrolling_region.left,
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
        style: terminal.CursorStyleReq,
    ) !void {
        // Assume we're setting to a non-default.
        self.default_cursor = false;

        switch (style) {
            .default => {
                self.default_cursor = true;
                self.terminal.screen.cursor.style = self.default_cursor_style;
                self.terminal.modes.set(
                    .cursor_blinking,
                    self.default_cursor_blink orelse true,
                );
            },

            .blinking_block => {
                self.terminal.screen.cursor.style = .block;
                self.terminal.modes.set(.cursor_blinking, true);
            },

            .steady_block => {
                self.terminal.screen.cursor.style = .block;
                self.terminal.modes.set(.cursor_blinking, false);
            },

            .blinking_underline => {
                self.terminal.screen.cursor.style = .underline;
                self.terminal.modes.set(.cursor_blinking, true);
            },

            .steady_underline => {
                self.terminal.screen.cursor.style = .underline;
                self.terminal.modes.set(.cursor_blinking, false);
            },

            .blinking_bar => {
                self.terminal.screen.cursor.style = .bar;
                self.terminal.modes.set(.cursor_blinking, true);
            },

            .steady_bar => {
                self.terminal.screen.cursor.style = .bar;
                self.terminal.modes.set(.cursor_blinking, false);
            },

            else => log.warn("unimplemented cursor style: {}", .{style}),
        }
    }

    pub fn setProtectedMode(self: *StreamHandler, mode: terminal.ProtectedMode) !void {
        self.terminal.setProtectedMode(mode);
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

    pub fn tabReset(self: *StreamHandler) !void {
        self.terminal.tabReset();
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
        self.terminal.fullReset(self.alloc);
        try self.setMouseShape(.text);
    }

    pub fn queryKittyKeyboard(self: *StreamHandler) !void {
        if (comptime disable_kitty_keyboard_protocol) return;

        log.debug("querying kitty keyboard mode", .{});
        var data: termio.Message.WriteReq.Small.Array = undefined;
        const resp = try std.fmt.bufPrint(&data, "\x1b[?{}u", .{
            self.terminal.screen.kitty_keyboard.current().int(),
        });

        self.messageWriter(.{
            .write_small = .{
                .data = data,
                .len = @intCast(resp.len),
            },
        });
    }

    pub fn pushKittyKeyboard(
        self: *StreamHandler,
        flags: terminal.kitty.KeyFlags,
    ) !void {
        if (comptime disable_kitty_keyboard_protocol) return;

        log.debug("pushing kitty keyboard mode: {}", .{flags});
        self.terminal.screen.kitty_keyboard.push(flags);
    }

    pub fn popKittyKeyboard(self: *StreamHandler, n: u16) !void {
        if (comptime disable_kitty_keyboard_protocol) return;

        log.debug("popping kitty keyboard mode n={}", .{n});
        self.terminal.screen.kitty_keyboard.pop(@intCast(n));
    }

    pub fn setKittyKeyboard(
        self: *StreamHandler,
        mode: terminal.kitty.KeySetMode,
        flags: terminal.kitty.KeyFlags,
    ) !void {
        if (comptime disable_kitty_keyboard_protocol) return;

        log.debug("setting kitty keyboard mode: {} {}", .{ mode, flags });
        self.terminal.screen.kitty_keyboard.set(mode, flags);
    }

    pub fn reportXtversion(
        self: *StreamHandler,
    ) !void {
        log.debug("reporting XTVERSION: ghostty {s}", .{build_config.version_string});
        var buf: [288]u8 = undefined;
        const resp = try std.fmt.bufPrint(
            &buf,
            "\x1BP>|{s} {s}\x1B\\",
            .{
                "ghostty",
                build_config.version_string,
            },
        );
        const msg = try termio.Message.writeReq(self.alloc, resp);
        self.messageWriter(msg);
    }

    //-------------------------------------------------------------------------
    // OSC

    pub fn changeWindowTitle(self: *StreamHandler, title: []const u8) !void {
        var buf: [256]u8 = undefined;
        if (title.len >= buf.len) {
            log.warn("change title requested larger than our buffer size, ignoring", .{});
            return;
        }

        @memcpy(buf[0..title.len], title);
        buf[title.len] = 0;

        // Mark that we've seen a title
        self.ev.seen_title = true;

        _ = self.ev.surface_mailbox.push(.{
            .set_title = buf,
        }, .{ .forever = {} });
    }

    pub fn setMouseShape(
        self: *StreamHandler,
        shape: terminal.MouseShape,
    ) !void {
        self.terminal.mouse_shape = shape;
        _ = self.ev.surface_mailbox.push(.{
            .set_mouse_shape = shape,
        }, .{ .forever = {} });
    }

    pub fn clipboardContents(self: *StreamHandler, kind: u8, data: []const u8) !void {
        // Note: we ignore the "kind" field and always use the standard clipboard.
        // iTerm also appears to do this but other terminals seem to only allow
        // certain. Let's investigate more.

        const clipboard_type: apprt.Clipboard = switch (kind) {
            'c' => .standard,
            's' => .selection,
            'p' => .primary,
            else => .standard,
        };

        // Get clipboard contents
        if (data.len == 1 and data[0] == '?') {
            _ = self.ev.surface_mailbox.push(.{
                .clipboard_read = clipboard_type,
            }, .{ .forever = {} });
            return;
        }

        // Write clipboard contents
        _ = self.ev.surface_mailbox.push(.{
            .clipboard_write = .{
                .req = try apprt.surface.Message.WriteReq.init(
                    self.alloc,
                    data,
                ),
                .clipboard_type = clipboard_type,
            },
        }, .{ .forever = {} });
    }

    pub fn promptStart(self: *StreamHandler, aid: ?[]const u8, redraw: bool) !void {
        _ = aid;
        self.terminal.markSemanticPrompt(.prompt);
        self.terminal.flags.shell_redraws_prompt = redraw;
    }

    pub fn promptContinuation(self: *StreamHandler, aid: ?[]const u8) !void {
        _ = aid;
        self.terminal.markSemanticPrompt(.prompt_continuation);
    }

    pub fn promptEnd(self: *StreamHandler) !void {
        self.terminal.markSemanticPrompt(.input);
    }

    pub fn endOfInput(self: *StreamHandler) !void {
        self.terminal.markSemanticPrompt(.command);
    }

    pub fn reportPwd(self: *StreamHandler, url: []const u8) !void {
        if (builtin.os.tag == .windows) {
            log.warn("reportPwd unimplemented on windows", .{});
            return;
        }

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

        // We need to unescape the path. We first try to unescape onto
        // the stack and fall back to heap allocation if we have to.
        var pathBuf: [1024]u8 = undefined;
        const path, const heap = path: {
            // If the path doesn't have any escapes, we can use it directly.
            if (std.mem.indexOfScalar(u8, uri.path, '%') == null)
                break :path .{ uri.path, false };

            // First try to stack-allocate
            var fba = std.heap.FixedBufferAllocator.init(&pathBuf);
            if (std.Uri.unescapeString(fba.allocator(), uri.path)) |path|
                break :path .{ path, false }
            else |_| {}

            // Fall back to heap
            if (std.Uri.unescapeString(self.alloc, uri.path)) |path|
                break :path .{ path, true }
            else |_| {}

            // Fall back to using it directly...
            log.warn("failed to unescape OSC 7 path, using it directly path={s}", .{uri.path});
            break :path .{ uri.path, false };
        };
        defer if (heap) self.alloc.free(path);

        log.debug("terminal pwd: {s}", .{path});
        try self.terminal.setPwd(path);

        // If we haven't seen a title, use our pwd as the title.
        if (!self.ev.seen_title) {
            try self.changeWindowTitle(path);
            self.ev.seen_title = false;
        }
    }

    /// Implements OSC 4, OSC 10, and OSC 11, which reports palette color,
    /// default foreground color, and background color respectively.
    pub fn reportColor(
        self: *StreamHandler,
        kind: terminal.osc.Command.ColorKind,
        terminator: terminal.osc.Terminator,
    ) !void {
        if (self.osc_color_report_format == .none) return;

        const color = switch (kind) {
            .palette => |i| self.terminal.color_palette.colors[i],
            .foreground => self.foreground_color,
            .background => self.background_color,
            .cursor => self.cursor_color orelse self.foreground_color,
        };

        var msg: termio.Message = .{ .write_small = .{} };
        const resp = switch (self.osc_color_report_format) {
            .@"16-bit" => switch (kind) {
                .palette => |i| try std.fmt.bufPrint(
                    &msg.write_small.data,
                    "\x1B]{s};{d};rgb:{x:0>4}/{x:0>4}/{x:0>4}{s}",
                    .{
                        kind.code(),
                        i,
                        @as(u16, color.r) * 257,
                        @as(u16, color.g) * 257,
                        @as(u16, color.b) * 257,
                        terminator.string(),
                    },
                ),
                else => try std.fmt.bufPrint(
                    &msg.write_small.data,
                    "\x1B]{s};rgb:{x:0>4}/{x:0>4}/{x:0>4}{s}",
                    .{
                        kind.code(),
                        @as(u16, color.r) * 257,
                        @as(u16, color.g) * 257,
                        @as(u16, color.b) * 257,
                        terminator.string(),
                    },
                ),
            },

            .@"8-bit" => switch (kind) {
                .palette => |i| try std.fmt.bufPrint(
                    &msg.write_small.data,
                    "\x1B]{s};{d};rgb:{x:0>2}/{x:0>2}/{x:0>2}{s}",
                    .{
                        kind.code(),
                        i,
                        @as(u16, color.r),
                        @as(u16, color.g),
                        @as(u16, color.b),
                        terminator.string(),
                    },
                ),
                else => try std.fmt.bufPrint(
                    &msg.write_small.data,
                    "\x1B]{s};rgb:{x:0>2}/{x:0>2}/{x:0>2}{s}",
                    .{
                        kind.code(),
                        @as(u16, color.r),
                        @as(u16, color.g),
                        @as(u16, color.b),
                        terminator.string(),
                    },
                ),
            },
            .none => unreachable, // early return above
        };
        msg.write_small.len = @intCast(resp.len);
        self.messageWriter(msg);
    }

    pub fn setColor(
        self: *StreamHandler,
        kind: terminal.osc.Command.ColorKind,
        value: []const u8,
    ) !void {
        const color = try terminal.color.RGB.parse(value);

        switch (kind) {
            .palette => |i| {
                self.terminal.color_palette.colors[i] = color;
                self.terminal.color_palette.mask.set(i);
            },
            .foreground => {
                self.foreground_color = color;
                _ = self.ev.renderer_mailbox.push(.{
                    .foreground_color = color,
                }, .{ .forever = {} });
            },
            .background => {
                self.background_color = color;
                _ = self.ev.renderer_mailbox.push(.{
                    .background_color = color,
                }, .{ .forever = {} });
            },
            .cursor => {
                self.cursor_color = color;
                _ = self.ev.renderer_mailbox.push(.{
                    .cursor_color = color,
                }, .{ .forever = {} });
            },
        }
    }

    pub fn resetColor(
        self: *StreamHandler,
        kind: terminal.osc.Command.ColorKind,
        value: []const u8,
    ) !void {
        switch (kind) {
            .palette => {
                const mask = &self.terminal.color_palette.mask;
                if (value.len == 0) {
                    // Find all bit positions in the mask which are set and
                    // reset those indices to the default palette
                    var it = mask.iterator(.{});
                    while (it.next()) |i| {
                        self.terminal.color_palette.colors[i] = self.terminal.default_palette[i];
                        mask.unset(i);
                    }
                } else {
                    var it = std.mem.tokenizeScalar(u8, value, ';');
                    while (it.next()) |param| {
                        // Skip invalid parameters
                        const i = std.fmt.parseUnsigned(u8, param, 10) catch continue;
                        if (mask.isSet(i)) {
                            self.terminal.color_palette.colors[i] = self.terminal.default_palette[i];
                            mask.unset(i);
                        }
                    }
                }
            },
            .foreground => {
                self.foreground_color = self.default_foreground_color;
                _ = self.ev.renderer_mailbox.push(.{
                    .foreground_color = self.foreground_color,
                }, .{ .forever = {} });
            },
            .background => {
                self.background_color = self.default_background_color;
                _ = self.ev.renderer_mailbox.push(.{
                    .background_color = self.background_color,
                }, .{ .forever = {} });
            },
            .cursor => {
                self.cursor_color = self.default_cursor_color;
                _ = self.ev.renderer_mailbox.push(.{
                    .cursor_color = self.cursor_color,
                }, .{ .forever = {} });
            },
        }
    }

    pub fn showDesktopNotification(
        self: *StreamHandler,
        title: []const u8,
        body: []const u8,
    ) !void {
        var message = apprt.surface.Message{ .desktop_notification = undefined };

        const title_len = @min(title.len, message.desktop_notification.title.len);
        @memcpy(message.desktop_notification.title[0..title_len], title[0..title_len]);
        message.desktop_notification.title[title_len] = 0;

        const body_len = @min(body.len, message.desktop_notification.body.len);
        @memcpy(message.desktop_notification.body[0..body_len], body[0..body_len]);
        message.desktop_notification.body[body_len] = 0;

        _ = self.ev.surface_mailbox.push(message, .{ .forever = {} });
    }
};
