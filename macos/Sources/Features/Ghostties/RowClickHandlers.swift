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
        // 1. Write status: running to disk BEFORE spawning the session.
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
                sourceTaskId: task.id,
                sourceTaskFilePath: taskStore.fileURL(for: task)?.path,
                forceSpawn: true
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

    /// Open the inline triage card for the orphan row.
    ///
    /// Delegates to `OrphanTriageStore.shared.open(for:)` which opens the card
    /// inline below the anchor row. One card at a time (D11 — auto-collapses
    /// any previously open card). The .md file is NOT opened here; U6's card
    /// collects a project first, then chains into `startInboxTask` on confirm.
    func triageOrphanTask(_ task: TaskItem) {
        OrphanTriageStore.shared.open(for: task)
    }

    // MARK: - Running lane

    /// Route column 2 to the task's existing terminal session and focus the cursor.
    ///
    /// No status flip, no respawn — except D8: if no live SurfaceView exists for
    /// this task (the process exited but `surface-close` hasn't fired yet),
    /// respawn at `project-path` so the user always gets a terminal. Status stays
    /// `running`; auto-migration to Graveyard remains the surface-close handler's job.
    func focusRunningTask(_ task: TaskItem) async {
        await routeToExistingSession(task)
    }

    // MARK: - Needs-you lane

    /// Route column 2 to the task's existing terminal session and focus the cursor.
    ///
    /// Identical to `focusRunningTask` in v0 — both lanes share the same
    /// routing logic. Lane membership for Needs-you is `task.status == .needsYou`
    /// from frontmatter only (R7); the live `isLikelyPromptingForInput` heuristic
    /// continues to drive the per-session indicator dot — no change to that wiring.
    func focusNeedsYouTask(_ task: TaskItem) async {
        await routeToExistingSession(task)
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

    /// Route column 2 to the task's existing terminal session (D8/D9 aware).
    ///
    /// Decision tree:
    ///   1. This window's coordinator has a live session for the project → focus it.
    ///   2. No live session in this window, but one is running globally (in another
    ///      window) → D9 silent no-op. Cross-window routing + "running in another
    ///      window" affordance are deferred to v1+.
    ///   3. No live session anywhere (process exited/crashed but surface-close hasn't
    ///      fired yet) → D8 respawn at `project-path`. Status stays `running`;
    ///      auto-migration to Graveyard is the surface-close handler's responsibility.
    private func routeToExistingSession(_ task: TaskItem) async {
        // Resolve the project record by name.
        guard let storeProject = workspaceStore.projects
            .first(where: { $0.name == task.project }) else { return }

        // Check whether this coordinator (this window) owns a live session.
        let hasLocalSession: Bool = {
            if let lastId = coordinator.lastActiveSessionPerProject[storeProject.id],
               coordinator.sessionTrees[lastId] != nil || coordinator.browserManagers[lastId] != nil {
                return true
            }
            let sessions = workspaceStore.sessions(for: storeProject.id)
            return sessions.contains {
                coordinator.sessionTrees[$0.id] != nil || coordinator.browserManagers[$0.id] != nil
            }
        }()

        if hasLocalSession {
            // Path 1: live session in this window — focus it.
            coordinator.focusLastSession(forProject: storeProject.id)
            return
        }

        // No live session in this window. Check if one is alive in another window
        // via the global status registry.
        let sessions = workspaceStore.sessions(for: storeProject.id)
        let isAliveGlobally = sessions.contains {
            workspaceStore.globalStatuses[$0.id]?.isAlive == true
        }

        if isAliveGlobally {
            // D9: The session is running in a different window. In v0, we silently
            // no-op here. Cross-window IPC and a "running in another window"
            // affordance (e.g. a toast or badge) are deferred to v1+.
            return
        }

        // D8: No live session anywhere — the process exited or crashed but the
        // surface-close handler hasn't fired yet (or the session was GC'd). Respawn
        // at project-path so the user always lands in a terminal. Status stays
        // `running`; migrating to Graveyard is the surface-close handler's job.
        let rootPath: String? = {
            if let raw = task.projectPath, !raw.isEmpty {
                return (raw as NSString).expandingTildeInPath
            }
            return storeProject.rootPath.isEmpty ? nil : storeProject.rootPath
        }()

        guard let path = rootPath else { return }

        let resolvedTemplateName: String? = task.template
            ?? (defaultTaskTemplate.isEmpty ? nil : defaultTaskTemplate)

        coordinator.startOrFocusSession(
            forProjectNamed: task.project,
            rootPath: path,
            templateName: resolvedTemplateName,
            sourceTaskId: task.id,
            sourceTaskFilePath: taskStore.fileURL(for: task)?.path
        )
    }
}
