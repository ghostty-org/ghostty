import AppKit

/// One tracking area per table; pointer movement only invalidates the old and new rows.
final class NativeTableHover: NSObject {
    private weak var table: NSTableView?
    private weak var hoveredView: NativeHoverRowView?
    private var tracking: NSTrackingArea?
    private weak var observedClip: NSClipView?
    private weak var observedWindow: NSWindow?
    private var clipObservation: NSObjectProtocol?
    private var windowObservations: [NSObjectProtocol] = []
    private var pointerInside = false
    private var refreshPending = false
    private var validateWindowPending = false
    private var generation: UInt64 = 0

    init(table: NSTableView) {
        self.table = table
        super.init()
    }

    deinit {
        if let clipObservation { NotificationCenter.default.removeObserver(clipObservation) }
        windowObservations.forEach(NotificationCenter.default.removeObserver)
    }

    func update() {
        guard let table else { return }
        let window = table.window
        let clip = window == nil ? nil : table.enclosingScrollView?.contentView
        let changed = observedWindow !== window || observedClip !== clip
        if changed {
            clear()
            if let clipObservation { NotificationCenter.default.removeObserver(clipObservation) }
            clipObservation = nil
            windowObservations.forEach(NotificationCenter.default.removeObserver)
            windowObservations.removeAll()
            observedWindow = window
            observedClip = clip
            if let clip {
                clip.postsBoundsChangedNotifications = true
                clipObservation = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleRefresh() }
                }
            }
            if let window {
                for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                    windowObservations.append(NotificationCenter.default.addObserver(
                        forName: name, object: window, queue: .main
                    ) { [weak self] note in
                        MainActor.assumeIsolated {
                            if note.name == NSWindow.didResignKeyNotification { self?.clear() } else {
                                self?.scheduleRefresh(validateWindow: true)
                            }
                        }
                    })
                }
            }
        }
        if tracking == nil {
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                      owner: self)
            tracking = area
            table.addTrackingArea(area)
        }
        scheduleRefresh(validateWindow: changed && window != nil)
    }

    func clear() {
        cancelRefresh()
        pointerInside = false
        setRow(nil)
    }

    func didUnhide() { scheduleRefresh(validateWindow: true) }

    private func cancelRefresh() {
        generation &+= 1
        refreshPending = false
        validateWindowPending = false
    }

    private func scheduleRefresh(validateWindow: Bool = false) {
        guard table?.window != nil, pointerInside || validateWindow else { return }
        validateWindowPending = validateWindowPending || validateWindow
        guard !refreshPending else { return }
        refreshPending = true
        let generation = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation, let table = self.table else { return }
            self.refreshPending = false
            if self.validateWindowPending {
                self.validateWindowPending = false
                self.pointerInside = NativePointerLocation.contains(table)
            }
            guard self.pointerInside, let window = table.window, window.isKeyWindow,
                  window.isVisible, !table.isHiddenOrHasHiddenAncestor else { self.clear(); return }
            // Wait for clip/row layout to settle. This local conversion does not
            // synchronously query WindowServer on every scroll notification.
            self.updateRow(at: table.convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }

    private func updateRow(at point: NSPoint) {
        guard let table, table.visibleRect.contains(point) else { clear(); return }
        let index = table.row(at: point)
        setRow(index >= 0 ? table.rowView(atRow: index, makeIfNecessary: true) as? NativeHoverRowView : nil)
    }

    func setRow(_ row: NativeHoverRowView?) {
        if hoveredView === row {
            // Reattachment can reset a recycled row while the pointer stays still.
            row?.isHovered = true
            return
        }
        hoveredView?.isHovered = false
        hoveredView = row
        row?.isHovered = true
    }
    // NSObject does not inherit NSResponder's Objective-C selector mapping.
    // Without explicit names Swift exports mouseMovedWith:, which AppKit never calls.
    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    @objc(mouseMoved:) func mouseMoved(with event: NSEvent) {
        cancelRefresh()
        guard let table, NativePointerLocation.contains(table, event: event) else { clear(); return }
        pointerInside = true
        updateRow(at: table.convert(event.locationInWindow, from: nil))
    }
    @objc(mouseExited:) func mouseExited(with event: NSEvent) { clear() }
}

class NativeHoverRowView: NSTableRowView {
    override var wantsUpdateLayer: Bool { false }
    private let hoverBackground = CAShapeLayer()
    private let themeObserver = OMGNativeThemeObserver()
    private var hoverBounds: NSRect?
    var isHovered = false {
        didSet {
            guard oldValue != isHovered else { return }
            updateHoverVisibility()
            hoverStateDidChange(isHovered)
        }
    }
    override var isSelected: Bool { didSet { if oldValue != isSelected { updateHoverVisibility() } } }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        hoverBackground.name = "omg.row.hover"
        layer?.insertSublayer(hoverBackground, at: 0)
        themeObserver.onChange = { [weak self] _ in self?.updateHoverColor() }
        updateHoverGeometry()
        updateHoverColor()
        updateHoverVisibility()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); isHovered = false }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        themeObserver.sourceWindow = window
        updateHoverColor()
    }
    override func layout() {
        super.layout()
        updateHoverGeometry()
    }
    override func drawBackground(in dirtyRect: NSRect) {}
    func hoverStateDidChange(_ hovered: Bool) {}

    private func updateHoverGeometry() {
        guard hoverBounds != bounds else { return }
        hoverBounds = bounds
        // NSTableView can cache row backgrounds without calling drawBackground
        // for needsDisplay on the row. Commit hover pixels independently of it.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        hoverBackground.frame = bounds
        let rect = bounds.insetBy(dx: 2, dy: 1)
        hoverBackground.path = rect.isEmpty ? nil :
            CGPath(roundedRect: rect, cornerWidth: 5, cornerHeight: 5, transform: nil)
    }

    private func updateHoverColor() {
        let color = OMGNativeTheme.resolve(for: self).hoverFill.cgColor
        guard hoverBackground.fillColor != color else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverBackground.fillColor = color
        CATransaction.commit()
    }

    private func updateHoverVisibility() {
        let hidden = !isHovered || isSelected
        guard hoverBackground.isHidden != hidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverBackground.isHidden = hidden
        CATransaction.commit()
    }
}
