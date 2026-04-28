import Cocoa
import SwiftUI

/// A borderless panel that looks like part of the window.
/// Single instance shared across all tabs — not per-tab.
@MainActor
class KanbanPanelController: NSWindowController {
    static let shared = KanbanPanelController()

    private static var hasAutoShown = false
    private var windowFrameObserver: Any?
    private weak var parentWindow: NSWindow?

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        panel.level = .floating
        panel.hasShadow = false

        // Make it flush against parent
        panel.styleMask.remove(.closable)
        panel.styleMask.remove(.miniaturizable)

        let content = NSHostingView(
            rootView: SidePanelView(viewModel: TerminalController.sharedSidebarViewModel)
        )
        panel.contentView = content

        // Persist width
        let savedWidth = UserDefaults.standard.double(forKey: "kanban_panel_width")
        let width = savedWidth > 0 ? savedWidth : 320.0
        panel.setContentSize(NSSize(width: width, height: 400))
        panel.minSize = NSSize(width: 240, height: 200)

        super.init(window: panel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func rebuildContent() {
        let content = NSHostingView(
            rootView: SidePanelView(viewModel: TerminalController.sharedSidebarViewModel)
        )
        window?.contentView = content
    }

    func show() {
        rebuildContent()
        guard let panel = window else { return }

        // Find the frontmost Ghostty window
        if let front = NSApp.keyWindow ?? NSApp.mainWindow,
           front.windowController is TerminalController {
            attach(to: front)
        }

        panel.orderFront(nil)
    }

    private func attach(to window: NSWindow) {
        parentWindow = window
        positionBeside(window)

        // Observe frame changes to follow parent
        if let obs = windowFrameObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        windowFrameObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.positionBeside(window)
        }
        windowFrameObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.positionBeside(window)
        }
    }

    private func positionBeside(_ window: NSWindow) {
        guard let panel = self.window else { return }
        let wf = window.frame
        let pw = panel.frame.width
        // Flush against left edge, same height as window
        let panelRect = NSRect(x: wf.minX, y: wf.minY, width: pw, height: wf.height)
        panel.setFrame(panelRect, display: true)
    }

    func toggle() {
        guard let panel = window else { return }
        if panel.isVisible {
            panel.close()
        } else {
            show()
        }
    }

    static func showOnceIfNeeded() {
        guard !hasAutoShown else { return }
        hasAutoShown = true
        shared.show()
    }
}
