import AppKit

@MainActor
enum GitTagDialog {
    static let panelSize = NSSize(width: 520, height: 300)

    static func present(repository: GitRepositoryIdentity, commit: GitHistoryCommit,
                        window: NSWindow?) async -> GitMutation? {
        await withCheckedContinuation { continuation in
            let panel = NSPanel(contentRect: NSRect(origin: .zero, size: panelSize),
                                styleMask: [.titled], backing: .buffered, defer: false)
            panel.title = GitL10n.text("New Tag…")
            panel.isReleasedWhenClosed = false
            panel.appearance = window?.appearance ?? NSApp.effectiveAppearance
            let palette = OMGThemeBackground.palette(for: window)
            panel.backgroundColor = palette.background
            panel.titlebarAppearsTransparent = true
            panel.isOpaque = true
            let controller = GitTagDialogController(repository: repository, commit: commit) { mutation in
                if let window { window.endSheet(panel) }
                panel.orderOut(nil)
                panel.contentViewController = nil
                continuation.resume(returning: mutation)
            }
            panel.contentViewController = controller
            (controller.view as? OMGNativeSurfaceView)?.bindTheme(to: window)
            if let window { window.beginSheet(panel) } else { panel.makeKeyAndOrderFront(nil) }
        }
    }
}

@MainActor
final class GitTagDialogController: NSViewController, NSWindowDelegate, NSTextFieldDelegate {
    private let repository: GitRepositoryIdentity
    private let commit: GitHistoryCommit
    private let finish: (GitMutation?) -> Void
    private let nameField = NSTextField()
    private let messageField = NSTextField()
    private let statusField = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let createButton = NSButton(title: GitL10n.text("Create Tag"), target: nil, action: nil)
    private let suggestButton = NSButton(title: GitL10n.text("Generate"), target: nil, action: nil)
    private var task: Task<Void, Never>?
    private var didFinish = false
    private var isBusy = false

    init(repository: GitRepositoryIdentity, commit: GitHistoryCommit, finish: @escaping (GitMutation?) -> Void) {
        self.repository = repository
        self.commit = commit
        self.finish = finish
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = OMGNativeSurfaceView()
        root.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: GitL10n.text("New Tag…"))
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let commitLabel = NSTextField(wrappingLabelWithString: commit.id.shortSHA + " · " + commit.subject)
        commitLabel.textColor = .secondaryLabelColor
        commitLabel.maximumNumberOfLines = 2
        nameField.placeholderString = "v1.2.0"
        nameField.setAccessibilityLabel(GitL10n.text("Tag name"))
        nameField.delegate = self
        messageField.placeholderString = GitL10n.text("Optional tag message")
        messageField.stringValue = commit.subject
        messageField.setAccessibilityLabel(GitL10n.text("Message"))
        suggestButton.target = self
        suggestButton.action = #selector(suggest)
        suggestButton.bezelStyle = .rounded
        statusField.textColor = .systemRed
        statusField.maximumNumberOfLines = 4
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false

        let nameRow = NSStackView(views: [
            NSTextField(labelWithString: GitL10n.text("Tag name")), nameField,
            progress, suggestButton
        ])
        nameRow.alignment = .centerY
        let messageRow = NSStackView(views: [
            NSTextField(labelWithString: GitL10n.text("Message")), messageField
        ])
        messageRow.alignment = .centerY
        nameRow.views[0].widthAnchor.constraint(equalToConstant: 78).isActive = true
        messageRow.views[0].widthAnchor.constraint(equalToConstant: 78).isActive = true

        let help = NSTextField(wrappingLabelWithString: GitL10n.text(
            "Create suggests the next minor version from the branch's tag history. The tag is pushed with the next push (--follow-tags)."
        ))
        help.textColor = .secondaryLabelColor
        help.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let cancel = button(GitL10n.text("Cancel"), action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        createButton.target = self
        createButton.action = #selector(createTag)
        createButton.bezelStyle = .rounded
        createButton.keyEquivalent = "\r"
        let actions = NSStackView(views: [cancel, NSView(), createButton])
        let stack = NSStackView(views: [title, commitLabel, nameRow, messageRow, help, statusField, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        messageField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -16),
            nameRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            messageRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        view = root
        updateValidation()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.delegate = self
        view.window?.makeFirstResponder(nameField)
        updateValidation()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        task?.cancel()
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let result = NSButton(title: title, target: self, action: action)
        result.bezelStyle = .rounded
        return result
    }

    func controlTextDidChange(_ notification: Notification) {
        updateValidation()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        task?.cancel()
        finishOnce(nil)
        return false
    }

    @objc private func cancel() { task?.cancel(); finishOnce(nil) }

    @objc private func createTag() {
        guard !didFinish, !isBusy else { return }
        do {
            try GitTagService.validate(nameField.stringValue)
            finishOnce(.createTag(name: nameField.stringValue,
                                  message: messageField.stringValue.isEmpty ? nameField.stringValue : messageField.stringValue,
                                  commit: commit.id))
        } catch {
            statusField.stringValue = error.localizedDescription
        }
    }

    @objc private func suggest() {
        guard !didFinish else { return }
        let settings = OhMyGhosttySettings.shared
        setBusy(true)
        statusField.stringValue = ""
        if settings.gitCommitAIRoutes.isEmpty {
            task = Task { @MainActor in
                defer { setBusy(false) }
                do {
                    if let suggestion = GitTagService.suggestNextMinor(tags: try await tagsMergedAtCommit()) {
                        guard !Task.isCancelled, !didFinish else { return }
                        nameField.stringValue = suggestion
                    }
                } catch {
                    if !Task.isCancelled, !didFinish { statusField.stringValue = error.localizedDescription }
                }
            }
            return
        }

        let routes = settings.gitCommitAIRoutes
        let style = settings.gitCommitAIPrompt
        task = Task { @MainActor in
            defer { setBusy(false) }
            do {
                let tags = try await tagsMergedAtCommit()
                let prompt = """
                Suggest the next Git tag for this branch. Existing tags merged at this commit:
                \(tags.prefix(40).joined(separator: "\n"))
                Increment the MINOR version of the latest version tag and reset patch (e.g. v1.6.124 -> v1.7.0).
                Return only the tag name, nothing else.
                """
                let generator = GitCommitAIService { route, text in
                    try await GitACPService.shared.generate(repository: self.repository, route: route,
                        style: "operation/tag/" + style, prompt: text)
                }
                let result = try await generator.generate(routes: routes, prompt: prompt)
                let candidate = result.message.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !Task.isCancelled, !didFinish else { return }
                if (try? GitTagService.validate(candidate)) != nil {
                    nameField.stringValue = candidate
                } else if let suggestion = GitTagService.suggestNextMinor(tags: tags) {
                    nameField.stringValue = suggestion
                }
            } catch {
                guard !Task.isCancelled, !didFinish else { return }
                let refreshedTags = try? await tagsMergedAtCommit()
                guard !Task.isCancelled, !didFinish else { return }
                if let refreshedTags,
                   let suggestion = GitTagService.suggestNextMinor(tags: refreshedTags) {
                    nameField.stringValue = suggestion
                } else {
                    statusField.stringValue = error.localizedDescription
                }
            }
        }
    }

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        if busy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        nameField.isEnabled = !busy
        messageField.isEnabled = !busy
        suggestButton.isEnabled = !busy
        updateValidation()
    }

    private func updateValidation() {
        let valid = (try? GitTagService.validate(nameField.stringValue)) != nil
        createButton.isEnabled = valid && !isBusy && !didFinish
        if valid { statusField.stringValue = "" }
    }

    private func finishOnce(_ mutation: GitMutation?) {
        guard !didFinish else { return }
        didFinish = true
        task?.cancel()
        finish(mutation)
    }

    private func tagsMergedAtCommit() async throws -> [String] {
        let result = try await repository.executor.execute(
            arguments: ["tag", "--merged", commit.id.rawValue, "--sort=-version:refname"],
            workingDirectory: repository.worktreePath, maxOutputBytes: 64_000)
        guard result.isSuccess else {
            throw GitExecutionError.processFailed(exitCode: result.exitCode, stderr: result.stderrString)
        }
        return result.stdoutString.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
