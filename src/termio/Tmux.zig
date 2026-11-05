//! tmux control mode follower backend.
//!
//! A follower surface mirrors one tmux pane. The pane lives in the tmux
//! server, so there is no pty and no subprocess here: writes are handed
//! to the app thread, which turns them into `send-keys` on the gateway,
//! and reads are injected by the gateway when it receives `%output`.
//!
//! Writes cross the thread boundary through the surface mailbox rather
//! than reaching into the session directly, because the session is owned
//! by the app thread. Output goes the other way through `queueOutput`,
//! which only appends to a buffer: the app thread drains its own mailbox,
//! so it must never wait on a follower. A reader thread parses the
//! buffer, as the exec backend's read thread does with its pty. Parsing
//! on the IO thread instead would deadlock it on its own mailbox, which
//! the stream handler fills with replies while it parses.

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../apprt.zig");
const global = @import("../global.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const ProcessInfo = @import("../pty.zig").ProcessInfo;

const log = std.log.scoped(.io_tmux);

pub const Tmux = @This();

alloc: Allocator,

/// The tmux pane id (the number in `%3`) this surface mirrors.
pane_id: usize,

/// Pane output the app thread handed us that the reader thread hasn't
/// processed yet. See queueOutput. `quit` tells the reader thread to
/// stop. All three are guarded by `output_mutex`.
output: std.ArrayList(u8) = .empty,
quit: bool = false,
output_mutex: std.Io.Mutex = .init,
output_cond: std.Io.Condition = .init,

/// Set when we enter the IO thread. See the note above about why we go
/// through the mailbox.
surface_mailbox: ?apprt.surface.Mailbox = null,

/// The last size we told tmux about. The GUI resizes us on every layout
/// pass, and most of those don't change the grid at all.
last_size: ?renderer.GridSize = null,

pub fn init(alloc: Allocator, pane_id: usize) Tmux {
    return .{ .alloc = alloc, .pane_id = pane_id };
}

pub fn deinit(self: *Tmux) void {
    self.output.deinit(self.alloc);
}

/// Queue pane output for the reader thread. Safe to call from any
/// thread; it only appends, so the caller never waits on the reader.
pub fn queueOutput(self: *Tmux, data: []const u8) Allocator.Error!void {
    self.output_mutex.lockUncancelable(global.io());
    defer self.output_mutex.unlock(global.io());
    try self.output.appendSlice(self.alloc, data);
    self.output_cond.signal(global.io());
}

/// Parse queued pane output until threadExit sets `quit`.
fn readerMain(self: *Tmux, io: *termio.Termio) void {
    while (true) {
        var output = output: {
            self.output_mutex.lockUncancelable(global.io());
            defer self.output_mutex.unlock(global.io());
            while (self.output.items.len == 0 and !self.quit) {
                self.output_cond.waitUncancelable(global.io(), &self.output_mutex);
            }
            if (self.quit) return;

            const output = self.output;
            self.output = .empty;
            break :output output;
        };
        defer output.deinit(self.alloc);
        io.processOutput(output.items);
    }
}

pub fn initTerminal(self: *Tmux, term: *terminal.Terminal) void {
    _ = self;
    _ = term;
}

pub fn threadEnter(
    self: *Tmux,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = alloc;
    self.surface_mailbox = io.surface_mailbox;

    const reader = try std.Thread.spawn(.{}, readerMain, .{ self, io });
    reader.setName(global.io(), "io-tmux-reader") catch {};
    td.backend = .{ .tmux = .{ .reader = reader } };

    // A follower whose grid tmux decides has nothing to announce: the
    // session already knows the pane's size and asks for its contents
    // itself.
    if (io.grid_override != null) return;

    // Announce the size we start at. Nothing resizes a surface that opens
    // at the size it keeps, and the session wants the size before it asks
    // tmux what is on the pane.
    const grid_size = io.size.grid();
    self.last_size = grid_size;
    self.send(.{ .tmux_resize = grid_size });
}

pub fn threadExit(self: *Tmux, td: *termio.Termio.ThreadData) void {
    {
        self.output_mutex.lockUncancelable(global.io());
        defer self.output_mutex.unlock(global.io());
        self.quit = true;
        self.output_cond.signal(global.io());
    }
    td.backend.tmux.reader.join();
    self.surface_mailbox = null;
}

pub fn focusGained(
    self: *Tmux,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = self;
    _ = td;
    _ = focused;
}

pub fn resize(
    self: *Tmux,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    _ = screen_size;

    if (self.last_size) |last| {
        if (last.columns == grid_size.columns and
            last.rows == grid_size.rows) return;
    }
    self.last_size = grid_size;

    self.send(.{ .tmux_resize = grid_size });
}

pub fn queueWrite(
    self: *Tmux,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = td;
    _ = linefeed;
    if (data.len == 0) return;

    const req: apprt.surface.Message.WriteReq = try .init(alloc, data);
    self.send(.{ .tmux_send_keys = req });
}

fn send(self: *Tmux, msg: apprt.surface.Message) void {
    var mailbox = self.surface_mailbox orelse return;
    _ = mailbox.push(msg, .{ .forever = {} });
}

pub fn childExitedAbnormally(
    self: *Tmux,
    gpa: Allocator,
    t: *terminal.Terminal,
    exit_code: u32,
    runtime_ms: u64,
) !void {
    _ = self;
    _ = gpa;
    _ = t;
    _ = exit_code;
    _ = runtime_ms;
}

pub fn getProcessInfo(self: *Tmux, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
    _ = self;
    return null;
}

pub const ThreadData = struct {
    /// Parses the queued pane output. See readerMain.
    reader: std.Thread,

    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }
};

pub const Config = struct {
    pane_id: usize,
};
