import AppKit

extension AppDelegate {
    @MainActor
    func handleReopen(hasVisibleWindows: Bool, coordinator: TerminalWorkspaceCoordinator) -> Bool {
        // A retained parked tab can make AppKit report a visible window even
        // though no committed workspace is displayed. Suppress its default
        // selection after repairing the workspace so it cannot undo the repair.
        if coordinator.ensureVisibleWorkspace() { return false }
        if hasVisibleWindows { return true }
        if !coordinator.liveControllers.isEmpty { return false }
        guard applicationHasBecomeActive else { return true }
        _ = TerminalController.newWindow(ghostty)
        return false
    }
}
