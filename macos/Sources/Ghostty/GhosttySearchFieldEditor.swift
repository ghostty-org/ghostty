#if canImport(AppKit)
import AppKit
import GhosttyKit

/// Field editor for Ghostty's search field that intercepts key equivalents
/// which are ghostty key bindings (including performable ones like
/// navigate_search) and dispatches them directly to the surface.
///
/// This is necessary because:
/// 1. NSTextView's default field editor consumes standard key equivalents
///    (like Cmd+G for findNext:) via performKeyEquivalent before the app
///    can handle them.
/// 2. Ghostty's navigate_search bindings use `.performable = true`, which
///    are intentionally excluded from the menu key equivalent reverse map.
///    So even if we suppress the field editor, the menu system can't dispatch them.
///
/// The solution: check if the key event is a ghostty binding via
/// ghostty_surface_key_is_binding, and if so, dispatch it directly.
final class GhosttySearchFieldEditor: NSTextView {
    /// The surface view to dispatch key bindings to.
    weak var surfaceView: Ghostty.SurfaceView?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        guard let surface = surfaceView?.surface else {
            return super.performKeyEquivalent(with: event)
        }

        // Build the ghostty key event from the NSEvent.
        var ghosttyEvent = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)

        // Check if this key event matches a ghostty binding.
        let isBinding = (event.characters ?? "").withCString { ptr -> Bool in
            ghosttyEvent.text = ptr
            var flags = ghostty_binding_flags_e(0)
            return ghostty_surface_key_is_binding(surface, ghosttyEvent, &flags)
        }

        if isBinding {
            // Dispatch the key event to the surface, which will execute
            // the bound action (e.g. navigate_search:next).
            (event.characters ?? "").withCString { ptr in
                ghosttyEvent.text = ptr
                _ = ghostty_surface_key(surface, ghosttyEvent)
            }
            return true
        }

        return super.performKeyEquivalent(with: event)
    }
}
#endif
