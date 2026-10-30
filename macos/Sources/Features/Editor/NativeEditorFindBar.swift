import AppKit
import SwiftUI

struct EditorFindBarState {
    let query: String
    let replacement: String
    let summary: String
    let isReplace: Bool
    let isGoToLine: Bool
    let isCaseSensitive: Bool
    let shouldFocus: Bool
}

struct EditorFindBarActions {
    let queryChanged: (String) -> Void
    let replacementChanged: (String) -> Void
    let caseChanged: (Bool) -> Void
    let focusChanged: (Bool) -> Void
    let submit: () -> Void
    let findPrevious: () -> Void
    let findNext: () -> Void
    let replaceCurrent: () -> Void
    let replaceAll: () -> Void
    let close: () -> Void
}

struct NativeEditorFindBar: NSViewRepresentable {
    let state: EditorFindBarState
    let actions: EditorFindBarActions

    func makeNSView(context: Context) -> EditorFindBar {
        EditorFindBar()
    }

    func updateNSView(_ view: EditorFindBar, context: Context) {
        view.configure(state: state, actions: actions)
    }
}

@MainActor
final class EditorFindBar: NSView, NSSearchFieldDelegate {
    let searchField = NSSearchField()
    private let replaceField = NSSearchField()
    private let summaryField = NSTextField(labelWithString: "0/0")
    private let previousButton = NSButton(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Find Previous")!, target: nil, action: nil)
    private let nextButton = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Find Next")!, target: nil, action: nil)
    private let caseButton = NSButton(checkboxWithTitle: "Aa", target: nil, action: nil)
    private let closeButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Find")!, target: nil, action: nil)
    private let replaceButton = NSButton(title: "Replace", target: nil, action: nil)
    private let replaceAllButton = NSButton(title: "All", target: nil, action: nil)
    private let topRow = NSStackView()
    private let replaceRow = NSStackView()
    private var callbacks: EditorFindBarActions?
    private var lastFocusRequest = false
    private var pendingFocusRequest = false
    private var showsReplaceRow = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 4
        layer?.shadowOffset = CGSize(width: 0, height: -1)

        searchField.placeholderString = "Find"
        replaceField.placeholderString = "Replace"
        searchField.delegate = self
        replaceField.delegate = self
        for control in [searchField, replaceField, summaryField, previousButton, nextButton,
                        caseButton, closeButton, replaceButton, replaceAllButton] {
            control.translatesAutoresizingMaskIntoConstraints = false
        }
        summaryField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        summaryField.alignment = .center
        summaryField.widthAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        previousButton.target = self
        previousButton.action = #selector(previous)
        nextButton.target = self
        nextButton.action = #selector(next)
        caseButton.target = self
        caseButton.action = #selector(changeCase)
        closeButton.target = self
        closeButton.action = #selector(close)
        replaceButton.target = self
        replaceButton.action = #selector(replace)
        replaceAllButton.target = self
        replaceAllButton.action = #selector(replaceAll)
        searchField.target = self
        searchField.action = #selector(submit)
        replaceField.target = self
        replaceField.action = #selector(replace)

        [searchField, summaryField, previousButton, nextButton, caseButton, closeButton].forEach {
            topRow.addArrangedSubview($0)
        }
        topRow.orientation = .horizontal
        topRow.spacing = 4
        topRow.alignment = .centerY
        [replaceField, replaceButton, replaceAllButton].forEach {
            replaceRow.addArrangedSubview($0)
        }
        replaceRow.orientation = .horizontal
        replaceRow.spacing = 4
        replaceRow.alignment = .centerY
        let stack = NSStackView(views: [topRow, replaceRow])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            replaceField.widthAnchor.constraint(equalTo: searchField.widthAnchor),
            previousButton.widthAnchor.constraint(equalToConstant: 24),
            nextButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.widthAnchor.constraint(equalToConstant: 24)
        ])
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        replaceField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(state: EditorFindBarState, actions: EditorFindBarActions) {
        callbacks = actions
        let editingSearch = searchField.currentEditor().map { window?.firstResponder === $0 } ?? false
        if searchField.stringValue != state.query, !editingSearch {
            searchField.stringValue = state.query
        }
        let editingReplacement = replaceField.currentEditor().map { window?.firstResponder === $0 } ?? false
        if replaceField.stringValue != state.replacement, !editingReplacement {
            replaceField.stringValue = state.replacement
        }
        summaryField.stringValue = state.summary
        caseButton.state = state.isCaseSensitive ? .on : .off
        summaryField.isHidden = state.isGoToLine
        previousButton.isHidden = state.isGoToLine
        nextButton.isHidden = state.isGoToLine
        caseButton.isHidden = state.isGoToLine
        replaceRow.isHidden = !state.isReplace
        searchField.placeholderString = state.isGoToLine ? "Line:Column" : "Find"
        if showsReplaceRow != state.isReplace {
            showsReplaceRow = state.isReplace
            invalidateIntrinsicContentSize()
        }
        if state.shouldFocus && !lastFocusRequest { pendingFocusRequest = true }
        if !state.shouldFocus { pendingFocusRequest = false }
        lastFocusRequest = state.shouldFocus
        fulfillPendingFocus()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        fulfillPendingFocus()
    }

    override func viewDidHide() {
        super.viewDidHide()
        if window?.firstResponder === searchField.currentEditor() {
            callbacks?.focusChanged(false)
        }
    }

    private func fulfillPendingFocus() {
        guard pendingFocusRequest, let window, !isHiddenOrHasHiddenAncestor else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window,
                  !self.isHiddenOrHasHiddenAncestor, self.pendingFocusRequest else { return }
            if window.makeFirstResponder(self.searchField) {
                self.pendingFocusRequest = false
            }
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === searchField { callbacks?.queryChanged(field.stringValue) }
        if field === replaceField { callbacks?.replacementChanged(field.stringValue) }
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        if notification.object as? NSTextField === searchField { callbacks?.focusChanged(true) }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if notification.object as? NSTextField === searchField { callbacks?.focusChanged(false) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText(), selector == #selector(NSResponder.cancelOperation(_:)) else {
            return false
        }
        callbacks?.close()
        return true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 360, height: showsReplaceRow ? 76 : 44)
    }

    @objc private func previous() { callbacks?.findPrevious() }
    @objc private func next() { callbacks?.findNext() }
    @objc private func changeCase() { callbacks?.caseChanged(caseButton.state == .on) }
    @objc private func submit() { callbacks?.submit() }
    @objc private func replace() { callbacks?.replaceCurrent() }
    @objc private func replaceAll() { callbacks?.replaceAll() }
    @objc private func close() { callbacks?.close() }
}
