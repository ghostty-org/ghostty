import AppKit

/// Everything displayed by a single row of the tab sidebar.
struct TabSidebarRowContent: Equatable {
    let title: String
    let subtitle: String?
    let shortcut: String?
    let color: TerminalTabColor
    let isCurrent: Bool
    let isZoomed: Bool

    /// The coding agent running in the focused surface, or nil for anything else.
    let agent: TabSidebarAgent?

    @MainActor
    init(controller: TerminalController, index: Int, isCurrent: Bool) {
        let window = controller.window as? TerminalWindow

        // The window title is already the title override (if any) or the
        // computed title of the focused surface.
        let text = TabSidebarLogic.rowText(
            title: controller.window?.title ?? "",
            isOverride: controller.titleOverride != nil,
            pwd: controller.focusedSurface?.pwd)
        self.title = text.title
        self.subtitle = text.subtitle
        self.agent = controller.focusedSurface?.surfaceModel?.foregroundPID.flatMap(TabSidebarAgent.detect(pid:))

        // This mirrors `relabelTabs` but is based on the row index so it is never stale.
        if index < 9, let equiv = controller.ghostty.config.keyboardShortcut(for: "goto_tab:\(index + 1)") {
            self.shortcut = "\(equiv)"
        } else {
            self.shortcut = nil
        }

        self.color = window?.tabColor ?? .none
        self.isCurrent = isCurrent
        self.isZoomed = window?.surfaceIsZoomed ?? false
    }

    init(
        title: String,
        subtitle: String? = nil,
        shortcut: String? = nil,
        color: TerminalTabColor = .none,
        isCurrent: Bool = false,
        isZoomed: Bool = false,
        agent: TabSidebarAgent? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.shortcut = shortcut
        self.color = color
        self.isCurrent = isCurrent
        self.isZoomed = isZoomed
        self.agent = agent
    }
}

/// The row view draws the (optionally tinted) rounded background of a row and tracks hover.
final class TabSidebarRowView: NSTableRowView {
    var content: TabSidebarRowContent? {
        didSet {
            guard content != oldValue else { return }
            needsDisplay = true
        }
    }

    /// True for the row selected with the arrow keys while searching.
    var isSearchHighlighted: Bool = false {
        didSet {
            guard isSearchHighlighted != oldValue else { return }
            needsDisplay = true
        }
    }

    private(set) var isHovered: Bool = false {
        didSet {
            guard isHovered != oldValue else { return }
            needsDisplay = true
            cellView?.isHovered = isHovered
        }
    }

    private var cellView: TabSidebarCellView? {
        numberOfColumns > 0 ? view(atColumn: 0) as? TabSidebarCellView : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncHoverWithMouseLocation()
    }

    /// Rows are reused and reloaded while the mouse doesn't move, so we
    /// can't rely only on enter/exit events.
    func syncHoverWithMouseLocation() {
        guard let window else {
            isHovered = false
            return
        }

        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        isHovered = bounds.contains(point)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard let content else { return }

        let fill: NSColor?
        if let tint = content.color.displayColor {
            let alpha: CGFloat = content.isCurrent ? 0.38 : (isHovered ? 0.26 : 0.18)
            fill = tint.withAlphaComponent(alpha)
        } else if content.isCurrent {
            fill = NSColor.labelColor.withAlphaComponent(0.10)
        } else if isHovered {
            fill = NSColor.labelColor.withAlphaComponent(0.05)
        } else {
            fill = nil
        }

        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 10, dy: 2),
            xRadius: 8,
            yRadius: 8
        )
        if let fill {
            fill.setFill()
            path.fill()
        }

        // The search highlight must be visible on the current (filled) row too.
        if isSearchHighlighted {
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    // We draw our own highlight for the current tab.
    override func drawSelection(in dirtyRect: NSRect) {}
}

/// The cell view shows the title, working directory, shortcut and close button of a tab.
final class TabSidebarCellView: NSTableCellView {
    private let iconView: NSImageView = {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setAccessibilityIdentifier("TabSidebarIcon")
        return view
    }()

    /// The icon shown for tabs that don't run a known agent.
    private static let terminalIcon: NSImage? = NSImage(
        systemSymbolName: "terminal",
        accessibilityDescription: "Terminal"
    )?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))

    let titleField: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 13, weight: .medium)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }()

    private let subtitleField: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingHead
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }()

    private let shortcutLabel: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 11)
        field.textColor = .tertiaryLabelColor
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        field.setContentHuggingPriority(.required, for: .horizontal)
        return field
    }()

    private lazy var zoomButton: NSButton = makeAccessoryButton(
        image: NSImage(named: "ResetZoom"),
        toolTip: "Reset Split Zoom",
        identifier: "TabSidebarZoomButton",
        action: #selector(zoomClicked(_:)))

    private lazy var closeButton: NSButton = makeAccessoryButton(
        image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab"),
        toolTip: "Close Tab",
        identifier: "TabSidebarCloseButton",
        action: #selector(closeClicked(_:)))

    /// Called when the close button is clicked.
    var onClose: (() -> Void)?

    /// Called when the reset zoom button is clicked.
    var onResetZoom: (() -> Void)?

    /// When true, the title field is being edited and must not be overwritten.
    var isEditingTitle: Bool = false {
        didSet { updateAccessoryVisibility() }
    }

    var isHovered: Bool = false {
        didSet { updateAccessoryVisibility() }
    }

    private var content: TabSidebarRowContent?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        textField = titleField

        let textStack = NSStackView(views: [titleField, subtitleField])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(iconView)
        addSubview(textStack)

        // Share a trailing slot without collapsing it when the close button or
        // shortcut is hidden. This keeps the close button fixed at the row edge.
        let trailingSlot = NSView()
        trailingSlot.translatesAutoresizingMaskIntoConstraints = false
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        trailingSlot.addSubview(shortcutLabel)
        trailingSlot.addSubview(closeButton)
        let slotWidth = trailingSlot.widthAnchor.constraint(equalToConstant: 24)
        slotWidth.priority = .defaultLow

        // The stack is stretched to the text, so the accessories must be pushed to its
        // trailing end. Otherwise the slot sits at its leading end, the close button
        // lies outside of the slot and clicks on it never reach the button.
        let accessoryStack = NSStackView(views: [])
        accessoryStack.setViews([zoomButton, trailingSlot], in: .trailing)
        accessoryStack.orientation = .horizontal
        accessoryStack.alignment = .centerY
        accessoryStack.spacing = 8
        accessoryStack.translatesAutoresizingMaskIntoConstraints = false
        accessoryStack.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(accessoryStack)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(equalTo: accessoryStack.leadingAnchor, constant: -10),
            titleField.widthAnchor.constraint(equalTo: textStack.widthAnchor),
            subtitleField.widthAnchor.constraint(lessThanOrEqualTo: textStack.widthAnchor),
            accessoryStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            accessoryStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            slotWidth,
            trailingSlot.widthAnchor.constraint(greaterThanOrEqualToConstant: 24),
            trailingSlot.heightAnchor.constraint(equalToConstant: 24),
            shortcutLabel.leadingAnchor.constraint(greaterThanOrEqualTo: trailingSlot.leadingAnchor),
            shortcutLabel.trailingAnchor.constraint(equalTo: trailingSlot.trailingAnchor),
            shortcutLabel.centerYAnchor.constraint(equalTo: trailingSlot.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingSlot.trailingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: trailingSlot.centerYAnchor),
        ])

        updateAccessoryVisibility()
    }

    private func makeAccessoryButton(
        image: NSImage?,
        toolTip: String,
        identifier: String,
        action: Selector
    ) -> NSButton {
        let button = NSButton()
        button.image = image
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.refusesFirstResponder = true
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = toolTip
        button.setAccessibilityLabel(toolTip)
        button.target = self
        button.action = action
        button.setAccessibilityIdentifier(identifier)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 24),
        ])
        return button
    }

    func configure(with content: TabSidebarRowContent) {
        self.content = content

        if !isEditingTitle {
            titleField.stringValue = content.title
            titleField.toolTip = content.title
        }
        titleField.textColor = content.isCurrent ? .labelColor : .secondaryLabelColor
        setAccessibilityLabel(content.title)

        subtitleField.stringValue = content.subtitle ?? ""

        shortcutLabel.stringValue = content.shortcut ?? ""
        updateIcon()
        updateAccessoryVisibility()
    }

    private func updateIcon() {
        if let agent = content?.agent, let image = NSImage(named: agent.imageName) {
            image.isTemplate = true
            iconView.image = image
            iconView.contentTintColor = agent.tintColor ?? .labelColor
            iconView.toolTip = agent.displayName
            iconView.setAccessibilityLabel(agent.displayName)
        } else {
            iconView.image = Self.terminalIcon
            iconView.contentTintColor = content?.isCurrent == true ? .labelColor : .secondaryLabelColor
            iconView.toolTip = nil
            iconView.setAccessibilityLabel("Terminal")
        }
    }

    private func updateAccessoryVisibility() {
        // On hover the close button replaces the shortcut hint.
        subtitleField.isHidden = isEditingTitle || content?.subtitle == nil
        zoomButton.isHidden = isEditingTitle || content?.isZoomed != true
        closeButton.isHidden = isEditingTitle || !isHovered
        shortcutLabel.isHidden = isEditingTitle || isHovered || (content?.shortcut ?? "").isEmpty
    }

    @objc private func closeClicked(_ sender: Any?) {
        onClose?()
    }

    @objc private func zoomClicked(_ sender: Any?) {
        onResetZoom?()
    }
}
