import AppKit
import Foundation
import SwiftUI

/// State and commit logic for the inline orphan triage card (U6 / SEA-162).
///
/// One store lives for the lifetime of the task sidebar. Multiple orphan rows
/// can be clicked sequentially — only one card is open at a time (D11). The
/// currently active orphan id is `activeTaskId`; setting it to a new value
/// auto-collapses any previously open card.
///
/// The store owns the picker state, validation, and the two-step commit
/// sequence: write frontmatter → chain into `RowClickHandlers.startInboxTask`.
///
/// D26: lives flat under `macos/Sources/Features/Ghostties/`, no subdirectory.
@MainActor
final class OrphanTriageStore: ObservableObject {

    /// Shared instance. The triage card is a sidebar-level concern — one card
    /// per sidebar, not per row. `RowClickHandlers.triageOrphanTask` calls
    /// `shared.open(for:)` so any part of the sidebar can trigger triage
    /// without needing to pass the store through the view hierarchy.
    static let shared = OrphanTriageStore()

    private init() {}

    #if DEBUG
    /// Test-only initializer. Creates an isolated instance with empty state so
    /// unit tests can exercise state transitions without touching the singleton.
    init(isolatedForTesting: Void) {}
    #endif

    // MARK: - Active card state (D11)

    /// The task ID of the row whose inline triage card is currently open.
    /// `nil` means no card is showing. Setting this auto-dismisses any
    /// previously open card (no writes, just UI collapse).
    @Published private(set) var activeTaskId: String?

    // MARK: - Picker state

    /// The project the user has selected. Required — no smart-default (D6).
    /// `nil` until the user makes a choice; Confirm is disabled while nil.
    @Published var selectedProjectId: UUID?

    /// Optional template name. Written to frontmatter only if non-empty.
    @Published var selectedTemplateName: String?

    /// Edited task title. Shown pre-filled from `task.title`; written only
    /// if non-empty after trimming.
    @Published var editedTitle: String = ""

    // MARK: - Animation / hit-test guard (D14)

    /// When true, the row's tap target is disabled for the 180ms animation window.
    @Published private(set) var isAnimating: Bool = false

    // MARK: - Error state (D13)

    /// Task ids that had a frontmatter write failure. Drives the persistent
    /// error chip on the row. Cleared when the user retries or cancels.
    @Published var errorTaskIds: Set<String> = []

    // MARK: - Private

    private var animationTask: Task<Void, Never>?

    // MARK: - Open / close

    /// Open the triage card for `taskId`, resetting picker state and starting
    /// the animation guard. If a different card is already open, it collapses
    /// first (D11).
    ///
    /// - Parameters:
    ///   - task: The orphan task row that was clicked.
    ///   - defaultTitle: Pre-fills the title field from `task.title`.
    func open(for task: TaskItem) {
        guard activeTaskId != task.id else { return }    // already open — no-op
        // Collapse any prior card without writing (D11).
        activeTaskId = task.id
        selectedProjectId = nil
        selectedTemplateName = nil
        editedTitle = task.title
        errorTaskIds.remove(task.id)
        beginAnimationGuard()
    }

    /// Cancel the triage card. No writes. Row stays in Inbox.
    func cancel() {
        let closing = activeTaskId
        activeTaskId = nil
        selectedProjectId = nil
        selectedTemplateName = nil
        editedTitle = ""
        if let id = closing { errorTaskIds.remove(id) }
        animationTask?.cancel()
        isAnimating = false
    }

    // MARK: - D7 empty-projects flow

    /// Present NSOpenPanel, insert the chosen path into `WorkspaceStore`, and
    /// auto-select the new or existing project in the picker.
    func addProjectViaFolderPicker(workspaceStore: WorkspaceStore) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a project folder to associate with this task"
        panel.prompt = "Add Project"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        workspaceStore.addProject(at: url)

        // Auto-select the project we just added (or found by path if it already existed).
        let stdPath = url.standardizedFileURL.path
        if let match = workspaceStore.projects.first(where: { $0.rootPath == stdPath }) {
            selectedProjectId = match.id
        }
    }

    // MARK: - Validation

    /// True when a project is selected and the confirm action can proceed.
    var canConfirm: Bool {
        selectedProjectId != nil
    }

    // MARK: - Commit (D4 confirm flow)

    /// Write frontmatter and chain into `RowClickHandlers.startInboxTask`.
    ///
    /// Sequence:
    ///   1. Write `project-path` (mandatory).
    ///   2. If `editedTitle` is different from `task.title`, write `title`.
    ///   3. If `selectedTemplateName` is set, write `template`.
    ///   4. Close the card.
    ///   5. Call `startInboxTask` via the handlers to start the terminal session.
    ///
    /// Any write failure → `errorTaskIds.insert(task.id)`, card stays open (D13).
    ///
    /// - Parameters:
    ///   - task: The task being triaged.
    ///   - taskStore: Used for the frontmatter write APIs.
    ///   - workspaceStore: Used to resolve the selected project's root path.
    ///   - handlers: The `RowClickHandlers` bundle for this click context.
    func confirm(
        task: TaskItem,
        taskStore: TaskStore,
        workspaceStore: WorkspaceStore,
        handlers: RowClickHandlers
    ) {
        guard let projectId = selectedProjectId else { return }
        guard let project = workspaceStore.projects.first(where: { $0.id == projectId }) else { return }

        let projectPath = project.rootPath
        let trimmedTitle = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTitle = trimmedTitle.isEmpty ? task.title : trimmedTitle
        let templateName = selectedTemplateName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        Task { @MainActor in
            do {
                // Write project-path (mandatory).
                try await taskStore.writeProjectPath(projectPath, for: task.id)

                // Write title only if changed.
                if newTitle != task.title {
                    try await taskStore.writeTitle(newTitle, for: task.id)
                }

                // Write template if specified.
                if !templateName.isEmpty {
                    try await taskStore.writeTemplate(templateName, for: task.id)
                }

                // Close the card before starting the session.
                let taskId = task.id
                self.activeTaskId = nil
                self.selectedProjectId = nil
                self.selectedTemplateName = nil
                self.editedTitle = ""
                self.errorTaskIds.remove(taskId)

                // Chain into U4's startInboxTask. The file watcher will eventually
                // reload the updated TaskItem; we pass the updated values inline
                // by constructing a patched copy for the session spawn path.
                // RowClickHandlers.startInboxTask reads task.projectPath directly,
                // so build a patched TaskItem with the newly written project-path.
                let patchedTask = TaskItem(
                    id: task.id,
                    title: newTitle,
                    source: task.source,
                    sourceID: task.sourceID,
                    branch: task.branch,
                    project: task.project,
                    projectPath: projectPath,
                    template: templateName.isEmpty ? task.template : templateName,
                    created: task.created,
                    status: task.status,
                    priority: task.priority,
                    filesStaged: task.filesStaged,
                    goal: task.goal,
                    notes: task.notes,
                    needs: task.needs,
                    severity: task.severity,
                    pr: task.pr,
                    prState: task.prState,
                    ci: task.ci,
                    completed: task.completed,
                    events: task.events
                )
                try await handlers.startInboxTask(patchedTask)

            } catch {
                // D13: write failed — persist error chip, card stays open.
                self.errorTaskIds.insert(task.id)
            }
        }
    }

    // MARK: - Private helpers

    /// Blocks row hit-testing for 180ms while the card reveals (D14).
    private func beginAnimationGuard() {
        animationTask?.cancel()
        isAnimating = true
        animationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            self.isAnimating = false
        }
    }
}
