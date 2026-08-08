import Foundation
import Cocoa
import SwiftUI
import GhosttyKit

/// This initializes a clipboard confirmation warning window. The window itself
/// WILL NOT show automatically and the caller must show the window via
/// showWindow, beginSheet, etc.
class ClipboardConfirmationController: TextViewAlert {
    let surface: ghostty_surface_t
    let contents: String
    let request: Ghostty.ClipboardRequest
    let state: UnsafeMutableRawPointer?

    init(surface: ghostty_surface_t, contents: String, request: Ghostty.ClipboardRequest, state: UnsafeMutableRawPointer?) {
        self.surface = surface
        self.contents = contents
        self.request = request
        self.state = state
        super.init(accessorySize: CGSize(width: 480, height: 192))
        messageText = request.alertMessageText
        informativeText = request.text()
        alertStyle = request.alertStyle
        textView.string = contents
        helpLink = request.alertHelpLink
        addButton(withTitle: Action.confirm.text(request))
        addButton(withTitle: Action.cancel.text(request))
            .keyEquivalent = .init([KeyboardShortcut(.escape).key.character])
    }
}

private extension Ghostty.ClipboardRequest {
    var alertMessageText: String {
        let request = self
        switch request {
        case .paste:
            return "Warning: Potentially Unsafe Paste"
        case .osc_52_read, .osc_52_write:
            return "Authorize Clipboard Access"
        }
    }

    var alertHelpLink: String {
        switch self {
        case .paste:
            "https://ghostty.org/docs/config/reference#clipboard-paste-protection"
        case .osc_52_read, .osc_52_write:
            "https://ghostty.org/docs/config/reference#clipboard-write"
        }
    }

    var alertStyle: NSAlert.Style {
        switch self {
        case .paste:
            .critical
        case .osc_52_read, .osc_52_write:
            .warning
        }
    }
}

extension ClipboardConfirmationController {
    enum Action: String {
        case cancel
        case confirm

        func text(_ reason: Ghostty.ClipboardRequest) -> String {
            switch (self, reason) {
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
}
