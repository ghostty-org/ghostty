import AppKit
import Quartz

/// A pane on the trailing edge of a terminal window that shows a file selected in the file
/// explorer. Text files are shown as read-only monospaced text, everything else with
/// Quick Look.
final class FilePreviewView: NSView {
    /// The file currently shown.
    private(set) var url: URL?

    /// Called when the close button is clicked.
    var onClose: (() -> Void)?

    private let header = NSView()

    private let iconView: NSImageView = {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let nameField: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 13, weight: .semibold)
        field.textColor = .labelColor
        field.lineBreakMode = .byTruncatingMiddle
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setAccessibilityIdentifier("FilePreviewName")
        return field
    }()

    private lazy var openButton = makeButton(
        symbol: "arrow.up.forward.app",
        toolTip: "Open with Default App",
        identifier: "FilePreviewOpenButton",
        action: #selector(openWithDefaultApp(_:)))

    private lazy var revealButton = makeButton(
        symbol: "folder",
        toolTip: "Reveal in Finder",
        identifier: "FilePreviewRevealButton",
        action: #selector(revealInFinder(_:)))

    private lazy var closeButton = makeButton(
        symbol: "xmark",
        toolTip: "Close Preview",
        identifier: "FilePreviewCloseButton",
        action: #selector(closeClicked(_:)))

    private let textScrollView: NSScrollView = {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        return scrollView
    }()

    private var textView: NSTextView? {
        textScrollView.documentView as? NSTextView
    }

    /// The Quick Look view, created the first time a file needs it.
    private var quickLookView: QLPreviewView?

    private let messageField: NSTextField = {
        let field = NSTextField(wrappingLabelWithString: "")
        field.font = .systemFont(ofSize: 12)
        field.textColor = .secondaryLabelColor
        field.alignment = .center
        return field
    }()

    private lazy var messageStack: NSStackView = {
        let button = NSButton(title: "Open with Default App", target: self, action: #selector(openWithDefaultApp(_:)))
        button.refusesFirstResponder = true
        let stack = NSStackView(views: [messageField, button])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private let resizeHandle = TabSidebarResizeHandle(
        edge: .leading,
        setWidth: { TabSidebarSettings.shared.setPreviewWidth($0, persist: $1) },
        resetWidth: {
            TabSidebarSettings.shared.setPreviewWidth(FileExplorerLogic.previewDefaultWidth, persist: true)
        })

    /// The body area below the header.
    private let body = NSView()

    /// The background, derived from the terminal background.
    private var backgroundColor: NSColor = .windowBackgroundColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Setup

    private func setup() {
        setAccessibilityIdentifier("FilePreview")

        let buttons = NSStackView(views: [openButton, revealButton, closeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 2
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.setContentHuggingPriority(.required, for: .horizontal)

        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(iconView)
        header.addSubview(nameField)
        header.addSubview(buttons)
        addSubview(header)

        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(body)

        if let textView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.drawsBackground = false
            textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            textView.textColor = .labelColor
            textView.textContainerInset = NSSize(width: 8, height: 8)
            textView.isAutomaticSpellingCorrectionEnabled = false
            textView.isContinuousSpellCheckingEnabled = false
            textView.setAccessibilityIdentifier("FilePreviewText")

            // Don't wrap lines, code reads better with horizontal scrolling.
            textView.isHorizontallyResizable = true
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude)
        }
        body.addSubview(textScrollView)
        body.addSubview(messageStack)

        resizeHandle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(resizeHandle)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: TerminalTitleStripView.contentHeight),

            iconView.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            nameField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            nameField.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            nameField.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -8),
            buttons.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            buttons.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            body.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 1),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),

            textScrollView.topAnchor.constraint(equalTo: body.topAnchor),
            textScrollView.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            textScrollView.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            textScrollView.bottomAnchor.constraint(equalTo: body.bottomAnchor),

            messageStack.centerYAnchor.constraint(equalTo: body.centerYAnchor),
            messageStack.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 24),
            messageStack.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -24),

            resizeHandle.topAnchor.constraint(equalTo: topAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: bottomAnchor),
            resizeHandle.leadingAnchor.constraint(equalTo: leadingAnchor),
            resizeHandle.widthAnchor.constraint(equalToConstant: 6),
        ])
    }

    private func makeButton(symbol: String, toolTip: String, identifier: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)
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

    // MARK: Content

    /// Shows the given file.
    func show(_ url: URL) {
        self.url = url
        iconView.image = NSWorkspace.shared.icon(forFile: url.path)
        nameField.stringValue = url.lastPathComponent
        nameField.toolTip = TabSidebarLogic.abbreviatePath(url.path)

        switch FileExplorerLogic.previewKind(for: url) {
        case .text:
            if let text = FileExplorerLogic.readText(url) {
                showText(text)
            } else {
                showQuickLook(url)
            }

        case .quickLook:
            showQuickLook(url)

        case .tooLarge:
            showMessage("This file is too large to preview.")
        }
    }

    private func showText(_ text: String) {
        textView?.string = text
        textView?.scroll(.zero)
        textScrollView.isHidden = false
        quickLookView?.isHidden = true
        messageStack.isHidden = true
    }

    private func showQuickLook(_ url: URL) {
        textView?.string = ""
        textScrollView.isHidden = true
        messageStack.isHidden = true

        let view = quickLookView ?? makeQuickLookView()
        view?.previewItem = url as NSURL
        view?.isHidden = false
        if view == nil { showMessage("This file can't be previewed.") }
    }

    private func showMessage(_ message: String) {
        textView?.string = ""
        textScrollView.isHidden = true
        quickLookView?.isHidden = true
        messageField.stringValue = message
        messageStack.isHidden = false
    }

    private func makeQuickLookView() -> QLPreviewView? {
        guard let view = QLPreviewView(frame: .zero, style: .normal) else { return nil }
        view.shouldCloseWithWindow = true
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setAccessibilityIdentifier("FilePreviewQuickLook")
        body.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: body.topAnchor),
            view.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: body.bottomAnchor),
        ])
        quickLookView = view
        return view
    }

    /// Releases the shown file, e.g. when the pane is closed.
    func clear() {
        url = nil
        textView?.string = ""
        quickLookView?.previewItem = nil
    }

    // MARK: Actions

    @objc private func openWithDefaultApp(_ sender: Any?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func revealInFinder(_ sender: Any?) {
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func closeClicked(_ sender: Any?) {
        onClose?()
    }

    // MARK: Appearance

    /// Updates the pane background so it matches the terminal background.
    func updateAppearance(backgroundColor: NSColor) {
        let base = backgroundColor.usingColorSpace(.sRGB) ?? backgroundColor
        let isLight = base.isLightColor
        let tint: NSColor = isLight ? .black : .white
        let blended = base.withAlphaComponent(1).blended(withFraction: 0.03, of: tint) ?? base
        self.backgroundColor = blended.withAlphaComponent(base.alphaComponent)
        appearance = NSAppearance(named: isLight ? .aqua : .darkAqua)
        needsDisplay = true
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        bounds.fill()

        // Hairlines separating the pane from the terminal and the header from the body.
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.minX, y: bounds.minY, width: 1, height: bounds.height).fill()
        NSRect(x: bounds.minX, y: header.frame.minY - 1, width: bounds.width, height: 1).fill()
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }
}
