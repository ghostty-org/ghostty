import AppKit
import Combine
import Foundation

/// The logical lane a task row belongs to, derived at click-time from the
/// task's `status` + whether it has valid project context in `WorkspaceStore`.
///
/// This is a pure computed value — not stored state. The router derives it
/// from `task.status` + `hasProjectContext(task)` on every click.
enum RowClickLane: Equatable {
    case inboxWithProject    // inbox status + project resolves in WorkspaceStore
    case inboxOrphan         // inbox status + no matching WorkspaceStore project
    case backlogWithProject  // backlog status + project resolves in WorkspaceStore (SG-04)
    case reviewWithProject   // review status + project resolves in WorkspaceStore (SG-04)
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
///
/// ### D14 — Dual guard for double-click protection
///
/// Two complementary guards prevent double-fire on rapid taps:
///
/// 1. **Hit-test block (180ms):** `hitTestingBlockedTaskIds` is populated for
///    180ms when a click fires. `TaskRowView` observes this set and applies
///    `.allowsHitTesting(false)` while the task id is present — exactly the
///    animation window during which the row slides to the Running lane.
///
/// 2. **Debounce timer (400ms):** `promotionInFlight` holds a per-taskId
///    `DispatchWorkItem`. If `handleRowClick` is called again for the same id
///    before 400ms elapses the call is dropped. This closes the window between
///    the hit-test unblock (180ms) and the watcher migration (≤ 400ms typical).
///
/// Both guards coexist — they cover different failure modes (in-animation tap
/// vs. rapid-but-post-animation tap). The 400ms timer begins after the status
/// write succeeds, not at tap-time, so a write failure doesn't freeze the row.
@MainActor
final class RowClickRouter: ObservableObject {
    static let shared = RowClickRouter()

    // MARK: - D14 state

    /// Task ids whose rows should refuse hit-testing (180ms animation window).
    /// Published so `TaskRowView` can gate `.allowsHitTesting` reactively.
    @Published private(set) var hitTestingBlockedTaskIds: Set<String> = []

    /// Per-task promotion-in-flight work items (400ms debounce guard).
    /// Entry present → the task is locked; skip repeated clicks.
    private var promotionInFlight: [String: DispatchWorkItem] = [:]

    // MARK: - D13 state

    /// Per-task write errors shown as a persistent row-level error chip until
    /// the next successful write clears the entry. Published so the row view
    /// can observe and render the chip without polling.
    @Published private(set) var taskRowErrors: [String: String] = [:]

    private init() {}

    // MARK: - Entry point

    /// Derive the click lane and dispatch to the appropriate handler.
    ///
    /// Called by `TaskRowView` in place of the old `handleTap()` implementation.
    ///
    /// For the `.inboxWithProject` lane, applies the D14 dual guard before
    /// dispatching: (a) hit-test block for 180ms, (b) 400ms debounce timer
    /// that starts after a successful write.
    ///
    /// Multi-window safety (D9 + P1-001): spawning fires only in the window
    /// where the click happened. The `coordinator` is the per-window instance
    /// injected by `TaskRowView`'s `@EnvironmentObject`, so there is no global
    /// coordinator dispatch here.
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
            // D14-a: drop click if animation guard is active for this task.
            guard !hitTestingBlockedTaskIds.contains(task.id) else { return }
            // D14-b: drop click if promotion-in-flight debounce is active.
            guard promotionInFlight[task.id] == nil else { return }

            // Arm the 180ms hit-test block immediately so an in-animation re-tap
            // is swallowed before the async write even starts.
            hitTestingBlockedTaskIds.insert(task.id)
            let hitTestCancelItem = DispatchWorkItem { [weak self] in
                self?.hitTestingBlockedTaskIds.remove(task.id)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: hitTestCancelItem)

            // Dispatch the async write + spawn on the main actor. The debounce
            // timer is armed inside the handler AFTER the write succeeds (D14-b).
            _Concurrency.Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await handlers.startInboxTask(task)
                    // Write succeeded — arm the 400ms post-write debounce guard.
                    self.armDebounce(for: task.id)
                } catch {
                    // D13: disk-write failure → publish error for the row chip.
                    self.taskRowErrors[task.id] = error.localizedDescription
                    // Clear the 180ms hit-test block early on failure so the row
                    // is interactive again once the user can see the error chip.
                    hitTestCancelItem.cancel()
                    self.hitTestingBlockedTaskIds.remove(task.id)
                }
            }

        case .inboxOrphan:
            handlers.triageOrphanTask(task)

        case .backlogWithProject:
            // Backlog: open the task's .md file in the default editor. No spawn,
            // no status change — Backlog means "planned but not now".
            if let url = taskStore.fileURL(for: task) {
                NSWorkspace.shared.open(url)
            }

        case .reviewWithProject:
            // Review: open the .md file AND spawn a Claude Code session with the
            // "review" template hint so the agent reads completed work. Applies
            // the same D14 dual guard as .inboxWithProject.
            guard !hitTestingBlockedTaskIds.contains(task.id) else { return }
            guard promotionInFlight[task.id] == nil else { return }

            hitTestingBlockedTaskIds.insert(task.id)
            let hitTestCancelItem = DispatchWorkItem { [weak self] in
                self?.hitTestingBlockedTaskIds.remove(task.id)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: hitTestCancelItem)

            _Concurrency.Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await handlers.startReviewTask(task)
                    self.armDebounce(for: task.id)
                } catch {
                    self.taskRowErrors[task.id] = error.localizedDescription
                    hitTestCancelItem.cancel()
                    self.hitTestingBlockedTaskIds.remove(task.id)
                }
            }

        case .running:
            _Concurrency.Task { @MainActor in await handlers.focusRunningTask(task) }

        case .needsYou:
            _Concurrency.Task { @MainActor in await handlers.focusNeedsYouTask(task) }

        case .graveyard:
            handlers.expandGraveyardTask(task)
        }
    }

    // MARK: - D13 — Error chip management

    /// Clear the error chip for a task (called on next successful write).
    func clearRowError(for taskId: String) {
        taskRowErrors.removeValue(forKey: taskId)
    }

    // MARK: - D14 — Debounce management

    /// Arm the 400ms post-write debounce guard for a task.
    /// Removes itself from `promotionInFlight` after the interval expires.
    private func armDebounce(for taskId: String) {
        let item = DispatchWorkItem { [weak self] in
            self?.promotionInFlight.removeValue(forKey: taskId)
        }
        promotionInFlight[taskId] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.40, execute: item)
    }

    /// Cancel and remove an in-flight debounce timer (e.g. on write error).
    func cancelDebounce(for taskId: String) {
        promotionInFlight[taskId]?.cancel()
        promotionInFlight.removeValue(forKey: taskId)
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
        case .inbox:
            return hasProjectContext(task, workspaceStore: workspaceStore)
                ? .inboxWithProject
                : .inboxOrphan

        case .backlog:
            // Backlog tasks open the .md file read-only; orphans fall to inboxOrphan
            // (triage card collects a project first before any file action).
            return hasProjectContext(task, workspaceStore: workspaceStore)
                ? .backlogWithProject
                : .inboxOrphan

        case .review:
            // Review tasks spawn Claude Code in review mode; orphans triage first.
            return hasProjectContext(task, workspaceStore: workspaceStore)
                ? .reviewWithProject
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
