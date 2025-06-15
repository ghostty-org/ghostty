const std = @import("std");
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;

const gdk = @import("gdk");

const Config = @import("../../config.zig").Config;
const input = @import("../../input.zig");
const key = @import("key.zig");
const ApprtWindow = @import("Window.zig");

pub const noop = @import("winproto/noop.zig");
pub const x11 = @import("winproto/x11.zig");
pub const wayland = @import("winproto/wayland.zig");

pub const Protocol = enum {
    none,
    wayland,
    x11,
};

/// App-state for the underlying windowing protocol. There should be one
/// instance of this struct per application.
pub const App = union(Protocol) {
    none: noop.App,
    wayland: if (build_options.wayland) wayland.App else noop.App,
    x11: if (build_options.x11) x11.App else noop.App,

    pub fn init(
        alloc: Allocator,
        gdk_display: *gdk.Display,
        app_id: [:0]const u8,
        config: *const Config,
    ) !App {
        inline for (@typeInfo(App).@"union".fields) |field| {
            if (try field.type.init(
                alloc,
                gdk_display,
                app_id,
                config,
            )) |v| {
                return @unionInit(App, field.name, v);
            }
        }

        return .{ .none = .{} };
    }

    pub fn deinit(self: *App, alloc: Allocator) void {
        switch (self.*) {
            inline else => |*v| v.deinit(alloc),
        }
    }

    pub fn eventMods(
        self: *App,
        device: ?*gdk.Device,
        gtk_mods: gdk.ModifierType,
    ) input.Mods {
        return switch (self.*) {
            inline else => |*v| v.eventMods(device, gtk_mods),
        } orelse key.translateMods(gtk_mods);
    }

    pub fn supportsQuickTerminal(self: App) bool {
        return switch (self) {
            inline else => |v| v.supportsQuickTerminal(),
        };
    }

    /// Set up necessary support for the quick terminal that must occur
    /// *before* the window-level winproto object is created.
    ///
    /// Only has an effect on the Wayland backend, where the gtk4-layer-shell
    /// library is initialized.
    pub fn initQuickTerminal(self: *App, apprt_window: *ApprtWindow) !void {
        switch (self.*) {
            inline else => |*v| try v.initQuickTerminal(apprt_window),
        }
    }
};

/// Per-Window state for the underlying windowing protocol.
///
/// In Wayland, the terminology used is "Surface" and for it, this is
/// really "Surface"-specific state. But Ghostty uses the term "Surface"
/// heavily to mean something completely different, so we use "Window" here
/// to better match what it generally maps to in the Ghostty codebase.
pub const Window = union(Protocol) {
    none: noop.Window,
    wayland: if (build_options.wayland) wayland.Window else noop.Window,
    x11: if (build_options.x11) x11.Window else noop.Window,

    pub fn init(
        alloc: Allocator,
        app: *App,
        apprt_window: *ApprtWindow,
    ) !Window {
        return switch (app.*) {
            inline else => |*v, tag| {
                inline for (@typeInfo(Window).@"union".fields) |field| {
                    if (comptime std.mem.eql(
                        u8,
                        field.name,
                        @tagName(tag),
                    )) return @unionInit(
                        Window,
                        field.name,
                        try field.type.init(
                            alloc,
                            v,
                            apprt_window,
                        ),
                    );
                }
            },
        };
    }

    pub fn deinit(self: *Window, alloc: Allocator) void {
        switch (self.*) {
            inline else => |*v| v.deinit(alloc),
        }
    }

    pub fn resizeEvent(self: *Window) !void {
        switch (self.*) {
            inline else => |*v| try v.resizeEvent(),
        }
    }

    pub fn syncAppearance(self: *Window) !void {
        switch (self.*) {
            inline else => |*v| try v.syncAppearance(),
        }
    }

    pub fn clientSideDecorationEnabled(self: Window) bool {
        return switch (self) {
            inline else => |v| v.clientSideDecorationEnabled(),
        };
    }

    pub fn addSubprocessEnv(self: *Window, env: *std.process.EnvMap) !void {
        switch (self.*) {
            inline else => |*v| try v.addSubprocessEnv(env),
        }
    }

    pub fn setUrgent(self: *Window, urgent: bool) !void {
        switch (self.*) {
            inline else => |*v| try v.setUrgent(urgent),
        }
    }
};
