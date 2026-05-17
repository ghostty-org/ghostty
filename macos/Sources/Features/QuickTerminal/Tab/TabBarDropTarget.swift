import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A transparent NSView that covers the full tab-strip content area and
/// participates only as a drag destination. Its job is to give NSScrollView
/// something to drive its built-in autoscroll against when the cursor is over
/// a gap, past the last tab, or otherwise not over a per-tab destination.
///
/// Drop ordering is still owned by `DraggableTabNSView`; this view never sets
/// `dropTargetIndex` itself.
struct TabBarDropTarget: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = TabBarDropTargetNSView()
        view.registerForDraggedTypes([
            NSPasteboard.PasteboardType(UTType.quickTerminalTab.identifier)
        ])
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private class TabBarDropTargetNSView: NSView {
    // Allow per-tab destinations to receive the drag instead of this underlay
    // when the cursor is actually over a tab. AppKit walks the responder chain
    // top-down for drop targets; making this view non-opaque to hit-testing
    // is unnecessary because tab cells are drawn on top of it.

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Returning `.move` keeps the drag session alive so NSScrollView's
        // built-in autoscroll engages near the edges. Drop placement is
        // still handled by the per-tab destinations.
        return .move
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // The drag source's `draggingSession(_:endedAt:)` handles the actual
        // reorder/move logic from the screen point. We just acknowledge.
        return true
    }
}
