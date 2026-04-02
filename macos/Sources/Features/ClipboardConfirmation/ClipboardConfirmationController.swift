import Foundation
import Cocoa
import SwiftUI
import GhosttyKit

/// This initializes a clipboard confirmation warning window. The window itself
/// WILL NOT show automatically and the caller must show the window via
/// showWindow, beginSheet, etc.
class ClipboardConfirmationController: NSWindowController {
    override var windowNibName: NSNib.Name? { "ClipboardConfirmation" }

    let surface: ghostty_surface_t
    let contents: String
    let request: Ghostty.ClipboardRequest
    let confirmReason: Ghostty.ClipboardConfirmReason
    let homoglyphHighlight: Ghostty.PasteHomoglyphURLHighlight?
    let state: UnsafeMutableRawPointer?
    weak private var delegate: ClipboardConfirmationViewDelegate?

    init(
        surface: ghostty_surface_t,
        contents: String,
        request: Ghostty.ClipboardRequest,
        confirmReason: Ghostty.ClipboardConfirmReason = .none,
        homoglyphHighlight: Ghostty.PasteHomoglyphURLHighlight? = nil,
        state: UnsafeMutableRawPointer?,
        delegate: ClipboardConfirmationViewDelegate
    ) {
        self.surface = surface
        self.contents = contents
        self.request = request
        self.confirmReason = confirmReason
        self.homoglyphHighlight = homoglyphHighlight
        self.state = state
        self.delegate = delegate
        super.init(window: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    // MARK: - NSWindowController

    override func windowDidLoad() {
        guard let window = window else { return }

        window.title = request.windowTitle(confirmReason: confirmReason)

        window.contentView = NSHostingView(rootView: ClipboardConfirmationView(
            contents: contents,
            request: request,
            confirmReason: confirmReason,
            homoglyphHighlight: homoglyphHighlight,
            delegate: delegate
        ))
    }
}
