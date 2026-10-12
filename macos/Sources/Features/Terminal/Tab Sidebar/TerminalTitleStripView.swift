import AppKit

/// A bar at the top of the terminal area that shows the title and working directory of
/// the tab. Tabs are listed in the tab sidebar, so the window titlebar doesn't show the
/// title; this bar does instead, right above the terminal it belongs to.
///
/// Like a titlebar, the bar can be dragged to move the window and double clicked to zoom
/// it (see `TerminalWindow.isTitlebarDoubleClick`).
final class TerminalTitleStripView: NSView {
    /// The height of the bar below the titlebar. It matches the sidebar header so both
    /// line up.
    static let contentHeight: CGFloat = 32

    /// The controller of the window that hosts this bar.
    private weak var controller: TerminalController?

    private let titleField: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 13, weight: .semibold)
        field.textColor = .labelColor
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        field.setContentHuggingPriority(.required, for: .horizontal)
        field.setAccessibilityIdentifier("TerminalTitleStripTitle")
        return field
    }()

    private let pathField: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 12)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingHead
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityIdentifier("TerminalTitleStripPath")
        return field
    }()

    /// The background, matching the terminal background.
    private var backgroundColor: NSColor = .windowBackgroundColor

    init(controller: TerminalController) {
        self.controller = controller
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        setAccessibilityIdentifier("TerminalTitleStrip")

        let stack = NSStackView(views: [titleField, pathField])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: bottomAnchor, constant: -Self.contentHeight / 2),
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onItemDidChange(_:)),
            name: .terminalTabSidebarItemDidChange,
            object: nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        update()
    }

    @objc private func onItemDidChange(_ notification: Notification) {
        guard window != nil, notification.object as? TerminalController === controller else { return }

        // Title and pwd publishers emit before their values change.
        DispatchQueue.main.async { [weak self] in
            self?.update()
        }
    }

    /// Updates the title and working directory from the controller.
    func update() {
        guard let controller else { return }
        let text = TabSidebarLogic.rowText(
            title: controller.window?.title ?? "",
            isOverride: controller.titleOverride != nil,
            pwd: controller.focusedSurface?.pwd)
        titleField.stringValue = text.title
        titleField.toolTip = text.title
        pathField.stringValue = text.subtitle ?? ""
        pathField.toolTip = controller.focusedSurface?.pwd
        pathField.isHidden = text.subtitle == nil
    }

    // MARK: Appearance

    /// Updates the bar so it matches the terminal background.
    func updateAppearance(backgroundColor: NSColor) {
        let base = backgroundColor.usingColorSpace(.sRGB) ?? backgroundColor
        self.backgroundColor = base
        appearance = NSAppearance(named: base.isLightColor ? .aqua : .darkAqua)
        needsDisplay = true
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        bounds.fill()

        // A hairline separating the bar from the terminal.
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: 1).fill()
    }

    // MARK: Mouse

    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.performTitlebarDoubleClickAction()
            return
        }

        window?.performDrag(with: event)
    }
}
