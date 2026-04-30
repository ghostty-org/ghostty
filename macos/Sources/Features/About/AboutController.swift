import Foundation
import Cocoa
import SwiftUI

class AboutController: NSWindowController, NSWindowDelegate {
    static let shared: AboutController = AboutController()

    private let viewModel = AboutViewModel()
    override var windowNibName: NSNib.Name? { "About" }

    override func windowDidLoad() {
        guard let window = window else { return }
        window.center()
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: AboutView().environmentObject(viewModel))
    }

    // MARK: - Functions

    func show() {
        window?.makeKeyAndOrderFront(nil)
        viewModel.startCyclingIcons()
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
        viewModel.stopCyclingIcons()
    }
}
