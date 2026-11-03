import AppKit

/// AppKit orders launch windows front only conditionally while the app is not
/// yet active. Restored windows shown before activation can stay marked
/// visible without ever reaching the window server, so neither Dock reopen nor
/// tab selection can bring them back. The checkpoint is therefore presented
/// only once the application is actually active.
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
