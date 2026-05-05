import AppKit
import Foundation
import SwiftUI

/// State machine and commit logic for the inline new-task composer (U8 / SEA-164).
///
/// One shared instance lives for the lifetime of the task sidebar. Only one
/// composer is open at a time (D11): opening while already open focuses the
/// title field instead of spawning a second card.
///
/// **Confirm flow (from D5):** writes a `.md` file with `status: running`
/// directly. The file-watcher picks it up, the row appears in Running, and
/// `SessionCoordinator` spawns a terminal at the project path. No call to
/// `startInboxTask` needed — the `.md` is already at running status.
///
/// **Cancel:** Esc closes the composer; no file is written. Title drafts are
/// NOT preserved across sessions (D23-v0 scope trim).
///
/// D26: lives flat under `macos/Sources/Features/Ghostties/`, no subdirectory.
@MainActor
final class NewTaskComposerStore: ObservableObject {

    // MARK: - Shared instance (D11)

    /// One composer per sidebar at a time.
    static let shared = NewTaskComposerStore()

    private init() {}

    #if DEBUG
    /// Test-only initialiser — isolated state, no singleton side-effects.
    init(isolatedForTesting: Void) {}
    #endif

    // MARK: - Visibility (D11)

    /// True when the composer panel is showing.
    @Published private(set) var isOpen: Bool = false

    /// When true, the title field should receive first responder on the next
    /// render cycle. Cleared by the view after the focus request is consumed.
    @Published var focusTitleFieldTrigger: Bool = false

    // MARK: - Field state

    /// The task title being composed. Required (non-whitespace-only to confirm).
    @Published var titleText: String = ""

    /// The `WorkspaceStore.Project.id` currently selected in the picker.
    /// Set by smart-default cascade on open (D6).
    @Published var selectedProjectId: UUID?

    /// Optional template name. Written to frontmatter only if non-empty.
    @Published var selectedTemplateName: String?

    // MARK: - Error state (D13)

    /// Inline error message shown inside the composer on write failure.
    /// Nil when no error. Cleared on next open or on successful write.
    @Published private(set) var writeError: String?

    // MARK: - MRU tracking (D6)

    /// The ID of the last project the user confirmed a task for.
    /// Backed by AppStorage so it survives app relaunches.
    @AppStorage("ghostties.newTaskComposerMRUProjectId")
    var mruProjectIdString: String = ""

    var mruProjectId: UUID? {
        get { UUID(uuidString: mruProjectIdString) }
        set { mruProjectIdString = newValue?.uuidString ?? "" }
    }

    // MARK: - Validation

    /// True when the title is non-empty (non-whitespace) and a project is selected.
    var canConfirm: Bool {
        !titleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedProjectId != nil
    }

    // MARK: - Open / focus

    /// Open the composer or, if already open, focus the title field (D11).
    ///
    /// Applies the smart-default cascade (D6):
    ///   1. cwd of the frontmost terminal session → matching `WorkspaceStore` project
    ///   2. MRU project (`mruProjectId`)
    ///   3. Most-recently-touched project (`project.lastActiveAt` descending)
    ///
    /// If `WorkspaceStore.shared.projects` is empty, `selectedProjectId` stays nil
    /// and the picker enters the "Add a project to begin" onboarding state (D7).
    func open(workspaceStore: WorkspaceStore) {
        if isOpen {
            // D11: second invocation → focus existing title field.
            focusTitleFieldTrigger = true
            return
        }

        // Reset field state.
        titleText = ""
        selectedTemplateName = nil
        writeError = nil

        // D6: smart-default cascade for project picker.
        selectedProjectId = resolveDefaultProject(workspaceStore: workspaceStore)

        isOpen = true
    }

    /// Close the composer without writing anything (cancel / Esc).
    func cancel() {
        isOpen = false
        titleText = ""
        selectedTemplateName = nil
        writeError = nil
    }

    // MARK: - Confirm

    /// Validate, write the `.md` file with `status: running`, and close.
    /// On write failure the composer stays open with an inline error (D13).
    func confirm(taskStore: TaskStore, workspaceStore: WorkspaceStore) async {
        let trimmedTitle = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, let projectId = selectedProjectId else { return }

        // Look up the project to get name + path.
        guard let project = workspaceStore.projects.first(where: { $0.id == projectId }) else {
            writeError = "Selected project no longer exists."
            return
        }

        writeError = nil

        do {
            _ = try await taskStore.createTask(
                title: trimmedTitle,
                project: project.name,
                status: .running,
                priority: .none,
                projectPath: project.rootPath,
                template: selectedTemplateName,
                source: "shell"
            )
            // Success: persist MRU, close composer.
            mruProjectId = projectId
            isOpen = false
            titleText = ""
            selectedTemplateName = nil
        } catch {
            // D13: keep composer open, show error inline.
            writeError = "Couldn't write task: \(error.localizedDescription)"
        }
    }

    // MARK: - D7: add-project via NSOpenPanel

    /// Invoked when the user taps "[+ Add project…]" chip inside the picker.
    /// Opens NSOpenPanel, adds the project, and auto-selects it.
    func addProjectViaPanel(workspaceStore: WorkspaceStore) {
        guard let newId = workspaceStore.addProjectViaFolderPicker() else { return }
        selectedProjectId = newId
        mruProjectId = newId
    }

    // MARK: - Smart-default cascade (D6)

    /// Returns the best-guess project ID using the three-step cascade.
    private func resolveDefaultProject(workspaceStore: WorkspaceStore) -> UUID? {
        let projects = workspaceStore.projects
        guard !projects.isEmpty else { return nil }

        // Step 1: cwd of the frontmost terminal session → match to a project by rootPath prefix.
        if let cwdMatch = resolveFromFrontmostTerminal(projects: projects) {
            return cwdMatch
        }

        // Step 2: MRU project (last confirmed via this composer).
        if let mru = mruProjectId, projects.contains(where: { $0.id == mru }) {
            return mru
        }

        // Step 3: Most-recently-touched project (lastActiveAt descending).
        let sorted = projects.sorted {
            switch ($0.lastActiveAt, $1.lastActiveAt) {
            case let (a?, b?): return a > b
            case (_?, nil): return true
            default: return false
            }
        }
        return sorted.first?.id
    }

    /// Step 1 of the cascade: find the project whose `rootPath` is a prefix
    /// of the frontmost NSWindow's title (which typically shows the cwd).
    ///
    /// macOS doesn't expose a terminal session's cwd via a public API.
    /// The best approximation without deep process inspection is the key
    /// window title, which Ghostty sets to the current working directory path.
    /// We match against `WorkspaceStore.projects` rootPaths.
    private func resolveFromFrontmostTerminal(projects: [Project]) -> UUID? {
        guard let keyWindow = NSApp.keyWindow else { return nil }
        let windowTitle = keyWindow.title

        // Try to match the window title (which is usually the cwd path or a
        // basename like "ghostties") against project root paths.
        // First try exact last-path-component match, then prefix match.
        for project in projects {
            let rootURL = URL(fileURLWithPath: project.rootPath)
            let basename = rootURL.lastPathComponent
            if windowTitle == basename || windowTitle.hasPrefix(project.rootPath) {
                return project.id
            }
        }
        return nil
    }
}
