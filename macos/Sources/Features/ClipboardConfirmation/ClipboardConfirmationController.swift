import Foundation
import Cocoa
import SwiftUI

/// This initializes a clipboard confirmation warning alert.
class ClipboardConfirmationController: TextViewAlert {
    private(set) var confirmation: Ghostty.ClipboardConfirmationRequest

    init(
        confirmation: Ghostty.ClipboardConfirmationRequest,
    ) {
        self.confirmation = confirmation
        super.init()
        let request = confirmation.kind
        messageText = request.alertMessageText
        informativeText = request.text()
        alertStyle = request.alertStyle
        textView.string = confirmation.contents
        helpLink = request.alertHelpLink
        addButton(withTitle: Action.confirm.text(request))
        addButton(withTitle: Action.cancel.text(request))
            .keyEquivalent = .init([KeyboardShortcut(.escape).key.character])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    /// Replace the request represented by the visible sheet without changing
    /// the sheet's focus state. The previous request is cancelled by its
    /// SurfaceView before this method is called.
    func replaceConfirmation(with confirmation: Ghostty.ClipboardConfirmationRequest) {
        guard self.confirmation !== confirmation else { return }
        self.confirmation = confirmation

        let request = confirmation.kind
        messageText = request.alertMessageText
        informativeText = request.text()
        alertStyle = request.alertStyle
        textView.string = confirmation.contents
        helpLink = request.alertHelpLink

        if let button = buttons[safe: 0] {
            button.title = Action.confirm.text(request)
        }

        if let button = buttons[safe: 1] {
            button.title = Action.cancel.text(request)
        }
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
        .informational
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
