import Cocoa

@MainActor
struct GhosttyCustomTabItem {
    let id: UUID
    let title: String
}

@MainActor
protocol GhosttyCustomTabBarDelegate: AnyObject {
    func tabBarDidSelectTab(at index: Int)
    func tabBarDidRequestNewTab()
    func tabBarDidRequestCloseTab(at index: Int)
}

@MainActor
final class GhosttyCustomTabBar: NSView {
    static let barHeight: CGFloat = 28

    weak var delegate: GhosttyCustomTabBarDelegate?

    var allowsWindowDrag: Bool = false

    private var items: [GhosttyCustomTabItem] = []
    private var selectedIndex: Int = 0
    private var hoveredIndex: Int = -1
    private var hoveredCloseIndex: Int = -1
    private var hoverTrackingAreas: [NSTrackingArea] = []
    private var dragEvent: NSEvent?

    private let tabMinWidth: CGFloat = 100
    private let tabMaxWidth: CGFloat = 200
    private let newTabButtonWidth: CGFloat = 28
    private let closeButtonSize: CGFloat = 14
    private let tabPadding: CGFloat = 8

    private var backgroundFillColor: NSColor = NSColor(white: 0.1, alpha: 0.95)
    private var selectedFillColor: NSColor = NSColor(white: 0.2, alpha: 1)
    private var hoverFillColor: NSColor = NSColor(white: 0.15, alpha: 1)
    private var separatorColor: NSColor = NSColor(white: 0.25, alpha: 1)
    private var titleColor: NSColor = NSColor(white: 0.6, alpha: 1)
    private var selectedTitleColor: NSColor = .white
    private var secondaryControlColor: NSColor = NSColor(white: 0.5, alpha: 1)
    private var closeHoverFillColor: NSColor = NSColor(white: 0.35, alpha: 1)

    override var isFlipped: Bool { true }

    func update(
        items: [GhosttyCustomTabItem],
        selectedIndex: Int,
        backgroundColor: NSColor,
        isKeyWindow: Bool,
        allowsWindowDrag: Bool
    ) {
        self.items = items
        self.selectedIndex = selectedIndex
        self.allowsWindowDrag = allowsWindowDrag
        updatePalette(backgroundColor: backgroundColor, isKeyWindow: isKeyWindow)
        rebuildTrackingAreas()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        backgroundFillColor.setFill()
        dirtyRect.fill()

        let tabWidth = calculateTabWidth()
        for index in items.indices {
            let tabRect = NSRect(
                x: CGFloat(index) * tabWidth,
                y: 0,
                width: tabWidth,
                height: bounds.height
            )
            drawTab(at: index, in: tabRect)
        }

        let plusRect = NSRect(
            x: CGFloat(items.count) * tabWidth,
            y: 0,
            width: newTabButtonWidth,
            height: bounds.height
        )
        drawNewTabButton(in: plusRect)

        separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragEvent = nil

        if let index = tabIndex(at: point) {
            let tabWidth = calculateTabWidth()
            let tabRect = NSRect(
                x: CGFloat(index) * tabWidth,
                y: 0,
                width: tabWidth,
                height: bounds.height
            )
            let closeRect = closeButtonRect(for: index, tabRect: tabRect).insetBy(dx: -4, dy: -4)
            if closeRect.contains(point) {
                delegate?.tabBarDidRequestCloseTab(at: index)
                return
            }

            delegate?.tabBarDidSelectTab(at: index)
            return
        }

        if isNewTabButton(at: point) {
            delegate?.tabBarDidRequestNewTab()
            return
        }

        if allowsWindowDrag {
            dragEvent = event
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard allowsWindowDrag, let dragEvent else { return }
        self.dragEvent = nil
        window?.performDrag(with: dragEvent)
    }

    override func mouseUp(with event: NSEvent) {
        dragEvent = nil
        super.mouseUp(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = -1
        hoveredCloseIndex = -1
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        rebuildTrackingAreas()
    }

    private func drawTab(at index: Int, in rect: NSRect) {
        let isSelected = index == selectedIndex
        let isHovered = index == hoveredIndex

        if isSelected {
            selectedFillColor.setFill()
            rect.fill()
        } else if isHovered {
            hoverFillColor.setFill()
            rect.fill()
        }

        let title = items[index].title.isEmpty ? "Terminal" : items[index].title
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: isSelected ? selectedTitleColor : titleColor,
            .font: NSFont.systemFont(ofSize: 11, weight: isSelected ? .medium : .regular),
        ]

        let closeSpace: CGFloat = closeButtonSize + tabPadding
        let maxTextWidth = rect.width - tabPadding * 2 - closeSpace
        let attributed = NSAttributedString(string: title, attributes: attributes)
        let textSize = attributed.size()
        let textRect = NSRect(
            x: rect.minX + tabPadding,
            y: (rect.height - textSize.height) / 2,
            width: min(textSize.width, maxTextWidth),
            height: textSize.height
        )
        attributed.draw(
            with: textRect,
            options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin]
        )

        if isHovered || isSelected {
            let closeRect = closeButtonRect(for: index, tabRect: rect)
            let isCloseHovered = index == hoveredCloseIndex
            if isCloseHovered {
                closeHoverFillColor.setFill()
                let background = NSBezierPath(
                    roundedRect: closeRect.insetBy(dx: -2, dy: -2),
                    xRadius: 3,
                    yRadius: 3
                )
                background.fill()
            }

            let closeAttributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: isCloseHovered ? selectedTitleColor : secondaryControlColor,
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            ]
            let closeString = NSAttributedString(string: "×", attributes: closeAttributes)
            let closeSize = closeString.size()
            let drawRect = NSRect(
                x: closeRect.midX - closeSize.width / 2,
                y: closeRect.midY - closeSize.height / 2,
                width: closeSize.width,
                height: closeSize.height
            )
            closeString.draw(in: drawRect)
        }

        separatorColor.setFill()
        NSRect(x: rect.maxX - 0.5, y: 4, width: 0.5, height: rect.height - 8).fill()
    }

    private func drawNewTabButton(in rect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: secondaryControlColor,
            .font: NSFont.systemFont(ofSize: 14, weight: .light),
        ]
        let attributed = NSAttributedString(string: "+", attributes: attributes)
        let size = attributed.size()
        let drawRect = NSRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        attributed.draw(in: drawRect)
    }

    private func calculateTabWidth() -> CGFloat {
        guard !items.isEmpty else { return tabMinWidth }
        let availableWidth = bounds.width - newTabButtonWidth
        let perTabWidth = availableWidth / CGFloat(items.count)
        return min(max(perTabWidth, tabMinWidth), tabMaxWidth)
    }

    private func tabIndex(at point: NSPoint) -> Int? {
        let tabWidth = calculateTabWidth()
        let index = Int(point.x / tabWidth)
        guard index >= 0, index < items.count else { return nil }
        return index
    }

    private func isNewTabButton(at point: NSPoint) -> Bool {
        let tabWidth = calculateTabWidth()
        let plusX = CGFloat(items.count) * tabWidth
        return point.x >= plusX && point.x <= plusX + newTabButtonWidth
    }

    private func closeButtonRect(for index: Int, tabRect: NSRect) -> NSRect {
        NSRect(
            x: tabRect.maxX - tabPadding - closeButtonSize,
            y: (tabRect.height - closeButtonSize) / 2,
            width: closeButtonSize,
            height: closeButtonSize
        )
    }

    private func updateHover(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let oldHover = hoveredIndex
        let oldHoverClose = hoveredCloseIndex

        hoveredIndex = tabIndex(at: point) ?? -1
        hoveredCloseIndex = -1

        if hoveredIndex >= 0 {
            let tabWidth = calculateTabWidth()
            let tabRect = NSRect(
                x: CGFloat(hoveredIndex) * tabWidth,
                y: 0,
                width: tabWidth,
                height: bounds.height
            )
            let closeRect = closeButtonRect(for: hoveredIndex, tabRect: tabRect).insetBy(dx: -4, dy: -4)
            if closeRect.contains(point) {
                hoveredCloseIndex = hoveredIndex
            }
        }

        if hoveredIndex != oldHover || hoveredCloseIndex != oldHoverClose {
            needsDisplay = true
        }
    }

    private func rebuildTrackingAreas() {
        for area in hoverTrackingAreas {
            removeTrackingArea(area)
        }
        hoverTrackingAreas.removeAll()

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingAreas.append(area)
    }

    private func updatePalette(backgroundColor: NSColor, isKeyWindow: Bool) {
        let effectiveBackground = backgroundColor.withAlphaComponent(isKeyWindow ? 0.95 : 0.88)
        backgroundFillColor = effectiveBackground

        let isLight = backgroundColor.isLightColor
        if isLight {
            selectedFillColor = effectiveBackground.shadow(withLevel: 0.08) ?? effectiveBackground
            hoverFillColor = effectiveBackground.shadow(withLevel: 0.04) ?? effectiveBackground
            separatorColor = NSColor.black.withAlphaComponent(0.15)
            titleColor = NSColor.black.withAlphaComponent(0.65)
            selectedTitleColor = NSColor.black.withAlphaComponent(0.92)
            secondaryControlColor = NSColor.black.withAlphaComponent(0.45)
            closeHoverFillColor = NSColor.black.withAlphaComponent(0.12)
        } else {
            selectedFillColor = effectiveBackground.highlight(withLevel: 0.12) ?? effectiveBackground
            hoverFillColor = effectiveBackground.highlight(withLevel: 0.06) ?? effectiveBackground
            separatorColor = NSColor.white.withAlphaComponent(0.12)
            titleColor = NSColor.white.withAlphaComponent(0.62)
            selectedTitleColor = NSColor.white.withAlphaComponent(0.96)
            secondaryControlColor = NSColor.white.withAlphaComponent(0.5)
            closeHoverFillColor = NSColor.white.withAlphaComponent(0.14)
        }
    }
}
