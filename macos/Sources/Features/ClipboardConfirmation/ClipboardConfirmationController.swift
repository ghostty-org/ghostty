import Foundation
import AppKit
import SwiftUI
import GhosttyKit

/// This initializes a clipboard confirmation warning alert. The window itself
/// WILL NOT show automatically and the caller must show the window via
/// showWindow, beginSheet, etc.
class ClipboardConfirmationAlert: NSAlert, NSAlertDelegate {
    let surface: ghostty_surface_t
    let contents: String
    let request: Ghostty.ClipboardRequest
    let state: UnsafeMutableRawPointer?

    enum Action: String {
        case cancel
        case confirm

        static func text(_ action: Action, _ reason: Ghostty.ClipboardRequest) -> String {
            switch (action, reason) {
            case (.cancel, .paste):
                return "Cancel"
            case (.cancel, .osc_52_read), (.cancel, .osc_52_write):
                return "Deny"
            case (.confirm, .paste):
                return "Paste"
            case (.confirm, .osc_52_read), (.confirm, .osc_52_write):
                return "Allow"
            }
        }
    }

    init(surface: ghostty_surface_t, contents: String, request: Ghostty.ClipboardRequest, state: UnsafeMutableRawPointer?) {
        self.surface = surface
        self.contents = contents
        self.request = request
        self.state = state
        super.init()

        showsHelp = true
        switch request {
        case .paste:
            messageText = "Potentially Unsafe Paste"
            alertStyle = .critical
            helpAnchor = "clipboard-paste-protection"
        case .osc_52_read, .osc_52_write:
            messageText = "Authorize Clipboard Access"
            alertStyle = .warning
            helpAnchor = "clipboard-write"
        }

        informativeText = request.text()
        let accessoryView = NSTextView.scrollableTextView()
        accessoryView.frame = .init(x: 0, y: 0, width: 300, height: 200)
        if let textView = accessoryView.documentView as? NSTextView {
            textView.drawsBackground = false
            textView.isEditable = false
            textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            textView.textContainerInset = .zero

            textView.string = contents
        }

        self.accessoryView = accessoryView

        addCancelButton(Action.text(.cancel, request))
        addConfirmButton(Action.text(.confirm, request))
        delegate = self
    }

    func addCancelButton(_ buttonTitle: String) {
        addButton(withTitle: buttonTitle)
            .keyEquivalent = .init([KeyboardShortcut(.escape).key.character])
    }

    func addConfirmButton(_ buttonTitle: String) {
        addButton(withTitle: buttonTitle)
            .keyEquivalent = .init([KeyboardShortcut(.return).key.character])
    }

    func alertShowHelp(_ alert: NSAlert) -> Bool {
        var components = URLComponents(string: "https://ghostty.org/docs/config/reference")
        components?.fragment = alert.helpAnchor
        guard let url = components?.url else {
            return false
        }
        NSWorkspace.shared.open(url)
        return true
    }
}
