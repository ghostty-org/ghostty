//! Wayland protocol implementation for the Ghostty GTK apprt.
const std = @import("std");
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");

const gdk = @import("gdk");
const gdk_wayland = @import("gdk_wayland");
const gobject = @import("gobject");
const gtk4_layer_shell = @import("gtk4-layer-shell");
const gtk = @import("gtk");
const wayland = @import("wayland");

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

        kde_slide_manager: ?*org.KdeKwinSlideManager = null,

        default_deco_mode: ?org.KdeKwinServerDecorationManager.Mode = null,
    };

    pub fn init(
        alloc: Allocator,
        gdk_display: *gdk.Display,
        app_id: [:0]const u8,
        config: *const Config,
    ) !?App {
        _ = config;
        _ = app_id;

        // Check if we're actually on Wayland
        if (gobject.typeCheckInstanceIsA(
            gdk_display.as(gobject.TypeInstance),
            gdk_wayland.WaylandDisplay.getGObjectType(),
        ) == 0) return null;

        const gdk_wayland_display = gobject.ext.cast(
            gdk_wayland.WaylandDisplay,
            gdk_display,
        ) orelse return error.NoWaylandDisplay;
        const display: *wl.Display = @ptrCast(@alignCast(
            gdk_wayland_display.getWlDisplay() orelse return error.NoWaylandDisplay,
        ));

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
        _: ?*gdk.Device,
        _: gdk.ModifierType,
    ) ?input.Mods {
        return null;
    }

    pub fn supportsQuickTerminal(_: App) bool {
        if (!gtk4_layer_shell.isSupported()) {
            log.warn("your compositor does not support the wlr-layer-shell protocol; disabling quick terminal", .{});
            return false;
        }
        return true;
    }

    pub fn initQuickTerminal(_: *App, apprt_window: *ApprtWindow) !void {
        const window: *gtk.Window = @ptrCast(apprt_window.window);

        gtk4_layer_shell.initForWindow(window);
        gtk4_layer_shell.setLayer(window, .top);
        gtk4_layer_shell.setKeyboardMode(window, .on_demand);
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
                    return;
                }

                if (registryBind(
                    org.KdeKwinServerDecorationManager,
                    registry,
                    global,
                )) |deco_manager| {
                    context.kde_decoration_manager = deco_manager;
                    deco_manager.setListener(*Context, decoManagerListener, context);
                    return;
                }

                if (registryBind(
                    org.KdeKwinSlideManager,
                    registry,
                    global,
                )) |slide_manager| {
                    context.kde_slide_manager = slide_manager;
                    return;
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
    apprt_window: *ApprtWindow,

    /// The Wayland surface for this window.
    surface: *wl.Surface,

    /// The context from the app where we can load our Wayland interfaces.
    app_context: *App.Context,

    /// A token that, when present, indicates that the window is blurred.
    blur_token: ?*org.KdeKwinBlur,

    /// Object that controls the decoration mode (client/server/auto)
    /// of the window.
    decoration: ?*org.KdeKwinServerDecoration,

    /// Object that controls the slide-in/slide-out animations of the
    /// quick terminal. Always null for windows other than the quick terminal.
    slide: ?*org.KdeKwinSlide,

    pub fn init(
        alloc: Allocator,
        app: *App,
        apprt_window: *ApprtWindow,
    ) !Window {
        _ = alloc;

        const gtk_native = apprt_window.window.as(gtk.Native);
        const gdk_surface = gtk_native.getSurface() orelse return error.NotWaylandSurface;

        // This should never fail, because if we're being called at this point
        // then we've already asserted that our app state is Wayland.
        if (gobject.typeCheckInstanceIsA(
            gdk_surface.as(gobject.TypeInstance),
            gdk_wayland.WaylandSurface.getGObjectType(),
        ) == 0)
            return error.NoWaylandSurface;

        const gdk_wl_surface = gobject.ext.cast(
            gdk_wayland.WaylandSurface,
            gdk_surface,
        ) orelse return error.NoWaylandSurface;
        const wl_surface: *wl.Surface = @ptrCast(@alignCast(
            gdk_wl_surface.getWlSurface() orelse return error.NoWaylandSurface,
        ));

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

        if (apprt_window.isQuickTerminal()) {
            const surface: *gdk.Surface = @ptrCast(gdk_surface);
            _ = gdk.Surface.signals.enter_monitor.connect(
                surface,
                *ApprtWindow,
                enteredMonitor,
                apprt_window,
                .{},
            );
        }

        return .{
            .apprt_window = apprt_window,
            .surface = wl_surface,
            .app_context = app.context,
            .blur_token = null,
            .decoration = deco,
            .slide = null,
        };
    }

    pub fn deinit(self: Window, alloc: Allocator) void {
        _ = alloc;
        if (self.blur_token) |blur| blur.release();
        if (self.decoration) |deco| deco.release();
        if (self.slide) |slide| slide.release();
    }

    pub fn resizeEvent(_: *Window) !void {}

    pub fn syncAppearance(self: *Window) !void {
        self.syncBlur() catch |err| {
            log.err("failed to sync blur={}", .{err});
        };
        self.syncDecoration() catch |err| {
            log.err("failed to sync blur={}", .{err});
        };

        if (self.apprt_window.isQuickTerminal()) {
            self.syncQuickTerminal() catch |err| {
                log.warn("failed to sync quick terminal appearance={}", .{err});
            };
        }
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
        const blur = self.apprt_window.config.background_blur;

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
        return switch (self.apprt_window.config.window_decoration) {
            .auto => self.app_context.default_deco_mode orelse .Client,
            .client => .Client,
            .server => .Server,
            .none => .None,
        };
    }

    fn syncQuickTerminal(self: *Window) !void {
        const window: *gtk.Window = @ptrCast(self.apprt_window.window);
        const position = self.apprt_window.config.quick_terminal_position;

        const anchored_edge: ?gtk4_layer_shell.ShellEdge = switch (position) {
            .left => .left,
            .right => .right,
            .top => .top,
            .bottom => .bottom,
            .center => null,
        };

        for (std.meta.tags(gtk4_layer_shell.ShellEdge)) |edge| {
            if (anchored_edge) |anchored| {
                if (edge == anchored) {
                    gtk4_layer_shell.setMargin(window, edge, 0);
                    gtk4_layer_shell.setAnchor(window, edge, true);
                    continue;
                }
            }

            // Arbitrary margin - could be made customizable?
            gtk4_layer_shell.setMargin(window, edge, 20);
            gtk4_layer_shell.setAnchor(window, edge, false);
        }

        if (self.apprt_window.isQuickTerminal()) {
            if (self.slide) |slide| slide.release();

            self.slide = if (anchored_edge) |anchored| slide: {
                const mgr = self.app_context.kde_slide_manager orelse break :slide null;

                const slide = mgr.create(self.surface) catch |err| {
                    log.warn("could not create slide object={}", .{err});
                    break :slide null;
                };

                const slide_location: org.KdeKwinSlide.Location = switch (anchored) {
                    .top => .top,
                    .bottom => .bottom,
                    .left => .left,
                    .right => .right,
                };

                slide.setLocation(@intCast(@intFromEnum(slide_location)));
                slide.commit();
                break :slide slide;
            } else null;
        }
    }

    /// Update the size of the quick terminal based on monitor dimensions.
    fn enteredMonitor(
        _: *gdk.Surface,
        monitor: *gdk.Monitor,
        apprt_window: *ApprtWindow,
    ) callconv(.C) void {
        const window: *gtk.Window = @ptrCast(apprt_window.window);
        const size = apprt_window.config.quick_terminal_size;
        const position = apprt_window.config.quick_terminal_position;

        var monitor_size: gdk.Rectangle = undefined;
        monitor.getGeometry(&monitor_size);

        const dims = size.calculate(position, .{
            .width = @intCast(monitor_size.f_width),
            .height = @intCast(monitor_size.f_height),
        });

        window.setDefaultSize(@intCast(dims.width), @intCast(dims.height));
    }
};
