import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A delegate that handles drag session lifecycle for quick terminal tabs.
/// This is needed because SwiftUI's onDrag doesn't provide callbacks for when drags end.
class QuickTerminalTabDragDelegate: NSObject, NSDraggingSource {
    let tab: QuickTerminalTab
    let tabManager: QuickTerminalTabManager
    /// The scroll view the tab strip lives in. Captured at drag start so we
    /// can drive auto-scroll from the drag source — `draggingSession(_:movedTo:)`
    /// fires on every cursor move regardless of what's under the cursor, so
    /// auto-scroll works even when the user drags off the bar.
    private weak var scrollView: NSScrollView?

    /// Active auto-scroll timer while the cursor sits in the leading/trailing
    /// hot zone of the scroll view during a drag.
    private var autoScrollTimer: Timer?
    private var autoScrollDirection: CGFloat?

    private static let autoScrollEdge: CGFloat = 80
    private static let autoScrollStep: CGFloat = 12
    private static let autoScrollInterval: TimeInterval = 1.0 / 60.0

    init(tab: QuickTerminalTab, tabManager: QuickTerminalTabManager, scrollView: NSScrollView?) {
        self.tab = tab
        self.tabManager = tabManager
        self.scrollView = scrollView
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
        movedTo screenPoint: NSPoint
    ) {
        // Auto-scroll the tab strip if the cursor is near either edge. We
        // hook in here (on the drag source) rather than on per-tab drop
        // destinations so scrolling continues to work even when the cursor
        // is over a gap, an unfocused area, or off the bar entirely.
        updateAutoScroll(at: screenPoint)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        stopAutoScroll()

        // This is called when the drag ends, regardless of where it was dropped
        // If draggedTab is still set, the drop wasn't handled by our drop delegates
        guard tabManager.draggedTab != nil else { return }

        // Check if we're outside the quick terminal window
        guard let quickWindow = tabManager.controller?.window else {
            tabManager.draggedTab = nil
            return
        }

        if !quickWindow.frame.contains(screenPoint) {
            // Released outside the quick terminal window.
            if let targetWindow = findGhosttyWindowAtLocation(screenPoint),
               isInTabBarArea(screenPoint, of: targetWindow) {
                // Over another Ghostty window's tab bar — adopt as a new tab there.
                tabManager.moveTabToExistingWindow(tab, targetWindow: targetWindow)
            } else {
                // Fully outside any Ghostty window — detach into a new window.
                tabManager.moveTabToNewWindow(tab, at: screenPoint)
            }
        } else if isInQuickTerminalTabBar(screenPoint, of: quickWindow) {
            // Dropped in the tab bar — reorder if there's a valid drop target.
            if let source = tabManager.tabs.firstIndex(where: { $0.id == tab.id }),
               let dropIndex = tabManager.dropTargetIndex,
               dropIndex != source {
                let guardedDest = dropIndex > source ? dropIndex + 1 : dropIndex
                tabManager.moveTab(from: IndexSet(integer: source), to: guardedDest)
            }
            tabManager.draggedTab = nil
        } else {
            // Released elsewhere inside the quick terminal window (terminal
            // surface, search overlay, debug banner, etc.). Cancel the drag —
            // we never detach into a new window from inside the quick terminal.
            tabManager.draggedTab = nil
        }
    }

    /// Checks if the given screen location is in the tab bar area of the quick terminal window.
    private func isInQuickTerminalTabBar(_ location: NSPoint, of window: NSWindow) -> Bool {
        let windowFrame = window.frame
        let tabBarHeight = QuickTerminalTabBarView.Constants.height
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
        NSApp.orderedWindows.first { window in
            !(window.windowController is QuickTerminalController)
                && window.windowController is TerminalController
                && window.frame.contains(location)
        }
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

    // MARK: - Drag Auto-Scroll

    private func updateAutoScroll(at screenPoint: NSPoint) {
        guard let scrollView, let window = scrollView.window else {
            stopAutoScroll()
            return
        }

        // Convert the screen point to the scroll view's clip-view coordinates
        // (document coords) so it lines up with `clipView.bounds`.
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let clipView = scrollView.contentView
        let cursor = clipView.convert(windowPoint, from: nil)
        let visible = clipView.bounds

        let direction: CGFloat
        if cursor.x < visible.minX + Self.autoScrollEdge {
            direction = -Self.autoScrollStep
        } else if cursor.x > visible.maxX - Self.autoScrollEdge {
            direction = Self.autoScrollStep
        } else {
            stopAutoScroll()
            return
        }

        startAutoScroll(direction: direction, in: scrollView)
    }

    private func startAutoScroll(direction: CGFloat, in scrollView: NSScrollView) {
        if autoScrollTimer != nil, autoScrollDirection == direction { return }
        stopAutoScroll()

        autoScrollDirection = direction
        autoScrollTimer = Timer.scheduledTimer(
            withTimeInterval: Self.autoScrollInterval,
            repeats: true
        ) { [weak self, weak scrollView] _ in
            guard let scrollView, let documentView = scrollView.documentView else {
                self?.stopAutoScroll()
                return
            }
            let visible = scrollView.documentVisibleRect
            let maxX = max(0, documentView.bounds.width - visible.width)
            let newX = max(0, min(visible.origin.x + direction, maxX))
            if newX == visible.origin.x {
                self?.stopAutoScroll()
                return
            }
            scrollView.contentView.scroll(to: NSPoint(x: newX, y: visible.origin.y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        autoScrollDirection = nil
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

        // Create the drag delegate. Pass the enclosing scroll view so the
        // delegate can drive auto-scroll from the drag source independently
        // of which view is currently under the cursor.
        dragDelegate = QuickTerminalTabDragDelegate(
            tab: tab,
            tabManager: tabManager,
            scrollView: enclosingScrollView
        )

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
