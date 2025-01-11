/// Utility functions for X11 handling.
const std = @import("std");
const build_options = @import("build_options");
const c = @import("c.zig").c;
const input = @import("../../input.zig");

const log = std.log.scoped(.gtk_x11);

/// Returns true if the passed in display is an X11 display.
pub fn is_display(display: ?*c.GdkDisplay) bool {
    if (comptime !build_options.x11) return false;
    return c.g_type_check_instance_is_a(
        @ptrCast(@alignCast(display orelse return false)),
        c.gdk_x11_display_get_type(),
    ) != 0;
}

/// Returns true if the app is running on X11
pub fn is_current_display_server() bool {
    if (comptime !build_options.x11) return false;
    const display = c.gdk_display_get_default();
    return is_display(display);
}

pub const Xkb = struct {
    base_event_code: c_int,

    /// Initialize an Xkb struct for the given GDK display. If the display isn't
    /// backed by X then this will return null.
    pub fn init(display_: ?*c.GdkDisplay) !?Xkb {
        if (comptime !build_options.x11) return null;

        // Display should never be null but we just treat that as a non-X11
        // display so that the caller can just ignore it and not unwrap it.
        const display = display_ orelse return null;

        // If the display isn't X11, then we don't need to do anything.
        if (!is_display(display)) return null;

        log.debug("Xkb.init: initializing Xkb", .{});
        const xdisplay = c.gdk_x11_display_get_xdisplay(display);
        var result: Xkb = .{
            .base_event_code = 0,
        };

        log.debug("Xkb.init: running XkbQueryExtension", .{});
        var opcode: c_int = 0;
        var base_error_code: c_int = 0;
        var major = c.XkbMajorVersion;
        var minor = c.XkbMinorVersion;
        if (c.XkbQueryExtension(
            xdisplay,
            &opcode,
            &result.base_event_code,
            &base_error_code,
            &major,
            &minor,
        ) == 0) {
            log.err("Fatal: error initializing Xkb extension: error executing XkbQueryExtension", .{});
            return error.XkbInitializationError;
        }

        log.debug("Xkb.init: running XkbSelectEventDetails", .{});
        if (c.XkbSelectEventDetails(
            xdisplay,
            c.XkbUseCoreKbd,
            c.XkbStateNotify,
            c.XkbModifierStateMask,
            c.XkbModifierStateMask,
        ) == 0) {
            log.err("Fatal: error initializing Xkb extension: error executing XkbSelectEventDetails", .{});
            return error.XkbInitializationError;
        }

        return result;
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
    pub fn modifier_state_from_notify(self: Xkb, display_: ?*c.GdkDisplay) ?input.Mods {
        if (comptime !build_options.x11) return null;

        const display = display_ orelse return null;

        // Shoutout to Mozilla for figuring out a clean way to do this, this is
        // paraphrased from Firefox/Gecko in widget/gtk/nsGtkKeyUtils.cpp.
        const xdisplay = c.gdk_x11_display_get_xdisplay(display);
        if (c.XEventsQueued(xdisplay, c.QueuedAfterReading) == 0) return null;

        var nextEvent: c.XEvent = undefined;
        _ = c.XPeekEvent(xdisplay, &nextEvent);
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
