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
    /// **Real implementation (U4 / SEA-160).** Replaces the U3 stub.
    ///
    /// Behavior contract (R2, R3):
    ///
    /// 1. Always opens the task's `.md` file in the default editor.
    /// 2. Writes `status: running` to the task's frontmatter via
    ///    `TaskStore.writeStatus` — throws on disk error (D13).
    /// 3. Clears any previous row-level error chip on a successful write.
    /// 4. Calls `SessionCoordinator.startOrFocusSession` to spawn or focus a
    ///    terminal at the task's `project-path` (authoritative) or a
    ///    `WorkspaceStore` project lookup (fallback). Handler is **write-only**
    ///    w.r.t. UI state — the `TaskFileWatcher` fires on the `.md` change and
    ///    `TaskStore.recomputeLanes()` migrates the row to Running (R3).
    /// 5. If `startOrFocusSession` finds no live session and the resolved-paths
    ///    cache has a stale entry (terminal exited but row still says running),
    ///    it respawns at `project-path`. Status stays `running`. Auto-migration
    ///    to Graveyard is NOT done here — that belongs to the surface-close
    ///    handler (D8).
    ///
    /// D14 guards (enforced by the caller, `RowClickRouter.handleRowClick`):
    ///
    /// - 180ms `.allowsHitTesting(false)` window on the row while the animation
    ///   plays. `RowClickRouter` publishes `hitTestingBlockedTaskIds`; the row
    ///   view applies the guard reactively.
    /// - 400ms post-write debounce: `RowClickRouter` arms a per-taskId timer
    ///   after this method returns successfully. A second click within that
    ///   window is dropped before reaching this function.
    ///
    /// D15: `DispatchQueue.main.async` is applied to the surface-CLOSE path in
    /// `SessionCoordinator.surfaceDidClose` (P2-004). The OPEN path here is
    /// already `@MainActor`, so NO additional dispatch is applied — doing so
    /// would re-order the spawn (ADV-004).
    ///
    /// - Throws: `CLIError` (from `TaskStore.writeStatus`) on disk I/O failure.
    ///   Caller (`RowClickRouter`) stores the error in `taskRowErrors` for the
    ///   row-level error chip (D13). No toast in v0.
    func startInboxTask(_ task: TaskItem) async throws {
        // 1. Always: open the .md file so the user has context while the
        //    terminal session warms up.
        openMarkdownFile(for: task)

        // 2. Write status: running to disk BEFORE spawning the session.
        //    This is the single source of truth for lane membership (R3):
        //    the file-watcher picks up the change and migrates the row to the
        //    Running zone without any manual UIstate mutation here.
        //    Throws on I/O failure → caller renders error chip (D13).
        try await taskStore.writeStatus(.running, for: task.id)

        // 3. Clear any prior error chip now that the write succeeded.
        RowClickRouter.shared.clearRowError(for: task.id)

        // 4. Terminal side: resolve the project cwd path.
        //    Resolution order:
        //      a. Explicit `project-path` frontmatter (authoritative; tilde-expanded)
        //      b. WorkspaceStore.projects lookup by name == task.project
        //      c. Give up on the terminal side — .md is already open.
        //
        //    D8: `startOrFocusSession` handles the stale resolved-paths case
        //    internally — if the terminal exited but the row still says running,
        //    it respawns at `rootPath`. Status stays `running`; do NOT migrate
        //    to Graveyard from this handler.
        //
        //    D9 + P1-001: The `coordinator` is the per-window instance injected
        //    by `TaskRowView`'s @EnvironmentObject — spawn fires only in the
        //    window where the click happened. If the row is clicked in window B
        //    for a task already running in window A, `startOrFocusSession` will
        //    find no live session in window B's coordinator and respawn locally
        //    in B (acceptable v0 behavior per D9).
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
        // A nil result lets `startOrFocusSession` use its own internal fallback.
        let resolvedTemplateName: String? = task.template
            ?? (defaultTaskTemplate.isEmpty ? nil : defaultTaskTemplate)

        if let path = resolvedPath {
            // 5a. Spawn or focus a session at the resolved project path.
            //     `startOrFocusSession` is synchronous (@MainActor) — no additional
            //     async dispatch needed (ADV-004: dispatching async re-orders spawn).
            coordinator.startOrFocusSession(
                forProjectNamed: task.project,
                rootPath: path,
                templateName: resolvedTemplateName,
                sourceTaskId: task.id
            )
        } else if let storeProject = workspaceStore.projects
            .first(where: { $0.name == task.project }) {
            // 5b. Fallback: no filesystem path resolvable, but a project with
            //     this name exists — focus whatever live session it has, don't spawn.
            //     (The .md and status write already happened above.)
            coordinator.focusLastSession(forProject: storeProject.id)
        }
        // else: no path and no matching project — .md is open, status is written.
        // The file-watcher will migrate the row to Running; no terminal here.
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

    /// Open the task's `.md` file only. Inline expansion is U7.
    ///
    /// Real impl (U7) will add: in-sidebar expansion to show the task's goal,
    /// activity log, and a re-open button.
    func expandGraveyardTask(_ task: TaskItem) {
        // v0 stub: open .md only; inline expansion is U7.
        openMarkdownFile(for: task)
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
