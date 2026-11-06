import AppKit
import QuartzCore

/// The shared click-to-copy confirmation used across OMG.
///
/// One place owns the wording, duration and animation so every copy
/// affordance behaves the same and a later change lands everywhere at once.
@MainActor
enum CopyFeedback {
    /// How long a confirmation stays visible.
    static let duration: TimeInterval = 1.2

    /// The confirmation wording shared by every copy affordance.
    static func confirmationText() -> String {
        SettingsStrings(language: OhMyGhosttySettings.shared.language).copiedTitle
    }

    /// The confirmation label shown in place of the copied value.
    static func confirmationLabel() -> String {
        "✓ " + confirmationText()
    }

    /// Copies a value to the pasteboard.
    static func copy(_ value: String, to pasteboard: NSPasteboard = .general) {
        InspectorCopyMenu.copy(value, to: pasteboard)
    }

    /// Fades a control in after its confirmation appears.
    static func animate(_ view: NSView?) {
        guard let view, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.35
        fade.toValue = 1
        fade.duration = 0.18
        view.layer?.add(fade, forKey: "copyFeedback")
    }
}

/// Tracks the shared copy confirmation for controls that render their own
/// appearance instead of using `CopyFeedbackButton`.
@MainActor
final class CopyFeedbackState {
    private(set) var isCopied = false
    private var task: Task<Void, Never>?

    /// Shows the confirmation and clears it after the shared duration.
    func flash(onChange: @escaping (Bool) -> Void) {
        task?.cancel()
        isCopied = true
        onChange(true)
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(CopyFeedback.duration))
            guard !Task.isCancelled, let self else { return }
            self.isCopied = false
            onChange(false)
        }
    }

    /// Ends a running confirmation without notifying the caller.
    func cancel() {
        task?.cancel()
        isCopied = false
    }
}

/// A label-style button that copies a value on click and confirms with the
/// shared copy feedback.
class CopyFeedbackButton: NSButton {
    var pasteboard = NSPasteboard.general
    private let feedback = CopyFeedbackState()
    private(set) var value: String?
    private var display = ""
    var textFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular) { didSet { updateTitle() } }
    var normalColor = NSColor.secondaryLabelColor { didSet { updateTitle() } }

    var isCopied: Bool { feedback.isCopied }

    /// The width that keeps the control stable while it confirms a copy.
    var preferredWidth: CGFloat {
        ceil(max((display as NSString).size(withAttributes: [.font: textFont]).width,
                 (CopyFeedback.confirmationLabel() as NSString).size(withAttributes: [.font: textFont]).width)) + 4
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        alignment = .left
        imagePosition = .noImage
        lineBreakMode = .byTruncatingMiddle
        wantsLayer = true
        target = self
        action = #selector(copyValue)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Configures the label and the value copied on click.
    func configure(
        display: String,
        value: String?,
        tooltip: String? = nil,
        accessibilityLabel: String? = nil
    ) {
        if self.value != value || self.display != display {
            feedback.cancel()
        }
        self.value = value
        self.display = display
        isEnabled = value != nil
        toolTip = tooltip
        if let accessibilityLabel { setAccessibilityLabel(accessibilityLabel) }
        setAccessibilityValue(feedback.isCopied ? CopyFeedback.confirmationText() : "")
        updateTitle()
    }

    /// Clears the copied value and any running confirmation.
    func reset() {
        feedback.cancel()
        value = nil
        setAccessibilityValue("")
        updateTitle()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil else { return }
        feedback.cancel()
        setAccessibilityValue("")
        updateTitle()
    }

    @objc private func copyValue() {
        guard let value else { return }
        CopyFeedback.copy(value, to: pasteboard)
        feedback.flash { [weak self] isCopied in
            guard let self else { return }
            self.setAccessibilityValue(isCopied ? CopyFeedback.confirmationText() : "")
            self.updateTitle(animated: isCopied)
        }
    }

    private func updateTitle(animated: Bool = false) {
        attributedTitle = NSAttributedString(
            string: feedback.isCopied ? CopyFeedback.confirmationLabel() : display,
            attributes: [
                .font: textFont,
                .foregroundColor: normalColor,
            ]
        )
        guard animated else { return }
        CopyFeedback.animate(self)
    }
}

/// An icon button that copies a value on click and confirms with the shared
/// copy feedback by swapping to a checkmark.
class CopyFeedbackIconButton: NSButton {
    var pasteboard = NSPasteboard.general
    private let feedback = CopyFeedbackState()
    private var symbol = "doc.on.doc"
    private var idleToolTip = ""
    private var value: String?

    /// Configures the symbol and the value copied on click.
    func configure(symbol: String, value: String?, tooltip: String) {
        if self.value != value { feedback.cancel() }
        self.symbol = symbol
        self.value = value
        idleToolTip = tooltip
        isEnabled = value != nil
        apply(isCopied: feedback.isCopied)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .inline
        target = self
        action = #selector(copyValue)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func copyValue() {
        guard let value else { return }
        CopyFeedback.copy(value, to: pasteboard)
        feedback.flash { [weak self] isCopied in
            guard let self else { return }
            self.apply(isCopied: isCopied)
            CopyFeedback.animate(self)
        }
    }

    private func apply(isCopied: Bool) {
        image = NSImage(
            systemSymbolName: isCopied ? "checkmark" : symbol,
            accessibilityDescription: nil
        )
        contentTintColor = isCopied ? .labelColor : .secondaryLabelColor
        toolTip = isCopied ? CopyFeedback.confirmationText() : idleToolTip
        setAccessibilityValue(isCopied ? CopyFeedback.confirmationText() : "")
    }
}
