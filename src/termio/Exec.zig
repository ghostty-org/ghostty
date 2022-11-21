//! Implementation of IO that uses child exec to talk to the child process.
pub const Exec = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const termio = @import("../termio.zig");
const Command = @import("../Command.zig");
const Window = @import("../Window.zig");
const Pty = @import("../Pty.zig");
const SegmentedPool = @import("../segmented_pool.zig").SegmentedPool;
const terminal = @import("../terminal/main.zig");
const libuv = @import("libuv");
const renderer = @import("../renderer.zig");
const tracy = @import("tracy");
const trace = tracy.trace;
const fastmem = @import("../fastmem.zig");

const log = std.log.scoped(.io_exec);

const c = @cImport({
    @cInclude("errno.h");
    @cInclude("signal.h");
    @cInclude("unistd.h");
});

/// Allocator
alloc: Allocator,

/// This is the pty fd created for the subcommand.
pty: Pty,

/// This is the container for the subcommand.
command: Command,

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
renderer_wakeup: libuv.Async,

/// The mailbox for notifying the renderer of things.
renderer_mailbox: *renderer.Thread.Mailbox,

/// The mailbox for communicating with the window.
window_mailbox: Window.Mailbox,

/// The cached grid size whenever a resize is called.
grid_size: renderer.GridSize,

/// The data associated with the currently running thread.
data: ?*EventData,

/// Initialize the exec implementation. This will also start the child
/// process.
pub fn init(alloc: Allocator, opts: termio.Options) !Exec {
    // Create our pty
    var pty = try Pty.open(.{
        .ws_row = @intCast(u16, opts.grid_size.rows),
        .ws_col = @intCast(u16, opts.grid_size.columns),
        .ws_xpixel = @intCast(u16, opts.screen_size.width),
        .ws_ypixel = @intCast(u16, opts.screen_size.height),
    });
    errdefer pty.deinit();

    // Determine the path to the binary we're executing
    const path = (try Command.expandPath(alloc, opts.config.command orelse "sh")) orelse
        return error.CommandNotFound;
    defer alloc.free(path);

    // Set our env vars
    var env = try std.process.getEnvMap(alloc);
    defer env.deinit();
    try env.put("TERM", "xterm-256color");
    try env.put("COLORTERM", "truecolor");

    // Build our subcommand
    var cmd: Command = .{
        .path = path,
        .args = &[_][]const u8{path},
        .env = &env,
        .cwd = opts.config.@"working-directory",
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
        .data = &pty,
    };
    try cmd.start(alloc);
    log.info("started subcommand path={s} pid={?}", .{ path, cmd.pid });

    // Create our terminal
    var term = try terminal.Terminal.init(
        alloc,
        opts.grid_size.columns,
        opts.grid_size.rows,
    );
    errdefer term.deinit(alloc);
    term.color_palette = opts.config.palette.value;

    return Exec{
        .alloc = alloc,
        .pty = pty,
        .command = cmd,
        .terminal = term,
        .terminal_stream = undefined,
        .renderer_state = opts.renderer_state,
        .renderer_wakeup = opts.renderer_wakeup,
        .renderer_mailbox = opts.renderer_mailbox,
        .window_mailbox = opts.window_mailbox,
        .grid_size = opts.grid_size,
        .data = null,
    };
}

pub fn deinit(self: *Exec) void {
    // Kill our command
    self.killCommand() catch |err|
        log.err("error sending SIGHUP to command, may hang: {}", .{err});
    _ = self.command.wait(false) catch |err|
        log.err("error waiting for command to exit: {}", .{err});

    // Clean up our other members
    self.terminal.deinit(self.alloc);
}

/// Kill the underlying subprocess. This closes the pty file handle and
/// sends a SIGHUP to the child process. This doesn't wait for the child
/// process to be exited.
fn killCommand(self: *Exec) !void {
    // Close our PTY
    self.pty.deinit();

    // We need to get our process group ID and send a SIGHUP to it.
    if (self.command.pid) |pid| {
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

pub fn threadEnter(self: *Exec, loop: libuv.Loop) !ThreadData {
    assert(self.data == null);

    // Get a copy to our allocator
    const alloc_ptr = loop.getData(Allocator).?;
    const alloc = alloc_ptr.*;

    // Setup our data that is used for callbacks
    var ev_data_ptr = try alloc.create(EventData);
    errdefer alloc.destroy(ev_data_ptr);

    // Read data
    var stream = try libuv.Tty.init(alloc, loop, self.pty.master);
    errdefer stream.deinit(alloc);
    stream.setData(ev_data_ptr);
    try stream.readStart(ttyReadAlloc, ttyRead);

    // Setup our event data before we start
    ev_data_ptr.* = .{
        .read_arena = std.heap.ArenaAllocator.init(alloc),
        .renderer_state = self.renderer_state,
        .renderer_wakeup = self.renderer_wakeup,
        .renderer_mailbox = self.renderer_mailbox,
        .data_stream = stream,
        .terminal_stream = .{
            .handler = .{
                .alloc = self.alloc,
                .ev = ev_data_ptr,
                .terminal = &self.terminal,
                .grid_size = &self.grid_size,
                .window_mailbox = self.window_mailbox,
            },
        },
    };
    errdefer ev_data_ptr.deinit();

    // Store our data so our callbacks can access it
    self.data = ev_data_ptr;

    // Return our thread data
    return ThreadData{
        .alloc = alloc,
        .ev = ev_data_ptr,
    };
}

pub fn threadExit(self: *Exec, data: ThreadData) void {
    _ = data;

    self.data = null;
}

/// Resize the terminal.
pub fn resize(
    self: *Exec,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
    padding: renderer.Padding,
) !void {
    const padded_size = screen_size.subPadding(padding);

    // Update the size of our pty
    try self.pty.setSize(.{
        .ws_row = @intCast(u16, grid_size.rows),
        .ws_col = @intCast(u16, grid_size.columns),
        .ws_xpixel = @intCast(u16, padded_size.width),
        .ws_ypixel = @intCast(u16, padded_size.height),
    });

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

pub inline fn queueWrite(self: *Exec, data: []const u8) !void {
    try self.data.?.queueWrite(data);
}

const ThreadData = struct {
    /// Allocator used for the event data
    alloc: Allocator,

    /// The data that is attached to the callbacks.
    ev: *EventData,

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

    /// This is the arena allocator used for IO read buffers. Since we use
    /// libuv under the covers, this lets us rarely heap allocate since we're
    /// usually just reusing buffers from this.
    read_arena: std.heap.ArenaAllocator,

    /// The stream parser. This parses the stream of escape codes and so on
    /// from the child process and calls callbacks in the stream handler.
    terminal_stream: terminal.Stream(StreamHandler),

    /// The shared render state
    renderer_state: *renderer.State,

    /// A handle to wake up the renderer. This hints to the renderer that that
    /// a repaint should happen.
    renderer_wakeup: libuv.Async,

    /// The mailbox for notifying the renderer of things.
    renderer_mailbox: *renderer.Thread.Mailbox,

    /// The data stream is the main IO for the pty.
    data_stream: libuv.Tty,

    /// This is the pool of available (unused) write requests. If you grab
    /// one from the pool, you must put it back when you're done!
    write_req_pool: SegmentedPool(libuv.WriteReq.T, WRITE_REQ_PREALLOC) = .{},

    /// The pool of available buffers for writing to the pty.
    write_buf_pool: SegmentedPool([64]u8, WRITE_REQ_PREALLOC) = .{},

    /// Last time the cursor was reset. This is used to prevent message
    /// flooding with cursor resets.
    last_cursor_reset: u64 = 0,

    pub fn deinit(self: *EventData, alloc: Allocator) void {
        self.read_arena.deinit();

        // Clear our write pools. We know we aren't ever going to do
        // any more IO since we stop our data stream below so we can just
        // drop this.
        self.write_req_pool.deinit(alloc);
        self.write_buf_pool.deinit(alloc);

        // Stop our data stream
        self.data_stream.readStop();
        self.data_stream.close((struct {
            fn callback(h: *libuv.Tty) void {
                const handle_alloc = h.loop().getData(Allocator).?.*;
                h.deinit(handle_alloc);
            }
        }).callback);
    }

    /// This queues a render operation with the renderer thread. The render
    /// isn't guaranteed to happen immediately but it will happen as soon as
    /// practical.
    inline fn queueRender(self: *EventData) !void {
        try self.renderer_wakeup.send();
    }

    /// Queue a write to the pty.
    fn queueWrite(self: *EventData, data: []const u8) !void {
        // We go through and chunk the data if necessary to fit into
        // our cached buffers that we can queue to the stream.
        var i: usize = 0;
        while (i < data.len) {
            const req = try self.write_req_pool.get();
            const buf = try self.write_buf_pool.get();
            const end = @min(data.len, i + buf.len);
            fastmem.copy(u8, buf, data[i..end]);
            try self.data_stream.write(
                .{ .req = req },
                &[1][]u8{buf[0..(end - i)]},
                ttyWrite,
            );

            i = end;
        }
    }
};

fn ttyWrite(req: *libuv.WriteReq, status: i32) void {
    const tty = req.handle(libuv.Tty).?;
    const ev = tty.getData(EventData).?;
    ev.write_req_pool.put();
    ev.write_buf_pool.put();

    libuv.convertError(status) catch |err|
        log.err("write error: {}", .{err});

    //log.info("WROTE: {d}", .{status});
}

fn ttyReadAlloc(t: *libuv.Tty, size: usize) ?[]u8 {
    const zone = trace(@src());
    defer zone.end();

    const ev = t.getData(EventData) orelse return null;
    const alloc = ev.read_arena.allocator();
    return alloc.alloc(u8, size) catch null;
}

fn ttyRead(t: *libuv.Tty, n: isize, buf: []const u8) void {
    const zone = trace(@src());
    defer zone.end();

    const ev = t.getData(EventData).?;
    defer {
        const alloc = ev.read_arena.allocator();
        alloc.free(buf);
    }

    // log.info("DATA: {d}", .{n});
    // log.info("DATA: {any}", .{buf[0..@intCast(usize, n)]});

    // First check for errors in the case n is less than 0.
    libuv.convertError(@intCast(i32, n)) catch |err| {
        switch (err) {
            // ignore EOF because it should end the process.
            libuv.Error.EOF => {},
            else => log.err("read error: {}", .{err}),
        }

        return;
    };

    // Whenever a character is typed, we ensure the cursor is in the
    // non-blink state so it is rendered if visible. If we're under
    // HEAVY read load, we don't want to send a ton of these so we
    // use a timer under the covers
    const now = t.loop().now();
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
    const end = @intCast(usize, n);
    if (ev.terminal_stream.parser.state == .ground) {
        for (buf[i..end]) |ch| {
            switch (terminal.parse_table.table[ch][@enumToInt(terminal.Parser.State.ground)].action) {
                // Print, call directly.
                .print => ev.terminal_stream.handler.print(@intCast(u21, ch)) catch |err|
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

/// This is used as the handler for the terminal.Stream type. This is
/// stateful and is expected to live for the entire lifetime of the terminal.
/// It is NOT VALID to stop a stream handler, create a new one, and use that
/// unless all of the member fields are copied.
const StreamHandler = struct {
    ev: *EventData,
    alloc: Allocator,
    grid_size: *renderer.GridSize,
    terminal: *terminal.Terminal,
    window_mailbox: Window.Mailbox,

    inline fn queueRender(self: *StreamHandler) !void {
        try self.ev.queueRender();
    }

    inline fn queueWrite(self: *StreamHandler, data: []const u8) !void {
        try self.ev.queueWrite(data);
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

    pub fn horizontalTab(self: *StreamHandler) !void {
        try self.terminal.horizontalTab();
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
        switch (mode) {
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

            else => if (enabled) log.warn("unimplemented mode: {}", .{mode}),
        }
    }

    pub fn setAttribute(self: *StreamHandler, attr: terminal.Attribute) !void {
        switch (attr) {
            .unknown => |unk| log.warn("unimplemented or unknown attribute: {any}", .{unk}),

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
            .primary => self.queueWrite("\x1B[?62;c") catch |err|
                log.warn("error queueing device attr response: {}", .{err}),
            else => log.warn("unimplemented device attributes req: {}", .{req}),
        }
    }

    pub fn deviceStatusReport(
        self: *StreamHandler,
        req: terminal.DeviceStatusReq,
    ) !void {
        switch (req) {
            .operating_status => self.queueWrite("\x1B[0n") catch |err|
                log.warn("error queueing device attr response: {}", .{err}),

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
                var buf: [32]u8 = undefined;
                const resp = try std.fmt.bufPrint(&buf, "\x1B[{};{}R", .{
                    pos.y + 1,
                    pos.x + 1,
                });

                try self.queueWrite(resp);
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
        try self.queueWrite("");
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

        _ = self.window_mailbox.push(.{
            .set_title = buf,
        }, .{ .forever = {} });
    }

    pub fn clipboardContents(self: *StreamHandler, kind: u8, data: []const u8) !void {
        // Note: we ignore the "kind" field and always use the primary clipboard.
        // iTerm also appears to do this but other terminals seem to only allow
        // certain. Let's investigate more.

        // Get clipboard contents
        if (data.len == 1 and data[0] == '?') {
            _ = self.window_mailbox.push(.{
                .clipboard_read = kind,
            }, .{ .forever = {} });
            return;
        }

        // Write clipboard contents
        _ = self.window_mailbox.push(.{
            .clipboard_write = try Window.Message.WriteReq.init(
                self.alloc,
                data,
            ),
        }, .{ .forever = {} });
    }
};
