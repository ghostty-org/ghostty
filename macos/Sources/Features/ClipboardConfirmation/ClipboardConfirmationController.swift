import Foundation
import Cocoa
import SwiftUI

/// This initializes a clipboard confirmation warning window. The window itself
/// WILL NOT show automatically and the caller must show the window via
/// showWindow, beginSheet, etc.
class ClipboardConfirmationController: NSWindowController {
    override var windowNibName: NSNib.Name? { "ClipboardConfirmation" }

    private(set) var confirmation: Ghostty.ClipboardConfirmationRequest
    weak private var delegate: ClipboardConfirmationViewDelegate?

    init(
        confirmation: Ghostty.ClipboardConfirmationRequest,
        delegate: ClipboardConfirmationViewDelegate
    ) {
        self.confirmation = confirmation
        self.delegate = delegate
        super.init(window: nil)
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

        guard isWindowLoaded, let window else { return }
        configure(window)
    }

    // MARK: - NSWindowController

    override func windowDidLoad() {
        guard let window = window else { return }

        configure(window)
    }

    private func configure(_ window: NSWindow) {
        switch confirmation.kind {
        case .paste:
            window.title = "Warning: Potentially Unsafe Paste"
        case .osc_52_read, .osc_52_write, .kitty_read, .kitty_write:
            window.title = "Authorize Clipboard Access"
        }

        window.contentView = NSHostingView(rootView: ClipboardConfirmationView(
            contents: confirmation.contents,
            request: confirmation.kind,
            programName: confirmation.programName,
            canRemember: confirmation.canRemember,
            previewImage: confirmation.previewImage,
            delegate: delegate
        ))
    }
}
