//! Wayland protocol implementation for the Ghostty GTK apprt.
const std = @import("std");
const Allocator = std.mem.Allocator;

const gdk = @import("gdk");
const gdk_wayland = @import("gdk_wayland");
const gobject = @import("gobject");
const gtk = @import("gtk");
const layer_shell = @import("gtk4-layer-shell");

const wayland = @import("wayland");
const wl = wayland.client.wl;
const ext = wayland.client.ext;
const kde = wayland.client.kde;
const org = wayland.client.org;
const xdg = wayland.client.xdg;

const Config = @import("../../../config.zig").Config;
const Globals = @import("wayland/Globals.zig");
const input = @import("../../../input.zig");
const ApprtWindow = @import("../class/window.zig").Window;
const BlurRegion = @import("BlurRegion.zig");

const log = std.log.scoped(.winproto_wayland);

/// Wayland state that contains application-wide Wayland objects (e.g. wl_display).
pub const App = struct {
    display: *wl.Display,
    globals: *Globals,

    pub fn init(
        alloc: Allocator,
        gdk_display: *gdk.Display,
        app_id: [:0]const u8,
        config: *const Config,
    ) !?App {
        _ = config;
        _ = app_id;

        const gdk_wayland_display = gobject.ext.cast(
            gdk_wayland.WaylandDisplay,
            gdk_display,
        ) orelse return null;

        const display: *wl.Display = @ptrCast(@alignCast(
            gdk_wayland_display.getWlDisplay() orelse return error.NoWaylandDisplay,
        ));

        const globals: *Globals = try .init(alloc, display);
        errdefer globals.deinit();

        return .{
            .display = display,
            .globals = globals,
        };
    }

    pub fn deinit(self: *App) void {
        self.globals.deinit();
    }

    pub fn eventMods(
        _: *App,
        _: ?*gdk.Device,
        _: gdk.ModifierType,
    ) ?input.Mods {
        return null;
    }

    pub fn supportsQuickTerminal(self: App) bool {
        _ = self;
        if (!layer_shell.isSupported()) {
            log.warn("your compositor does not support the wlr-layer-shell protocol; disabling quick terminal", .{});
            return false;
        }

        return true;
    }

    pub fn initQuickTerminal(self: *App, apprt_window: *ApprtWindow) !void {
        const window = apprt_window.as(gtk.Window);
        layer_shell.initForWindow(window);

        // Set target monitor based on config (null lets compositor decide)
        const monitor = resolveQuickTerminalMonitor(self.globals, apprt_window);
        defer if (monitor) |v| v.unref();
        layer_shell.setMonitor(window, monitor);
    }
};

/// Per-window (wl_surface) state for the Wayland protocol.
pub const Window = struct {
    apprt_window: *ApprtWindow,

    /// The Wayland surface for this window.
    surface: *wl.Surface,

    /// The context from the app where we can load our Wayland interfaces.
    globals: *Globals,

    /// Object that controls background effects like background blur.
    bg_effect: ?*ext.BackgroundEffectSurfaceV1 = null,

    /// Object that controls the decoration mode (client/server/auto)
    /// of the window.
    decoration: ?*org.KdeKwinServerDecoration = null,

    /// Object that controls the slide-in/slide-out animations of the
    /// quick terminal. Always null for windows other than the quick terminal.
    slide: ?*org.KdeKwinSlide = null,

    /// Object that, when present, denotes that the window is currently
    /// requesting attention from the user.
    activation_token: ?*xdg.ActivationTokenV1 = null,

    blur_region: BlurRegion = .empty,

    pub fn init(
        alloc: Allocator,
        app: *App,
        apprt_window: *ApprtWindow,
    ) !Window {
        _ = alloc;

        const gtk_native = apprt_window.as(gtk.Native);
        const gdk_surface = gtk_native.getSurface() orelse return error.NotWaylandSurface;

        // This should never fail, because if we're being called at this point
        // then we've already asserted that our app state is Wayland.
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
            const mgr = app.globals.get(.kde_decoration_manager) orelse
                break :deco null;

            const deco: *org.KdeKwinServerDecoration = mgr.create(
                wl_surface,
            ) catch |err| {
                log.warn("could not create decoration object={}", .{err});
                break :deco null;
            };

            break :deco deco;
        };

        const bg_effect: ?*ext.BackgroundEffectSurfaceV1 = bg: {
            const mgr = app.globals.get(.ext_background_effect) orelse
                break :bg null;

            const bg_effect: *ext.BackgroundEffectSurfaceV1 = mgr.getBackgroundEffect(
                wl_surface,
            ) catch |err| {
                log.warn("could not create background effect object={}", .{err});
                break :bg null;
            };

            break :bg bg_effect;
        };

        if (apprt_window.isQuickTerminal()) {
            _ = gdk.Surface.signals.enter_monitor.connect(
                gdk_surface,
                *ApprtWindow,
                enteredMonitor,
                apprt_window,
                .{},
            );
        }

        return .{
            .apprt_window = apprt_window,
            .surface = wl_surface,
            .globals = app.globals,
            .decoration = deco,
            .bg_effect = bg_effect,
        };
    }

    pub fn deinit(self: *Window) void {
        self.blur_region.deinit(self.globals.alloc);
        if (self.bg_effect) |bg| bg.destroy();
        if (self.decoration) |deco| deco.release();
        if (self.slide) |slide| slide.release();
    }

    pub fn resizeEvent(self: *Window) !void {
        self.syncBlur() catch |err| {
            log.err("failed to sync blur={}", .{err});
        };
    }

    pub fn syncAppearance(self: *Window) !void {
        self.syncBlur() catch |err| {
            log.err("failed to sync blur={}", .{err});
        };
        self.syncDecoration() catch |err| {
            log.err("failed to sync decoration={}", .{err});
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
            .Server => if (self.globals.get(.kde_decoration_manager)) |_| false else true,
            .None => false,
            else => unreachable,
        };
    }

    pub fn addSubprocessEnv(self: *Window, env: *std.process.EnvMap) !void {
        _ = self;
        _ = env;
    }

    pub fn setUrgent(self: *Window, urgent: bool) !void {
        const activation = self.globals.get(.xdg_activation) orelse return;

        // If there already is a token, destroy and unset it
        if (self.activation_token) |token| token.destroy();

        self.activation_token = if (urgent) token: {
            const token = try activation.getActivationToken();
            token.setSurface(self.surface);
            token.setListener(*Window, onActivationTokenEvent, self);
            token.commit();
            break :token token;
        } else null;
    }

    /// Update the blur state of the window.
    fn syncBlur(self: *Window) !void {
        const compositor = self.globals.get(.compositor) orelse return;
        const bg = self.bg_effect orelse return;
        if (!self.globals.state.bg_effect_capabilities.blur) return;

        const config = if (self.apprt_window.getConfig()) |v|
            v.get()
        else
            return;
        const blur = config.@"background-blur";

        if (!blur.enabled()) {
            self.blur_region.deinit(self.globals.alloc);
            bg.setBlurRegion(null);
            return;
        }

        var region: BlurRegion = try .calcForWindow(
            self.globals.alloc,
            self.apprt_window,
            self.clientSideDecorationEnabled(),
            false,
        );
        errdefer region.deinit(self.globals.alloc);

        if (region.eql(self.blur_region)) {
            // Region didn't change. Don't do anything.
            region.deinit(self.globals.alloc);
            return;
        }

        const wl_region = try compositor.createRegion();
        errdefer if (wl_region) |r| r.destroy();
        for (region.slices.items) |s| wl_region.add(
            @intCast(s.x),
            @intCast(s.y),
            @intCast(s.width),
            @intCast(s.height),
        );

        bg.setBlurRegion(wl_region);
        self.blur_region = region;
    }

    fn syncDecoration(self: *Window) !void {
        const deco = self.decoration orelse return;

        // The protocol requests uint instead of enum so we have
        // to convert it.
        deco.requestMode(@intCast(@intFromEnum(self.getDecorationMode())));
    }

    fn getDecorationMode(self: Window) org.KdeKwinServerDecorationManager.Mode {
        return switch (self.apprt_window.getWindowDecoration()) {
            .auto => self.globals.state.default_deco_mode orelse .Client,
            .client => .Client,
            .server => .Server,
            .none => .None,
        };
    }

    fn syncQuickTerminal(self: *Window) !void {
        const window = self.apprt_window.as(gtk.Window);
        const config = if (self.apprt_window.getConfig()) |v|
            v.get()
        else
            return;

        layer_shell.setLayer(window, switch (config.@"gtk-quick-terminal-layer") {
            .overlay => .overlay,
            .top => .top,
            .bottom => .bottom,
            .background => .background,
        });
        layer_shell.setNamespace(window, config.@"gtk-quick-terminal-namespace");

        // Re-resolve the target monitor on every sync so that config reloads
        // and primary-output changes take effect without recreating the window.
        const target_monitor = resolveQuickTerminalMonitor(self.globals, self.apprt_window);
        defer if (target_monitor) |v| v.unref();
        layer_shell.setMonitor(window, target_monitor);

        layer_shell.setKeyboardMode(
            window,
            switch (config.@"quick-terminal-keyboard-interactivity") {
                .none => .none,
                .@"on-demand" => on_demand: {
                    if (layer_shell.getProtocolVersion() < 4) {
                        log.warn("your compositor does not support on-demand keyboard access; falling back to exclusive access", .{});
                        break :on_demand .exclusive;
                    }
                    break :on_demand .on_demand;
                },
                .exclusive => .exclusive,
            },
        );

        const anchored_edge: ?layer_shell.ShellEdge = switch (config.@"quick-terminal-position") {
            .left => .left,
            .right => .right,
            .top => .top,
            .bottom => .bottom,
            .center => null,
        };

        for (std.meta.tags(layer_shell.ShellEdge)) |edge| {
            if (anchored_edge) |anchored| {
                if (edge == anchored) {
                    layer_shell.setMargin(window, edge, 0);
                    layer_shell.setAnchor(window, edge, true);
                    continue;
                }
            }

            // Arbitrary margin - could be made customizable?
            layer_shell.setMargin(window, edge, 20);
            layer_shell.setAnchor(window, edge, false);
        }

        if (self.slide) |slide| slide.release();

        self.slide = if (anchored_edge) |anchored| slide: {
            const mgr = self.globals.get(.kde_slide_manager) orelse break :slide null;

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

    /// Update the size of the quick terminal based on monitor dimensions.
    fn enteredMonitor(
        _: *gdk.Surface,
        monitor: *gdk.Monitor,
        apprt_window: *ApprtWindow,
    ) callconv(.c) void {
        const window = apprt_window.as(gtk.Window);
        const config = if (apprt_window.getConfig()) |v| v.get() else return;

        const resolved_monitor = resolveQuickTerminalMonitor(
            apprt_window.winproto().wayland.globals,
            apprt_window,
        );
        defer if (resolved_monitor) |v| v.unref();

        // Use the configured monitor for sizing if not in mouse mode.
        const size_monitor = resolved_monitor orelse monitor;

        var monitor_size: gdk.Rectangle = undefined;
        size_monitor.getGeometry(&monitor_size);

        const dims = config.@"quick-terminal-size".calculate(
            config.@"quick-terminal-position",
            .{
                .width = @intCast(monitor_size.f_width),
                .height = @intCast(monitor_size.f_height),
            },
        );

        window.setDefaultSize(@intCast(dims.width), @intCast(dims.height));
    }

    fn onActivationTokenEvent(
        token: *xdg.ActivationTokenV1,
        event: xdg.ActivationTokenV1.Event,
        self: *Window,
    ) void {
        const activation = self.globals.get(.xdg_activation) orelse return;
        const current_token = self.activation_token orelse return;

        if (token.getId() != current_token.getId()) {
            log.warn("received event for unknown activation token; ignoring", .{});
            return;
        }

        switch (event) {
            .done => |done| {
                activation.activate(done.token, self.surface);
                token.destroy();
                self.activation_token = null;
            },
        }
    }
};

/// Resolve the quick-terminal-screen config to a specific monitor.
/// Returns null to let the compositor decide (used for .mouse mode).
/// Caller owns the returned ref and must unref it.
fn resolveQuickTerminalMonitor(
    globals: *Globals,
    apprt_window: *ApprtWindow,
) ?*gdk.Monitor {
    const config = if (apprt_window.getConfig()) |v| v.get() else return null;

    switch (config.@"quick-terminal-screen") {
        .mouse => return null,
        .main, .@"macos-menu-bar" => {},
    }

    const display = apprt_window.as(gtk.Widget).getDisplay();
    const monitors = display.getMonitors();

    // Try to find the monitor matching the primary output name.
    if (globals.state.primary_output_name) |stored_name| {
        var i: u32 = 0;
        while (monitors.getObject(i)) |item| : (i += 1) {
            const monitor = gobject.ext.cast(gdk.Monitor, item) orelse {
                item.unref();
                continue;
            };
            if (monitor.getConnector()) |connector_z| {
                if (std.mem.orderZ(u8, connector_z, stored_name) == .eq) {
                    return monitor;
                }
            }
            monitor.unref();
        }
    }

    // Fall back to the first monitor in the list.
    const first = monitors.getObject(0) orelse return null;
    return gobject.ext.cast(gdk.Monitor, first) orelse {
        first.unref();
        return null;
    };
}
