#if canImport(AppKit)
import SwiftUI
import AppKit
import GhosttyKit

extension Ghostty {
    /// The accessibility identifier used to tag the search NSTextField so that
    /// `windowWillReturnFieldEditor(_:to:)` can vend our custom field editor.
    static let searchFieldIdentifier = "ghostty-search-field"

    /// NSViewRepresentable wrapper around NSTextField for the search field.
    ///
    /// This gives us a guaranteed NSTextField reference that we can tag with
    /// an accessibility identifier directly, rather than relying on SwiftUI's
    /// internal propagation of accessibility identifiers to the underlying
    /// AppKit view (which is an implementation detail).
    struct GhosttySearchField: NSViewRepresentable {
        @Binding var text: String
        let surfaceView: SurfaceView
        let onClose: () -> Void

        /// Whether the field should become first responder. Set via onAppear/notification.
        /// Callers should toggle this false→true to re-trigger focus.
        @Binding var isFocused: Bool

        func makeNSView(context: Context) -> NSTextField {
            let field = NSTextField()
            field.placeholderString = "Search"
            field.setAccessibilityIdentifier(Ghostty.searchFieldIdentifier)
            field.delegate = context.coordinator
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.font = .systemFont(ofSize: NSFont.systemFontSize)
            field.cell?.sendsActionOnEndEditing = false
            return field
        }

        func updateNSView(_ field: NSTextField, context: Context) {
            // Update text only if it differs to avoid cursor jumps
            if field.stringValue != text {
                field.stringValue = text
            }

            // Update coordinator references
            context.coordinator.parent = self

            // Handle focus requests on rising edge, then reset the flag
            // so subsequent true→false→true transitions re-trigger focus.
            if isFocused, let window = field.window {
                window.makeFirstResponder(field)
                DispatchQueue.main.async {
                    isFocused = false
                }
            }
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(self)
        }

        class Coordinator: NSObject, NSTextFieldDelegate {
            var parent: GhosttySearchField

            init(_ parent: GhosttySearchField) {
                self.parent = parent
            }

            func controlTextDidChange(_ obj: Foundation.Notification) {
                guard let field = obj.object as? NSTextField else { return }
                parent.text = field.stringValue
            }

            func control(
                _ control: NSControl,
                textView: NSTextView,
                doCommandBy commandSelector: Selector
            ) -> Bool {
                // Don't intercept during IME composition — Return should commit
                // the marked text and Escape should cancel composition.
                if textView.hasMarkedText() {
                    return false
                }

                if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                    // Enter key: navigate search
                    guard let surface = parent.surfaceView.surface else { return true }

                    let shiftPressed = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                    let action = shiftPressed
                        ? "navigate_search:previous"
                        : "navigate_search:next"
                    ghostty_surface_binding_action(
                        surface, action,
                        UInt(action.lengthOfBytes(using: .utf8))
                    )
                    return true
                }

                if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                    // Escape key: close search if empty, otherwise move focus back
                    if parent.text.isEmpty {
                        parent.onClose()
                    } else {
                        Ghostty.moveFocus(to: parent.surfaceView)
                    }
                    return true
                }

                return false
            }
        }
    }
}
#endif
