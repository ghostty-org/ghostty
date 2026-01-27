import AppKit

final class WorktrunkToolbar: NSToolbar, NSToolbarDelegate {
    private weak var targetController: TerminalController?
    private let titleTextField = CenteredDynamicLabel(labelWithString: " ")
    private var titleFont: NSFont?
    private var titleColor: NSColor?

    var titleText: String {
        get { titleTextField.stringValue }
        set {
            titleTextField.stringValue = newValue
            updateTitleAttributes()
        }
    }

    var titleTextFont: NSFont? {
        get { titleFont }
        set {
            titleFont = newValue
            updateTitleAttributes()
        }
    }

    var titleTextColor: NSColor? {
        get { titleColor }
        set {
            titleColor = newValue
            updateTitleAttributes()
        }
    }

    init(target: TerminalController?) {
        self.targetController = target
        super.init(identifier: NSToolbar.Identifier("WorktrunkToolbar.v2"))
        delegate = self
        displayMode = .iconOnly
        allowsUserCustomization = false
        autosavesConfiguration = false
        updateTitleAttributes()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .worktrunkTitleText, .flexibleSpace]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .worktrunkTitleText, .flexibleSpace]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .worktrunkTitleText:
            let item = NSToolbarItem(itemIdentifier: .worktrunkTitleText)
            item.view = titleTextField
            item.visibilityPriority = .user
            item.isEnabled = true
            item.isBordered = false
            titleTextField.translatesAutoresizingMaskIntoConstraints = false
            titleTextField.setContentHuggingPriority(.defaultLow, for: .horizontal)
            titleTextField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            NSLayoutConstraint.activate([
                titleTextField.heightAnchor.constraint(equalToConstant: 22),
            ])
            return item
        case .toggleSidebar:
            let item = NSToolbarItem(itemIdentifier: .toggleSidebar)
            let button = NSButton(frame: NSRect(x: 0, y: 0, width: 38, height: 22))
            button.bezelStyle = .toolbar
            button.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle Sidebar")
            button.imagePosition = .imageOnly
            button.target = targetController
            button.action = #selector(TerminalController.toggleSidebar(_:))
            item.view = button
            item.label = "Toggle Sidebar"
            item.isNavigational = true
            return item
        default:
            return NSToolbarItem(itemIdentifier: itemIdentifier)
        }
    }

    private func updateTitleAttributes() {
        let text = titleTextField.stringValue.isEmpty ? " " : titleTextField.stringValue
        let baseFont = titleFont ?? NSFont.titleBarFont(ofSize: NSFont.systemFontSize)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: baseFont.withSize(baseFont.pointSize + 1),
            .foregroundColor: titleColor ?? NSColor.labelColor,
        ]
        titleTextField.attributedStringValue = NSAttributedString(string: text, attributes: attributes)
    }
}

extension NSToolbarItem.Identifier {
    static let worktrunkTitleText = NSToolbarItem.Identifier("WorktrunkTitleText")
}

private class CenteredDynamicLabel: NSTextField {
    override func viewDidMoveToSuperview() {
        isEditable = false
        isBordered = false
        drawsBackground = false
        alignment = .center
        lineBreakMode = .byTruncatingTail
        cell?.truncatesLastVisibleLine = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let attributedString = attributedStringValue.mutableCopy() as? NSMutableAttributedString else {
            super.draw(dirtyRect)
            return
        }

        let textSize = attributedString.size()
        let yOffset = (bounds.height - textSize.height) / 2 - 1
        let centeredRect = NSRect(
            x: bounds.origin.x,
            y: bounds.origin.y + yOffset,
            width: bounds.width,
            height: textSize.height
        )
        attributedString.draw(in: centeredRect)
    }
}
