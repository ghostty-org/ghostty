import AppKit

struct GitPopoverSegment: Equatable {
    let id: String
    let title: String
    var symbol: String?
    var accessibilityLabel: String
}

/// Compact, theme-aware AppKit segments matching the Git toolbar controls.
@MainActor
final class GitPopoverSegments: NSView {
    private let stack = NSStackView()
    private var buttons: [GitPopoverSegmentButton] = []
    private var segments: [GitPopoverSegment] = []
    private var colors = GitCollectionColors()
    private var widths: [CGFloat] = []
    private var selectedID: String?
    private let themeObserver = OMGNativeThemeObserver()
    private var widthConstraints: [NSLayoutConstraint] = []
    var stretchesToWidth = false
    var buttonsForTesting: [NSButton] { buttons }
    var onSelect: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        themeObserver.onChange = { [weak self] in self?.applyTheme($0) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        segments: [GitPopoverSegment],
        selectedID: String?,
        colors: GitCollectionColors,
        widths: [CGFloat]
    ) {
        guard widths.count == segments.count else { return }
        if self.segments != segments {
            buttons.forEach { $0.removeFromSuperview() }
            self.segments = segments
            self.widths = widths
            widthConstraints = []
            buttons = segments.indices.map { _ in
                let button = GitPopoverSegmentButton()
                button.target = self
                button.action = #selector(activate(_:))
                stack.addArrangedSubview(button)
                return button
            }
            for (button, width) in zip(buttons, widths) {
                let constraint = stretchesToWidth
                    ? button.widthAnchor.constraint(equalTo: widthAnchor,
                                                    multiplier: 1 / CGFloat(buttons.count),
                                                    constant: -2 / CGFloat(buttons.count))
                    : button.widthAnchor.constraint(equalToConstant: width)
                constraint.isActive = true
                if !stretchesToWidth { widthConstraints.append(constraint) }
                button.heightAnchor.constraint(equalToConstant: 24).isActive = true
            }
        }
        self.widths = widths
        for (constraint, width) in zip(widthConstraints, widths) { constraint.constant = width }
        self.colors = colors
        self.selectedID = selectedID
        for (index, segment) in segments.enumerated() {
            buttons[index].configure(segment: segment, selected: segment.id == selectedID,
                                     colors: colors)
        }
        setAccessibilityLabel(segments.map(\.accessibilityLabel).joined(separator: ", "))
        needsDisplay = true
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: widths.reduce(0, +) + 2, height: 26)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        themeObserver.sourceWindow = window?.sheetParent ?? window
        applyTheme(.resolve(for: self))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        colors.text.gitOpacity(0.025).setFill()
        shape.fill()
        colors.separator.setStroke()
        shape.lineWidth = 0.75
        shape.stroke()
    }

    @objc private func activate(_ sender: GitPopoverSegmentButton) {
        guard let id = sender.segmentID else { return }
        selectedID = id
        for button in buttons { button.setSelected(button.segmentID == id) }
        onSelect?(id)
    }

    func applyTheme(_ theme: OMGNativeTheme) {
        configure(segments: segments, selectedID: selectedID,
                  colors: GitCollectionColors(nativeTheme: theme), widths: widths)
    }
}

@MainActor
private final class GitPopoverSegmentButton: NSButton {
    private var colors = GitCollectionColors()
    private var hovered = false
    fileprivate var segmentID: String?
    private var isSelectedSegment = false
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setButtonType(.momentaryPushIn)
        isBordered = false
        translatesAutoresizingMaskIntoConstraints = false
        controlSize = .small
        font = .systemFont(ofSize: 11, weight: .medium)
        alignment = .center
        focusRingType = .none
        (cell as? NSButtonCell)?.highlightsBy = []
        imagePosition = .imageOnly
        setAccessibilityRole(.radioButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(segment: GitPopoverSegment, selected: Bool, colors: GitCollectionColors) {
        isBordered = false
        segmentID = segment.id
        self.colors = colors
        title = segment.title
        image = segment.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: segment.accessibilityLabel) }
        imagePosition = image == nil ? .noImage : title.isEmpty ? .imageOnly : .imageLeading
        toolTip = segment.accessibilityLabel
        setAccessibilityLabel(segment.accessibilityLabel)
        setSelected(selected)
    }

    func setSelected(_ selected: Bool) {
        isSelectedSegment = selected
        state = selected ? .on : .off
        contentTintColor = selected ? colors.accent : colors.secondary
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: selected ? colors.text : colors.secondary,
        ])
        setAccessibilityValue(selected ? GitL10n.text("Selected") : "")
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = NativePointerLocation.contains(self); needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

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

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        if isSelectedSegment {
            colors.accent.withAlphaComponent(hovered ? 0.22 : 0.13).setFill()
            shape.fill()
            colors.accent.withAlphaComponent(hovered ? 0.55 : 0.3).setStroke()
            shape.lineWidth = 0.75
            shape.stroke()
        } else if hovered {
            colors.text.gitOpacity(0.055).setFill()
            shape.fill()
            colors.text.gitOpacity(0.23).setStroke()
            shape.lineWidth = 0.75
            shape.stroke()
        }
        super.draw(dirtyRect)
        if window?.firstResponder === self {
            colors.accent.setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }
    }
}

final class GitPopoverBackgroundView: NSView {
    var backgroundColor: NSColor { didSet { needsDisplay = true } }

    init(backgroundColor: NSColor) {
        self.backgroundColor = backgroundColor
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = backgroundColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
