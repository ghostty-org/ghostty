import AppKit

/// One transient hover owner per table, including reused and scrolled rows.
class GitHoverTableView: InspectorCopyTableView {
    var rowIdentity: (Int) -> String? = { _ in nil }
    private(set) var hoveredRowID: String?
    private var tracking: NSTrackingArea?
    private var observations: [NSObjectProtocol] = []
    deinit { observations.forEach(NotificationCenter.default.removeObserver) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observations.forEach(NotificationCenter.default.removeObserver)
        observations = []
        clearHover()
        guard let window else { return }
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observations.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                object: clip, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateHoverFromPointer() }
                })
        }
        observations.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
            object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.clearHover() }
            })
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if tracking == nil {
            let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .activeInKeyWindow], owner: self)
            addTrackingArea(area); tracking = area
        }
        updateHoverFromPointer()
    }
    override func mouseMoved(with event: NSEvent) {
        guard NativePointerLocation.contains(self, event: event) else { clearHover(); return }
        setHover(at: convert(event.locationInWindow, from: nil), onlyIfChanged: true)
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { clearHover() }
    func setHover(at point: NSPoint?, onlyIfChanged: Bool = false) {
        let row = point.flatMap { visibleRect.contains($0) ? self.row(at: $0) : nil } ?? -1
        let next = row >= 0 ? rowIdentity(row) : nil
        guard !onlyIfChanged || next != hoveredRowID else { return }
        hoveredRowID = next
        refreshRowBackgrounds()
    }
    func clearHover() { setHover(at: nil) }
    func updateHoverFromPointer() {
        guard let window, NativePointerLocation.contains(self) else { clearHover(); return }
        setHover(at: convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
    }
    func refreshRowBackgrounds() {
        enumerateAvailableRowViews { view, index in
            guard let row = view as? GitCollectionRowView else { return }
            row.isPointerHovered = self.rowIdentity(index).map { $0 == self.hoveredRowID } ?? false
            row.isMultipleSelection = self.selectedRowIndexes.count > 1
        }
    }
}
