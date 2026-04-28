import Cocoa
import SwiftUI

/// Manages an independent floating panel window that hosts the kanban sidebar,
/// completely decoupled from terminal tab lifecycle.
@MainActor
class KanbanPanelController: NSWindowController {
    static let shared = KanbanPanelController()

    private static var hasAutoShown = false
    private var hostingView: NSHostingView<SidePanelView>?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Kanban"
        window.minSize = NSSize(width: 260, height: 200)
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Show the panel, rebuilding content so the latest viewModel is used.
    func show() {
        let view = SidePanelView(viewModel: TerminalController.sharedSidebarViewModel)
        hostingView = NSHostingView(rootView: view)
        window?.contentView = hostingView
        window?.makeKeyAndOrderFront(nil)
    }

    /// Toggle the panel open/close.
    func toggle() {
        guard let window else { return }
        if window.isVisible {
            window.close()
        } else {
            show()
        }
    }

    /// Auto-show the panel once (call after the shared sidebar viewModel is ready).
    static func showOnceIfNeeded() {
        guard !hasAutoShown else { return }
        hasAutoShown = true
        shared.show()
    }
}
