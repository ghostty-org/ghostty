import AppKit
import SwiftUI
import GhosttyKit

/// Bridges the SwiftUI sidebar to Ghostty's terminal surface system.
///
/// Sessions work like **vertical tabs**: each session owns a terminal surface tree
/// (which may contain splits), and the sidebar switches which tree occupies the
/// terminal area. Only one session is visible at a time. Background sessions keep
/// their processes running — the coordinator holds strong references to their trees.
///
/// When the user creates splits via Ghostty shortcuts (Cmd+D), those splits live in
/// the controller's `surfaceTree`. Before switching sessions, we snapshot the current
/// tree back into `sessionTrees` so splits are preserved across switches.
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

    /// Maps session IDs to their full split trees. Trees are kept alive here even
    /// when not displayed — this preserves both the surfaces and any user-created
    /// splits. The active session's tree may be stale (the controller owns the
    /// live version); call `snapshotActiveTree()` to sync before reading.
    private(set) var sessionTrees: [UUID: SplitTree<Ghostty.SurfaceView>] = [:]

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
    /// The previous session's tree is snapshotted before the switch.
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
        let newTree = SplitTree(view: newView)

        // Snapshot the outgoing session's tree (captures any user-created splits).
        snapshotActiveTree()

        sessionTrees[session.id] = newTree
        statuses[session.id] = .running
        activeSessionId = session.id

        showSession(newTree, focusView: newView)
        return true
    }

    // MARK: - Session Switching

    /// Switch the terminal area to show a specific session.
    ///
    /// Snapshots the current session's tree (preserving splits) before switching.
    /// This is the "vertical tab" behavior — clicking a session in the sidebar
    /// replaces the terminal content with the target session's full split tree.
    func focusSession(id: UUID) {
        guard let tree = sessionTrees[id] else { return }

        // Snapshot the outgoing session's tree first.
        snapshotActiveTree()

        activeSessionId = id
        showSession(tree, focusView: tree.first)
    }

    // MARK: - Lifecycle

    /// Check if a session has a live surface.
    func isRunning(id: UUID) -> Bool {
        sessionTrees[id] != nil && statuses[id] == .running
    }

    /// Close a session's surface tree. All processes in the tree are terminated.
    func closeSession(id: UUID) {
        guard let tree = sessionTrees[id] else { return }

        // Remove from our tracking first, then close surfaces via the controller.
        sessionTrees.removeValue(forKey: id)
        statuses[id] = .exited

        // If this was the active session, switch to another running session.
        if activeSessionId == id {
            switchToNextSession()
        }

        // Tell Ghostty to close each surface in the tree (kills processes).
        guard let controller = terminalController else { return }
        for surface in tree {
            controller.closeSurface(surface, withConfirmation: false)
        }
    }

    /// Clean up runtime state for a session (after removing from the store).
    func clearRuntime(id: UUID) {
        sessionTrees.removeValue(forKey: id)
        statuses.removeValue(forKey: id)
    }

    // MARK: - Private

    /// Discovers the terminal controller through the view hierarchy.
    private var terminalController: BaseTerminalController? {
        containerView?.window?.windowController as? BaseTerminalController
    }

    /// Snapshot the active session's current tree from the controller.
    ///
    /// The controller owns the live tree (including any splits the user created
    /// via Ghostty shortcuts). We must capture it before every switch so that
    /// returning to this session restores the user's split layout.
    private func snapshotActiveTree() {
        guard let currentId = activeSessionId,
              let controller = terminalController,
              sessionTrees[currentId] != nil else { return }
        sessionTrees[currentId] = controller.surfaceTree
    }

    /// Replace the terminal area with a session's full split tree.
    ///
    /// Uses `replaceSurfaceTree` (the canonical safe setter) instead of direct
    /// `surfaceTree` assignment to avoid bypassing undo registration.
    /// We pass `undoAction: nil` because session switching is a sidebar navigation
    /// action, not an undoable edit.
    private func showSession(_ tree: SplitTree<Ghostty.SurfaceView>, focusView: Ghostty.SurfaceView?) {
        guard let controller = terminalController else { return }
        let oldFocused = controller.focusedSurface

        controller.replaceSurfaceTree(
            tree,
            moveFocusTo: focusView,
            moveFocusFrom: oldFocused
        )
    }

    /// Switch to the next available running session, or show nothing.
    private func switchToNextSession() {
        if let (nextId, nextTree) = sessionTrees.first(where: { statuses[$0.key] == .running }) {
            activeSessionId = nextId
            showSession(nextTree, focusView: nextTree.first)
        } else {
            activeSessionId = nil
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
        // Defer processing by one run-loop tick. BaseTerminalController also observes
        // ghosttyCloseSurface and updates the live surfaceTree synchronously, but
        // NotificationCenter delivery order depends on registration order and is not
        // guaranteed. By dispatching async we ensure the controller has already
        // removed the closed surface before we snapshot its tree.
        DispatchQueue.main.async { [weak self] in
            self?.handleSurfaceClose(notification)
        }
    }

    private func handleSurfaceClose(_ notification: Notification) {
        guard let closedSurface = notification.object as? Ghostty.SurfaceView else { return }

        // Find which session owns this surface by scanning all stored trees.
        guard let sessionId = sessionId(for: closedSurface) else { return }

        let processAlive = notification.userInfo?["process_alive"] as? Bool ?? false

        // For the active session, read the live tree from the controller (which
        // BaseTerminalController has already updated to remove the closed surface).
        // For background sessions, remove the surface from our stored tree.
        if sessionId == activeSessionId {
            if let controller = terminalController {
                let liveTree = controller.surfaceTree
                if liveTree.isEmpty {
                    sessionTrees.removeValue(forKey: sessionId)
                    statuses[sessionId] = processAlive ? .killed : .exited
                    switchToNextSession()
                } else {
                    sessionTrees[sessionId] = liveTree
                }
            }
        } else {
            // Background session: remove the closed surface's node from our stored tree.
            if let tree = sessionTrees[sessionId],
               let node = tree.root?.node(view: closedSurface) {
                let updated = tree.removing(node)
                if updated.isEmpty {
                    sessionTrees.removeValue(forKey: sessionId)
                    statuses[sessionId] = processAlive ? .killed : .exited
                } else {
                    sessionTrees[sessionId] = updated
                }
            }
        }
    }

    /// Find which session owns a given surface by searching all stored trees.
    private func sessionId(for surface: Ghostty.SurfaceView) -> UUID? {
        // Check the active session's live tree first (from the controller).
        if let activeId = activeSessionId,
           let controller = terminalController,
           controller.surfaceTree.contains(where: { $0 === surface }) {
            return activeId
        }
        // Check stored trees for background sessions.
        for (id, tree) in sessionTrees where id != activeSessionId {
            if tree.contains(where: { $0 === surface }) {
                return id
            }
        }
        return nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
