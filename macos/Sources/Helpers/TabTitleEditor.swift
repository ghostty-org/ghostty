import AppKit

/// Delegate used by ``TabTitleEditor`` to resolve tab-specific behavior.
protocol TabTitleEditorDelegate: AnyObject {
    /// Returns whether inline rename should be allowed for the given tab window.
    func tabTitleEditor(
        _ editor: TabTitleEditor,
        canRenameTabFor targetWindow: NSWindow
    ) -> Bool

    /// Returns the current title value to seed into the inline editor.
    func tabTitleEditor(
        _ editor: TabTitleEditor,
        titleFor targetWindow: NSWindow
    ) -> String

    /// Called when inline editing commits a title for a target tab window.
    func tabTitleEditor(
        _ editor: TabTitleEditor,
        didCommitTitle editedTitle: String,
        for targetWindow: NSWindow
    )

    /// Called when inline editing could not start and the host should show a fallback flow.
    func tabTitleEditor(
        _ editor: TabTitleEditor,
        performFallbackRenameFor targetWindow: NSWindow
    )
}

/// Handles inline tab title editing for native AppKit window tabs.
final class TabTitleEditor: NSObject, NSTextFieldDelegate {
    /// Host window containing the tab bar where editing occurs.
    private weak var hostWindow: NSWindow?
    /// Delegate that provides and commits title data for target tab windows.
    private weak var delegate: TabTitleEditorDelegate?

    /// Active inline editor view, if editing is in progress.
    private weak var inlineTitleEditor: NSTextField?
    /// Tab window currently being edited.
    private weak var inlineTitleTargetWindow: NSWindow?
    /// Original hidden state for title labels that are temporarily hidden while editing.
    private var hiddenLabels: [(label: NSTextField, wasHidden: Bool)] = []
    /// Original button title state restored once editing finishes.
    private var buttonState: (button: NSButton, title: String, attributedTitle: NSAttributedString?)?
    /// Deferred begin-editing work used to avoid visual flicker on double-click.
    private var pendingEditWorkItem: DispatchWorkItem?

    /// Creates a coordinator bound to a host window and rename delegate.
    init(hostWindow: NSWindow, delegate: TabTitleEditorDelegate) {
        self.hostWindow = hostWindow
        self.delegate = delegate
    }

    /// Handles double-click events from the host window and begins inline edit if possible. If this
    /// returns true then the double click was handled by the coordinator.
    func handleDoubleClick(_ event: NSEvent) -> Bool {
        // We only want double-clicks
        guard event.type == .leftMouseDown, event.clickCount == 2 else { return false }

        // If we don't have a host window to look up the click, we do nothing.
        guard let hostWindow else { return false }

        // Find the tab window that is being clicked.
        let locationInScreen = hostWindow.convertPoint(toScreen: event.locationInWindow)
        guard let tabIndex = hostWindow.tabIndex(atScreenPoint: locationInScreen),
              let targetWindow = hostWindow.tabbedWindows?[safe: tabIndex],
              delegate?.tabTitleEditor(self, canRenameTabFor: targetWindow) == true
        else { return false }

        // We need to start editing in a separate event loop tick, so set that up.
        pendingEditWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self, weak targetWindow] in
            guard let self, let targetWindow else { return }
            if self.beginEditing(for: targetWindow) {
                return
            }

            // Inline editing failed, so trigger fallback rename whatever it is.
            self.delegate?.tabTitleEditor(self, performFallbackRenameFor: targetWindow)
        }

        pendingEditWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
        return true
    }

    /// Begins editing the given target tab window title. Returns true if we're able to start the
    /// inline edit.
    @discardableResult
    func beginEditing(for targetWindow: NSWindow) -> Bool {
        // Resolve the visual tab button for the target tab window. We rely on visual order
        // since native tab view hierarchy order does not necessarily match what is on screen.
        guard let hostWindow,
              let tabbedWindows = hostWindow.tabbedWindows,
              let tabIndex = tabbedWindows.firstIndex(of: targetWindow),
              let tabButton = hostWindow.tabButtonsInVisualOrder()[safe: tabIndex],
              delegate?.tabTitleEditor(self, canRenameTabFor: targetWindow) == true
        else { return false }

        // If we have a pending edit, we need to cancel it because we got
        // called to start edit explicitly.
        pendingEditWorkItem?.cancel()
        pendingEditWorkItem = nil
        finishEditing(commit: true)

        // Build the editor using title text and style derived from the tab's existing label.
        let titleLabels = tabButton
            .descendants(withClassName: "NSTextField")
            .compactMap { $0 as? NSTextField }
        let editedTitle = delegate?.tabTitleEditor(self, titleFor: targetWindow) ?? targetWindow.title
        let sourceLabel = sourceTabTitleLabel(from: titleLabels, matching: editedTitle)
        let editorFrame = tabTitleEditorFrame(for: tabButton, sourceLabel: sourceLabel)
        guard editorFrame.width >= 20, editorFrame.height >= 14 else { return false }

        let editor = NSTextField(frame: editorFrame)
        editor.delegate = self
        editor.stringValue = editedTitle
        editor.alignment = sourceLabel?.alignment ?? .center
        editor.isBordered = false
        editor.isBezeled = false
        editor.drawsBackground = false
        editor.focusRingType = .none
        editor.lineBreakMode = .byClipping
        if let editorCell = editor.cell as? NSTextFieldCell {
            editorCell.wraps = false
            editorCell.usesSingleLineMode = true
            editorCell.isScrollable = true
        }
        if let sourceLabel {
            applyTextStyle(to: editor, from: sourceLabel, title: editedTitle)
        }

        // Hide it until the tab button has finished layout so we can avoid flicker.
        editor.isHidden = true

        inlineTitleEditor = editor
        inlineTitleTargetWindow = targetWindow

        // Temporarily hide native title label views while editing so only the text field is visible.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hiddenLabels = titleLabels.map { ($0, $0.isHidden) }
        for label in titleLabels {
            label.isHidden = true
        }
        if let tabButton = tabButton as? NSButton {
            buttonState = (tabButton, tabButton.title, tabButton.attributedTitle)
            tabButton.title = ""
            tabButton.attributedTitle = NSAttributedString(string: "")
        } else {
            buttonState = nil
        }
        tabButton.layoutSubtreeIfNeeded()
        tabButton.displayIfNeeded()
        tabButton.addSubview(editor)
        CATransaction.commit()

        // Focus after insertion so AppKit has created the field editor for this text field.
        DispatchQueue.main.async { [weak hostWindow, weak editor] in
            guard let hostWindow, let editor else { return }
            editor.isHidden = false
            hostWindow.makeFirstResponder(editor)
            if let fieldEditor = editor.currentEditor() as? NSTextView,
               let editorFont = editor.font {
                fieldEditor.font = editorFont
                var typingAttributes = fieldEditor.typingAttributes
                typingAttributes[.font] = editorFont
                fieldEditor.typingAttributes = typingAttributes
            }
            editor.currentEditor()?.selectAll(nil)
        }

        return true
    }

    /// Finishes any in-flight inline edit and optionally commits the edited title.
    func finishEditing(commit: Bool) {
        // If we're pending starting a new edit, cancel it.
        pendingEditWorkItem?.cancel()
        pendingEditWorkItem = nil

        // To finish editing we need a current editor.
        guard let editor = inlineTitleEditor else { return }
        let editedTitle = editor.stringValue
        let targetWindow = inlineTitleTargetWindow

        // Clear coordinator references first so re-entrant paths don't see stale state.
        editor.delegate = nil
        inlineTitleEditor = nil
        inlineTitleTargetWindow = nil

        // Make sure the window grabs focus again
        if let hostWindow {
            if let currentEditor = editor.currentEditor(), hostWindow.firstResponder === currentEditor {
                hostWindow.makeFirstResponder(nil)
            } else if hostWindow.firstResponder === editor {
                hostWindow.makeFirstResponder(nil)
            }
        }

        editor.removeFromSuperview()

        // Restore original tab title presentation.
        for (label, wasHidden) in hiddenLabels {
            label.isHidden = wasHidden
        }
        hiddenLabels.removeAll()

        if let buttonState {
            buttonState.button.title = buttonState.title
            buttonState.button.attributedTitle = buttonState.attributedTitle ?? NSAttributedString(string: buttonState.title)
        }
        self.buttonState = nil

        // Delegate owns title persistence semantics (including empty-title handling).
        guard commit, let targetWindow else { return }
        delegate?.tabTitleEditor(self, didCommitTitle: editedTitle, for: targetWindow)
    }

    /// Chooses an editor frame that aligns with the tab title within the tab button.
    private func tabTitleEditorFrame(for tabButton: NSView, sourceLabel: NSTextField?) -> NSRect {
        let bounds = tabButton.bounds
        let horizontalInset: CGFloat = 6
        var frame = bounds.insetBy(dx: horizontalInset, dy: 0)

        if let sourceLabel {
            let labelFrame = tabButton.convert(sourceLabel.bounds, from: sourceLabel)
            frame.origin.y = labelFrame.minY
            frame.size.height = labelFrame.height
        }

        return frame.integral
    }

    /// Selects the best title label candidate from private tab button subviews.
    private func sourceTabTitleLabel(from labels: [NSTextField], matching title: String) -> NSTextField? {
        let expected = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !expected.isEmpty {
            // Prefer a visible exact title match when we can find one.
            if let exactVisible = labels.first(where: {
                !$0.isHidden &&
                $0.alphaValue > 0.01 &&
                $0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == expected
            }) {
                return exactVisible
            }

            // Fall back to any exact match, including hidden labels.
            if let exactAny = labels.first(where: {
                $0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == expected
            }) {
                return exactAny
            }
        }

        // Otherwise heuristically choose the largest visible, centered label first.
        let visibleNonEmpty = labels.filter {
            !$0.isHidden &&
            $0.alphaValue > 0.01 &&
            !$0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        if let centeredVisible = visibleNonEmpty
            .filter({ $0.alignment == .center })
            .max(by: { $0.bounds.width < $1.bounds.width }) {
            return centeredVisible
        }

        if let visible = visibleNonEmpty.max(by: { $0.bounds.width < $1.bounds.width }) {
            return visible
        }

        return labels.max(by: { $0.bounds.width < $1.bounds.width })
    }

    /// Copies text styling from the source tab label onto the inline editor.
    private func applyTextStyle(to editor: NSTextField, from label: NSTextField, title: String) {
        var attributes: [NSAttributedString.Key: Any] = [:]
        if label.attributedStringValue.length > 0 {
            attributes = label.attributedStringValue.attributes(at: 0, effectiveRange: nil)
        }

        if attributes[.font] == nil, let font = label.font {
            attributes[.font] = font
        }

        if attributes[.foregroundColor] == nil {
            attributes[.foregroundColor] = label.textColor
        }

        if let font = attributes[.font] as? NSFont {
            editor.font = font
        }

        if let textColor = attributes[.foregroundColor] as? NSColor {
            editor.textColor = textColor
        }

        if !attributes.isEmpty {
            editor.attributedStringValue = NSAttributedString(string: title, attributes: attributes)
        } else {
            editor.stringValue = title
        }
    }

    // MARK: NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === inlineTitleEditor else { return false }

        // Enter commits and exits inline edit.
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            finishEditing(commit: true)
            return true
        }

        // Escape cancels and restores the previous tab title.
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finishEditing(commit: false)
            return true
        }

        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let inlineTitleEditor,
              let finishedEditor = obj.object as? NSTextField,
              finishedEditor === inlineTitleEditor
        else { return }

        // Blur/end-edit commits, matching standard NSTextField behavior.
        finishEditing(commit: true)
    }
}
