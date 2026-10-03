import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A transparent NSView that covers the full tab-strip content area and
/// participates only as a drag destination. Two jobs:
///
/// 1. Give `NSScrollView` something to drive its built-in autoscroll against
///    when the cursor is over a gap, past the last tab, or otherwise not over
///    a per-tab destination.
/// 2. Track whether the drag cursor is currently over the tab bar at all, so
///    the drag delegate can use that signal for drop-end routing instead of
///    hand-computing a tab-bar rect from window geometry.
///
/// Drop ordering is still owned by `DraggableTabNSView`; this view never sets
/// `dropTargetIndex` itself.
struct TabBarDropTarget: NSViewRepresentable {
    @ObservedObject var tabManager: QuickTerminalTabManager

    func makeNSView(context: Context) -> NSView {
        let view = TabBarDropTargetNSView()
        view.tabManager = tabManager
        view.registerForDraggedTypes([
            NSPasteboard.PasteboardType(UTType.quickTerminalTab.identifier)
        ])
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TabBarDropTargetNSView)?.tabManager = tabManager
    }
}

private class TabBarDropTargetNSView: NSView {
    weak var tabManager: QuickTerminalTabManager?

    // Allow per-tab destinations to receive the drag instead of this underlay
    // when the cursor is actually over a tab. AppKit walks the responder chain
    // top-down for drop targets; tab cells are drawn on top of this view, so
    // they take precedence naturally.

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        tabManager?.dragIsOverTabBar = true
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        tabManager?.dragIsOverTabBar = true
        // Returning `.move` keeps the drag session alive so NSScrollView's
        // built-in autoscroll engages near the edges. Drop placement is
        // still handled by the per-tab destinations.
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        tabManager?.dragIsOverTabBar = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // The drag source's `draggingSession(_:endedAt:)` handles the actual
        // reorder/move logic. We just acknowledge.
        return true
    }
}
