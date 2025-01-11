//! Wayland protocol implementation for the Ghostty GTK apprt.
const std = @import("std");
const wayland = @import("wayland");
const Allocator = std.mem.Allocator;
const c = @import("../c.zig").c;
const Config = @import("../../../config.zig").Config;
const input = @import("../../../input.zig");

const wl = wayland.client.wl;
const org = wayland.client.org;

const log = std.log.scoped(.winproto_wayland);

/// Wayland state that contains application-wide Wayland objects (e.g. wl_display).
pub const App = struct {
    display: *wl.Display,
    context: *Context,

    const Context = struct {
        kde_blur_manager: ?*org.KdeKwinBlurManager = null,
    };

    pub fn init(
        alloc: Allocator,
        gdk_display: *c.GdkDisplay,
        app_id: [:0]const u8,
        config: *const Config,
    ) !?App {
        _ = config;
        _ = app_id;

        // Check if we're actually on Wayland
        if (c.g_type_check_instance_is_a(
            @ptrCast(@alignCast(gdk_display)),
            c.gdk_wayland_display_get_type(),
        ) == 0) return null;

        const display: *wl.Display = @ptrCast(c.gdk_wayland_display_get_wl_display(
            gdk_display,
        ) orelse return error.NoWaylandDisplay);

        // Create our context for our callbacks so we have a stable pointer.
        // Note: at the time of writing this comment, we don't really need
        // a stable pointer, but it's too scary that we'd need one in the future
        // and not have it and corrupt memory or something so let's just do it.
        const context = try alloc.create(Context);
        errdefer alloc.destroy(context);
        context.* = .{};

        // Get our display registry so we can get all the available interfaces
        // and bind to what we need.
        const registry = try display.getRegistry();
        registry.setListener(*Context, registryListener, context);
        if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

        return .{
            .display = display,
            .context = context,
        };
    }

    pub fn deinit(self: *App, alloc: Allocator) void {
        alloc.destroy(self.context);
    }

    pub fn eventMods(
        _: *App,
        _: ?*c.GdkDevice,
        _: c.GdkModifierType,
    ) ?input.Mods {
        return null;
    }

    fn registryListener(
        registry: *wl.Registry,
        event: wl.Registry.Event,
        context: *Context,
    ) void {
        switch (event) {
            // https://wayland.app/protocols/wayland#wl_registry:event:global
            .global => |global| global: {
                log.debug("wl_registry.global: interface={s}", .{global.interface});

                if (registryBind(
                    org.KdeKwinBlurManager,
                    registry,
                    global,
                    1,
                )) |blur_manager| {
                    context.kde_blur_manager = blur_manager;
                    break :global;
                }
            },

            // We don't handle removal events
            .global_remove => {},
        }
    }

    fn registryBind(
        comptime T: type,
        registry: *wl.Registry,
        global: anytype,
        version: u32,
    ) ?*T {
        if (std.mem.orderZ(
            u8,
            global.interface,
            T.interface.name,
        ) != .eq) return null;

        return registry.bind(global.name, T, version) catch |err| {
            log.warn("error binding interface {s} error={}", .{
                global.interface,
                err,
            });
            return null;
        };
    }
};

/// Per-window (wl_surface) state for the Wayland protocol.
pub const Window = struct {
    config: DerivedConfig,

    /// The Wayland surface for this window.
    surface: *wl.Surface,

    /// The context from the app where we can load our Wayland interfaces.
    app_context: *App.Context,

    /// A token that, when present, indicates that the window is blurred.
    blur_token: ?*org.KdeKwinBlur = null,

    const DerivedConfig = struct {
        blur: bool,

        pub fn init(config: *const Config) DerivedConfig {
            return .{
                .blur = config.@"background-blur-radius".enabled(),
            };
        }
    };

    pub fn init(
        alloc: Allocator,
        app: *App,
        gtk_window: *c.GtkWindow,
        config: *const Config,
    ) !Window {
        _ = alloc;

        const gdk_surface = c.gtk_native_get_surface(
            @ptrCast(gtk_window),
        ) orelse return error.NotWaylandSurface;

        // This should never fail, because if we're being called at this point
        // then we've already asserted that our app state is Wayland.
        if (c.g_type_check_instance_is_a(
            @ptrCast(@alignCast(gdk_surface)),
            c.gdk_wayland_surface_get_type(),
        ) == 0) return error.NotWaylandSurface;

        const wl_surface: *wl.Surface = @ptrCast(c.gdk_wayland_surface_get_wl_surface(
            gdk_surface,
        ) orelse return error.NoWaylandSurface);

        return .{
            .config = DerivedConfig.init(config),
            .surface = wl_surface,
            .app_context = app.context,
        };
    }

    pub fn deinit(self: Window, alloc: Allocator) void {
        _ = alloc;
        if (self.blur_token) |blur| blur.release();
    }

    pub fn updateConfigEvent(self: *Window, config: *const Config) !void {
        self.config = DerivedConfig.init(config);
    }

    pub fn resizeEvent(_: *Window) !void {}

    pub fn syncAppearance(self: *Window) !void {
        try self.syncBlur();
    }

    /// Update the blur state of the window.
    fn syncBlur(self: *Window) !void {
        const manager = self.app_context.kde_blur_manager orelse return;
        const blur = self.config.blur;

        if (self.blur_token) |tok| {
            // Only release token when transitioning from blurred -> not blurred
            if (!blur) {
                manager.unset(self.surface);
                tok.release();
                self.blur_token = null;
            }
        } else {
            // Only acquire token when transitioning from not blurred -> blurred
            if (blur) {
                const tok = try manager.create(self.surface);
                tok.commit();
                self.blur_token = tok;
            }
        }
    }
};
