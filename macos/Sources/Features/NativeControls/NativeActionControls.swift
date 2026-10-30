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
            NativeActionMenu.make(entries).popUp(positioning: nil,
                                                at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeActionControl, context: Context) -> CGSize? {
        CGSize(width: expands ? (proposal.width ?? nsView.intrinsicContentSize.width)
                              : max(title.isEmpty ? height : 0, nsView.intrinsicContentSize.width),
               height: height)
    }
}

final class NativeActionControl: NSButton {
    var onPress: (() -> Void)?
    var contextEntries: [NativeMenuEntry] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setButtonType(.momentaryPushIn)
        controlSize = .small
        font = .systemFont(ofSize: 11, weight: .medium)
        target = self
        action = #selector(activate)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, symbol: String?, help: String?, enabled: Bool,
                   style: NativeActionStyle, identifier: String?) {
        self.title = title
        image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        imagePosition = symbol == nil ? .noImage : title.isEmpty ? .imageOnly : .imageLeading
        isEnabled = enabled
        isBordered = style != .plain
        bezelStyle = .rounded
        bezelColor = style == .prominent ? .controlAccentColor : nil
        contentTintColor = style == .prominent ? .white : nil
        cell?.lineBreakMode = .byTruncatingTail
        toolTip = help
        setAccessibilityLabel(title.isEmpty ? help : title)
        setAccessibilityIdentifier(identifier)
        invalidateIntrinsicContentSize()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard isEnabled, !contextEntries.isEmpty else { return super.menu(for: event) }
        return NativeActionMenu.make(contextEntries)
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
