//! Wayland protocol implementation for the Ghostty GTK apprt.
const std = @import("std");
const wayland = @import("wayland");
const Allocator = std.mem.Allocator;
const c = @import("../c.zig").c;
const Config = @import("../../../config.zig").Config;
const input = @import("../../../input.zig");
const ApprtWindow = @import("../Window.zig");

const wl = wayland.client.wl;
const org = wayland.client.org;

const log = std.log.scoped(.winproto_wayland);

/// Wayland state that contains application-wide Wayland objects (e.g. wl_display).
pub const App = struct {
    display: *wl.Display,
    context: *Context,

    const Context = struct {
        kde_blur_manager: ?*org.KdeKwinBlurManager = null,

        // FIXME: replace with `zxdg_decoration_v1` once GTK merges
        // https://gitlab.gnome.org/GNOME/gtk/-/merge_requests/6398
        kde_decoration_manager: ?*org.KdeKwinServerDecorationManager = null,

        default_deco_mode: ?org.KdeKwinServerDecorationManager.Mode = null,
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

        if (context.kde_decoration_manager != null) {
            // FIXME: Roundtrip again because we have to wait for the decoration
            // manager to respond with the preferred default mode. Ew.
            if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
        }

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
            .global => |global| {
                log.debug("wl_registry.global: interface={s}", .{global.interface});

                if (registryBind(
                    org.KdeKwinBlurManager,
                    registry,
                    global,
                )) |blur_manager| {
                    context.kde_blur_manager = blur_manager;
                } else if (registryBind(
                    org.KdeKwinServerDecorationManager,
                    registry,
                    global,
                )) |deco_manager| {
                    context.kde_decoration_manager = deco_manager;
                    deco_manager.setListener(*Context, decoManagerListener, context);
                }
            },

            // We don't handle removal events
            .global_remove => {},
        }
    }

    /// Bind a Wayland interface to a global object. Returns non-null
    /// if the binding was successful, otherwise null.
    ///
    /// The type T is the Wayland interface type that we're requesting.
    /// This function will verify that the global object is the correct
    /// interface and version before binding.
    fn registryBind(
        comptime T: type,
        registry: *wl.Registry,
        global: anytype,
    ) ?*T {
        if (std.mem.orderZ(
            u8,
            global.interface,
            T.interface.name,
        ) != .eq) return null;

        return registry.bind(global.name, T, T.generated_version) catch |err| {
            log.warn("error binding interface {s} error={}", .{
                global.interface,
                err,
            });
            return null;
        };
    }

    fn decoManagerListener(
        _: *org.KdeKwinServerDecorationManager,
        event: org.KdeKwinServerDecorationManager.Event,
        context: *Context,
    ) void {
        switch (event) {
            .default_mode => |mode| {
                context.default_deco_mode = @enumFromInt(mode.mode);
            },
        }
    }
};

/// Per-window (wl_surface) state for the Wayland protocol.
pub const Window = struct {
    config: *const ApprtWindow.DerivedConfig,

    /// The Wayland surface for this window.
    surface: *wl.Surface,

    /// The context from the app where we can load our Wayland interfaces.
    app_context: *App.Context,

    /// A token that, when present, indicates that the window is blurred.
    blur_token: ?*org.KdeKwinBlur,

    /// Object that controls the decoration mode (client/server/auto)
    /// of the window.
    decoration: ?*org.KdeKwinServerDecoration,

    pub fn init(
        alloc: Allocator,
        app: *App,
        apprt_window: *ApprtWindow,
    ) !Window {
        _ = alloc;

        const gdk_surface = c.gtk_native_get_surface(
            @ptrCast(apprt_window.window),
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

        // Get our decoration object so we can control the
        // CSD vs SSD status of this surface.
        const deco: ?*org.KdeKwinServerDecoration = deco: {
            const mgr = app.context.kde_decoration_manager orelse
                break :deco null;

            const deco: *org.KdeKwinServerDecoration = mgr.create(
                wl_surface,
            ) catch |err| {
                log.warn("could not create decoration object={}", .{err});
                break :deco null;
            };

            break :deco deco;
        };

        return .{
            .config = &apprt_window.config,
            .surface = wl_surface,
            .app_context = app.context,
            .blur_token = null,
            .decoration = deco,
        };
    }

    pub fn deinit(self: Window, alloc: Allocator) void {
        _ = alloc;
        if (self.blur_token) |blur| blur.release();
        if (self.decoration) |deco| deco.release();
    }

    pub fn resizeEvent(_: *Window) !void {}

    pub fn syncAppearance(self: *Window) !void {
        self.syncBlur() catch |err| {
            log.err("failed to sync blur={}", .{err});
        };
        self.syncDecoration() catch |err| {
            log.err("failed to sync blur={}", .{err});
        };
    }

    pub fn clientSideDecorationEnabled(self: Window) bool {
        return switch (self.getDecorationMode()) {
            .Client => true,
            // If we support SSDs, then we should *not* enable CSDs if we prefer SSDs.
            // However, if we do not support SSDs (e.g. GNOME) then we should enable
            // CSDs even if the user prefers SSDs.
            .Server => if (self.app_context.kde_decoration_manager) |_| false else true,
            .None => false,
            else => unreachable,
        };
    }

    pub fn addSubprocessEnv(self: *Window, env: *std.process.EnvMap) !void {
        _ = self;
        _ = env;
    }

    /// Update the blur state of the window.
    fn syncBlur(self: *Window) !void {
        const manager = self.app_context.kde_blur_manager orelse return;
        const blur = self.config.background_blur;

        if (self.blur_token) |tok| {
            // Only release token when transitioning from blurred -> not blurred
            if (!blur.enabled()) {
                manager.unset(self.surface);
                tok.release();
                self.blur_token = null;
            }
        } else {
            // Only acquire token when transitioning from not blurred -> blurred
            if (blur.enabled()) {
                const tok = try manager.create(self.surface);
                tok.commit();
                self.blur_token = tok;
            }
        }
    }

    fn syncDecoration(self: *Window) !void {
        const deco = self.decoration orelse return;

        // The protocol requests uint instead of enum so we have
        // to convert it.
        deco.requestMode(@intCast(@intFromEnum(self.getDecorationMode())));
    }

    fn getDecorationMode(self: Window) org.KdeKwinServerDecorationManager.Mode {
        return switch (self.config.window_decoration) {
            .auto => self.app_context.default_deco_mode orelse .Client,
            .client => .Client,
            .server => .Server,
            .none => .None,
        };
    }
};
