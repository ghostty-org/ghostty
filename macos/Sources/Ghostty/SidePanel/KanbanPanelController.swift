import Cocoa
import SwiftUI

/// A transparent overlay panel that sits ABOVE the Ghostty window.
/// The sidebar at the left edge is interactive; clicks outside pass
/// through to the Ghostty terminal underneath. Ghostty's tab system
/// is untouched.
@MainActor
class KanbanSidebarController {
    static let shared = KanbanSidebarController()
    private static var hasAutoShown = false

    private var overlayPanel: NSPanel?
    private var hostingView: NSHostingView<SidePanelView>?
    private var width: CGFloat = 85
    private weak var activeWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []

    private init() {
        let saved = UserDefaults.standard.double(forKey: "kanban_sidebar_width")
        if saved >= 60 { width = saved }
    }

    func show() {
        let content = SidePanelView(viewModel: TerminalController.sharedSidebarViewModel)
        hostingView = NSHostingView(rootView: content)
        hostingView?.wantsLayer = true

        guard let w = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        attach(to: w)
    }

    private func attach(to window: NSWindow) {
        // Outset panel frame to the left by sidebarWidth so the sidebar
        // sits LEFT of the Ghostty window (overlapping nothing).
        let outsetFrame = NSRect(
            x: window.frame.minX - width,
            y: window.frame.minY,
            width: window.frame.width + width,
            height: window.frame.height
        )

        let panel = NSPanel(
            contentRect: outsetFrame,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        panel.level = .normal
        panel.hasShadow = false
        panel.backgroundColor = .clear

        // Sidebar at (0,0) in the outset area
        guard let hostingView else { return }
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: outsetFrame.height)
        hostingView.autoresizingMask = [.height]

        // Transparent pass-through spacer covering the Ghostty window area
        let spacer = PassThroughView(frame: NSRect(
            x: width, y: 0,
            width: max(0, outsetFrame.width - width),
            height: outsetFrame.height
        ))
        spacer.autoresizingMask = [.width, .height]

        // Hit-test: only sidebar area gets mouse events
        let hitView = SidebarHitView(frame: NSRect(origin: .zero, size: outsetFrame.size), sidebarWidth: width)
        hitView.autoresizingMask = [.width, .height]
        hitView.addSubview(hostingView)
        hitView.addSubview(spacer)
        panel.contentView = hitView

        panel.orderFront(nil)
        overlayPanel = panel
        activeWindow = window

        // Follow parent window
        let mo = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main
        ) { [weak self] _ in self?.syncFrame(to: window) }
        let ro = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak self] _ in self?.syncFrame(to: window) }
        observers = [mo, ro]

        // Follow tab switches
        let ko = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] n in
            guard let self, let w = n.object as? NSWindow,
                  w.windowController is TerminalController,
                  w != self.activeWindow else { return }
            self.activeWindow = w
            self.syncFrame(to: w)
        }
        observers.append(ko)
    }

    private func syncFrame(to window: NSWindow) {
        let f = NSRect(
            x: window.frame.minX - width,
            y: window.frame.minY,
            width: window.frame.width + width,
            height: window.frame.height
        )
        overlayPanel?.setFrame(f, display: true)
    }

    func hide() {
        overlayPanel?.close()
        overlayPanel = nil
        hostingView = nil
        activeWindow = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    func toggle() {
        if overlayPanel?.isVisible == true { hide() } else { show() }
    }

    static func showOnceIfNeeded() {
        guard !hasAutoShown else { return }
        hasAutoShown = true
        shared.show()
    }
}

/// Hit-test: clicks on the sidebar (first `sidebarWidth` points) hit the
/// sidebar; clicks beyond pass through to the Ghostty window below.
private class SidebarHitView: NSView {
    let sidebarWidth: CGFloat
    init(frame: NSRect, sidebarWidth: CGFloat) {
        self.sidebarWidth = sidebarWidth
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if point.x <= sidebarWidth {
            return super.hitTest(point)
        }
        return nil
    }
}

/// Marker view — fully transparent, no interaction.
private class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
