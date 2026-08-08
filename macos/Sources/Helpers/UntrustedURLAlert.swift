#if os(macOS)
import AppKit

/// Presents decisions for untrusted URLs at the AppKit boundary.
enum UntrustedURLAlert {
    static func presentConfirmation(for url: URL, displayString: String) {
        deferPresentation {
            let workspace = NSWorkspace.shared
            let handler = workspace.urlForApplication(toOpen: url)
                .map { "\u{201c}\($0.deletingPathExtension().lastPathComponent)\u{201d}" }
                ?? "the default application"
            let alert = TextViewAlert()
            alert.textView.string = displayString
            alert.alertStyle = .critical
            alert.messageText = "Open Link from Terminal Output?"
            alert.informativeText = """
            This link will open in \(handler). Only continue if you recognize \
            and trust the destination.
            """
            alert.addButton(withTitle: "Cancel")
                .keyEquivalent = "\r"

            alert.addButton(withTitle: "Open Link")

            // Cancel is deliberately the default action.
            guard await alert.present() == .alertSecondButtonReturn else { return }
            _ = workspace.open(url)
        }
    }

    static func presentBlock(
        reason: UntrustedURL.DenialReason,
        displayString: String
    ) {
        deferPresentation {
            let alert = TextViewAlert()
            alert.alertStyle = .critical
            alert.messageText = "Ghostty Blocked This Link"
            alert.informativeText = reason.message
            alert.textView.string = displayString
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Copy Link")

            // Keep blocked targets out of Launch Services. Copying the
            // displayed, sanitized value gives the user an explicit path
            // forward without adding a one-click policy bypass.
            guard await alert.present() == .alertSecondButtonReturn else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(displayString, forType: .string)
        }
    }

    /// The core action callback runs with the renderer mutex held. Queue modal
    /// presentation for the next main-loop turn so AppKit cannot reenter a
    /// render callback before that mutex is released.
    private static func deferPresentation(_ action: @escaping @MainActor () async -> Void) {
        DispatchQueue.main.async {
            Task { @MainActor in
                await action()
            }
        }
    }
}
#endif
