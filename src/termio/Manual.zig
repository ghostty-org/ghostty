//! Manual backend for terminal I/O that doesn't spawn a subprocess.
//! This is used for scenarios where terminal output comes from an external
//! source (e.g., SSH connection) rather than a local PTY.
const Manual = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");

const log = std.log.scoped(.io_manual);

// No state needed for manual backend
_placeholder: u8 = 0,

pub const Config = struct {
    // No configuration needed
};

pub const ThreadData = struct {
    // No thread data needed for manual backend

    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }
};

pub fn init(
    alloc: Allocator,
    cfg: Config,
) !Manual {
    _ = alloc;
    _ = cfg;
    return .{};
}

pub fn deinit(self: *Manual) void {
    _ = self;
}

pub fn initTerminal(self: *Manual, term: *terminal.Terminal) void {
    _ = self;
    _ = term;
    // Nothing to initialize for manual backend
}

pub fn threadEnter(
    self: *Manual,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = self;
    _ = alloc;
    _ = io;

    // Set up thread data with manual backend data
    td.backend = .{ .manual = .{} };

    log.info("manual backend thread entered", .{});
}

pub fn threadExit(self: *Manual, td: *termio.Termio.ThreadData) void {
    _ = self;
    _ = td;
    log.info("manual backend thread exited", .{});
}

pub fn focusGained(
    self: *Manual,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = self;
    _ = td;
    _ = focused;
    // Nothing to do for focus changes in manual mode
}

pub fn resize(
    self: *Manual,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    _ = self;
    _ = grid_size;
    _ = screen_size;
    // Nothing to do for resize in manual mode
    // The external application handles terminal size
}

pub fn queueWrite(
    self: *Manual,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = self;
    _ = alloc;
    _ = td;
    _ = linefeed;
    // In manual mode, writes are handled externally
    // The application should capture writes via a callback
    log.debug("manual backend queueWrite called with {} bytes", .{data.len});
}

pub fn changeConfig(self: *Manual, config: *termio.DerivedConfig) void {
    _ = self;
    _ = config;
}

pub fn childExitedAbnormally(
    self: *Manual,
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
    // No child process in manual mode
}
