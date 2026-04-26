import Foundation
import AppKit

/// Lightweight bridge between SwiftUI row focus (`@FocusState` on `TaskRowView`)
/// and AppKit menu actions (`⌘O`, `Return`) in `AppDelegate`.
///
/// `TaskRowView` writes here when a row gains or loses focus. `AppDelegate`
/// reads `focusedTask` to execute `⌘O` (open `.md`) and `Return` (activate row).
///
/// The store intentionally has no UI — it is a one-way publisher from SwiftUI
/// focus events to AppKit responder actions.
///
/// ### Multi-window safety
///
/// The store holds the **most recently focused** task across all windows.
/// When the sidebar loses focus entirely (e.g. user clicks the terminal),
/// `focusedTask` is cleared by the last focused row calling
/// `clearFocus(for: task.id)`. This matches the "no row focused → no-op"
/// contract for both `⌘O` and `Return`.
@MainActor
final class RowFocusStore {
    static let shared = RowFocusStore()

    /// The currently focused task, or nil if no sidebar row has focus.
    private(set) var focusedTask: TaskItem?

    /// The `TaskStore` associated with the window that owns the focused row.
    /// Required for `⌘O` to resolve the `.md` URL.
    private(set) var focusedTaskStore: TaskStore?

    private init() {}

    /// Called by `TaskRowView` when it receives focus.
    func setFocused(_ task: TaskItem, taskStore: TaskStore) {
        focusedTask = task
        focusedTaskStore = taskStore
    }

    /// Called by `TaskRowView` when it loses focus — only clears the store
    /// if this task is still the one registered (avoids races between rows).
    func clearFocus(for taskId: String) {
        if focusedTask?.id == taskId {
            focusedTask = nil
            focusedTaskStore = nil
        }
    }
}
