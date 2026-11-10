import AppKit

/// Read-only inspector fields participate in the host's early key routing,
/// before terminal bindings can consume Copy or Select All.
class InspectorCopyableTextField: NSTextField {
    var pasteboard = NSPasteboard.general
    var copyValue: String?
    var copyItems: [(String, String)]?
    var contextMenuProvider: (() -> NSMenu?)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        EditorCommandRouter.shared.unregister(owner: self)
        guard window != nil else { return }
        EditorCommandRouter.shared.register(owner: self) { [weak self] event in
            guard let self, event.window === self.window,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
                  let editor = self.currentEditor() as? NSTextView, self.window?.firstResponder === editor else { return false }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": editor.selectAll(nil); return true
            case "c":
                let range = editor.selectedRange()
                if range.length > 0, NSMaxRange(range) <= (editor.string as NSString).length {
                    InspectorCopyMenu.copy((editor.string as NSString).substring(with: range), to: self.pasteboard)
                }
                return true
            default: return false
            }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?() ?? InspectorCopyMenu(values: copyItems ?? [(SettingsStrings(language: OhMyGhosttySettings.shared.language).copyTitle, copyValue ?? stringValue)], pasteboard: pasteboard)
    }
}

/// Metadata clicks select one complete value; Copy uses the normal responder route.
final class InspectorMetadataText: NSButton {
    private(set) var value = ""
    private var displayText = ""
    private var copyLabel = ""
    private var highlights: [String] = []
    var isCopied: Bool { feedback.isCopied }
    private(set) var isValueSelected = false
    var pasteboard = NSPasteboard.general
    private let feedback = CopyFeedbackState()
    var onDoubleClick: (() -> Void)?
    var contextMenuProvider: (() -> NSMenu?)?
    /// Reserve room for the copy confirmation so it never truncates mid-word.
    var naturalWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 10)
        return max(40, ceil(max(
            (displayText as NSString).size(withAttributes: [.font: font]).width,
            (CopyFeedback.confirmationLabel() as NSString).size(withAttributes: [.font: font]).width
        )) + 4)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        alignment = .left
        imagePosition = .noImage
        cell?.lineBreakMode = .byTruncatingMiddle
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 3
        target = self
        action = #selector(selectValue(_:))
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        isValueSelected = true
        present()
        return true
    }
    override func resignFirstResponder() -> Bool {
        isValueSelected = false
        present()
        return true
    }
    func configure(text: String, value: String, label: String, highlights: [String] = []) {
        if self.value != value || displayText != text {
            feedback.cancel()
            if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        }
        self.value = value
        displayText = text
        copyLabel = label
        self.highlights = highlights
        setAccessibilityLabel(label + ": " + value)
        present()
    }
    private func present() {
        let shown = feedback.isCopied ? CopyFeedback.confirmationLabel() : displayText
        let title = NSMutableAttributedString(string: shown, attributes: [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        if !feedback.isCopied, !highlights.isEmpty {
            GitSearchHighlight.apply(terms: highlights, to: title)
        }
        attributedTitle = title
        // Clicking copies now, so there is no persistent selection highlight.
        layer?.backgroundColor = .clear
        let strings = SettingsStrings(language: OhMyGhosttySettings.shared.language)
        toolTip = isCopied ? strings.copiedTitle : strings.selectionCopyHint(copyLabel, value: value)
        setAccessibilityValue(isCopied ? strings.copiedTitle : (isValueSelected ? strings.selectedTitle : ""))
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        EditorCommandRouter.shared.unregister(owner: self)
        guard window != nil else {
            feedback.cancel()
            isValueSelected = false
            present()
            return
        }
        EditorCommandRouter.shared.register(owner: self) { [weak self] event in
            guard let self, event.window === self.window, self.window?.firstResponder === self,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "c" else { return false }
            self.copy(nil)
            return true
        }
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2, onDoubleClick != nil { activate(clickCount: event.clickCount); return }
        super.mouseDown(with: event)
    }
    @objc private func selectValue(_ sender: Any?) { activate(clickCount: 1) }
    func activate(clickCount: Int) {
        if clickCount >= 2, let onDoubleClick { onDoubleClick(); return }
        // Metadata values copy on a single click, matching the Agent History
        // confirmation instead of requiring select-then-Command-C.
        window?.makeFirstResponder(self)
        copy(nil)
    }
    @objc func copy(_ sender: Any?) {
        CopyFeedback.copy(value, to: pasteboard)
        feedback.flash { [weak self] _ in
            guard let self else { return }
            self.present()
            CopyFeedback.animate(self)
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?() ?? InspectorCopyMenu(values: [(SettingsStrings(language: OhMyGhosttySettings.shared.language).copyTitle(copyLabel), value)], pasteboard: pasteboard)
    }
}

class InspectorCopyableTextView: NSTextView {
    var pasteboard = NSPasteboard.general
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        EditorCommandRouter.shared.unregister(owner: self)
        guard window != nil else { return }
        EditorCommandRouter.shared.register(owner: self) { [weak self] event in
            guard let self, event.window === self.window, self.window?.firstResponder === self,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command else { return false }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": self.selectAll(nil); return true
            case "c":
                let range = self.selectedRange()
                if range.length > 0, NSMaxRange(range) <= (self.string as NSString).length {
                    InspectorCopyMenu.copy((self.string as NSString).substring(with: range), to: self.pasteboard)
                }
                return true
            default: return false
            }
        }
    }
}

class InspectorCopyMenu: NSMenu {
    var pasteboard = NSPasteboard.general
    init(values: [(String, String)] = [], pasteboard: NSPasteboard = .general) {
        super.init(title: "")
        self.pasteboard = pasteboard
        addCopyItems(values)
    }
    @available(*, unavailable) required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func addCopyItems(_ values: [(String, String)]) {
        for (title, value) in values {
            let item = NSMenuItem(title: title, action: #selector(copyItem(_:)), keyEquivalent: "")
            item.representedObject = value
            item.target = self
            addItem(item)
        }
    }
    @objc private func copyItem(_ item: NSMenuItem) {
        if let value = item.representedObject as? String { Self.copy(value, to: pasteboard) }
    }
    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

class InspectorCopyTableView: NSTableView {
    var copyValue: (() -> String?)?
    var focusedKeyHandler: ((NSEvent) -> Bool)?
    var pasteboard = NSPasteboard.general
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        EditorCommandRouter.shared.unregister(owner: self)
        guard window != nil else { return }
        EditorCommandRouter.shared.register(owner: self) { [weak self] event in
            guard let self, event.window === self.window, self.window?.firstResponder === self else { return false }
            if self.focusedKeyHandler?(event) == true { return true }
            guard
                  event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "c" else { return false }
            if let value = self.copyValue?() { InspectorCopyMenu.copy(value, to: self.pasteboard) }
            return true
        }
    }
}
