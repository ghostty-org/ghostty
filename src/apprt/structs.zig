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
};

/// The clipboard type.
///
/// If this is changed, you must also update ghostty.h
pub const Clipboard = enum(u2) {
    standard = 0, // ctrl+c/v
    selection = 1,
    primary = 2,
};

pub const ClipboardRequestType = enum(u8) {
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
};

/// A desktop notification.
pub const DesktopNotification = struct {
    /// The title of the notification. May be an empty string to not show a
    /// title.
    title: []const u8,

    /// The body of a notification. This will always be shown.
    body: []const u8,
};
