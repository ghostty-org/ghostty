//! X11 window protocol implementation for the Ghostty GTK apprt.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const gdk = @import("gdk");
const gdk_x11 = @import("gdk_x11");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const xlib = @import("xlib");

pub const c = @import("x11_c");

const input = @import("../../../input.zig");
const configpkg = @import("../../../config.zig");
const Config = configpkg.Config;
const ApprtWindow = @import("../class/window.zig").Window;
const GlobalShortcuts = @import("../class/global_shortcuts.zig").GlobalShortcuts;
const BlurRegion = @import("BlurRegion.zig");

const log = std.log.scoped(.gtk_x11);

pub const App = struct {
    display: *xlib.Display,
    base_event_code: c_int,
    atoms: Atoms,

    pub fn init(
        _: Allocator,
        gdk_display: *gdk.Display,
        app_id: [:0]const u8,
        config: *const Config,
    ) !?App {
        // If the display isn't X11, then we don't need to do anything.
        const gdk_x11_display = gobject.ext.cast(
            gdk_x11.X11Display,
            gdk_display,
        ) orelse return null;

        const xlib_display = gdk_x11_display.getXdisplay();

        const x11_program_name: [:0]const u8 = if (config.@"x11-instance-name") |pn|
            pn
        else if (builtin.mode == .Debug)
            "ghostty-debug"
        else
            "ghostty";

        // Set the X11 window class property (WM_CLASS) if we are on an X11
        // display.
        //
        // Note that we also set the program name here using g_set_prgname.
        // This is how the instance name field for WM_CLASS is derived when
        // calling gdk_x11_display_set_program_class; there does not seem to be
        // a way to set it directly. It does not look like this is being set by
        // our other app initialization routines currently, but since we're
        // currently deriving its value from x11-instance-name effectively, I
        // feel like gating it behind an X11 check is better intent.
        //
        // This makes the property show up like so when using xprop:
        //
        //     WM_CLASS(STRING) = "ghostty", "com.mitchellh.ghostty"
        //
        // Append "-debug" on both when using the debug build.
        glib.setPrgname(x11_program_name);
        gdk_x11.X11Display.setProgramClass(gdk_display, app_id);

        // XKB
        log.debug("Xkb.init: initializing Xkb", .{});
        log.debug("Xkb.init: running XkbQueryExtension", .{});
        var opcode: c_int = 0;
        var base_event_code: c_int = 0;
        var base_error_code: c_int = 0;
        var major = c.XkbMajorVersion;
        var minor = c.XkbMinorVersion;
        if (c.XkbQueryExtension(
            @ptrCast(@alignCast(xlib_display)),
            &opcode,
            &base_event_code,
            &base_error_code,
            &major,
            &minor,
        ) == 0) {
            log.err("Fatal: error initializing Xkb extension: error executing XkbQueryExtension", .{});
            return error.XkbInitializationError;
        }

        log.debug("Xkb.init: running XkbSelectEventDetails", .{});
        if (c.XkbSelectEventDetails(
            @ptrCast(@alignCast(xlib_display)),
            c.XkbUseCoreKbd,
            c.XkbStateNotify,
            c.XkbModifierStateMask,
            c.XkbModifierStateMask,
        ) == 0) {
            log.err("Fatal: error initializing Xkb extension: error executing XkbSelectEventDetails", .{});
            return error.XkbInitializationError;
        }

        return .{
            .display = xlib_display,
            .base_event_code = base_event_code,
            .atoms = .init(gdk_x11_display),
        };
    }

    pub fn deinit(self: *App) void {
        _ = self;
    }

    /// Checks for an immediate pending XKB state update event, and returns the
    /// keyboard state based on if it finds any. This is necessary as the
    /// standard GTK X11 API (and X11 in general) does not include the current
    /// key pressed in any modifier state snapshot for that event (e.g. if the
    /// pressed key is a modifier, that is not necessarily reflected in the
    /// modifiers).
    ///
    /// Returns null if there is no event. In this case, the caller should fall
    /// back to the standard GDK modifier state (this likely means the key
    /// event did not result in a modifier change).
    pub fn eventMods(
        self: App,
        device: ?*gdk.Device,
        gtk_mods: gdk.ModifierType,
    ) ?input.Mods {
        _ = device;
        _ = gtk_mods;

        // Shoutout to Mozilla for figuring out a clean way to do this, this is
        // paraphrased from Firefox/Gecko in widget/gtk/nsGtkKeyUtils.cpp.
        if (c.XEventsQueued(
            @ptrCast(@alignCast(self.display)),
            c.QueuedAfterReading,
        ) == 0) return null;

        var nextEvent: c.XEvent = undefined;
        _ = c.XPeekEvent(@ptrCast(@alignCast(self.display)), &nextEvent);
        if (nextEvent.type != self.base_event_code) return null;

        const xkb_event: *c.XkbEvent = @ptrCast(&nextEvent);
        if (xkb_event.any.xkb_type != c.XkbStateNotify) return null;

        const xkb_state_notify_event: *c.XkbStateNotifyEvent = @ptrCast(xkb_event);
        // Check the state according to XKB masks.
        const lookup_mods = xkb_state_notify_event.lookup_mods;
        var mods: input.Mods = .{};

        log.debug("X11: found extra XkbStateNotify event w/lookup_mods: {b}", .{lookup_mods});
        if (lookup_mods & c.ShiftMask != 0) mods.shift = true;
        if (lookup_mods & c.ControlMask != 0) mods.ctrl = true;
        if (lookup_mods & c.Mod1Mask != 0) mods.alt = true;
        if (lookup_mods & c.Mod4Mask != 0) mods.super = true;
        if (lookup_mods & c.LockMask != 0) mods.caps_lock = true;

        return mods;
    }

    pub fn bindGlobalShortcuts(
        _: *App,
        _: *GlobalShortcuts,
        _: *const Config,
    ) bool {
        return false;
    }

    pub fn clearGlobalShortcuts(_: *App) void {}

    pub fn supportsQuickTerminal(_: App) bool {
        return true;
    }

    pub fn initQuickTerminal(self: *App, apprt_window: *ApprtWindow) !void {
        const window = apprt_window.as(gtk.Window);
        window.setDecorated(0);

        const config = if (apprt_window.getConfig()) |v| v.get() else {
            window.fullscreen();
            return;
        };
        const monitor = quickTerminalMonitor(
            self.display,
            apprt_window,
            config.@"quick-terminal-screen",
        ) orelse {
            window.fullscreen();
            return;
        };
        defer monitor.unref();

        window.fullscreenOnMonitor(monitor);
    }
};

pub const Window = struct {
    app: *App,
    apprt_window: *ApprtWindow,
    x11_surface: *gdk_x11.X11Surface,
    alloc: Allocator,

    blur_region: BlurRegion = .empty,

    // Cache last applied values to avoid redundant X11 property updates.
    // Redundant property updates seem to cause some visual glitches
    // with some window managers: https://github.com/ghostty-org/ghostty/pull/8075
    last_applied_decoration_hints: ?MotifWMHints = null,
    quick_terminal_hints_applied: bool = false,

    pub fn init(
        alloc: Allocator,
        app: *App,
        apprt_window: *ApprtWindow,
    ) !Window {
        const surface = apprt_window.as(gtk.Native).getSurface() orelse
            return error.NotX11Surface;

        const x11_surface = gobject.ext.cast(
            gdk_x11.X11Surface,
            surface,
        ) orelse return error.NotX11Surface;

        var result = Window{
            .app = app,
            .alloc = alloc,
            .apprt_window = apprt_window,
            .x11_surface = x11_surface,
        };
        if (apprt_window.isQuickTerminal()) try result.syncQuickTerminal();
        return result;
    }

    pub fn deinit(self: *Window) void {
        self.blur_region.deinit(self.alloc);
    }

    pub fn resizeEvent(self: *Window) !void {
        // The blur region must update with window resizes
        self.syncBlur() catch |err| {
            log.err("failed to sync blur={}", .{err});
        };
    }

    pub fn syncAppearance(self: *Window) !void {
        // The user could have toggled between CSDs and SSDs,
        // therefore we need to recalculate the blur region offset.
        self.syncBlur() catch |err| {
            log.err("failed to sync blur={}", .{err});
        };
        self.syncDecorations() catch |err| {
            log.err("failed to sync decorations={}", .{err});
        };
        if (self.apprt_window.isQuickTerminal()) try self.syncQuickTerminal();
    }

    pub fn clientSideDecorationEnabled(self: Window) bool {
        if (self.apprt_window.isQuickTerminal()) return false;
        return switch (self.apprt_window.getWindowDecoration()) {
            .auto, .client => true,
            .server, .none => false,
        };
    }

    pub fn prepareQuickTerminal(self: *Window) !void {
        if (!self.apprt_window.isQuickTerminal()) return;
        try self.syncQuickTerminal();
        _ = c.XRaiseWindow(
            @ptrCast(@alignCast(self.app.display)),
            self.x11_surface.getXid(),
        );
        _ = c.XFlush(@ptrCast(@alignCast(self.app.display)));
    }

    fn syncQuickTerminal(self: *Window) !void {
        if (!self.quick_terminal_hints_applied) {
            try self.applyQuickTerminalHints();
            self.quick_terminal_hints_applied = true;
        }
        try self.requestQuickTerminalState();
        _ = c.XFlush(@ptrCast(@alignCast(self.app.display)));
    }

    fn applyQuickTerminalHints(self: *Window) !void {
        const states = [_]c.Atom{
            self.app.atoms.net_wm_state_fullscreen,
            self.app.atoms.net_wm_state_above,
            self.app.atoms.net_wm_state_sticky,
            self.app.atoms.net_wm_state_skip_taskbar,
            self.app.atoms.net_wm_state_skip_pager,
        };
        try self.changeProperty(
            c.Atom,
            self.app.atoms.net_wm_state,
            c.XA_ATOM,
            ._32,
            .{ .mode = .replace },
            &states,
        );

        const desktop = [_]c_ulong{std.math.maxInt(u32)};
        try self.changeProperty(
            c_ulong,
            self.app.atoms.net_wm_desktop,
            c.XA_CARDINAL,
            ._32,
            .{ .mode = .replace },
            &desktop,
        );
    }

    fn requestQuickTerminalState(self: *Window) !void {
        try self.requestWindowState(
            .remove,
            self.app.atoms.net_wm_state_below,
            c.None,
        );
        try self.requestWindowState(
            .add,
            self.app.atoms.net_wm_state_above,
            self.app.atoms.net_wm_state_fullscreen,
        );
        try self.requestWindowState(
            .add,
            self.app.atoms.net_wm_state_sticky,
            self.app.atoms.net_wm_state_skip_taskbar,
        );
        try self.requestWindowState(
            .add,
            self.app.atoms.net_wm_state_skip_pager,
            c.None,
        );
        try self.requestAllDesktops();
    }

    fn requestWindowState(
        self: *Window,
        action: NetWmStateAction,
        first: c.Atom,
        second: c.Atom,
    ) !void {
        const display: *c.Display = @ptrCast(@alignCast(self.app.display));
        var event = std.mem.zeroes(c.XEvent);
        event.xclient.type = c.ClientMessage;
        event.xclient.display = display;
        event.xclient.window = self.x11_surface.getXid();
        event.xclient.message_type = self.app.atoms.net_wm_state;
        event.xclient.format = 32;
        event.xclient.data.l[0] = @intFromEnum(action);
        event.xclient.data.l[1] = @intCast(first);
        event.xclient.data.l[2] = @intCast(second);
        event.xclient.data.l[3] = 1; // source indication: normal application

        if (c.XSendEvent(
            display,
            c.XDefaultRootWindow(display),
            0,
            c.SubstructureRedirectMask | c.SubstructureNotifyMask,
            &event,
        ) == 0) return error.RequestFailed;
    }

    fn requestAllDesktops(self: *Window) !void {
        const display: *c.Display = @ptrCast(@alignCast(self.app.display));
        var event = std.mem.zeroes(c.XEvent);
        event.xclient.type = c.ClientMessage;
        event.xclient.display = display;
        event.xclient.window = self.x11_surface.getXid();
        event.xclient.message_type = self.app.atoms.net_wm_desktop;
        event.xclient.format = 32;
        event.xclient.data.l[0] = @intCast(std.math.maxInt(u32));
        event.xclient.data.l[1] = 1; // source indication: normal application

        if (c.XSendEvent(
            display,
            c.XDefaultRootWindow(display),
            0,
            c.SubstructureRedirectMask | c.SubstructureNotifyMask,
            &event,
        ) == 0) return error.RequestFailed;
    }

    fn syncBlur(self: *Window) !void {
        const config = if (self.apprt_window.getConfig()) |v| v.get() else return;

        // When blur is disabled, remove the property if it was previously set
        const blur = config.@"background-blur";

        var region: BlurRegion = if (blur.enabled())
            try .calcForWindow(
                self.alloc,
                self.apprt_window,
                self.clientSideDecorationEnabled(),
                true,
            )
        else
            .empty;
        errdefer region.deinit(self.alloc);

        // Only update X11 properties when the blur region actually changes
        if (region.eql(self.blur_region)) {
            region.deinit(self.alloc);
            return;
        }

        if (region.slices.items.len > 0) {
            log.debug("set blur={}, window xid={}, region={}", .{
                blur,
                self.x11_surface.getXid(),
                region,
            });

            try self.changeProperty(
                BlurRegion.Slice,
                self.app.atoms.kde_blur,
                c.XA_CARDINAL,
                ._32,
                .{ .mode = .replace },
                region.slices.items,
            );
        } else {
            try self.deleteProperty(self.app.atoms.kde_blur);
        }

        self.blur_region.deinit(self.alloc);
        self.blur_region = region;
    }

    fn syncDecorations(self: *Window) !void {
        var hints: MotifWMHints = .{};

        self.getWindowProperty(
            MotifWMHints,
            self.app.atoms.motif_wm_hints,
            self.app.atoms.motif_wm_hints,
            ._32,
            .{},
            &hints,
        ) catch |err| switch (err) {
            // motif_wm_hints is already initialized, so this is fine
            error.PropertyNotFound => {},

            error.RequestFailed,
            error.PropertyTypeMismatch,
            error.PropertyFormatMismatch,
            => return err,
        };

        hints.flags.decorations = true;
        hints.decorations.all = switch (self.apprt_window.getWindowDecoration()) {
            .server => true,
            .auto, .client, .none => false,
        };

        // Only update decoration hints when they actually change
        if (self.last_applied_decoration_hints) |last| {
            if (std.meta.eql(hints, last)) return;
        }

        try self.changeProperty(
            MotifWMHints,
            self.app.atoms.motif_wm_hints,
            self.app.atoms.motif_wm_hints,
            ._32,
            .{ .mode = .replace },
            &.{hints},
        );
        self.last_applied_decoration_hints = hints;
    }

    pub fn addSubprocessEnv(self: *Window, env: *std.process.Environ.Map) !void {
        var buf: [64]u8 = undefined;
        const window_id = try std.fmt.bufPrint(
            &buf,
            "{}",
            .{self.x11_surface.getXid()},
        );

        try env.put("WINDOWID", window_id);
    }

    pub fn setUrgent(self: *Window, urgent: bool) !void {
        self.x11_surface.setUrgencyHint(@intFromBool(urgent));
    }

    fn getWindowProperty(
        self: *Window,
        comptime T: type,
        name: c.Atom,
        typ: c.Atom,
        comptime format: PropertyFormat,
        options: struct {
            offset: c_long = 0,
            length: c_long = std.math.maxInt(c_long),
            delete: bool = false,
        },
        result: *T,
    ) GetWindowPropertyError!void {
        // FIXME: Maybe we should switch to libxcb one day.
        // Sounds like a much better idea than whatever this is
        var actual_type_return: c.Atom = undefined;
        var actual_format_return: c_int = undefined;
        var nitems_return: c_ulong = undefined;
        var bytes_after_return: c_ulong = undefined;
        var prop_return: ?format.bufferType() = null;

        const code = c.XGetWindowProperty(
            @ptrCast(@alignCast(self.app.display)),
            self.x11_surface.getXid(),
            name,
            options.offset,
            options.length,
            @intFromBool(options.delete),
            typ,
            &actual_type_return,
            &actual_format_return,
            &nitems_return,
            &bytes_after_return,
            @ptrCast(&prop_return),
        );
        if (code != c.Success) return error.RequestFailed;

        if (actual_type_return == c.None) return error.PropertyNotFound;
        if (typ != actual_type_return) return error.PropertyTypeMismatch;
        if (@intFromEnum(format) != actual_format_return) return error.PropertyFormatMismatch;

        const data_ptr: *T = @ptrCast(prop_return);
        result.* = data_ptr.*;
        _ = c.XFree(prop_return);
    }

    fn changeProperty(
        self: *Window,
        comptime T: type,
        name: c.Atom,
        typ: c.Atom,
        comptime format: PropertyFormat,
        options: struct {
            mode: PropertyChangeMode,
        },
        values: []const T,
    ) X11Error!void {
        const data: format.bufferType() = @ptrCast(@constCast(values));
        // The number of "words" that each element `T` occupies.
        const words_per_elem = @divExact(@sizeOf(T), @sizeOf(format.elemType()));

        const status = c.XChangeProperty(
            @ptrCast(@alignCast(self.app.display)),
            self.x11_surface.getXid(),
            name,
            typ,
            @intFromEnum(format),
            @intFromEnum(options.mode),
            data,
            @intCast(words_per_elem * values.len),
        );

        // For some godforsaken reason Xlib alternates between
        // error values (0 = success) and booleans (1 = success), and they look exactly
        // the same in the signature (just `int`, since Xlib is written in C89)...
        if (status == 0) return error.RequestFailed;
    }

    fn deleteProperty(self: *Window, name: c.Atom) X11Error!void {
        const status = c.XDeleteProperty(
            @ptrCast(@alignCast(self.app.display)),
            self.x11_surface.getXid(),
            name,
        );
        if (status == 0) return error.RequestFailed;
    }
};

const X11Error = error{
    RequestFailed,
};

const GetWindowPropertyError = X11Error || error{
    PropertyNotFound,
    PropertyTypeMismatch,
    PropertyFormatMismatch,
};

const NetWmStateAction = enum(c_long) {
    remove = 0,
    add = 1,
    toggle = 2,
};

const Atoms = struct {
    kde_blur: c.Atom,
    motif_wm_hints: c.Atom,
    net_wm_desktop: c.Atom,
    net_wm_state: c.Atom,
    net_wm_state_above: c.Atom,
    net_wm_state_below: c.Atom,
    net_wm_state_fullscreen: c.Atom,
    net_wm_state_sticky: c.Atom,
    net_wm_state_skip_taskbar: c.Atom,
    net_wm_state_skip_pager: c.Atom,

    fn init(display: *gdk_x11.X11Display) Atoms {
        return .{
            .kde_blur = gdk_x11.x11GetXatomByNameForDisplay(
                display,
                "_KDE_NET_WM_BLUR_BEHIND_REGION",
            ),
            .motif_wm_hints = gdk_x11.x11GetXatomByNameForDisplay(
                display,
                "_MOTIF_WM_HINTS",
            ),
            .net_wm_desktop = gdk_x11.x11GetXatomByNameForDisplay(display, "_NET_WM_DESKTOP"),
            .net_wm_state = gdk_x11.x11GetXatomByNameForDisplay(display, "_NET_WM_STATE"),
            .net_wm_state_above = gdk_x11.x11GetXatomByNameForDisplay(display, "_NET_WM_STATE_ABOVE"),
            .net_wm_state_below = gdk_x11.x11GetXatomByNameForDisplay(display, "_NET_WM_STATE_BELOW"),
            .net_wm_state_fullscreen = gdk_x11.x11GetXatomByNameForDisplay(display, "_NET_WM_STATE_FULLSCREEN"),
            .net_wm_state_sticky = gdk_x11.x11GetXatomByNameForDisplay(display, "_NET_WM_STATE_STICKY"),
            .net_wm_state_skip_taskbar = gdk_x11.x11GetXatomByNameForDisplay(display, "_NET_WM_STATE_SKIP_TASKBAR"),
            .net_wm_state_skip_pager = gdk_x11.x11GetXatomByNameForDisplay(display, "_NET_WM_STATE_SKIP_PAGER"),
        };
    }
};

fn quickTerminalMonitor(
    xlib_display: *xlib.Display,
    apprt_window: *ApprtWindow,
    screen: Config.QuickTerminalScreen,
) ?*gdk.Monitor {
    const display: *c.Display = @ptrCast(@alignCast(xlib_display));
    const pointer = if (screen == .mouse) pointerPosition(display) else null;
    const gdk_display = apprt_window.as(gtk.Widget).getDisplay();
    const monitors = gdk_display.getMonitors();
    var first: ?*gdk.Monitor = null;
    var i: u32 = 0;
    while (monitors.getObject(i)) |item| : (i += 1) {
        const monitor = gobject.ext.cast(gdk.Monitor, item) orelse {
            item.unref();
            continue;
        };
        var geometry: gdk.Rectangle = undefined;
        monitor.getGeometry(&geometry);
        if (pointer) |pos| {
            if (pos.x >= geometry.f_x and
                pos.x < geometry.f_x + geometry.f_width and
                pos.y >= geometry.f_y and
                pos.y < geometry.f_y + geometry.f_height)
            {
                if (first) |fallback| fallback.unref();
                return monitor;
            }
        }
        if (first == null) {
            first = monitor;
        } else {
            monitor.unref();
        }
    }

    return first;
}

fn pointerPosition(display: *c.Display) ?struct { x: c_int, y: c_int } {
    var root: c.Window = undefined;
    var child: c.Window = undefined;
    var root_x: c_int = undefined;
    var root_y: c_int = undefined;
    var window_x: c_int = undefined;
    var window_y: c_int = undefined;
    var mask: c_uint = undefined;
    if (c.XQueryPointer(
        display,
        c.XDefaultRootWindow(display),
        &root,
        &child,
        &root_x,
        &root_y,
        &window_x,
        &window_y,
        &mask,
    ) == 0) return null;
    return .{ .x = root_x, .y = root_y };
}

const PropertyChangeMode = enum(c_int) {
    replace = c.PropModeReplace,
    prepend = c.PropModePrepend,
    append = c.PropModeAppend,
};

const PropertyFormat = enum(c_int) {
    _8 = 8,
    _16 = 16,
    _32 = 32,

    fn elemType(comptime self: PropertyFormat) type {
        return switch (self) {
            ._8 => c_char,
            ._16 => c_int,
            ._32 => c_long,
        };
    }

    fn bufferType(comptime self: PropertyFormat) type {
        // The buffer type has to be a multi-pointer to bytes
        // *aligned to the element type* (very important,
        // otherwise you'll read garbage!)
        //
        // I know this is really ugly. X11 is ugly. I consider it apropos.
        return [*]align(@alignOf(self.elemType())) u8;
    }
};

// See Xm/MwmUtil.h, packaged with the Motif Window Manager
const MotifWMHints = extern struct {
    flags: packed struct(c_ulong) {
        _pad: u1 = 0,
        decorations: bool = false,

        // We don't really care about the other flags
        _rest: std.meta.Int(.unsigned, @bitSizeOf(c_ulong) - 2) = 0,
    } = .{},
    functions: c_ulong = 0,
    decorations: packed struct(c_ulong) {
        all: bool = false,

        // We don't really care about the other flags
        _rest: std.meta.Int(.unsigned, @bitSizeOf(c_ulong) - 1) = 0,
    } = .{},
    input_mode: c_long = 0,
    status: c_ulong = 0,
};
