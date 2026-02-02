import AppKit

/// Custom NSWindow subclass for the Settings window.
///
/// Adds two things over a plain NSWindow:
/// 1. Responds to the `close:` action sent by Ghostty's "Close" menu item
///    (which maps to `close_surface`). Terminal views handle this natively,
///    but non-terminal windows like Settings need to handle it explicitly.
///    NSWindow.close() is ObjC selector `close` (no colon), so `close:`
///    (with colon) is a distinct selector and doesn't conflict.
class SettingsWindow: NSWindow {
    @objc(close:) func closeFromMenu(_ sender: Any?) {
        performClose(sender)
    }
}
