import Foundation

/// The logical lane a task row belongs to, derived at click-time from the
/// task's `status` + whether it has valid project context in `WorkspaceStore`.
///
/// This is a pure computed value — not stored state. The router derives it
/// from `task.status` + `hasProjectContext(task)` on every click.
///
/// Backlog and Review are intentionally absent from v0 — no v0 fixtures use
/// those statuses. See TODO: SG-04 in `RowClickRouter.handleRowClick`.
enum RowClickLane: Equatable {
    case inboxWithProject    // inbox status + project resolves in WorkspaceStore
    case inboxOrphan         // inbox status + no matching WorkspaceStore project
    case running             // running status
    case needsYou            // needs-you status
    case graveyard           // done status
}

/// Lane-aware dispatcher for task row clicks.
///
/// `handleRowClick` is the single entry point from `TaskRowView`. It derives
/// the lane from the task's current state and dispatches to a named handler
/// stub. U4–U7 will replace the stub bodies with real implementations.
///
/// Router is a `@MainActor` singleton because it reads `WorkspaceStore.shared`
/// and calls `SessionCoordinator` methods, both of which require the main actor.
@MainActor
final class RowClickRouter {
    static let shared = RowClickRouter()

    private init() {}

    // MARK: - Entry point

    /// Derive the click lane and dispatch to the appropriate handler.
    ///
    /// Called by `TaskRowView` in place of the old `handleTap()` implementation.
    ///
    /// - Parameters:
    ///   - task: The task whose row was clicked.
    ///   - taskStore: The observable task store (provides `.fileURL(for:)`).
    ///   - coordinator: The window's session coordinator.
    ///   - workspaceStore: The workspace store used for project lookups.
    func handleRowClick(
        _ task: TaskItem,
        taskStore: TaskStore,
        coordinator: SessionCoordinator,
        workspaceStore: WorkspaceStore,
        defaultTaskTemplate: String = ""
    ) {
        let lane = computeLane(for: task, workspaceStore: workspaceStore)
        let handlers = RowClickHandlers(
            taskStore: taskStore,
            coordinator: coordinator,
            workspaceStore: workspaceStore,
            defaultTaskTemplate: defaultTaskTemplate
        )

        switch lane {
        case .inboxWithProject:
            handlers.startInboxTask(task)

        case .inboxOrphan:
            handlers.triageOrphanTask(task)

        case .running:
            Task { @MainActor in await handlers.focusRunningTask(task) }

        case .needsYou:
            Task { @MainActor in await handlers.focusNeedsYouTask(task) }

        case .graveyard:
            handlers.expandGraveyardTask(task)

        // TODO: SG-04 — Backlog/Review routing deferred until those lanes have
        // v0 fixtures (see R1: 5-handler enumeration for .inboxWithProject,
        // .inboxOrphan, .running, .needsYou, .graveyard).
        }
    }

    // MARK: - Lane computation (testable in isolation)

    /// Derive the click lane for a task without dispatching.
    ///
    /// This is the high-value testable unit — the lane derivation logic lives
    /// here rather than inline in `handleRowClick` so tests can exercise it
    /// without a live `SessionCoordinator` or AppKit world.
    ///
    /// - Parameters:
    ///   - task: The task to evaluate.
    ///   - workspaceStore: Used for project-name lookup.
    /// - Returns: The `RowClickLane` that determines which handler fires.
    func computeLane(for task: TaskItem, workspaceStore: WorkspaceStore) -> RowClickLane {
        switch task.status {
        case .inbox, .backlog, .review:
            // For inbox (and the deferred backlog/review cases), distinguish
            // project-context vs orphan. Backlog and Review fall into this
            // branch for now and use the orphan path as a safe no-op default
            // until SG-04 fixtures exist.
            return hasProjectContext(task, workspaceStore: workspaceStore)
                ? .inboxWithProject
                : .inboxOrphan

        case .running:
            return .running

        case .needsYou:
            return .needsYou

        case .done:
            return .graveyard
        }
    }

    // MARK: - Project-context check

    /// Returns `true` when the task's `project` field matches a known project
    /// in `WorkspaceStore.projects` by name (case-sensitive, matching the store
    /// convention used throughout `handleTap` and `startOrFocusSession`).
    ///
    /// A non-nil `task.projectPath` alone does NOT count as project context —
    /// the path is an override for the cwd, not a signal that the project is
    /// registered in the sidebar. Both conditions together (`project` name match)
    /// make the context actionable.
    func hasProjectContext(_ task: TaskItem, workspaceStore: WorkspaceStore) -> Bool {
        guard !task.project.isEmpty else { return false }
        return workspaceStore.projects.contains(where: { $0.name == task.project })
    }
}
