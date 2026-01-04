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
        } else if isInQuickTerminalTabBar(screenPoint, of: quickWindow) {
            // Dropped in the tab bar - perform the tab move if we have a drop target
            if let source = tabManager.tabs.firstIndex(where: { $0.id == tab.id }),
               let dropIndex = tabManager.dropTargetIndex,
               dropIndex != source {
                let guardedDest = dropIndex > source ? dropIndex + 1 : dropIndex
                tabManager.moveTab(from: IndexSet(integer: source), to: guardedDest)
            }
            tabManager.draggedTab = nil
        } else {
            // Dropped on the terminal surface (not tab bar) - move to new window
            tabManager.moveTabToNewWindow(tab, at: screenPoint)
        }
    }

    /// Checks if the given screen location is in the tab bar area of the quick terminal window.
    private func isInQuickTerminalTabBar(_ location: NSPoint, of window: NSWindow) -> Bool {
        let windowFrame = window.frame
        // Tab bar is at the top of the window, 24px tall
        let tabBarHeight: CGFloat = 24
        let tabBarRect = NSRect(
            x: windowFrame.minX,
            y: windowFrame.maxY - tabBarHeight,
            width: windowFrame.width,
            height: tabBarHeight
        )
        return tabBarRect.contains(location)
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

/// The NSView that handles the actual drag operation and drop destination.
class DraggableTabNSView: NSView {
    var tab: QuickTerminalTab!
    var tabManager: QuickTerminalTabManager!
    private var hostingView: NSHostingView<AnyView>?
    private var dragDelegate: QuickTerminalTabDragDelegate?
    /// The location where the drag gesture started (captured on first mouseDragged event)
    private var dragStartLocation: NSPoint?
    /// Whether we've exceeded the drag threshold and started tracking as a real drag
    private var isDragging = false
    /// Minimum distance to move before starting a tab drag (prevents accidental window drags)
    private static let dragThreshold: CGFloat = 5

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

        // Register as a drop destination
        registerForDraggedTypes([NSPasteboard.PasteboardType(UTType.quickTerminalTab.identifier)])
    }

    func updateHostingView<Content: View>(content: Content) {
        hostingView?.rootView = AnyView(content)
    }

    // Note: We don't override mouseDown/mouseUp because those events go to the
    // NSHostingView subview (for SwiftUI gesture handling), not to this parent view.
    // Instead, we capture the start location on the first mouseDragged event.

    override func mouseDragged(with event: NSEvent) {
        let currentLocation = event.locationInWindow

        // Capture start location on first drag event of a new gesture
        if dragStartLocation == nil {
            dragStartLocation = currentLocation
            isDragging = false
            return
        }

        // Check if we've moved beyond the threshold to start dragging
        if !isDragging {
            let distance = hypot(currentLocation.x - dragStartLocation!.x, currentLocation.y - dragStartLocation!.y)
            guard distance >= Self.dragThreshold else { return }
            isDragging = true
        }

        // Only initiate the drag session once
        guard tabManager.draggedTab == nil else { return }

        // Set the dragged tab and capture its width
        tabManager.draggedTab = tab
        tabManager.draggedTabWidth = bounds.width

        // Reset tracking state now that we're starting a drag session
        dragStartLocation = nil
        isDragging = false

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
        let session = beginDraggingSession(with: [draggingItem], event: event, source: dragDelegate!)
        session.animatesToStartingPositionsOnCancelOrFail = false
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

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return updateDropTarget(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return updateDropTarget(sender)
    }

    private func updateDropTarget(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let draggedTab = tabManager.draggedTab,
              let source = tabManager.tabs.firstIndex(where: { $0.id == draggedTab.id }),
              let dest = tabManager.tabs.firstIndex(where: { $0.id == tab.id })
        else { return [] }

        // Determine if cursor is on the left or right half of the tab
        let locationInView = convert(sender.draggingLocation, from: nil)
        let isOnRightHalf = locationInView.x > bounds.width / 2

        // Calculate effective drop index based on cursor position
        let effectiveDest: Int
        if dest == source {
            // Over the source tab - use source index
            effectiveDest = source
        } else if dest > source {
            // Dragging to the right - if on left half, drop before this tab
            effectiveDest = isOnRightHalf ? dest : dest - 1
        } else {
            // Dragging to the left - if on right half, drop after this tab
            effectiveDest = isOnRightHalf ? dest + 1 : dest
        }

        // Set drop target index, but avoid setting it on initial pickup
        if effectiveDest != source {
            tabManager.dropTargetIndex = effectiveDest
        } else if let currentTarget = tabManager.dropTargetIndex, currentTarget != source {
            // Returning to source after having moved away
            tabManager.dropTargetIndex = effectiveDest
        }

        return .move
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // Don't do anything here - let processDragEnd handle the move
        // This ensures consistent behavior whether dropping on a tab or placeholder
        return true
    }
}
