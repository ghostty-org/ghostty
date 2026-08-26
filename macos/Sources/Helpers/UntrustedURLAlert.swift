import AppKit

/// Presents decisions for untrusted URLs at the AppKit boundary.
enum UntrustedURLAlert {
    static func presentConfirmation(for url: URL, displayString: String) {
        deferPresentation {
            let workspace = NSWorkspace.shared
            let handler = workspace.urlForApplication(toOpen: url)
                .map { "\u{201c}\($0.deletingPathExtension().lastPathComponent)\u{201d}" }
                ?? "the default application"
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.icon = NSImage(named: NSImage.cautionName)
            alert.messageText = "Open Link from Terminal Output?"
            alert.informativeText = """
            This link will open in \(handler). Only continue if you recognize \
            and trust the destination.
            """
            alert.accessoryView = targetView(displayString)
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Open Link")

            present(alert) { response in
                // Cancel is deliberately the default action.
                guard response == .alertSecondButtonReturn else { return }
                _ = workspace.open(url)
            }
        }
    }

    static func presentBlock(
        reason: UntrustedURL.DenialReason,
        displayString: String
    ) {
        deferPresentation {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.icon = NSImage(named: NSImage.cautionName)
            alert.messageText = "Ghostty Blocked This Link"
            alert.informativeText = reason.message
            alert.accessoryView = targetView(displayString)
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Copy Link")

            present(alert) { response in
                // Keep blocked targets out of Launch Services. Copying the
                // displayed, sanitized value gives the user an explicit path
                // forward without adding a one-click policy bypass.
                guard response == .alertSecondButtonReturn else { return }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(displayString, forType: .string)
            }
        }
    }

    /// The core action callback runs with the renderer mutex held. Queue modal
    /// presentation for the next main-loop turn so AppKit cannot reenter a
    /// render callback before that mutex is released.
    private static func deferPresentation(_ action: @escaping () -> Void) {
        DispatchQueue.main.async(execute: action)
    }

    private static func present(
        _ alert: NSAlert,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    private static func targetView(_ target: String) -> NSView {
        let scrollView = NSScrollView(frame: NSRect(
            x: 0,
            y: 0,
            width: 480,
            height: 96
        ))
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(
            ofSize: NSFont.systemFontSize,
            weight: .regular
        )
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.string = target
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: .greatestFiniteMagnitude
        )
        scrollView.documentView = textView
        return scrollView
    }
}
