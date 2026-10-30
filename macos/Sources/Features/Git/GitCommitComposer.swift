import SwiftUI

struct GitCommitComposer: View {
    @Binding var message: String
    let stagedCount: Int
    let isBusy: Bool
    let canCommit: Bool
    let isUpdatingIndex: Bool
    let commit: () -> Void
    var repository: GitRepositoryIdentity?
    var unstagedCount = 0
    var canStageAll = true
    var hasHead = false
    var submit: (Bool, Bool) -> Void = { _, _ in }
    @ObservedObject private var settings = OhMyGhosttySettings.shared
    @State private var generation: Task<Void, Never>?
    @State private var generationID: UUID?
    @State private var draftRevision = 0
    @State private var replaceConfirmationID: UUID?
    @State private var notice: String?
    @State private var noticeID = UUID()
    @State private var noticeExpires = false
    @State private var editorHeight: CGFloat = 44
    @State private var focused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let notice {
                HStack(alignment: .top) {
                    Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer(minLength: 0)
                    NativeActionButton(
                        symbol: "xmark",
                        help: GitL10n.text("Dismiss message"),
                        height: 22
                    ) { _ in
                        self.notice = nil
                    }
                }
            }
            GitCommitMessageEditor(text: $message, height: $editorHeight, focusChanged: { focused = $0 })
                .frame(height: editorHeight)
                .overlay(alignment: .topLeading) {
                    if message.isEmpty {
                        Text(GitL10n.text("Commit message")).font(.system(size: 11)).foregroundStyle(.tertiary)
                            .padding(.leading, 9).padding(.top, 6).allowsHitTesting(false)
                    }
                }
                .modifier(GitInputSurface(focused: focused))
            HStack(spacing: 6) {
                NativeActionButton(
                    symbol: generationID == nil ? "sparkles" : "stop.fill",
                    help: GitL10n.text(
                        generationID == nil
                            ? "Generate a commit message using your configured agents"
                            : "Cancel"
                    ),
                    enabled: generationID != nil || !(isBusy || isUpdatingIndex || !canCommit || stagedCount == 0 || repository == nil),
                    style: .bordered,
                    height: 28,
                    identifier: "git.commit.generate"
                ) { button in
                    if generationID != nil {
                        cancelGeneration()
                    } else {
                        requestGeneration(from: button.window)
                    }
                }
                HStack(spacing: 0) {
                    NativeActionButton(
                        title: GitL10n.text("Commit Staged"),
                        symbol: isBusy || generationID != nil ? "arrow.triangle.2.circlepath" : "checkmark",
                        enabled: allowsSubmit(stageAll: false, amend: false),
                        style: .prominent,
                        height: 28,
                        expands: true,
                        identifier: "git.commit.staged"
                    ) { _ in commit() }
                    Color.clear.frame(width: 4, height: 28)
                    NativeMenuButton(
                        symbol: "chevron.down",
                        help: GitL10n.text("Commit options"),
                        enabled: menuEnabled,
                        style: .bordered,
                        height: 28,
                        identifier: "git.commit.options",
                        entries: commitMenuEntries
                    )
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
            }
        }
        .onChange(of: message) { _ in draftRevision += 1 }
        .onChange(of: repository) { _ in
            cancelGeneration()
            replaceConfirmationID = nil
            notice = nil
        }
        .onDisappear {
            cancelGeneration()
            replaceConfirmationID = nil
        }
        .task(id: noticeID) {
            guard noticeExpires else { return }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard !Task.isCancelled else { return }
            notice = nil
        }
    }

    private var menuEnabled: Bool {
        allowsSubmit(stageAll: false, amend: false) || allowsSubmit(stageAll: true, amend: false) ||
        allowsSubmit(stageAll: false, amend: true) || allowsSubmit(stageAll: true, amend: true)
    }

    private func allowsSubmit(stageAll: Bool, amend: Bool) -> Bool {
        guard generationID == nil, !isBusy, !isUpdatingIndex, canCommit,
              !stageAll || canStageAll, !amend || hasHead else { return false }
        let hasChanges = stagedCount > 0 || (stageAll && unstagedCount > 0)
        return (amend || hasChanges) && (amend || !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var commitMenuEntries: [NativeMenuEntry] {
        [
            .action(
                GitL10n.text("Commit Staged"),
                symbol: "checkmark",
                enabled: allowsSubmit(stageAll: false, amend: false)
            ) { submit(false, false) },
            .action(
                GitL10n.text("Stage All and Commit"),
                symbol: "plus",
                enabled: allowsSubmit(stageAll: true, amend: false)
            ) { submit(true, false) },
            .separator,
            .action(
                GitL10n.text("Amend Last Commit"),
                symbol: "arrow.uturn.backward",
                enabled: allowsSubmit(stageAll: false, amend: true)
            ) { submit(false, true) },
            .action(
                GitL10n.text("Stage All and Amend"),
                symbol: "plus",
                enabled: allowsSubmit(stageAll: true, amend: true)
            ) { submit(true, true) },
        ]
    }

    private func requestGeneration(from window: NSWindow?) {
        guard !settings.gitCommitAIRoutes.isEmpty else { SettingsNavigation.open(.git); return }
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            startGeneration()
            return
        }

        guard let window else { return }
        let confirmationID = UUID()
        replaceConfirmationID = confirmationID
        let originalRevision = draftRevision
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = GitL10n.text("Replace the existing commit message?")
        alert.addButton(withTitle: GitL10n.text("Generate and Replace"))
        alert.addButton(withTitle: GitL10n.text("Cancel"))
        let accept: (NSApplication.ModalResponse) -> Void = { [self] response in
            guard response == .alertFirstButtonReturn,
                  replaceConfirmationID == confirmationID,
                  draftRevision == originalRevision else { return }
            replaceConfirmationID = nil
            startGeneration()
        }
        alert.beginSheetModal(for: window, completionHandler: accept)
    }

    private func cancelGeneration() {
        generation?.cancel()
        generation = nil
        generationID = nil
    }

    private func startGeneration() {
        guard let repository, generationID == nil, !isBusy, !isUpdatingIndex, canCommit, stagedCount > 0 else { return }
        let id = UUID()
        let revision = draftRevision
        let routes = settings.gitCommitAIRoutes
        generationID = id
        notice = nil
        noticeExpires = false
        noticeID = UUID()
        let customPrompt = settings.gitCommitAIPrompt
        generation = Task { @MainActor in
            defer {
                if generationID == id { generationID = nil; generation = nil }
            }
            do {
                let result = try await GitCommitAIService().generate(repository: repository, routes: routes, customPrompt: customPrompt)
                guard !Task.isCancelled, generationID == id else { return }
                guard draftRevision == revision else {
                    notice = GitL10n.text("Your draft changed during generation. It was not replaced; generate again.")
                    return
                }
                message = result.message
                notice = (result.attempt > 1 ? GitL10n.text("Generated using fallback: ") : GitL10n.text("Generated using: ")) + result.route.title
                noticeExpires = true
                noticeID = UUID()
            } catch {
                guard !Task.isCancelled, generationID == id else { return }
                if case GitExecutionError.outputLimitExceeded = error {
                    notice = GitL10n.text("Staged changes are too large for AI generation (200 KB patch limit). Split the commit and try again.")
                } else { notice = error.localizedDescription }
            }
        }
    }
}

/// Keep the text view and its selection/undo stack alive through status updates.
struct GitCommitMessageEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var focusChanged: (Bool) -> Void = { _ in }
    @Environment(\.gitCollectionColors) private var colors
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 44))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = GitCommitTextView(frame: scroll.bounds)
        editor.focusChanged = { [weak coordinator = context.coordinator] focused in
            DispatchQueue.main.async { coordinator?.parent.focusChanged(focused) }
        }
        editor.isRichText = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 11)
        editor.textColor = .labelColor
        editor.textContainerInset = NSSize(width: 4, height: 5)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel(GitL10n.text("Commit message"))
        editor.delegate = context.coordinator
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        editor.textColor = colors.text
        if editor.string != text {
            let selection = editor.selectedRange()
            editor.string = text
            let location = min(selection.location, (text as NSString).length)
            editor.setSelectedRange(NSRange(location: location, length: min(selection.length, (text as NSString).length - location)))
        }
        context.coordinator.measure(editor)
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GitCommitMessageEditor
        init(_ parent: GitCommitMessageEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            measure(editor)
        }
        func measure(_ editor: NSTextView) {
            guard let manager = editor.layoutManager, let container = editor.textContainer else { return }
            manager.ensureLayout(for: container)
            let height = min(112, max(44, ceil(manager.usedRect(for: container).height) + 10))
            guard abs(parent.height - height) > 0.5 else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, abs(self.parent.height - height) > 0.5 else { return }
                self.parent.height = height
            }
        }
    }
}
