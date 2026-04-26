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

    /// Route column 2 to the task's existing terminal session and focus the cursor.
    ///
    /// No status flip, no respawn — except D8: if no live SurfaceView exists for
    /// this task (the process exited but `surface-close` hasn't fired yet),
    /// respawn at `project-path` so the user always gets a terminal. Status stays
    /// `running`; auto-migration to Graveyard remains the surface-close handler's job.
    func focusRunningTask(_ task: TaskItem) async {
        openMarkdownFile(for: task)
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
        openMarkdownFile(for: task)
        await routeToExistingSession(task)
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
            sourceTaskId: task.id
        )
    }
}
