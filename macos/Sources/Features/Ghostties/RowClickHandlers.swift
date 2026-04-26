import AppKit
import Foundation

/// Handler stubs for the five R1 click lanes.
///
/// Each method corresponds to one `RowClickLane` case. U4–U7 will replace
/// the stub bodies with real implementations; U3's job is to wire the lanes
/// and preserve the existing Inbox-with-project behavior in `startInboxTask`.
///
/// Handlers are instantiated per-click by `RowClickRouter.handleRowClick`
/// so they always hold the current environment objects without needing to
/// store weak refs or observe lifecycle.
@MainActor
struct RowClickHandlers {
    let taskStore: TaskStore
    let coordinator: SessionCoordinator
    let workspaceStore: WorkspaceStore
    /// User preference: which `AgentTemplate` to launch when a task row is
    /// clicked and the task itself doesn't specify one. Passed through from
    /// `TaskRowView`'s `@AppStorage("ghostties.defaultTaskTemplate")`.
    let defaultTaskTemplate: String

    // MARK: - Inbox lane (with project context)

    /// Start or focus a terminal session for the task's project.
    ///
    /// **AE1 behavior preserved:** opens the `.md` file AND starts/focuses a
    /// terminal session, exactly as the original `handleTap()` did. This is the
    /// full Inbox-with-project experience on day one.
    ///
    /// Real impl (U4) will add: new-task creation via MCP `create_task` before
    /// the session spawn, proper `sourceTaskId` threading, and error feedback.
    func startInboxTask(_ task: TaskItem) {
        // Always: open the .md file.
        openMarkdownFile(for: task)

        // Terminal side: resolve the project cwd path.
        // Path resolution order (matches original handleTap):
        //   1. Explicit `project-path` frontmatter (authoritative; tilde-expanded)
        //   2. WorkspaceStore.projects lookup by name == task.project
        //   3. Give up on the terminal side — keep the .md open as the useful half.
        let resolvedPath: String? = {
            if let raw = task.projectPath, !raw.isEmpty {
                return (raw as NSString).expandingTildeInPath
            }
            if let storeProject = workspaceStore.projects
                .first(where: { $0.name == task.project }) {
                return storeProject.rootPath
            }
            return nil
        }()

        // Template resolution: task frontmatter wins over user preference.
        // A nil result lets `startOrFocusSession` use its own fallback.
        let resolvedTemplateName: String? = task.template
            ?? (defaultTaskTemplate.isEmpty ? nil : defaultTaskTemplate)

        if let path = resolvedPath {
            coordinator.startOrFocusSession(
                forProjectNamed: task.project,
                rootPath: path,
                templateName: resolvedTemplateName,
                sourceTaskId: task.id
            )
        } else if let storeProject = workspaceStore.projects
            .first(where: { $0.name == task.project }) {
            // Fallback: no path resolvable, but a project with this name
            // exists — focus whatever live session it has, don't spawn.
            coordinator.focusLastSession(forProject: storeProject.id)
        }
        // else: silent skip; the .md was already opened.
    }

    // MARK: - Inbox lane (orphan — no project context)

    /// Open the task's `.md` file only. No terminal spawn — orphan has no
    /// project context to attach to.
    ///
    /// Real impl (U6) will add the triage card UI for assigning a project.
    func triageOrphanTask(_ task: TaskItem) {
        // v0 stub: open .md only; triage card UI is U6.
        openMarkdownFile(for: task)
    }

    // MARK: - Running lane

    /// Open the task's `.md` file and focus the existing session if any.
    ///
    /// Real impl (U5) will add: smarter session lookup via `sourceTaskId`,
    /// visual focus indicator, and fallback spawn if the session has been GC'd.
    func focusRunningTask(_ task: TaskItem) {
        // v0 stub: open .md and focus existing session.
        openMarkdownFile(for: task)
        focusExistingSession(for: task)
    }

    // MARK: - Needs-you lane

    /// Open the task's `.md` file and focus the existing session if any.
    ///
    /// Real impl (U5) will add: scroll-to-prompt, input-focus on the needs-you
    /// pane, and visual indicator that input is expected.
    func focusNeedsYouTask(_ task: TaskItem) {
        // v0 stub: same as focusRunningTask — open .md and focus session.
        openMarkdownFile(for: task)
        focusExistingSession(for: task)
    }

    // MARK: - Graveyard lane (done)

    /// Toggle inline expansion for the given Graveyard (done) row.
    ///
    /// D4 / D11: single-expansion within the Graveyard lane. Opening a row
    /// auto-collapses any previously-open row. Re-clicking an open row (D10)
    /// collapses it. Column 2 is never touched — no `SessionCoordinator` call.
    func expandGraveyardTask(_ task: TaskItem) {
        taskStore.toggleGraveyardExpansion(for: task.id)
    }

    // MARK: - Private helpers

    /// Open the task's `.md` file in the user's default editor.
    /// Tolerates a nil `fileURL` silently — callers don't need to guard.
    private func openMarkdownFile(for task: TaskItem) {
        if let url = taskStore.fileURL(for: task) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Focus the last active session associated with the task's project.
    ///
    /// Resolves the project from `WorkspaceStore` by name, then delegates to
    /// `SessionCoordinator.focusLastSession(forProject:)`. No-ops silently if
    /// no matching project or session is found.
    private func focusExistingSession(for task: TaskItem) {
        guard let storeProject = workspaceStore.projects
            .first(where: { $0.name == task.project }) else { return }
        coordinator.focusLastSession(forProject: storeProject.id)
    }
}
