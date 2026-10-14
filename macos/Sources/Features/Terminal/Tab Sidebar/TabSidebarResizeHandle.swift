import AppKit

/// A thin handle on the edge of a pane that resizes it. By default it sits on the trailing
/// edge of the tab sidebar and stores the width in the shared `TabSidebarSettings` so all
/// windows resize together.
final class TabSidebarResizeHandle: NSView {
    /// The edge of the resized pane the handle sits on.
    enum Edge {
        case leading
        case trailing
    }

    private let edge: Edge

    /// Sets the width of the pane. `persist` is false during a live resize.
    private let setWidth: (CGFloat, Bool) -> Void

    /// Resets the width of the pane to its default.
    private let resetWidth: () -> Void

    /// The width of the pane when the drag started.
    private var startWidth: CGFloat = 0

    /// The mouse location (in window coordinates) when the drag started.
    private var startX: CGFloat = 0

    /// True once the mouse moved after mouse down, so plain clicks don't change the width.
    private var didDrag = false

    /// A handle that resizes the tab sidebar.
    convenience init() {
        self.init(
            edge: .trailing,
            setWidth: { TabSidebarSettings.shared.setWidth($0, persist: $1) },
            resetWidth: { TabSidebarSettings.shared.setWidth(TabSidebarLogic.defaultWidth, persist: true) })
    }

    init(edge: Edge, setWidth: @escaping (CGFloat, Bool) -> Void, resetWidth: @escaping () -> Void) {
        self.edge = edge
        self.setWidth = setWidth
        self.resetWidth = resetWidth
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        // Double click resets the width to the default.
        if event.clickCount == 2 {
            resetWidth()
            return
        }

        startWidth = superview?.bounds.width ?? 0
        startX = event.locationInWindow.x
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        didDrag = true
        NSCursor.resizeLeftRight.set()
        setWidth(width(for: event), false)
    }

    override func mouseUp(with event: NSEvent) {
        guard didDrag else { return }
        didDrag = false
        setWidth(width(for: event), true)
    }

    private func width(for event: NSEvent) -> CGFloat {
        let delta = event.locationInWindow.x - startX
        return startWidth + (edge == .trailing ? delta : -delta)
    }
}
