//! Win32 application runtime for Ghostty on Windows.
//! Uses native Win32 API for windowing, input, and clipboard.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const apprt = @import("../apprt.zig");
const configpkg = @import("../config.zig");
const Config = configpkg.Config;
const CoreApp = @import("../App.zig");
const internal_os = @import("../os/main.zig");

pub const resourcesDir = internal_os.resourcesDir;

pub const App = struct {
    core_app: *CoreApp,

    pub const must_draw_from_app_thread = false;

    pub fn init(
        self: *App,
        core_app: *CoreApp,
        opts: struct {},
    ) !void {
        _ = opts;
        self.* = .{ .core_app = core_app };
    }

    pub fn run(self: *App) !void {
        _ = self;
    }

    pub fn terminate(self: *App) void {
        _ = self;
    }

    pub fn wakeup(self: *App) void {
        _ = self;
    }

    /// IPC from external processes. Not yet implemented for Win32.
    pub fn performIpc(
        _: Allocator,
        _: apprt.ipc.Target,
        comptime action: apprt.ipc.Action.Key,
        _: apprt.ipc.Action.Value(action),
    ) !bool {
        return false;
    }

    pub fn performAction(
        self: *App,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) !bool {
        _ = self;
        _ = target;
        _ = value;
        return false;
    }
};

pub const Surface = struct {
    pub fn init(self: *Surface) !void {
        _ = self;
    }

    pub fn deinit(self: *Surface) void {
        _ = self;
    }
};
