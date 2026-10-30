import AppKit

/// One tracking area per table; pointer movement only invalidates the old and new rows.
final class NativeTableHover: NSObject {
    private weak var table: NSTableView?
    private weak var hoveredView: NativeHoverRowView?
    private var tracking: NSTrackingArea?

    init(table: NSTableView) {
        self.table = table
        super.init()
        for name in [NSView.boundsDidChangeNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didBecomeKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)), name: name, object: nil)
        }
    }

    @objc private func changed(_ notification: Notification) {
        guard let table else { return }
        if notification.name == NSView.boundsDidChangeNotification {
            guard notification.object as? NSClipView === table.enclosingScrollView?.contentView else { return }
        } else {
            guard notification.object as? NSWindow === table.window else { return }
        }
        refresh()
    }

    func update() {
        guard let table else { return }
        if let tracking { table.removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        tracking = area
        table.addTrackingArea(area)
        table.enclosingScrollView?.contentView.postsBoundsChangedNotifications = true
        refresh()
    }

    @objc private func refresh() {
        guard let table, NativePointerLocation.contains(table), let window = table.window else { setRow(nil); return }
        let point = table.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let index = table.row(at: point)
        setRow(index >= 0 ? table.rowView(atRow: index, makeIfNecessary: false) as? NativeHoverRowView : nil)
    }

    func setRow(_ row: NativeHoverRowView?) {
        guard hoveredView !== row else { return }
        hoveredView?.isHovered = false
        hoveredView = row
        row?.isHovered = true
    }
    @objc func mouseEntered(with event: NSEvent) { refresh() }
    @objc func mouseMoved(with event: NSEvent) { refresh() }
    @objc func mouseExited(with event: NSEvent) { setRow(nil) }
}

final class NativeHoverRowView: NSTableRowView {
    var isHovered = false { didSet { if oldValue != isHovered { needsDisplay = true } } }
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); isHovered = false }
    override func drawBackground(in dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)
        guard isHovered, !isSelected else { return }
        OMGNativeTheme.resolve(for: self).hoverFill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}
