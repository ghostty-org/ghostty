import AppKit

/// The floating card that describes what the pointer is resting on.
///
/// A non-activating child window rather than an `NSPopover`, and the reason
/// is the caret. A popover's window takes key status, which pulls the
/// insertion point out of the text view — the caret stops blinking and the
/// selection greys out — from nothing more than the mouse moving. A hover has
/// to be able to appear without changing what has focus, and
/// `.nonactivatingPanel` plus `canBecomeKey == false` is how AppKit says
/// that.
///
/// It is also a child window of the editor's window, so it follows when the
/// window moves and goes away with it. A floating panel that outlives its
/// parent is the classic way to end up with a tooltip stranded on an empty
/// desktop.
final class CodeHoverPanel: NSPanel {
    /// Wide enough for a real declaration, narrow enough to stay a card.
    /// Past this, prose wraps rather than the window growing across the
    /// screen.
    static let maximumWidth: CGFloat = 460

    /// And past this it scrolls rather than the window growing down the
    /// screen. `String`'s documentation is thousands of words long: without a
    /// ceiling the card covered the whole display, and because it was taller
    /// than the screen the clamp that keeps a window on screen pinned its
    /// *bottom* edge — so the one part guaranteed to be cut off was the
    /// beginning, which is the part you were reading.
    static let maximumHeight: CGFloat = 320

    /// Called when the pointer leaves the card.
    ///
    /// Needed because the text view stops hearing about the pointer the moment
    /// it is over this window: without this the card would be left on screen
    /// after the pointer wandered off to the sidebar, waiting for a mouse event
    /// that only comes if you go back to the code.
    var onPointerExit: (() -> Void)?

    private let inset: CGFloat = 10

    /// Room kept at the right for the copy button, so a long line of prose
    /// never runs underneath it.
    private let buttonColumn: CGFloat = 22

    private lazy var card = CardView(owner: self)
    private let scrollView = NSScrollView()
    private let document = FlippedView()
    private let container = NSStackView()
    private let copyButton = NSButton()

    /// What is on the card, kept so the copy button has something to copy.
    private var presented = CodeHoverInfo()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.maximumWidth, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        isFloatingPanel = true
        hidesOnDeactivate = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isMovableByWindowBackground = false
        animationBehavior = .utilityWindow

        // Key only when something on the card actually needs it — which is
        // selecting the text to copy part of it. Hovering never takes focus,
        // and neither does pressing the copy button; a floating panel also
        // leaves the parent window looking active while it holds focus, so
        // the editor does not grey out behind it.
        becomesKeyOnlyIfNeeded = true

        card.wantsLayer = true
        card.layer?.cornerRadius = 6
        card.layer?.borderWidth = 1

        // Overlay scrollers, so the bar floats over the text while scrolling
        // instead of claiming a column of a card this narrow.
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 6
        container.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(container)
        scrollView.documentView = document
        card.addSubview(scrollView)

        copyButton.bezelStyle = .accessoryBarAction
        copyButton.isBordered = false
        copyButton.imagePosition = .imageOnly
        copyButton.image = NSImage(
            systemSymbolName: "doc.on.doc",
            accessibilityDescription: "Copy"
        )
        copyButton.target = self
        copyButton.action = #selector(copyContents)
        copyButton.toolTip = "Copy"
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(copyButton)

        NSLayoutConstraint.activate([
            copyButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -6),
            copyButton.topAnchor.constraint(equalTo: card.topAnchor, constant: 4),

            scrollView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: inset),
            scrollView.trailingAnchor.constraint(
                equalTo: card.trailingAnchor,
                constant: -(inset + buttonColumn)
            ),
            scrollView.topAnchor.constraint(equalTo: card.topAnchor, constant: inset),
            scrollView.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -inset),

            // Width tied to the viewport and height left free: that pair is
            // what makes the prose wrap at the card's width and the document
            // grow downwards instead of sideways.
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),

            container.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            container.topAnchor.constraint(equalTo: document.topAnchor),
            container.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        contentView = card
    }

    /// Never the main window: this is a panel, and the editor stays the thing
    /// the app is about. Key is allowed, but only on demand — see
    /// `becomesKeyOnlyIfNeeded` above.
    override var canBecomeMain: Bool { false }

    /// Puts the card's text on the clipboard.
    ///
    /// A button rather than only a text selection, because the common want is
    /// the whole message — an error you are about to paste into a search — and
    /// dragging across wrapped prose to get it is worse than one click.
    @objc private func copyContents() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(presented.plainText, forType: .string)

        copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            self?.copyButton.image = NSImage(
                systemSymbolName: "doc.on.doc",
                accessibilityDescription: "Copy"
            )
        }
    }

    /// Whether the pointer is over the card.
    ///
    /// Asked before hiding on `mouseExited`: the card is placed over the text,
    /// so moving the pointer onto it *is* leaving the text view, and a card
    /// that vanishes when you reach for its scroller cannot be scrolled.
    var containsPointer: Bool {
        isVisible && frame.contains(NSEvent.mouseLocation)
    }

    // MARK: Presenting

    /// Fills the card and puts it beside `anchor`, given in screen
    /// coordinates.
    func present(
        _ info: CodeHoverInfo,
        theme: CodeTheme,
        font: NSFont,
        language: CodeLanguage,
        anchor: NSRect,
        over view: NSView
    ) {
        guard !info.isEmpty, let parentWindow = view.window else { return }
        let screen = parentWindow.screen ?? NSScreen.main
        presented = info

        fill(info, theme: theme, font: font, language: language, on: screen)
        position(near: anchor, on: screen)

        if parent == nil { parentWindow.addChildWindow(self, ordered: .above) }
        orderFront(nil)
        invalidateShadow()

        // At the top, always. A reused panel keeps the scroll position of the
        // last symbol, and reading a description from its middle is worse than
        // not showing it.
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func dismiss() {
        guard isVisible else { return }
        parent?.removeChildWindow(self)
        orderOut(nil)
    }

    // MARK: Content

    private func fill(
        _ info: CodeHoverInfo,
        theme: CodeTheme,
        font: NSFont,
        language: CodeLanguage,
        on screen: NSScreen?
    ) {
        container.views.forEach { $0.removeFromSuperview() }

        let background = theme.background.withAlphaComponent(1)
        card.layer?.backgroundColor = background.cgColor
        card.layer?.borderColor = theme.foreground.withAlphaComponent(0.18).cgColor

        let width = Self.maximumWidth - inset * 2 - buttonColumn

        for problem in info.problems {
            container.addView(
                label(
                    Self.problemText(problem, font: font, foreground: theme.foreground),
                    width: width
                ),
                in: .top
            )
        }

        // A rule between what is wrong and what the thing is, because they
        // are different claims: one is the server complaining, the other is
        // the server describing.
        if !info.problems.isEmpty, info.signature != nil || info.documentation != nil {
            container.addView(separator(color: theme.foreground.withAlphaComponent(0.15)), in: .top)
        }

        if let signature = info.signature {
            container.addView(
                label(
                    Self.signatureText(signature, theme: theme, font: font, language: language),
                    width: width
                ),
                in: .top
            )
        }

        if let documentation = info.documentation {
            container.addView(
                label(
                    Self.proseText(
                        documentation,
                        font: .systemFont(ofSize: font.pointSize + 1),
                        color: theme.foreground.withAlphaComponent(0.75)
                    ),
                    width: width
                ),
                in: .top
            )
        }

        container.layoutSubtreeIfNeeded()
        let fitting = container.fittingSize
        let ceiling = min(
            Self.maximumHeight,
            max(120, (screen?.visibleFrame.height ?? Self.maximumHeight) - 80)
        )
        setContentSize(NSSize(
            width: min(fitting.width, width) + inset * 2 + buttonColumn,
            height: min(fitting.height, ceiling) + inset * 2
        ))
    }

    private func label(_ text: NSAttributedString, width: CGFloat) -> NSTextField {
        let field = NSTextField(labelWithAttributedString: text)
        // Selectable so a fragment can be copied by hand; the button covers
        // wanting all of it.
        field.isSelectable = true
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.preferredMaxLayoutWidth = width
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(lessThanOrEqualToConstant: width).isActive = true
        return field
    }

    private func separator(color: NSColor) -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = color.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        line.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        return line
    }

    /// `[source] message`, with the source in the severity's colour.
    private static func problemText(
        _ problem: CodeHoverInfo.Problem,
        font: NSFont,
        foreground: NSColor
    ) -> NSAttributedString {
        let body = NSFont.systemFont(ofSize: font.pointSize + 1)
        let result = NSMutableAttributedString()
        if let source = problem.source {
            result.append(NSAttributedString(string: "[\(source)] ", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .medium),
                .foregroundColor: problem.color,
            ]))
        }
        result.append(NSAttributedString(string: problem.message, attributes: [
            .font: body,
            .foregroundColor: problem.source == nil ? problem.color : foreground,
        ]))
        return result
    }

    /// The declaration, coloured by the same highlighter the editor uses.
    ///
    /// Reusing the highlighter rather than showing flat text is what makes
    /// the card look like it belongs to the file underneath it — the types and
    /// keywords in a signature are the same types and keywords two lines up.
    private static func signatureText(
        _ text: String,
        theme: CodeTheme,
        font: NSFont,
        language: CodeLanguage
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: theme.foreground,
        ])
        let full = NSRange(location: 0, length: (text as NSString).length)
        for token in SyntaxHighlighter(language: language).tokens(in: text, range: full) {
            result.addAttribute(
                .foregroundColor,
                value: theme.color(for: token.kind),
                range: token.range
            )
        }
        return result
    }

    /// Documentation, with markdown's inline marks honoured.
    ///
    /// Inline only: a server's documentation is a paragraph with `code spans`
    /// and emphasis in it, not a document with headings and lists. Parsing it
    /// as a full document would reflow whitespace the author meant to keep,
    /// and failing to parse it at all would leave backticks on screen.
    private static func proseText(
        _ markdown: String,
        font: NSFont,
        color: NSColor
    ) -> NSAttributedString {
        let parsed = try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )
        let result = NSMutableAttributedString(
            attributedString: parsed.map { NSAttributedString($0) }
                ?? NSAttributedString(string: markdown)
        )

        let full = NSRange(location: 0, length: result.length)
        result.addAttributes([.font: font, .foregroundColor: color], range: full)
        result.enumerateAttribute(.inlinePresentationIntent, in: full) { value, range, _ in
            guard let raw = (value as? NSNumber)?.uintValue else { return }
            let intent = InlinePresentationIntent(rawValue: raw)
            if intent.contains(.code) {
                result.addAttribute(
                    .font,
                    value: NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular),
                    range: range
                )
            }
            if intent.contains(.stronglyEmphasized) {
                result.addAttribute(
                    .font,
                    value: NSFont.boldSystemFont(ofSize: font.pointSize),
                    range: range
                )
            }
        }
        return result
    }

    // MARK: Geometry

    /// Above the hovered line when there is room, below it otherwise, and
    /// always wholly on screen.
    ///
    /// Above by preference because the code you are reading continues
    /// *downwards*: a card below the line covers what comes next, which is
    /// usually the part being explained.
    private func position(near anchor: NSRect, on screen: NSScreen?) {
        let size = frame.size
        let gap: CGFloat = 6
        let visible = screen?.visibleFrame ?? NSRect(origin: .zero, size: size)

        var origin = NSPoint(x: anchor.minX, y: anchor.maxY + gap)

        // Below when it does not fit above, and back to above when it fits
        // neither — the clamp underneath then keeps it on screen, and losing
        // the bottom of a description is better than losing its first line.
        if origin.y + size.height > visible.maxY {
            let below = anchor.minY - gap - size.height
            origin.y = below >= visible.minY ? below : origin.y
        }

        origin.x = min(max(origin.x, visible.minX + 8), max(visible.maxX - size.width - 8, visible.minX))
        origin.y = min(max(origin.y, visible.minY + 8), max(visible.maxY - size.height - 8, visible.minY))

        setFrameOrigin(origin)
    }

    /// A document view that grows downwards, so "scroll to zero" means the
    /// top. Unflipped — AppKit's default — it would mean the bottom, and the
    /// card would open at the end of every description.
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    /// The card's background, and the thing that notices the pointer leaving.
    private final class CardView: NSView {
        private weak var owner: CodeHoverPanel?

        init(owner: CodeHoverPanel) {
            self.owner = owner
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            // `activeAlways` rather than `activeInKeyWindow`: this window is
            // never the key one, by design, so the usual option would never
            // arm the tracking area at all.
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            ))
        }

        override func mouseExited(with event: NSEvent) {
            super.mouseExited(with: event)
            owner?.onPointerExit?()
        }
    }
}
