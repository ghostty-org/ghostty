import AppKit

/// Background launches wait for activation before presenting the checkpoint.
/// This gate controls when restoration starts; the native adapter owns the
/// order in which windows are shown and joined into tab groups.
@MainActor
final class TerminalWorkspaceLaunchGate {
    static let shared = TerminalWorkspaceLaunchGate()
    private var start: (() -> Void)?

    /// Runs `start` now if the app is active, otherwise on first activation.
    func request(isActive: Bool, start: @escaping () -> Void) {
        self.start = start
        if isActive { activate() }
    }

    func activate() {
        guard let start else { return }
        self.start = nil
        start()
    }
}

extension AppDelegate {
    @MainActor
    func startWorkspaceRestorationWhenActive() {
        TerminalWorkspaceLaunchGate.shared.request(isActive: NSApp.isActive) { [ghostty] in
            TerminalWorkspaceSessionStore.shared.start(ghostty)
            TerminalTabSelectionRestoration.shared.finishLaunching()
        }
    }

    @MainActor
    func startPendingWorkspaceRestoration() {
        TerminalWorkspaceLaunchGate.shared.activate()
    }

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
