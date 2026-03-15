//! Wayland protocol implementation for the Ghostty GTK apprt.
const std = @import("std");
const Allocator = std.mem.Allocator;

const gdk = @import("gdk");
const gdk_wayland = @import("gdk_wayland");
const gobject = @import("gobject");
const gtk = @import("gtk");
const layer_shell = @import("gtk4-layer-shell");
const wayland = @import("wayland");

const Config = @import("../../../config.zig").Config;
const input = @import("../../../input.zig");
const ApprtWindow = @import("../class/window.zig").Window;

const wl = wayland.client.wl;
const kde = wayland.client.kde;
const org = wayland.client.org;
const xdg = wayland.client.xdg;

const log = std.log.scoped(.winproto_wayland);

/// Wayland state that contains application-wide Wayland objects (e.g. wl_display).
pub const App = struct {
    display: *wl.Display,
    context: *Context,

    const Context = struct {
        alloc: Allocator,

        kde_blur_manager: ?*org.KdeKwinBlurManager = null,

        // FIXME: replace with `zxdg_decoration_v1` once GTK merges
        // https://gitlab.gnome.org/GNOME/gtk/-/merge_requests/6398
        kde_decoration_manager: ?*org.KdeKwinServerDecorationManager = null,
        kde_decoration_manager_global_name: ?u32 = null,

        kde_slide_manager: ?*org.KdeKwinSlideManager = null,

        kde_output_order: ?*kde.OutputOrderV1 = null,
        kde_output_order_global_name: ?u32 = null,

        /// Connector name of the primary output (e.g., "DP-1") as reported
        /// by kde_output_order_v1. The first output in each priority list
        /// is the primary.
        primary_output_name: ?[:0]const u8 = null,

        /// Tracks the output order event cycle. Set to true after a `done`
        /// event so the next `output` event is captured as the new primary.
        /// Initialized to true so the first event after binding is captured.
        output_order_done: bool = true,

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
        errdefer {
            if (context.primary_output_name) |name| alloc.free(name);
            alloc.destroy(context);
        }
        context.* = .{ .alloc = alloc };

        // Get our display registry so we can get all the available interfaces
        // and bind to what we need.
        const registry = try display.getRegistry();
        registry.setListener(*Context, registryListener, context);
        if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

        // Do another roundtrip to process events emitted by globals we bound
        // during registry discovery (e.g. default decoration mode, output
        // order). Listeners are installed at bind time in registryListener.
        if (context.kde_decoration_manager != null or context.kde_output_order != null) {
            if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
        }

        return .{
            .display = display,
            .context = context,
        };
    }

    pub fn deinit(self: *App, alloc: Allocator) void {
        if (self.context.primary_output_name) |name| alloc.free(name);
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

        if (self.context.xdg_wm_dialog_present and
            layer_shell.getLibraryVersion().order(.{
                .major = 1,
                .minor = 0,
                .patch = 4,
            }) == .lt)
        {
            log.warn("the version of gtk4-layer-shell installed on your system is too old (must be 1.0.4 or newer); disabling quick terminal", .{});
            return false;
        }

        return true;
    }

    pub fn initQuickTerminal(self: *App, apprt_window: *ApprtWindow) !void {
        const window = apprt_window.as(gtk.Window);
        layer_shell.initForWindow(window);

        // Set target monitor based on config (null lets compositor decide)
        const monitor = resolveQuickTerminalMonitor(self.context, apprt_window);
        defer if (monitor) |v| v.unref();
        layer_shell.setMonitor(window, monitor);
    }

    /// Resolve the quick-terminal-screen config to a specific monitor.
    /// Returns null to let the compositor decide (used for .mouse mode).
    /// Caller owns the returned ref and must unref it.
    fn resolveQuickTerminalMonitor(
        context: *Context,
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
        if (context.primary_output_name) |stored_name| {
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

    fn getInterfaceType(comptime field: std.builtin.Type.StructField) ?type {
        // Globals should be optional pointers
        const T = switch (@typeInfo(field.type)) {
            .optional => |o| switch (@typeInfo(o.child)) {
                .pointer => |v| if (v.size == .one) v.child else return null,
                else => return null,
            },
            else => return null,
        };

        // Only process Wayland interfaces
        if (!@hasDecl(T, "interface")) return null;
        return T;
    }

    /// Returns the Context field that stores the registry global name for
    /// protocols that support replacement, or null for simple protocols.
    fn getGlobalNameField(comptime field_name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, field_name, "kde_decoration_manager")) {
            return "kde_decoration_manager_global_name";
        }
        if (std.mem.eql(u8, field_name, "kde_output_order")) {
            return "kde_output_order_global_name";
        }
        return null;
    }

    /// Reset cached state derived from kde_output_order_v1.
    fn resetOutputOrderState(context: *Context) void {
        if (context.primary_output_name) |name| context.alloc.free(name);
        context.primary_output_name = null;
        context.output_order_done = true;
    }

    fn registryListener(
        registry: *wl.Registry,
        event: wl.Registry.Event,
        context: *Context,
    ) void {
        const ctx_fields = @typeInfo(Context).@"struct".fields;

        switch (event) {
            .global => |v| {
                log.debug("found global {s}", .{v.interface});

                // We don't actually do anything with this other than checking
                // for its existence, so we process this separately.
                if (std.mem.orderZ(
                    u8,
                    v.interface,
                    "xdg_wm_dialog_v1",
                ) == .eq) {
                    context.xdg_wm_dialog_present = true;
                    return;
                }

                inline for (ctx_fields) |field| {
                    const T = getInterfaceType(field) orelse continue;
                    if (std.mem.orderZ(u8, v.interface, T.interface.name) == .eq) {
                        log.debug("matched {}", .{T});

                        const global = registry.bind(
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

                        // Destroy old binding if this global was re-advertised.
                        // Bind first so a failed bind preserves the old binding.
                        if (@field(context, field.name)) |old| {
                            old.destroy();

                            if (comptime std.mem.eql(u8, field.name, "kde_output_order")) {
                                resetOutputOrderState(context);
                            }
                        }

                        @field(context, field.name) = global;
                        if (comptime getGlobalNameField(field.name)) |name_field| {
                            @field(context, name_field) = v.name;
                        }

                        // Install listeners immediately at bind time. This
                        // keeps listener setup and object lifetime in one
                        // place and also supports globals that appear later.
                        if (comptime std.mem.eql(u8, field.name, "kde_decoration_manager")) {
                            global.setListener(*Context, decoManagerListener, context);
                        }
                        if (comptime std.mem.eql(u8, field.name, "kde_output_order")) {
                            global.setListener(*Context, outputOrderListener, context);
                        }
                        break;
                    }
                }
            },

            // This should be a rare occurrence, but in case a global
            // is suddenly no longer available, we destroy and unset it
            // as the protocol mandates.
            .global_remove => |v| remove: {
                inline for (ctx_fields) |field| {
                    if (getInterfaceType(field) == null) continue;

                    const global_name_field = comptime getGlobalNameField(field.name);
                    if (global_name_field) |name_field| {
                        if (@field(context, name_field)) |stored_name| {
                            if (stored_name == v.name) {
                                if (@field(context, field.name)) |global| global.destroy();
                                @field(context, field.name) = null;
                                @field(context, name_field) = null;

                                if (comptime std.mem.eql(u8, field.name, "kde_output_order")) {
                                    resetOutputOrderState(context);
                                }
                                break :remove;
                            }
                        }
                    } else {
                        if (@field(context, field.name)) |global| {
                            if (global.getId() == v.name) {
                                global.destroy();
                                @field(context, field.name) = null;
                                break :remove;
                            }
                        }
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

    fn outputOrderListener(
        _: *kde.OutputOrderV1,
        event: kde.OutputOrderV1.Event,
        context: *Context,
    ) void {
        switch (event) {
            .output => |v| {
                // Only the first output event after a `done` is the new primary.
                if (!context.output_order_done) return;
                context.output_order_done = false;

                const name = std.mem.sliceTo(v.output_name, 0);
                if (context.primary_output_name) |old| context.alloc.free(old);

                if (name.len == 0) {
                    context.primary_output_name = null;
                    log.warn("ignoring empty primary output name from kde_output_order_v1", .{});
                } else {
                    context.primary_output_name = context.alloc.dupeZ(u8, name) catch |err| {
                        context.primary_output_name = null;
                        log.warn("failed to allocate primary output name: {}", .{err});
                        return;
                    };
                    log.debug("primary output: {s}", .{name});
                }
            },
            .done => {
                if (context.output_order_done) {
                    // No output arrived since the previous done. Treat this as
                    // an empty update and drop any stale cached primary.
                    resetOutputOrderState(context);
                    return;
                }
                context.output_order_done = true;
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
        const config = if (self.apprt_window.getConfig()) |v|
            v.get()
        else
            return;
        const blur = config.@"background-blur";

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
        return switch (self.apprt_window.getWindowDecoration()) {
            .auto => self.app_context.default_deco_mode orelse .Client,
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
        const target_monitor = App.resolveQuickTerminalMonitor(self.app_context, self.apprt_window);
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
        const window = apprt_window.as(gtk.Window);
        const config = if (apprt_window.getConfig()) |v| v.get() else return;

        const resolved_monitor = App.resolveQuickTerminalMonitor(
            apprt_window.winproto().wayland.app_context,
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
