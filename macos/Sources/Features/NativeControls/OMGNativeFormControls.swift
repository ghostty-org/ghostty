import AppKit

final class OMGNativeTextField: NSTextField, OMGNativeThemeApplying {
    private(set) var theme = OMGNativeTheme(background: .windowBackgroundColor, foreground: .labelColor)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = OMGNativeTextCell(textCell: "")
        isEditable = true
        isSelectable = true
        isBezeled = true
        drawsBackground = false
        focusRingType = .none
        font = .systemFont(ofSize: 12)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var alignmentRectInsets: NSEdgeInsets { .init(top: 0, left: 0, bottom: 0, right: 0) }

    func applyTheme(_ theme: OMGNativeTheme) {
        self.theme = theme
        textColor = isEnabled ? theme.foreground : theme.disabled
        (currentEditor() as? NSTextView)?.textColor = textColor
        (currentEditor() as? NSTextView)?.drawsBackground = false
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTheme(.resolve(for: self))
    }
}

private final class OMGNativeTextCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let height = ceil((font ?? .systemFont(ofSize: 12)).boundingRectForFont.height)
        return NSRect(x: rect.minX + 8, y: rect.midY - height / 2, width: max(0, rect.width - 16), height: height)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard let field = controlView as? OMGNativeTextField else { return }
        let shape = NSBezierPath(roundedRect: cellFrame.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        field.theme.controlFill.setFill()
        shape.fill()
        (field.currentEditor() == nil ? field.theme.border : field.theme.accent.withAlphaComponent(0.5)).setStroke()
        shape.lineWidth = 0.5
        shape.stroke()
        super.drawInterior(withFrame: cellFrame, in: controlView)
    }
}

final class OMGNativePopUpButton: NSPopUpButton, OMGNativeThemeApplying {
    override var wantsUpdateLayer: Bool { false }
    private(set) var theme = OMGNativeTheme(background: .windowBackgroundColor, foreground: .labelColor)
    private var hovered = false
    private var tracking: NSTrackingArea?
    private(set) var options: NSPopover?
    override var isFlipped: Bool { true }
    override var alignmentRectInsets: NSEdgeInsets { .init(top: 0, left: 0, bottom: 0, right: 0) }

    func applyTheme(_ theme: OMGNativeTheme) { self.theme = theme; needsDisplay = true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { options?.close(); options = nil }
        wantsLayer = true
        applyTheme(.resolve(for: self))
    }

    override func mouseDown(with event: NSEvent) { showOptions() }
    override func performClick(_ sender: Any?) { showOptions() }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        showOptions()
        return true
    }
    override func keyDown(with event: NSEvent) {
        if [36, 49, 125, 126].contains(event.keyCode) { showOptions() } else { super.keyDown(with: event) }
    }
    private func showOptions() {
        guard isEnabled, let window else { return }
        if options?.isShown == true { options?.close(); return }
        let entries: [NativeMenuEntry] = itemArray.enumerated().map { index, item in
            .action(item.title, enabled: item.isEnabled, checked: index == indexOfSelectedItem) {}
        }
        let controller = NativeActionPopoverController(entries: entries)
        let popup = NSPopover()
        popup.behavior = .transient
        popup.animates = false
        controller.surface.bindTheme(to: window)
        controller.onCancel = { [weak popup] in popup?.close() }
        controller.onSelect = { [weak self, weak popup] index in
            guard let self, self.isEnabled, self.itemArray.indices.contains(index), self.itemArray[index].isEnabled else { return }
            popup?.close()
            self.selectItem(at: index)
            self.needsDisplay = true
            if let action = self.action { self.sendAction(action, to: self.target) }
        }
        popup.contentViewController = controller
        popup.contentSize = controller.preferredContentSize
        options = popup
        popup.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        controller.focusFirstOption()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        tracking = area
        addTrackingArea(area)
    }
    override func mouseEntered(with event: NSEvent) { hovered = NativePointerLocation.contains(self); needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        (isHighlighted ? theme.selectedFill : hovered && isEnabled ? theme.hoverFill : theme.controlFill).setFill()
        shape.fill()
        theme.border.setStroke()
        shape.lineWidth = 0.5
        shape.stroke()
        let color = isEnabled ? theme.foreground : theme.disabled
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: titleOfSelectedItem ?? "", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: color, .paragraphStyle: paragraph,
        ])
        text.draw(in: NSRect(x: 8, y: floor((bounds.height - text.size().height) / 2),
                            width: max(0, bounds.width - 32), height: text.size().height))
        let chevron = NSBezierPath()
        chevron.move(to: NSPoint(x: bounds.width - 18, y: bounds.midY - 2))
        chevron.line(to: NSPoint(x: bounds.width - 14, y: bounds.midY + 2))
        chevron.line(to: NSPoint(x: bounds.width - 10, y: bounds.midY - 2))
        color.setStroke()
        chevron.lineWidth = 1
        chevron.stroke()
        if window?.firstResponder === self {
            theme.accent.withAlphaComponent(0.5).setStroke()
            shape.stroke()
        }
    }
}
