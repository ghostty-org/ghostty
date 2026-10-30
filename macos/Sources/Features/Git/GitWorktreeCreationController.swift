import AppKit

@MainActor
final class GitWorktreeCreationController: NSViewController, NSTextFieldDelegate {
    private let start: String
    private let repository: GitRepositoryIdentity
    private let forcedDetached: Bool
    private let finish: (GitWorktreeActions.Creation?) -> Void
    private let root = OMGNativeSurfaceView()
    let pathField = OMGNativeTextField()
    let branchField = OMGNativeTextField()
    let modePicker = OMGNativePopUpButton()
    let openButton = NSButton(checkboxWithTitle: GitL10n.text("Open in a new tab after creation"), target: nil, action: nil)
    let createButton = NativeActionControl()
    private let branchLabel = NSTextField(labelWithString: GitL10n.text("New branch name"))
    private let validation = NSTextField(wrappingLabelWithString: "")
    private var didFinish = false

    init(start: String?, repository: GitRepositoryIdentity, detached: Bool,
         finish: @escaping (GitWorktreeActions.Creation?) -> Void) {
        self.start = start ?? "HEAD"
        self.repository = repository
        self.forcedDetached = detached
        self.finish = finish
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let title = NSTextField(labelWithString: GitL10n.text("Create Worktree"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString:
            GitL10n.format("Choose a directory and how to check out {0}.", start))
        subtitle.font = .systemFont(ofSize: 11)
        pathField.stringValue = (repository.worktreePath as NSString).deletingLastPathComponent + "/"
        pathField.placeholderString = GitL10n.text("Absolute worktree directory")
        branchField.placeholderString = "feature/new-worktree"
        for field in [pathField, branchField] {
            field.delegate = self
            field.controlSize = .small
            field.font = .systemFont(ofSize: 12)
            field.focusRingType = .none
            field.bezelStyle = .roundedBezel
        }
        modePicker.addItems(withTitles: [GitL10n.text("New branch"), "Detached HEAD"])
        if start.hasPrefix("refs/heads/") { modePicker.addItem(withTitle: GitL10n.text("Existing branch")) }
        modePicker.selectItem(at: forcedDetached ? 1 : 0)
        modePicker.isEnabled = !forcedDetached
        modePicker.target = self
        modePicker.action = #selector(modeChanged)
        modePicker.controlSize = .small
        openButton.state = .on
        openButton.controlSize = .small
        openButton.font = .systemFont(ofSize: 11)
        validation.font = .systemFont(ofSize: 10)
        validation.maximumNumberOfLines = 2
        let cancel = NativeActionControl()
        cancel.configure(title: GitL10n.text("Cancel"), symbol: nil, help: nil,
                         enabled: true, style: .bordered, identifier: "worktree.cancel")
        cancel.keyEquivalent = "\u{1b}"
        cancel.keyEquivalentModifierMask = []
        cancel.onPress = { [weak self] in self?.complete(nil) }
        createButton.configure(title: GitL10n.text("Create"), symbol: nil, help: nil,
                               enabled: false, style: .prominent, identifier: "worktree.create")
        createButton.onPress = { [weak self] in self?.submit() }
        createButton.keyEquivalent = "\r"
        createButton.keyEquivalentModifierMask = []
        let actions = NSStackView(views: [cancel, NSView(), createButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        let directoryLabel = NSTextField(labelWithString: GitL10n.text("Absolute worktree directory"))
        let modeLabel = NSTextField(labelWithString: GitL10n.text("Checkout"))
        for label in [directoryLabel, modeLabel, branchLabel] { label.font = .systemFont(ofSize: 11, weight: .medium) }
        let stack = NSStackView(views: [
            title, subtitle, directoryLabel, pathField, modeLabel, modePicker,
            branchLabel, branchField, openButton, validation, actions,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(16, after: subtitle)
        stack.setCustomSpacing(16, after: validation)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(equalToConstant: 430),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.heightAnchor.constraint(equalToConstant: 28),
        ])
        for field in [pathField, branchField] {
            field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            field.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        modePicker.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        modePicker.heightAnchor.constraint(equalToConstant: 28).isActive = true
        subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        validation.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        view = root
        root.onThemeChange = { [weak self] theme in self?.validation.textColor = theme.secondary }
        refresh()
    }

    func bindTheme(to window: NSWindow?) { _ = view; root.bindTheme(to: window) }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(pathField)
    }

    var creation: GitWorktreeActions.Creation? {
        let path = pathField.stringValue
        let branch = branchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("\n"), !path.contains("\r"),
              URL(fileURLWithPath: path).standardizedFileURL.path !=
                URL(fileURLWithPath: (repository.worktreePath as NSString).deletingLastPathComponent).standardizedFileURL.path,
              modePicker.indexOfSelectedItem != 0 || !branch.isEmpty else { return nil }
        return .init(mutation: .addWorktree(path: path, start: start,
                     branch: modePicker.indexOfSelectedItem == 0 ? branch : nil,
                     detached: modePicker.indexOfSelectedItem == 1), openAfterCreation: openButton.state == .on)
    }

    func controlTextDidChange(_ notification: Notification) { refresh() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if command == #selector(NSResponder.insertNewline(_:)) { submit(); return true }
        if command == #selector(NSResponder.cancelOperation(_:)) { complete(nil); return true }
        return false
    }
    @objc func modeChanged() { refresh() }
    private func refresh() {
        let isNew = modePicker.indexOfSelectedItem == 0
        branchField.isEnabled = isNew
        branchField.applyTheme(root.theme)
        branchLabel.textColor = isNew ? root.theme.foreground : root.theme.disabled
        createButton.isEnabled = creation != nil
        validation.stringValue = creation == nil
            ? GitL10n.text("Choose a new absolute directory and enter a branch name when creating a branch.") : ""
    }
    func submit() { if let creation { complete(creation) } }
    private func complete(_ creation: GitWorktreeActions.Creation?) {
        guard !didFinish else { return }
        didFinish = true
        finish(creation)
    }
}
