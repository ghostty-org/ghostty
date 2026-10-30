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
    var menu: [NativeMenuEntry] = []
    let action: (NSButton) -> Void
    @Environment(\.isEnabled) private var environmentEnabled

    func makeNSView(context: Context) -> NativeActionControl { NativeActionControl() }

    func updateNSView(_ button: NativeActionControl, context: Context) {
        button.configure(title: title, symbol: symbol, help: help,
                         enabled: enabled && environmentEnabled, style: style, identifier: identifier)
        button.setAccessibilityValue(accessibilityValue)
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
    var onPress: (() -> Void)?
    var contextEntries: [NativeMenuEntry] = []
    private(set) var theme = OMGNativeTheme(background: .windowBackgroundColor, foreground: .labelColor)
    private let themeObserver = OMGNativeThemeObserver()
    private var tracking: NSTrackingArea?
    private(set) var isHovered = false
    private(set) var isMenuOpen = false
    private var actionStyle: NativeActionStyle = .plain
    var controlStyle: NativeActionStyle {
        get { actionStyle }
        set { actionStyle = newValue; needsDisplay = true }
    }
    override var isFlipped: Bool { true }
    override var alignmentRectInsets: NSEdgeInsets { .init(top: 0, left: 0, bottom: 0, right: 0) }
    override var isEnabled: Bool { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setButtonType(.momentaryPushIn)
        controlSize = .small
        font = .systemFont(ofSize: 11, weight: .medium)
        target = self
        action = #selector(activate)
        isBordered = false
        focusRingType = .none
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        themeObserver.onChange = { [weak self] in self?.applyTheme($0) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, symbol: String?, help: String?, enabled: Bool,
                   style: NativeActionStyle, identifier: String?) {
        self.title = title
        image = symbol.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        }
        imagePosition = symbol == nil ? .noImage : title.isEmpty ? .imageOnly : .imageLeading
        isEnabled = enabled
        actionStyle = style
        isBordered = false
        cell?.lineBreakMode = .byTruncatingTail
        toolTip = help
        setAccessibilityLabel(title.isEmpty ? help : title)
        setAccessibilityIdentifier(identifier)
        invalidateIntrinsicContentSize()
        applyTheme(.resolve(for: self))
    }

    func applyTheme(_ theme: OMGNativeTheme) {
        self.theme = theme
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        themeObserver.sourceWindow = window?.sheetParent ?? window
        applyTheme(.resolve(for: self))
    }

    override var intrinsicContentSize: NSSize {
        let textWidth = (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 11)]).width
        return NSSize(width: max(24, ceil(textWidth) + (image == nil ? 0 : 14) +
                                (image != nil && !title.isEmpty ? 5 : 0) + (title.isEmpty ? 0 : 16)), height: 28)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        tracking = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }
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
        if isMenuOpen || isHighlighted { return theme.selectedFill }
        if actionStyle == .prominent { return theme.accent.withAlphaComponent(isHovered ? 0.32 : 0.23) }
        if isHovered { return theme.hoverFill }
        return actionStyle == .bordered ? theme.controlFill : .clear
    }

    /// Explicit geometry avoids platform bezel/image padding moving icon-only glyphs off-center.
    var glyphRect: NSRect {
        let textWidth = title.isEmpty ? 0 : min(max(0, bounds.width - 35),
            ceil((title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 11)]).width))
        let width: CGFloat = image == nil ? 0 : 12
        let gap: CGFloat = image != nil && !title.isEmpty ? 5 : 0
        return NSRect(x: alignment == .left && !title.isEmpty ? 8 : (bounds.width - textWidth - width - gap) / 2,
                      y: (bounds.height - width) / 2, width: width, height: width)
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
