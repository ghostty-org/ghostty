import AppKit

/// A thin handle on the trailing edge of the tab sidebar that resizes it. The width is
/// stored in the shared `TabSidebarSettings` so all windows resize together.
final class TabSidebarResizeHandle: NSView {
    /// The width of the sidebar when the drag started.
    private var startWidth: CGFloat = 0

    /// The mouse location (in window coordinates) when the drag started.
    private var startX: CGFloat = 0

    /// True once the mouse moved after mouse down, so plain clicks don't change the width.
    private var didDrag = false

    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        // Double click resets the width to the default.
        if event.clickCount == 2 {
            TabSidebarSettings.shared.setWidth(TabSidebarLogic.defaultWidth, persist: true)
            return
        }

        startWidth = superview?.bounds.width ?? TabSidebarSettings.shared.width
        startX = event.locationInWindow.x
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        didDrag = true
        NSCursor.resizeLeftRight.set()
        let width = startWidth + (event.locationInWindow.x - startX)
        TabSidebarSettings.shared.setWidth(width, persist: false)
    }

    override func mouseUp(with event: NSEvent) {
        guard didDrag else { return }
        didDrag = false
        let width = startWidth + (event.locationInWindow.x - startX)
        TabSidebarSettings.shared.setWidth(width, persist: true)
    }
}
