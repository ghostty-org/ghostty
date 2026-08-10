import AppKit
import SwiftUI

/// Copies a string to the clipboard, and says that it did.
///
/// The confirmation is the point. A copy button that changes nothing when
/// pressed is indistinguishable from one that failed, and the reader's next
/// move is to press it again — or worse, to select the text by hand and
/// wonder whether the button does anything at all.
struct CopyButton: View {
    let text: String

    /// Shown in the tooltip and read by the accessibility label, so the
    /// button says what it will copy rather than just "copy".
    var label: String = "Copy"

    @State private var copied = false
    @State private var isHovered = false

    /// How long the tick stays. Long enough to be seen after the eye moves
    /// back from wherever it was going to paste, short enough that the
    /// button is ready again before anyone needs it twice.
    private static let confirmation = Duration.seconds(1.6)

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            confirm()
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .frame(width: 20, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isHovered ? Color.secondary.opacity(0.16) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            // The text cursor belongs to text; over a button the pointer
            // should say "this is pressable". `set` rather than `push`/`pop`,
            // matching the tab bar — a pushed cursor outlives a view that
            // disappears while the pointer is still over it.
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .help(copied ? "Copied" : label)
        .accessibilityLabel(copied ? "Copied" : label)
    }

    private func confirm() {
        copied = true
        Task {
            try? await Task.sleep(for: Self.confirmation)
            copied = false
        }
    }
}
