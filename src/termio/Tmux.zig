//! tmux control mode follower backend.
//!
//! A follower surface mirrors one tmux pane. The pane lives in the tmux
//! server, so there is no pty and no subprocess here: writes are handed
//! to the app thread, which turns them into `send-keys` on the gateway,
//! and reads are injected by the gateway when it receives `%output`.
//!
//! Everything crosses the thread boundary through the surface mailbox
//! rather than reaching into the session directly, because the session
//! is owned by the app thread.

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../apprt.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const ProcessInfo = @import("../pty.zig").ProcessInfo;

const log = std.log.scoped(.io_tmux);

pub const Tmux = @This();

/// The tmux pane id (the number in `%3`) this surface mirrors.
pane_id: usize,

/// Set when we enter the IO thread. See the note above about why we go
/// through the mailbox.
surface_mailbox: ?apprt.surface.Mailbox = null,

/// The last size we told tmux about. The GUI resizes us on every layout
/// pass, and most of those don't change the grid at all.
last_size: ?renderer.GridSize = null,

pub fn init(pane_id: usize) Tmux {
    return .{ .pane_id = pane_id };
}

pub fn deinit(self: *Tmux) void {
    _ = self;
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
    td.backend = .{ .tmux = .{} };

    // Announce the size we start at. Nothing resizes a surface that opens
    // at the size it keeps, and the session wants the size before it asks
    // tmux what is on the pane.
    const grid_size = io.size.grid();
    self.last_size = grid_size;
    self.send(.{ .tmux_resize = grid_size });
}

pub fn threadExit(self: *Tmux, td: *termio.Termio.ThreadData) void {
    _ = td;
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
    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }
};

pub const Config = struct {
    pane_id: usize,
};
