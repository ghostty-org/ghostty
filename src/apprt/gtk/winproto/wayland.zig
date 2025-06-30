//! Wayland protocol implementation for the Ghostty GTK apprt.
const std = @import("std");
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");

const gdk = @import("gdk");
const gdk_wayland = @import("gdk_wayland");
const gobject = @import("gobject");
const gtk = @import("gtk");
const layer_shell = @import("gtk4-layer-shell");
const wayland = @import("wayland");

const Config = @import("../../../config.zig").Config;
const input = @import("../../../input.zig");
const ApprtWindow = @import("../Window.zig");

const wl = wayland.client.wl;
const org = wayland.client.org;
const xdg = wayland.client.xdg;

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

        xdg_activation: ?*xdg.ActivationV1 = null,

        /// Whether the xdg_wm_dialog_v1 protocol is present.
        ///
        /// If it is present, gtk4-layer-shell < 1.0.4 may crash when the user
        /// creates a quick terminal, and we need to ensure this fails
        /// gracefully if this situation occurs.
        ///
        /// FIXME: This is a temporary workaround - we should remove this when
        /// all of our supported distros drop support for affected old
        /// gtk4-layer-shell versions.
        ///
        /// See https://github.com/wmww/gtk4-layer-shell/issues/50
        xdg_wm_dialog_present: bool = false,
    };

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

        // Do another round-trip to get the default decoration mode
        if (context.kde_decoration_manager) |deco_manager| {
            deco_manager.setListener(*Context, decoManagerListener, context);
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

    pub fn supportsQuickTerminal(self: App) bool {
        if (!layer_shell.isSupported()) {
            log.warn("your compositor does not support the wlr-layer-shell protocol; disabling quick terminal", .{});
            return false;
        }

        if (self.context.xdg_wm_dialog_present and layer_shell.getLibraryVersion().order(.{
            .major = 1,
            .minor = 0,
            .patch = 4,
        }) == .lt) {
            log.warn("the version of gtk4-layer-shell installed on your system is too old (must be 1.0.4 or newer); disabling quick terminal", .{});
            return false;
        }

        return true;
    }

    pub fn initQuickTerminal(_: *App, apprt_window: *ApprtWindow) !void {
        const window = apprt_window.window.as(gtk.Window);

        layer_shell.initForWindow(window);
        layer_shell.setLayer(window, .top);
        layer_shell.setNamespace(window, "ghostty-quick-terminal");
    }

    fn getInterfaceType(comptime field: std.builtin.Type.StructField) ?type {
        // Globals should be optional pointers
        const T = switch (@typeInfo(field.type)) {
            .optional => |o| switch (@typeInfo(o.child)) {
                .pointer => |v| v.child,
                else => return null,
            },
            else => return null,
        };

        // Only process Wayland interfaces
        if (!@hasDecl(T, "interface")) return null;
        return T;
    }

    fn registryListener(
        registry: *wl.Registry,
        event: wl.Registry.Event,
        context: *Context,
    ) void {
        const ctx_fields = @typeInfo(Context).@"struct".fields;

        switch (event) {
            .global => |v| global: {
                // We don't actually do anything with this other than checking
                // for its existence, so we process this separately.
                if (std.mem.orderZ(u8, v.interface, "xdg_wm_dialog_v1") == .eq)
                    context.xdg_wm_dialog_present = true;

                inline for (ctx_fields) |field| {
                    const T = getInterfaceType(field) orelse continue;

                    if (std.mem.orderZ(
                        u8,
                        v.interface,
                        T.interface.name,
                    ) != .eq) break :global;

                    @field(context, field.name) = registry.bind(
                        v.name,
                        T,
                        T.generated_version,
                    ) catch |err| {
                        log.warn(
                            "error binding interface {s} error={}",
                            .{ v.interface, err },
                        );
                        return;
                    };
                }
            },

            // This should be a rare occurrence, but in case a global
            // is suddenly no longer available, we destroy and unset it
            // as the protocol mandates.
            .global_remove => |v| remove: {
                inline for (ctx_fields) |field| {
                    if (getInterfaceType(field) == null) continue;
                    const global = @field(context, field.name) orelse break :remove;
                    if (global.getId() == v.name) {
                        global.destroy();
                        @field(context, field.name) = null;
                    }
                }
            },
        }
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
    blur_token: ?*org.KdeKwinBlur = null,

    /// Object that controls the decoration mode (client/server/auto)
    /// of the window.
    decoration: ?*org.KdeKwinServerDecoration = null,

    /// Object that controls the slide-in/slide-out animations of the
    /// quick terminal. Always null for windows other than the quick terminal.
    slide: ?*org.KdeKwinSlide = null,

    /// Object that, when present, denotes that the window is currently
    /// requesting attention from the user.
    activation_token: ?*xdg.ActivationTokenV1 = null,

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
            .app_context = app.context,
            .decoration = deco,
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

    pub fn setUrgent(self: *Window, urgent: bool) !void {
        const activation = self.app_context.xdg_activation orelse return;

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
        const window = self.apprt_window.window.as(gtk.Window);
        const config = &self.apprt_window.config;

        layer_shell.setKeyboardMode(
            window,
            switch (config.quick_terminal_keyboard_interactivity) {
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

        const anchored_edge: ?layer_shell.ShellEdge = switch (config.quick_terminal_position) {
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

    /// Update the size of the quick terminal based on monitor dimensions.
    fn enteredMonitor(
        _: *gdk.Surface,
        monitor: *gdk.Monitor,
        apprt_window: *ApprtWindow,
    ) callconv(.c) void {
        const window = apprt_window.window.as(gtk.Window);
        const config = &apprt_window.config;

        var monitor_size: gdk.Rectangle = undefined;
        monitor.getGeometry(&monitor_size);

        const dims = config.quick_terminal_size.calculate(
            config.quick_terminal_position,
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
        const activation = self.app_context.xdg_activation orelse return;
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
