import AppKit
import Combine
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

    /// Per-window runtime status. Views should prefer `WorkspaceStore.shared.globalStatuses`
    /// for cross-window visibility; this local copy is kept for backward compatibility.
    @Published private(set) var statuses: [UUID: SessionStatus] = [:]

    /// Cache resolved command paths to avoid repeated shell spawns.
    /// Guarded by `resolvedPathsLock` since `resolveCommand` runs on detached tasks.
    /// `nonisolated(unsafe)` opts out of @MainActor isolation so the nonisolated
    /// `resolveCommand` method can access these; the lock provides actual safety.
    nonisolated(unsafe) private static let resolvedPathsLock = NSLock()
    nonisolated(unsafe) private static var _resolvedPaths: [String: String] = [:]

    /// Tracks the last focused session per project per window, so clicking a
    /// project in the icon rail can restore the correct terminal session.
    private(set) var lastActiveSessionPerProject: [UUID: UUID] = [:]

    /// Tracks when each session last produced output (title change as proxy).
    /// Used with the activity threshold to distinguish active vs waiting.
    private var lastOutputTimestamps: [UUID: ContinuousClock.Instant] = [:]

    /// Combine subscriptions for each session's root surface `$lastOutputDate`.
    private var outputSubscriptions: [UUID: AnyCancellable] = [:]

    /// Exit codes received from `GHOSTTY_ACTION_COMMAND_FINISHED` before the surface closes.
    /// Keyed by surface ID (not session ID) since the notification targets a surface.
    private var pendingExitCodes: [UUID: Int16] = [:]

    /// 1-second timer that triggers view re-evaluation for activity state transitions.
    private var activityTimer: Timer?

    /// How long after the last output before a running session transitions from processing.
    private static let activityThreshold: ContinuousClock.Duration = .seconds(2)

    /// Whether each session is currently at a shell prompt (OSC 133;B received).
    /// Reset to false on any output activity. Used to distinguish idle vs waiting.
    private var isAtPrompt: [UUID: Bool] = [:]

    /// The last surface title seen for each session. Used as a proxy for the last
    /// terminal output line when detecting "needs attention" prompts.
    private var lastSurfaceTitle: [UUID: String] = [:]

    /// When each session entered the processing state (continuous output).
    /// Cleared when the session returns to a prompt. Used for long-running detection.
    private var processingStartTimes: [UUID: ContinuousClock.Instant] = [:]

    /// How long a session must be continuously processing before showing as long-running.
    private static let longRunningThreshold: ContinuousClock.Duration = .seconds(1800)

    /// Known prompt patterns for detecting "needs attention" state.
    private static let promptPatterns: [String] = [
        "\\[Y/n\\]", "\\[y/N\\]", "\\[yes/no\\]",
        "Allow\\s", "Do you want", "Press Enter",
        "Confirm", "approve", "permission",
        "\\(y\\)", "\\(yes\\)",
    ]

    init(ghostty: Ghostty.App) {
        self.ghostty = ghostty
        observeLifecycle()
        observeProjectRemoval()
        observeCommandFinished()
        observePromptReady()
        observeMenuBarFocus()
        startActivityTimer()
    }

    // MARK: - Session Creation

    /// Create a new terminal session from a template within a project.
    ///
    /// Resolves the command path off the main thread (with a 3-second timeout),
    /// then creates a Ghostty surface and makes it the sole occupant of the
    /// terminal area. The previous session's tree is snapshotted before the switch.
    @discardableResult
    func createSession(
        session: AgentSession,
        template: AgentTemplate,
        project: Project
    ) async -> Bool {
        guard let ghosttyApp = ghostty.app else { return false }

        // Build the full command string and resolve the binary path, both off
        // the main thread. buildCommand() may write prompt cache files and
        // resolveCommand() may spawn a login shell — neither should block UI.
        // For shell templates (no command), resolvedCommand stays nil -> default shell.
        let resolvedCommand: String? = await {
            guard template.command != nil else { return nil }

            let buildAndResolveTask = Task.detached(priority: .userInitiated) { () -> String? in
                // Build the full command string (includes agent flags, prompt file references).
                let built = template.buildCommand()
                guard !built.isEmpty else { return nil }

                // Extract the base command (first token) for PATH resolution.
                let baseCommand = String(built.prefix(while: { !$0.isWhitespace }))
                let resolvedBase = Self.resolveCommand(baseCommand)

                // Replace the base command with its resolved absolute path.
                if resolvedBase != baseCommand {
                    return resolvedBase + built.dropFirst(baseCommand.count)
                }
                return built
            }
            let timeoutTask = Task {
                try await Task.sleep(for: .seconds(3))
                buildAndResolveTask.cancel()
            }
            let result = await buildAndResolveTask.value
            timeoutTask.cancel()
            return result
        }()

        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = template.workingDirectory ?? project.rootPath
        config.command = resolvedCommand
        config.environmentVariables = template.environmentVariables

        let newView = Ghostty.SurfaceView(ghosttyApp, baseConfig: config)
        let newTree = SplitTree(view: newView)

        // Snapshot the outgoing session's tree (captures any user-created splits).
        snapshotActiveTree()

        sessionTrees[session.id] = newTree
        setStatus(.running, for: session.id)
        subscribeToOutput(surface: newView, sessionId: session.id)
        activeSessionId = session.id
        lastActiveSessionPerProject[session.projectId] = session.id

        showSession(newTree, focusView: newView)
        return true
    }

    /// Create a session using the project's default or specified template with auto-generated naming.
    ///
    /// Shared helper used by ProjectDisclosureRow, WorkspaceSidebarView, and TemplatePickerView
    /// to avoid duplicating session-creation logic.
    @discardableResult
    func createQuickSession(for project: Project, template: AgentTemplate) async -> Bool {
        let store = WorkspaceStore.shared
        let count = store.sessions(for: project.id).count
        let name = "\(template.name) \(count + 1)"
        let session = store.addSession(name: name, templateId: template.id, projectId: project.id)
        return await createSession(session: session, template: template, project: project)
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

        // Record this session as the last active one for its project.
        if let session = WorkspaceStore.shared.sessions.first(where: { $0.id == id }) {
            lastActiveSessionPerProject[session.projectId] = id
        }
    }

    /// Focus the last active session for a given project, or the first running session if none.
    ///
    /// Called when the user clicks a project in the icon rail to auto-switch the terminal
    /// to the most recently used session in that project.
    func focusLastSession(forProject projectId: UUID) {
        // Try the remembered session first.
        if let lastId = lastActiveSessionPerProject[projectId],
           sessionTrees[lastId] != nil {
            focusSession(id: lastId)
            return
        }

        // Fall back to the first running session in this project.
        let projectSessions = WorkspaceStore.shared.sessions(for: projectId)
        if let running = projectSessions.first(where: { sessionTrees[$0.id] != nil }) {
            focusSession(id: running.id)
        }
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
        outputSubscriptions.removeValue(forKey: id)
        setStatus(.killed, for: id)

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
        outputSubscriptions.removeValue(forKey: id)
        lastOutputTimestamps.removeValue(forKey: id)
        isAtPrompt.removeValue(forKey: id)
        processingStartTimes.removeValue(forKey: id)
        lastSurfaceTitle.removeValue(forKey: id)
        WorkspaceStore.shared.removeSessionStatus(id: id)
        WorkspaceStore.shared.removeIndicatorState(id: id)
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

    /// Close all sessions belonging to a project. Called before the project is
    /// removed from the store, so that running terminals are properly terminated.
    func closeAllSessions(forProject projectId: UUID) {
        let projectSessions = WorkspaceStore.shared.sessions.filter { $0.projectId == projectId }
        for session in projectSessions {
            if sessionTrees[session.id] != nil {
                closeSession(id: session.id)
            }
            clearRuntime(id: session.id)
        }
        lastActiveSessionPerProject.removeValue(forKey: projectId)
    }

    /// Observe project removal notifications so we can close running sessions
    /// before the store deletes the project's session records.
    private func observeProjectRemoval() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(projectWillBeRemoved(_:)),
            name: .workspaceProjectWillBeRemoved,
            object: nil
        )
    }

    @objc private func projectWillBeRemoved(_ notification: Notification) {
        guard let projectId = notification.userInfo?["projectId"] as? UUID else { return }
        closeAllSessions(forProject: projectId)
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

        // Resolve the exit status using cached exit codes from COMMAND_FINISHED.
        let exitStatus: SessionStatus = {
            if processAlive { return .killed }
            let exitCode = pendingExitCodes.removeValue(forKey: closedSurface.id)
            switch exitCode {
            case .none:        return .exited      // No shell integration — fallback
            case .some(-1):    return .exited      // Shell integration present but no exit code reported
            case .some(0):     return .completed
            case .some(let c): return .error(exitCode: c)
            }
        }()

        // For the active session, read the live tree from the controller (which
        // BaseTerminalController has already updated to remove the closed surface).
        // For background sessions, remove the surface from our stored tree.
        if sessionId == activeSessionId {
            if let controller = terminalController {
                let liveTree = controller.surfaceTree
                if liveTree.isEmpty {
                    sessionTrees.removeValue(forKey: sessionId)
                    outputSubscriptions.removeValue(forKey: sessionId)
                    setStatus(exitStatus, for: sessionId)
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
                    outputSubscriptions.removeValue(forKey: sessionId)
                    setStatus(exitStatus, for: sessionId)
                } else {
                    sessionTrees[sessionId] = updated
                }
            }
        }
    }

    /// Resolve a bare command name to its absolute path using the user's login shell.
    ///
    /// Ghostty launches commands via `/usr/bin/login ... --noprofile --norc`, so the
    /// user's PATH from shell profiles isn't available. This spawns a login shell to
    /// get the full PATH, then searches for the binary. Returns the original command
    /// if resolution fails or the command is already absolute.
    nonisolated private static func resolveCommand(_ command: String) -> String {
        guard !command.hasPrefix("/") else { return command }

        // Check cache first.
        resolvedPathsLock.lock()
        let cached = _resolvedPaths[command]
        resolvedPathsLock.unlock()
        if let cached { return cached }

        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path

        // Fast path: check common CLI tool installation directories directly.
        // This avoids spawning a subprocess, which can fail silently in the
        // macOS GUI app context (minimal environment, no TTY).
        let commonPaths = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
        for dir in commonPaths {
            let candidate = (dir as NSString).appendingPathComponent(command)
            if fm.isExecutableFile(atPath: candidate) {
                resolvedPathsLock.lock()
                _resolvedPaths[command] = candidate
                resolvedPathsLock.unlock()
                return candidate
            }
        }

        // Slow path: spawn a login shell to discover the full PATH.
        // Covers binaries in unusual locations not in the common list above.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        let task = Process()
        task.executableURL = URL(fileURLWithPath: shell)
        task.arguments = ["-l", "-c", "echo $PATH"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return command
        }

        guard task.terminationStatus == 0 else { return command }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let pathString = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !pathString.isEmpty else { return command }

        for dir in pathString.split(separator: ":").map(String.init) {
            let candidate = (dir as NSString).appendingPathComponent(command)
            if fm.isExecutableFile(atPath: candidate) {
                resolvedPathsLock.lock()
                _resolvedPaths[command] = candidate
                resolvedPathsLock.unlock()
                return candidate
            }
        }

        return command
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

    // MARK: - Activity Tracking

    /// Subscribe to a session's root surface output activity via Combine.
    private func subscribeToOutput(surface: Ghostty.SurfaceView, sessionId: UUID) {
        outputSubscriptions[sessionId] = surface.lastOutputSubject
            .sink { [weak self, weak surface] in
                guard let self else { return }
                self.lastOutputTimestamps[sessionId] = .now
                // Output means we're no longer at the prompt.
                self.isAtPrompt[sessionId] = false
                // Start tracking processing duration if not already.
                if self.processingStartTimes[sessionId] == nil {
                    self.processingStartTimes[sessionId] = .now
                }
                // Capture the surface title as a proxy for the last output line.
                // Used by isLikelyPromptingForInput to detect attention-needed state.
                if let title = surface?.title, !title.isEmpty {
                    self.lastSurfaceTitle[sessionId] = title
                }
            }
    }

    /// Observe `GHOSTTY_ACTION_COMMAND_FINISHED` to cache exit codes before surfaces close.
    private func observeCommandFinished() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(commandDidFinish(_:)),
            name: Ghostty.Notification.ghosttyCommandFinished,
            object: nil
        )
    }

    @objc private func commandDidFinish(_ notification: Notification) {
        guard let surface = notification.object as? Ghostty.SurfaceView,
              let exitCode = notification.userInfo?["exit_code"] as? Int16,
              sessionId(for: surface) != nil else { return }
        // Cache the exit code keyed by surface ID. It will be consumed in handleSurfaceClose.
        pendingExitCodes[surface.id] = exitCode
    }

    /// Observe `GHOSTTY_ACTION_PROMPT_READY` to track shell prompt state.
    private func observePromptReady() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(promptDidBecomeReady(_:)),
            name: Ghostty.Notification.ghosttyPromptReady,
            object: nil
        )
    }

    @objc private func promptDidBecomeReady(_ notification: Notification) {
        guard let surface = notification.object as? Ghostty.SurfaceView,
              let sessionId = sessionId(for: surface) else { return }
        isAtPrompt[sessionId] = true
        processingStartTimes.removeValue(forKey: sessionId)
    }

    /// Observe menu bar session focus requests so clicking a row in the dropdown
    /// activates the correct session and brings its window to the front.
    private func observeMenuBarFocus() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuBarDidRequestFocus(_:)),
            name: .menuBarFocusSession,
            object: nil
        )
    }

    @objc private func menuBarDidRequestFocus(_ notification: Notification) {
        guard let sessionId = notification.userInfo?["sessionId"] as? UUID,
              sessionTrees[sessionId] != nil else { return }
        focusSession(id: sessionId)
        // Bring this coordinator's window to the front.
        if let window = containerView?.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Start a 1-second repeating timer that triggers view re-evaluation.
    ///
    /// This is how the sidebar detects the active→waiting transition: the timer
    /// fires, `objectWillChange` causes SwiftUI to re-read `indicatorState(for:)`,
    /// and the 2-second threshold comparison returns a different result.
    private func startActivityTimer() {
        activityTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Only fire objectWillChange if there are running sessions that could transition.
                let hasRunning = self.statuses.values.contains { $0.isAlive }
                if hasRunning {
                    self.objectWillChange.send()

                    // Push each running session's indicator state to the global store
                    // so the menu bar icon can reflect the aggregate status.
                    for (id, status) in self.statuses where status.isAlive {
                        let state = self.indicatorState(for: id)
                        WorkspaceStore.shared.updateIndicatorState(id: id, state: state)
                    }
                }
            }
        }
    }

    /// Compute the view-layer indicator state for a session.
    ///
    /// Combines lifecycle status, output recency, and shell prompt signals into
    /// one of seven visual states. For running sessions:
    /// - Recent output → processing (or long-running if 30+ min continuous)
    /// - No recent output + at shell prompt → idle
    /// - No recent output + NOT at prompt + likely prompting → needsAttention
    /// - No recent output + NOT at shell prompt → waiting
    func indicatorState(for sessionId: UUID) -> SessionIndicatorState {
        let status = statuses[sessionId]
            ?? WorkspaceStore.shared.globalStatuses[sessionId]
            ?? .exited

        switch status {
        case .running:
            // Check if the session has produced output recently.
            if let lastOutput = lastOutputTimestamps[sessionId],
               ContinuousClock.now - lastOutput < Self.activityThreshold {
                // Check long-running: continuously processing for 30+ min.
                if let start = processingStartTimes[sessionId],
                   ContinuousClock.now - start > Self.longRunningThreshold {
                    return .longRunning
                }
                return .processing
            }
            // No recent output — check if we're at a shell prompt.
            if isAtPrompt[sessionId] == true {
                return .idle
            }
            // Not at prompt — check if the agent is likely prompting for user input.
            if isLikelyPromptingForInput(sessionId: sessionId) {
                return .needsAttention
            }
            // Silent but no strong signal of a prompt — generic waiting.
            return .waiting

        case .completed, .exited, .killed:
            return .inactive

        case .error:
            return .error
        }
    }

    /// Check if a session is likely blocked on user input based on its last output.
    ///
    /// Uses two layers of detection:
    /// - Layer 1: Last output ends with `?` or `:` (prompt character heuristic)
    /// - Layer 2: Known prompt patterns (permission prompts, yes/no, confirm)
    ///
    /// Returns true if a known pattern matches, or if the last line ends with a
    /// prompt character and is long enough to be meaningful (> 3 chars).
    private func isLikelyPromptingForInput(sessionId: UUID) -> Bool {
        guard let lastLine = lastSurfaceTitle[sessionId] else { return false }
        let trimmed = lastLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Layer 1: Last character is ? or :
        let endsWithPromptChar = trimmed.hasSuffix("?") || trimmed.hasSuffix(":")

        // Layer 2: Known prompt patterns (pure regex, no LLM)
        let matchesPattern = Self.promptPatterns.contains { pattern in
            trimmed.range(of: pattern, options: .regularExpression) != nil
        }

        // Pattern match is a strong signal on its own.
        // Prompt char is weaker — require minimum line length to avoid false positives.
        return matchesPattern || (endsWithPromptChar && trimmed.count > 3)
    }

    /// Update a session's status locally and in the global store.
    private func setStatus(_ status: SessionStatus, for id: UUID) {
        statuses[id] = status
        WorkspaceStore.shared.updateSessionStatus(id: id, status: status)
    }

    deinit {
        activityTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        // Clean up this coordinator's session entries from the global store.
        // SessionCoordinator is always deallocated on the main thread (UI object),
        // so assumeIsolated is safe here.
        MainActor.assumeIsolated {
            for id in statuses.keys {
                WorkspaceStore.shared.removeSessionStatus(id: id)
                WorkspaceStore.shared.removeIndicatorState(id: id)
            }
        }
    }
}
