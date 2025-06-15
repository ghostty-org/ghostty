const std = @import("std");
const Allocator = std.mem.Allocator;

const gdk = @import("gdk");

const Config = @import("../../../config.zig").Config;
const input = @import("../../../input.zig");
const ApprtWindow = @import("../Window.zig");

const log = std.log.scoped(.winproto_noop);

pub const App = struct {
    pub fn init(
        _: Allocator,
        _: *gdk.Display,
        _: [:0]const u8,
        _: *const Config,
    ) !?App {
        return null;
    }

    pub fn deinit(self: *App, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }

    pub fn eventMods(
        _: *App,
        _: ?*gdk.Device,
        _: gdk.ModifierType,
    ) ?input.Mods {
        return null;
    }

    pub fn supportsQuickTerminal(_: App) bool {
        return false;
    }
    pub fn initQuickTerminal(_: *App, _: *ApprtWindow) !void {}
};

pub const Window = struct {
    pub fn init(
        _: Allocator,
        _: *App,
        _: *ApprtWindow,
    ) !Window {
        return .{};
    }

    pub fn deinit(self: Window, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }

    pub fn updateConfigEvent(
        _: *Window,
        _: *const ApprtWindow.DerivedConfig,
    ) !void {}

    pub fn resizeEvent(_: *Window) !void {}

    pub fn syncAppearance(_: *Window) !void {}

    /// This returns true if CSD is enabled for this window. This
    /// should be the actual present state of the window, not the
    /// desired state.
    pub fn clientSideDecorationEnabled(self: Window) bool {
        _ = self;
        return true;
    }

    pub fn addSubprocessEnv(_: *Window, _: *std.process.EnvMap) !void {}

    pub fn setUrgent(_: *Window, _: bool) !void {}
};
