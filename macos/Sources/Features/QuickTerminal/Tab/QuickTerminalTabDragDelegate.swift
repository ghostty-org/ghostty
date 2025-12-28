import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A delegate that handles drag session lifecycle for quick terminal tabs.
/// This is needed because SwiftUI's onDrag doesn't provide callbacks for when drags end.
class QuickTerminalTabDragDelegate: NSObject, NSDraggingSource {
    let tab: QuickTerminalTab
    let tabManager: QuickTerminalTabManager

    init(tab: QuickTerminalTab, tabManager: QuickTerminalTabManager) {
        self.tab = tab
        self.tabManager = tabManager
        super.init()
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        return .move
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        // This is called when the drag ends, regardless of where it was dropped
        // If draggedTab is still set, the drop wasn't handled by our drop delegates
        guard tabManager.draggedTab != nil else { return }

        // Check if we're outside the quick terminal window
        guard let quickWindow = tabManager.controller?.window else {
            tabManager.draggedTab = nil
            return
        }

        if !quickWindow.frame.contains(screenPoint) {
            // Check if we're over another Ghostty terminal window's tab bar area
            if let targetWindow = findGhosttyWindowAtLocation(screenPoint),
               isInTabBarArea(screenPoint, of: targetWindow) {
                tabManager.moveTabToExistingWindow(tab, targetWindow: targetWindow)
            } else {
                tabManager.moveTabToNewWindow(tab, at: screenPoint)
            }
        } else {
            // Dropped inside the window but not on a valid target
            tabManager.draggedTab = nil
        }
    }

    /// Finds a Ghostty terminal window (not quick terminal) at the given screen location.
    private func findGhosttyWindowAtLocation(_ location: NSPoint) -> NSWindow? {
        let windows = NSApp.orderedWindows

        for window in windows {
            if window.windowController is QuickTerminalController {
                continue
            }
            guard window.windowController is TerminalController else {
                continue
            }
            if window.frame.contains(location) {
                return window
            }
        }
        return nil
    }

    /// Checks if the given screen location is in the tab bar area of the window.
    private func isInTabBarArea(_ location: NSPoint, of window: NSWindow) -> Bool {
        let windowFrame = window.frame

        // Calculate the actual title bar + tab bar height by measuring the difference
        // between the window frame and the content layout rect. This works across
        // different macOS versions and window styles.
        let titleBarHeight = windowFrame.height - window.contentLayoutRect.height

        // Use the measured height, but ensure a minimum for edge cases
        let effectiveHeight = max(titleBarHeight, 28)

        let tabBarRect = NSRect(
            x: windowFrame.minX,
            y: windowFrame.maxY - effectiveHeight,
            width: windowFrame.width,
            height: effectiveHeight
        )

        return tabBarRect.contains(location)
    }
}

/// An NSViewRepresentable that wraps content and provides AppKit-level drag functionality.
struct DraggableTabView<Content: View>: NSViewRepresentable {
    let content: Content
    let tab: QuickTerminalTab
    let tabManager: QuickTerminalTabManager

    func makeNSView(context: Context) -> DraggableTabNSView {
        let view = DraggableTabNSView()
        view.tab = tab
        view.tabManager = tabManager
        view.setupHostingView(content: content)
        return view
    }

    func updateNSView(_ nsView: DraggableTabNSView, context: Context) {
        nsView.updateHostingView(content: content)
    }
}

/// The NSView that handles the actual drag operation.
class DraggableTabNSView: NSView {
    var tab: QuickTerminalTab!
    var tabManager: QuickTerminalTabManager!
    private var hostingView: NSHostingView<AnyView>?
    private var dragDelegate: QuickTerminalTabDragDelegate?

    func setupHostingView<Content: View>(content: Content) {
        let hosting = NSHostingView(rootView: AnyView(content))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)

        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        hostingView = hosting
    }

    func updateHostingView<Content: View>(content: Content) {
        hostingView?.rootView = AnyView(content)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        // Set the dragged tab
        tabManager.draggedTab = tab

        // Create the drag delegate
        dragDelegate = QuickTerminalTabDragDelegate(tab: tab, tabManager: tabManager)

        // Create the dragging item
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setData(
            tab.id.uuidString.data(using: .utf8) ?? Data(),
            forType: NSPasteboard.PasteboardType(UTType.quickTerminalTab.identifier)
        )

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)

        // Set the dragging frame to match the view
        draggingItem.setDraggingFrame(bounds, contents: snapshot())

        // Begin the drag session
        beginDraggingSession(with: [draggingItem], event: event, source: dragDelegate!)
    }

    /// Creates a snapshot image of the view for the drag preview.
    private func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        if let context = NSGraphicsContext.current?.cgContext {
            layer?.render(in: context)
        }
        image.unlockFocus()
        return image
    }
}
