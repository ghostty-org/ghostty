import Foundation
import Cocoa
import SwiftUI

class AboutController: NSWindowController, NSWindowDelegate {
    static let shared: AboutController = AboutController()

    private let viewModel = AboutViewModel()
    override var windowNibName: NSNib.Name? { "About" }

    override func windowDidLoad() {
        guard let window = window else { return }
        window.isMovableByWindowBackground = true

        let hostingView = NSHostingView(
            rootView: AboutView().environmentObject(viewModel).themedChrome()
        )
        window.contentView = hostingView

        // AboutView fixes its width but not its height, so the height that
        // exactly fits it — margins included — is measured here rather than
        // guessed: a guess either clips the content (too small) or leaves
        // uneven padding (too big), and this project has now tried both.
        // Measuring needs the default sizing options still active — they're
        // what makes `fittingSize` compute anything at all.
        let width = AboutView.windowWidth
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        let height = hostingView.fittingSize.height
        window.setContentSize(NSSize(width: width, height: height))

        // Frozen only now: leaving this at its default lets the hosting
        // view keep nudging the window's size on its own afterward — which
        // is what grew a previous, differently-sized version of this
        // window past what AboutView itself was asking for.
        if #available(macOS 13.0, *) {
            hostingView.sizingOptions = []
        }
        window.titlebarAppearsTransparent = true

        // After the size is fixed, so it centers the actual frame rather
        // than whatever the xib's placeholder size was.
        window.center()
    }

    // MARK: - Functions

    func show() {
        window?.makeKeyAndOrderFront(nil)
    }

    func hide() {
        window?.close()
    }

    // MARK: - First Responder

    @IBAction func close(_ sender: Any) {
        self.window?.performClose(sender)
    }

    @IBAction func closeWindow(_ sender: Any) {
        self.window?.performClose(sender)
    }

    // This is called when "escape" is pressed.
    @objc func cancel(_ sender: Any?) {
        close()
    }

    func windowWillClose(_ notification: Notification) {
        viewModel.isHovering = false
    }
}
