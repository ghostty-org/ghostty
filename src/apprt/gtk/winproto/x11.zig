//! X11 window protocol implementation for the Ghostty GTK apprt.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;
const c = @import("../c.zig").c;
const input = @import("../../../input.zig");
const Config = @import("../../../config.zig").Config;
const adwaita = @import("../adwaita.zig");

const log = std.log.scoped(.gtk_x11);

pub const App = struct {
    display: *c.Display,
    base_event_code: c_int,
    kde_blur_atom: c.Atom,

    pub fn init(
        alloc: Allocator,
        gdk_display: *c.GdkDisplay,
        app_id: [:0]const u8,
        config: *const Config,
    ) !?App {
        _ = alloc;

        // If the display isn't X11, then we don't need to do anything.
        if (c.g_type_check_instance_is_a(
            @ptrCast(@alignCast(gdk_display)),
            c.gdk_x11_display_get_type(),
        ) == 0) return null;

        // Get our X11 display
        const display: *c.Display = c.gdk_x11_display_get_xdisplay(
            gdk_display,
        ) orelse return error.NoX11Display;

        const x11_program_name: [:0]const u8 = if (config.@"x11-instance-name") |pn|
            pn
        else if (builtin.mode == .Debug)
            "ghostty-debug"
        else
            "ghostty";

        // Set the X11 window class property (WM_CLASS) if are are on an X11
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
        c.g_set_prgname(x11_program_name);
        c.gdk_x11_display_set_program_class(gdk_display, app_id);

        // XKB
        log.debug("Xkb.init: initializing Xkb", .{});
        log.debug("Xkb.init: running XkbQueryExtension", .{});
        var opcode: c_int = 0;
        var base_event_code: c_int = 0;
        var base_error_code: c_int = 0;
        var major = c.XkbMajorVersion;
        var minor = c.XkbMinorVersion;
        if (c.XkbQueryExtension(
            display,
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
            display,
            c.XkbUseCoreKbd,
            c.XkbStateNotify,
            c.XkbModifierStateMask,
            c.XkbModifierStateMask,
        ) == 0) {
            log.err("Fatal: error initializing Xkb extension: error executing XkbSelectEventDetails", .{});
            return error.XkbInitializationError;
        }

        return .{
            .display = display,
            .base_event_code = base_event_code,
            .kde_blur_atom = c.gdk_x11_get_xatom_by_name_for_display(
                gdk_display,
                "_KDE_NET_WM_BLUR_BEHIND_REGION",
            ),
        };
    }

    pub fn deinit(self: *App, alloc: Allocator) void {
        _ = self;
        _ = alloc;
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
        device: ?*c.GdkDevice,
        gtk_mods: c.GdkModifierType,
    ) ?input.Mods {
        _ = device;
        _ = gtk_mods;

        // Shoutout to Mozilla for figuring out a clean way to do this, this is
        // paraphrased from Firefox/Gecko in widget/gtk/nsGtkKeyUtils.cpp.
        if (c.XEventsQueued(self.display, c.QueuedAfterReading) == 0) return null;

        var nextEvent: c.XEvent = undefined;
        _ = c.XPeekEvent(self.display, &nextEvent);
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
};

pub const Window = struct {
    app: *App,
    config: DerivedConfig,
    window: c.Window,
    gtk_window: *c.GtkWindow,
    blur_region: Region,

    const DerivedConfig = struct {
        blur: bool,

        pub fn init(config: *const Config) DerivedConfig {
            return .{
                .blur = config.@"background-blur-radius".enabled(),
            };
        }
    };

    pub fn init(
        _: Allocator,
        app: *App,
        gtk_window: *c.GtkWindow,
        config: *const Config,
    ) !Window {
        const surface = c.gtk_native_get_surface(
            @ptrCast(gtk_window),
        ) orelse return error.NotX11Surface;

        // Check if we're actually on X11
        if (c.g_type_check_instance_is_a(
            @ptrCast(@alignCast(surface)),
            c.gdk_x11_surface_get_type(),
        ) == 0) return error.NotX11Surface;

        const blur_region: Region = blur: {
            if ((comptime !adwaita.versionAtLeast(0, 0, 0)) or
                !adwaita.enabled(config)) break :blur .{};

            // NOTE(pluiedev): CSDs are a f--king mistake.
            // Please, GNOME, stop this nonsense of making a window ~30% bigger
            // internally than how they really are just for your shadows and
            // rounded corners and all that fluff. Please. I beg of you.
            var x: f64 = 0;
            var y: f64 = 0;
            c.gtk_native_get_surface_transform(
                @ptrCast(gtk_window),
                &x,
                &y,
            );

            break :blur .{
                .x = @intFromFloat(x),
                .y = @intFromFloat(y),
            };
        };

        return .{
            .app = app,
            .config = DerivedConfig.init(config),
            .window = c.gdk_x11_surface_get_xid(surface),
            .gtk_window = gtk_window,
            .blur_region = blur_region,
        };
    }

    pub fn deinit(self: Window, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }

    pub fn updateConfigEvent(
        self: *Window,
        config: *const Config,
    ) !void {
        self.config = DerivedConfig.init(config);
    }

    pub fn resizeEvent(self: *Window) !void {
        // The blur region must update with window resizes
        self.blur_region.width = c.gtk_widget_get_width(@ptrCast(self.gtk_window));
        self.blur_region.height = c.gtk_widget_get_height(@ptrCast(self.gtk_window));
        try self.syncBlur();
    }

    pub fn syncAppearance(self: *Window) !void {
        try self.syncBlur();
    }

    fn syncBlur(self: *Window) !void {
        // FIXME: This doesn't currently factor in rounded corners on Adwaita,
        // which means that the blur region will grow slightly outside of the
        // window borders. Unfortunately, actually calculating the rounded
        // region can be quite complex without having access to existing APIs
        // (cf. https://github.com/cutefishos/fishui/blob/41d4ba194063a3c7fff4675619b57e6ac0504f06/src/platforms/linux/blurhelper/windowblur.cpp#L134)
        // and I think it's not really noticeable enough to justify the effort.
        // (Wayland also has this visual artifact anyway...)

        const blur = self.config.blur;
        log.debug("set blur={}, window xid={}, region={}", .{
            blur,
            self.window,
            self.blur_region,
        });

        if (blur) {
            _ = c.XChangeProperty(
                self.app.display,
                self.window,
                self.app.kde_blur_atom,
                c.XA_CARDINAL,
                // Despite what you might think, the "32" here does NOT mean
                // that the data should be in u32s. Instead, they should be
                // c_longs, which on any 64-bit architecture would be obviously
                // 64 bits. WTF?!
                32,
                c.PropModeReplace,
                // SAFETY: Region is an extern struct that has the same
                // representation of 4 c_longs put next to each other.
                // Therefore, reinterpretation should be safe.
                // We don't have to care about endianness either since
                // Xlib converts it to network byte order for us.
                @ptrCast(std.mem.asBytes(&self.blur_region)),
                4,
            );
        } else {
            _ = c.XDeleteProperty(
                self.app.display,
                self.window,
                self.app.kde_blur_atom,
            );
        }
    }
};

const Region = extern struct {
    x: c_long = 0,
    y: c_long = 0,
    width: c_long = 0,
    height: c_long = 0,
};
