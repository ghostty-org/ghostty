const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const posix = std.posix;
const xev = @import("../global.zig").xev;
const build_config = @import("../build_config.zig");
const configpkg = @import("../config.zig");
const internal_os = @import("../os/main.zig");
const renderer = @import("../renderer.zig");
const shell_integration = @import("shell_integration.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const Command = @import("../Command.zig");
const Pty = @import("../pty.zig").Pty;

// The preallocation size for the write request pool. This should be big
// enough to satisfy most write requests. It must be a power of 2.
const WRITE_REQ_PREALLOC = std.math.pow(usize, 2, 5);

/// The kinds of backends.
pub const Kind = enum { exec };

/// Configuration for the various backend types.
pub const Config = union(Kind) {
    /// Exec uses posix exec to run a command with a pty.
    exec: termio.Exec.Config,
};

/// Backend implementations. A backend is responsible for owning the pty
/// behavior and providing read/write capabilities.
pub const Backend = union(Kind) {
    exec: termio.Exec,

    pub fn deinit(self: *Backend) void {
        switch (self.*) {
            .exec => |*exec| exec.deinit(),
        }
    }

    pub fn initTerminal(self: *Backend, t: *terminal.Terminal) void {
        switch (self.*) {
            .exec => |*exec| exec.initTerminal(t),
        }
    }

    pub fn threadEnter(
        self: *Backend,
        alloc: Allocator,
        io: *termio.Termio,
        td: *termio.Termio.ThreadData,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.threadEnter(alloc, io, td),
        }
    }

    pub fn threadExit(self: *Backend, td: *termio.Termio.ThreadData) void {
        switch (self.*) {
            .exec => |*exec| exec.threadExit(td),
        }
    }

    pub fn focusGained(
        self: *Backend,
        td: *termio.Termio.ThreadData,
        focused: bool,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.focusGained(td, focused),
        }
    }

    pub fn resize(
        self: *Backend,
        grid_size: renderer.GridSize,
        screen_size: renderer.ScreenSize,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.resize(grid_size, screen_size),
        }
    }

    pub fn queueWrite(
        self: *Backend,
        alloc: Allocator,
        td: *termio.Termio.ThreadData,
        data: []const u8,
        linefeed: bool,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.queueWrite(alloc, td, data, linefeed),
        }
    }

    pub fn childExitedAbnormally(
        self: *Backend,
        gpa: Allocator,
        t: *terminal.Terminal,
        exit_code: u32,
        runtime_ms: u64,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.childExitedAbnormally(
                gpa,
                t,
                exit_code,
                runtime_ms,
            ),
        }
    }
};

/// Termio thread data. See termio.ThreadData for docs.
pub const ThreadData = union(Kind) {
    exec: termio.Exec.ThreadData,

    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        switch (self.*) {
            .exec => |*exec| exec.deinit(alloc),
        }
    }

    pub fn changeConfig(self: *ThreadData, config: *termio.DerivedConfig) void {
        _ = self;
        _ = config;
    }
};
