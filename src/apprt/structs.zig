const build_config = @import("../build_config.zig");

/// ContentScale is the ratio between the current DPI and the platform's
/// default DPI. This is used to determine how much certain rendered elements
/// need to be scaled up or down.
pub const ContentScale = struct {
    x: f32,
    y: f32,
};

/// The size of the surface in pixels.
pub const SurfaceSize = struct {
    width: u32,
    height: u32,
};

/// The position of the cursor in pixels.
pub const CursorPos = struct {
    x: f32,
    y: f32,
};

/// Input Method Editor (IME) position.
pub const IMEPos = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

/// The clipboard type.
///
/// If this is changed, you must also update ghostty.h
pub const Clipboard = enum(Backing) {
    standard = 0, // ctrl+c/v
    selection = 1,
    primary = 2,

    // We use a full C int for the backing type so that this is C ABI
    // compatible when binding to C APIs (GTK and embedded).
    const Backing = c_int;

    /// Make this a valid gobject if we're in a GTK environment.
    pub const getGObjectType = switch (build_config.app_runtime) {
        .gtk => @import("gobject").ext.defineEnum(
            Clipboard,
            .{ .name = "GhosttyApprtClipboard" },
        ),

        .none => void,
    };
};

pub const ClipboardContent = struct {
    mime: [:0]const u8,
    data: [:0]const u8,
};

pub const ClipboardRequestType = enum(c_int) {
    paste,
    osc_52_read,
    osc_52_write,
};

/// Clipboard request. This is used to request clipboard contents and must
/// be sent as a response to a ClipboardRequest event.
pub const ClipboardRequest = union(ClipboardRequestType) {
    /// A direct paste of clipboard contents.
    paste: void,

    /// A request to read clipboard contents via OSC 52.
    osc_52_read: Clipboard,

    /// A request to write clipboard contents via OSC 52.
    osc_52_write: Clipboard,

    /// Make this a valid gobject if we're in a GTK environment.
    pub const getGObjectType = switch (build_config.app_runtime) {
        .gtk => @import("gobject").ext.defineBoxed(
            ClipboardRequest,
            .{ .name = "GhosttyClipboardRequest" },
        ),

        .none => void,
    };
};

// If these are changed, you must also update ghostty.h
comptime {
    // Sync with ghostty_clipboard_e
    @import("std").debug.assert(@intFromEnum(Clipboard.standard) == 0);
    @import("std").debug.assert(@intFromEnum(Clipboard.selection) == 1);
    @import("std").debug.assert(@intFromEnum(Clipboard.primary) == 2);

    // Sync with ghostty_clipboard_request_e
    @import("std").debug.assert(@intFromEnum(ClipboardRequestType.paste) == 0);
    @import("std").debug.assert(@intFromEnum(ClipboardRequestType.osc_52_read) == 1);
    @import("std").debug.assert(@intFromEnum(ClipboardRequestType.osc_52_write) == 2);
}

/// The color scheme in use (light vs dark).
pub const ColorScheme = enum(u2) {
    light = 0,
    dark = 1,
};

/// Selection information
pub const Selection = struct {
    /// Top-left point of the selection in the viewport in scaled
    /// window pixels. (0,0) is the top-left of the window.
    tl_x_px: f64,
    tl_y_px: f64,

    /// The offset of the selection start in cells from the top-left
    /// of the viewport.
    ///
    /// This is a strange metric but its used by macOS.
    offset_start: u32,
    offset_len: u32,
};
