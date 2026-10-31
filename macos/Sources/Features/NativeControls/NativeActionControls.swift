import AppKit
import SwiftUI

enum NativeActionStyle {
    case plain, bordered, prominent
}

/// Layout may remain declarative; activation, accessibility and menus belong to AppKit.
struct NativeActionButton: NSViewRepresentable {
    var title = ""
    var symbol: String?
    var help: String?
    var enabled = true
    var style: NativeActionStyle = .plain
    var height: CGFloat = 28
    var expands = false
    var identifier: String?
    var accessibilityValue: String?
    var showsHover = true
    var menu: [NativeMenuEntry] = []
    let action: (NSButton) -> Void
    @Environment(\.isEnabled) private var environmentEnabled

    func makeNSView(context: Context) -> NativeActionControl { NativeActionControl() }

    func updateNSView(_ button: NativeActionControl, context: Context) {
        button.configure(title: title, symbol: symbol, help: help,
                         enabled: enabled && environmentEnabled, style: style, identifier: identifier)
        button.setAccessibilityValue(accessibilityValue)
        button.showsHover = showsHover
        button.onPress = { [weak button] in
            guard let button else { return }
            action(button)
        }
        button.contextEntries = menu
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeActionControl, context: Context) -> CGSize? {
        CGSize(width: expands ? (proposal.width ?? nsView.intrinsicContentSize.width)
                              : max(title.isEmpty ? height : 0, nsView.intrinsicContentSize.width),
               height: height)
    }
}

indirect enum NativeMenuEntry {
    case action(String, symbol: String? = nil, enabled: Bool = true, checked: Bool = false, handler: () -> Void)
    case submenu(String, entries: [NativeMenuEntry])
    case separator
}

struct NativeMenuButton: NSViewRepresentable {
    var title = ""
    var symbol: String? = "chevron.down"
    var help: String?
    var enabled = true
    var style: NativeActionStyle = .plain
    var height: CGFloat = 28
    var expands = false
    var identifier: String?
    let entries: [NativeMenuEntry]
    @Environment(\.isEnabled) private var environmentEnabled

    func makeNSView(context: Context) -> NativeActionControl { NativeActionControl() }

    func updateNSView(_ button: NativeActionControl, context: Context) {
        button.configure(title: title, symbol: symbol, help: help,
                         enabled: enabled && environmentEnabled, style: style, identifier: identifier)
        button.onPress = { [weak button] in
            guard let button, button.window != nil else { return }
            button.showMenu(NativeActionMenu.make(entries))
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeActionControl, context: Context) -> CGSize? {
        CGSize(width: expands ? (proposal.width ?? nsView.intrinsicContentSize.width)
                              : max(title.isEmpty ? height : 0, nsView.intrinsicContentSize.width),
               height: height)
    }
}

class NativeActionControl: NSButton, NSMenuDelegate {
    private static weak var hoveredControl: NativeActionControl?
    var showsHover = true { didSet { needsDisplay = true } }
    var onPress: (() -> Void)?
    var contextEntries: [NativeMenuEntry] = []
    private(set) var theme = OMGNativeTheme(background: .windowBackgroundColor, foreground: .labelColor)
    private let themeObserver = OMGNativeThemeObserver()
    private var tracking: NSTrackingArea?
    private(set) var isHovered = false
    private(set) var isMenuOpen = false
    private var actionStyle: NativeActionStyle = .plain
    private var configuredSymbol: String?
    var controlStyle: NativeActionStyle {
        get { actionStyle }
        set { actionStyle = newValue; needsDisplay = true }
    }
    override var isFlipped: Bool { true }
    // Explicit rendering contract, including subclasses with additional sublayers.
    override var wantsUpdateLayer: Bool { false }
    override var alignmentRectInsets: NSEdgeInsets { .init(top: 0, left: 0, bottom: 0, right: 0) }
    override var isEnabled: Bool { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Let AppKit clear the backing store before each draw; manual .copy clearing
        // punches holes through ancestors during composited/offscreen rendering.
        wantsLayer = true
        clipsToBounds = true
        setButtonType(.momentaryPushIn)
        controlSize = .small
        font = .systemFont(ofSize: 11, weight: .medium)
        target = self
        action = #selector(activate)
        isBordered = false
        focusRingType = .none
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        themeObserver.onChange = { [weak self] in self?.applyTheme($0) }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowChanged(_:)), name: name, object: nil)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, symbol: String?, help: String?, enabled: Bool,
                   style: NativeActionStyle, identifier: String?) {
        let titleChanged = self.title != title
        let imageChanged = configuredSymbol != symbol || (symbol == nil) != (image == nil)
        if titleChanged { self.title = title }
        if imageChanged {
            configuredSymbol = symbol
            image = symbol.flatMap {
                NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
            }
        }
        let position: NSControl.ImagePosition = symbol == nil ? .noImage : title.isEmpty ? .imageOnly : .imageLeading
        if imagePosition != position { imagePosition = position }
        if isEnabled != enabled { isEnabled = enabled }
        if actionStyle != style { actionStyle = style; needsDisplay = true }
        if isBordered { isBordered = false }
        if cell?.lineBreakMode != .byTruncatingTail { cell?.lineBreakMode = .byTruncatingTail }
        if toolTip != help { toolTip = help }
        setAccessibilityLabel(title.isEmpty ? help : title)
        setAccessibilityIdentifier(identifier)
        if titleChanged || imageChanged { invalidateIntrinsicContentSize() }
        applyTheme(.resolve(for: self))
    }

    func applyTheme(_ theme: OMGNativeTheme) {
        guard self.theme != theme else { return }
        self.theme = theme
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        themeObserver.sourceWindow = window?.sheetParent ?? window
        applyTheme(.resolve(for: self))
        refreshHover()
    }

    override var intrinsicContentSize: NSSize {
        let textWidth = (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 11)]).width
        return NSSize(width: max(24, ceil(textWidth) + (image == nil ? 0 : 14) +
                                (image != nil && !title.isEmpty ? 5 : 0) + (title.isEmpty ? 0 : 16)), height: 28)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if tracking == nil {
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self)
            tracking = area
            addTrackingArea(area)
        }
        refreshHover()
    }

    @objc private func refreshHover() {
        setHovered(NativePointerLocation.contains(self))
    }
    @objc private func windowChanged(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        refreshHover()
    }
    func setHovered(_ hovered: Bool) {
        if hovered {
            if let previous = Self.hoveredControl, previous !== self {
                previous.isHovered = false
                previous.needsDisplay = true
            }
            Self.hoveredControl = self
        } else if Self.hoveredControl === self {
            Self.hoveredControl = nil
        }
        guard isHovered != hovered else { return }
        isHovered = hovered
        needsDisplay = true
    }
    override func mouseEntered(with event: NSEvent) { refreshHover() }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
    override func highlight(_ flag: Bool) { super.highlight(flag); needsDisplay = true }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        needsDisplay = true
        return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        needsDisplay = true
        return result
    }

    var effectiveFill: NSColor {
        if !isEnabled { return actionStyle == .plain ? .clear : theme.controlFill }
        if isMenuOpen || (isHighlighted && NativePointerLocation.contains(self)) { return theme.selectedFill }
        if actionStyle == .prominent { return theme.accent.withAlphaComponent(isHovered ? 0.32 : 0.23) }
        if isHovered && showsHover { return theme.hoverFill }
        return actionStyle == .bordered ? theme.controlFill : .clear
    }

    /// Explicit geometry avoids platform bezel/image padding moving icon-only glyphs off-center.
    var glyphRect: NSRect {
        let textWidth = title.isEmpty ? 0 : min(max(0, bounds.width - 35),
            ceil((title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 11)]).width))
        let size = image?.withSymbolConfiguration(.init(pointSize: 12, weight: .medium))?.size ?? image?.size ?? .zero
        // Use SF Symbols' optical metrics, only shrinking symbols that exceed the slot.
        let scale = max(size.width, size.height) > 0 ? min(1, 16 / max(size.width, size.height)) : 0
        let width = size.width * scale
        let height = size.height * scale
        let gap: CGFloat = image != nil && !title.isEmpty ? 5 : 0
        return NSRect(x: alignment == .left && !title.isEmpty ? 8 : (bounds.width - textWidth - width - gap) / 2,
                      y: (bounds.height - height) / 2, width: width, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        effectiveFill.setFill()
        shape.fill()
        if actionStyle != .plain || isMenuOpen || window?.firstResponder === self {
            (isEnabled && (isMenuOpen || window?.firstResponder === self)
                ? theme.accent.withAlphaComponent(0.55) : theme.border).setStroke()
            shape.lineWidth = 0.5
            shape.stroke()
        }
        let color = isEnabled ? theme.foreground : theme.disabled
        if let image {
            let tinted = NSImage(size: image.size, flipped: false) { rect in
                image.draw(in: rect)
                color.withAlphaComponent(1).setFill()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: color.alphaComponent,
                        respectFlipped: true, hints: nil)
        }
        if !title.isEmpty {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = image == nil ? alignment : .left
            paragraph.lineBreakMode = .byTruncatingTail
            let text = NSAttributedString(string: title, attributes: [
                .font: font ?? NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: color, .paragraphStyle: paragraph,
            ])
            let x = image == nil ? 7 : glyphRect.maxX + 5
            text.draw(in: NSRect(x: x, y: floor((bounds.height - text.size().height) / 2),
                                width: max(0, bounds.width - x - 7), height: text.size().height))
        }
    }

    func showMenu(_ menu: NSMenu) {
        guard isEnabled, window != nil else { return }
        menu.delegate = self
        isMenuOpen = true
        needsDisplay = true
        defer { isMenuOpen = false; needsDisplay = true }
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.minX, y: bounds.maxY), in: self)
    }

    func menuWillOpen(_ menu: NSMenu) { isMenuOpen = true; needsDisplay = true }
    func menuDidClose(_ menu: NSMenu) { isMenuOpen = false; needsDisplay = true }
    func setPresentationActive(_ active: Bool) { isMenuOpen = active; needsDisplay = true }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard isEnabled, !contextEntries.isEmpty else { return super.menu(for: event) }
        let menu = NativeActionMenu.make(contextEntries)
        menu.delegate = self
        return menu
    }

    @objc private func activate() {
        guard isEnabled else { return }
        onPress?()
    }
}

enum NativePointerLocation {
    static func contains(_ view: NSView) -> Bool {
        guard let window = view.window, window.isKeyWindow, window.isVisible,
              !view.isHiddenOrHasHiddenAncestor else { return false }
        let screenPoint = NSEvent.mouseLocation
        let point = view.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        guard view.visibleRect.contains(point) else { return false }
        return NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0) == window.windowNumber
    }
}

enum NativeActionMenu {
    static func make(_ entries: [NativeMenuEntry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .submenu(let title, let entries):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.submenu = make(entries)
                menu.addItem(item)
            case .action(let title, let symbol, let enabled, let checked, let handler):
                let invocation = NativeMenuInvocation(handler)
                let item = NSMenuItem(title: title, action: #selector(NativeMenuInvocation.invoke(_:)), keyEquivalent: "")
                item.representedObject = invocation
                item.target = invocation
                item.isEnabled = enabled
                item.state = checked ? .on : .off
                item.image = checked && symbol == "checkmark" ? nil :
                    symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
                menu.addItem(item)
            }
        }
        return menu
    }
}

private final class NativeMenuInvocation: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }

    @objc func invoke(_ sender: NSMenuItem) {
        guard sender.isEnabled else { return }
        handler()
    }
}
