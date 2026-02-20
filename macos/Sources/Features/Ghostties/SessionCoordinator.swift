import AppKit
import SwiftUI
import GhosttyKit

/// Bridges the SwiftUI sidebar to Ghostty's terminal surface system.
///
/// Sessions work like **vertical tabs**: each session owns a terminal surface, and the
/// sidebar switches which one occupies the terminal area. Only one session is visible at a
/// time (unless the user manually splits via Ghostty shortcuts). Background sessions keep
/// their processes running — the coordinator holds strong references to their SurfaceViews.
///
/// Each window gets its own coordinator instance, injected via `.environmentObject()`.
/// The coordinator discovers its window controller lazily through the view hierarchy.
@MainActor
final class SessionCoordinator: ObservableObject {
    private let ghostty: Ghostty.App

    /// Weak reference to the container NSView — used to find the window controller.
    weak var containerView: NSView?

    /// The currently displayed session. Nil before any session is created.
    @Published private(set) var activeSessionId: UUID?

    /// Maps session IDs to their live SurfaceView references.
    /// Surfaces are kept alive here even when not displayed in the terminal area.
    @Published private(set) var surfaceViews: [UUID: Ghostty.SurfaceView] = [:]

    /// Maps session IDs to their runtime status.
    @Published private(set) var statuses: [UUID: SessionStatus] = [:]

    init(ghostty: Ghostty.App) {
        self.ghostty = ghostty
        observeLifecycle()
    }

    // MARK: - Session Creation

    /// Create a new terminal session from a template within a project.
    ///
    /// Creates a Ghostty surface with the appropriate configuration and makes it
    /// the sole occupant of the terminal area (replacing whatever was there before).
    /// The previous session's surface stays alive in the background.
    @discardableResult
    func createSession(
        session: AgentSession,
        template: SessionTemplate,
        project: Project
    ) -> Bool {
        guard let ghosttyApp = ghostty.app else { return false }

        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = project.rootPath
        config.command = template.command
        config.environmentVariables = template.environmentVariables

        let newView = Ghostty.SurfaceView(ghosttyApp, baseConfig: config)

        surfaceViews[session.id] = newView
        statuses[session.id] = .running
        activeSessionId = session.id

        showSurface(newView)
        return true
    }

    // MARK: - Session Switching

    /// Switch the terminal area to show a specific session.
    ///
    /// The previously visible session's surface stays alive in the background.
    /// This is the "vertical tab" behavior — clicking a session in the sidebar
    /// replaces the terminal content.
    func focusSession(id: UUID) {
        guard let surfaceView = surfaceViews[id] else { return }
        activeSessionId = id
        showSurface(surfaceView)
    }

    // MARK: - Lifecycle

    /// Check if a session has a live surface.
    func isRunning(id: UUID) -> Bool {
        surfaceViews[id] != nil && statuses[id] == .running
    }

    /// Close a session's surface. The process is terminated and the surface destroyed.
    func closeSession(id: UUID) {
        guard let surfaceView = surfaceViews[id] else { return }

        // Remove from our tracking first, then close via the controller.
        surfaceViews.removeValue(forKey: id)
        statuses[id] = .exited

        // If this was the active session, switch to another running session.
        if activeSessionId == id {
            switchToNextSession()
        }

        // Tell Ghostty to close the surface (kills the process).
        guard let controller = terminalController else { return }
        controller.closeSurface(surfaceView, withConfirmation: false)
    }

    /// Clean up runtime state for a session (after removing from the store).
    func clearRuntime(id: UUID) {
        surfaceViews.removeValue(forKey: id)
        statuses.removeValue(forKey: id)
    }

    // MARK: - Private

    /// Discovers the terminal controller through the view hierarchy.
    private var terminalController: BaseTerminalController? {
        containerView?.window?.windowController as? BaseTerminalController
    }

    /// Replace the terminal area with a single surface.
    private func showSurface(_ surfaceView: Ghostty.SurfaceView) {
        guard let controller = terminalController else { return }
        let oldFocused = controller.focusedSurface

        // Replace the entire split tree with just this surface.
        controller.surfaceTree = SplitTree(view: surfaceView)
        controller.focusedSurface = surfaceView

        DispatchQueue.main.async {
            Ghostty.moveFocus(to: surfaceView, from: oldFocused)
        }
    }

    /// Switch to the next available running session, or show nothing.
    private func switchToNextSession() {
        // Find another running session to display.
        if let (nextId, nextView) = surfaceViews.first(where: { statuses[$0.key] == .running }) {
            activeSessionId = nextId
            showSurface(nextView)
        } else {
            activeSessionId = nil
            // All sessions closed — the initial Ghostty surface is gone.
            // The controller handles the empty-tree case (may close the window).
        }
    }

    /// Observe Ghostty surface close notifications to track session lifecycle.
    private func observeLifecycle() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(surfaceDidClose(_:)),
            name: Ghostty.Notification.ghosttyCloseSurface,
            object: nil
        )
    }

    @objc private func surfaceDidClose(_ notification: Notification) {
        guard let closedSurface = notification.object as? Ghostty.SurfaceView else { return }

        // Find the session that owns this surface.
        guard let (sessionId, _) = surfaceViews.first(where: { $0.value === closedSurface }) else {
            return
        }

        surfaceViews.removeValue(forKey: sessionId)
        statuses[sessionId] = .exited

        // If the active session just closed, switch to another.
        if activeSessionId == sessionId {
            switchToNextSession()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
