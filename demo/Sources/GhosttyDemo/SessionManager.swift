import Foundation
import GhosttyKit

// MARK: - SessionManager

/// Manages terminal session lifecycle for the kanban board.
///
/// This is a rewrite of the macos SessionManager for the demo project.
/// Key differences:
///   - Uses `tabID: UUID?` instead of `surfaceId: UInt64?`
///   - Calls methods directly on `TerminalTabManager` (no NotificationCenter)
///   - Does not persist sessions independently — sessions live inside `KanbanTask`
///     and are saved via `BoardState` / `Persistence` into `tasks.json`.
@MainActor
final class SessionManager: ObservableObject {
    static let shared = SessionManager()

    // MARK: - Published state

    /// Flat, reactive list of all sessions across all tasks.
    /// Updated via `reconcile(from:)` on load and kept in sync with `sessionsByTaskID`.
    @Published var sessions: [Session] = []

    // MARK: - Dependencies

    private var tabManager: TerminalTabManager?
    private var ghosttyApp: ghostty_app_t?

    // MARK: - Internal indexing

    /// Maps task ID to the set of session IDs belonging to that task.
    private var taskSessionIDs: [UUID: Set<UUID>] = [:]

    /// Reverse mapping: session ID -> task ID.  Allows `deleteSession(sessionId:)`
    /// to locate the owning task without requiring a `taskID` parameter.
    private var sessionTaskMap: [UUID: UUID] = [:]

    // MARK: - Configuration

    /// Must be called once before any session lifecycle methods.
    func configure(tabManager: TerminalTabManager, app: ghostty_app_t) {
        self.tabManager = tabManager
        self.ghosttyApp = app
    }

    // MARK: - Session lifecycle

    /// Opens a new terminal tab, starts a Claude session, and registers it under `taskID`.
    /// Returns the newly created `Session` immediately; the terminal command is
    /// sent after a 200 ms delay to give the shell time to initialise.
    func createSession(
        for taskID: UUID,
        worktree: Bool,
        branch: String,
        cwd: String? = nil,
        boardState: BoardState
    ) -> Session {
        guard let tabManager, let ghosttyApp else {
            fatalError("SessionManager not configured – call configure(with:app:) first")
        }

        // 1. Create new tab (also selects it)
        tabManager.newTab(app: ghosttyApp)
        let tabID = tabManager.activeTabID!

        // 2. Send cd to workspace then Claude command
        let command: String
        if worktree {
            command = "claude --permission-mode bypassPermissions --worktree"
        } else {
            command = "claude --permission-mode bypassPermissions"
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak tabManager] in
            guard let tabManager else { return }
            if let cwd {
                tabManager.activeTab?.surfaceView.sendText("cd \(cwd)")
                tabManager.activeTab?.surfaceView.sendEnter()
            }
            tabManager.activeTab?.surfaceView.sendText(command)
            tabManager.activeTab?.surfaceView.sendEnter()
        }

        // 3. Build session record
        let session = Session(
            title: "New Session",
            status: .running,
            timestamp: Date(),
            isWorkTree: worktree,
            branch: branch,
            tabID: tabID,
            cwd: cwd
        )

        // 4. Register in our indexes
        upsertSession(session)
        appendToTask(taskID: taskID, sessionID: session.id)

        // 5. Persist via BoardState
        boardState.addSession(to: taskID, session: session)

        return session
    }

    /// Brings an existing session to the foreground.
    /// - If the session still has a `tabID`, the tab is selected.
    /// - Otherwise a new tab is created and the Claude resume command is sent.
    func resumeSession(_ session: Session) {
        guard let tabManager else { return }

        if let tabID = session.tabID {
            // Tab still exists — just switch to it
            tabManager.selectTab(id: tabID)
        } else {
            // Tab was closed — create a new one and resume
            guard let ghosttyApp else { return }
            tabManager.newTab(app: ghosttyApp)
            let newTabID = tabManager.activeTabID!

            let resumeID = session.sessionId ?? session.id.uuidString.uppercased()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak tabManager] in
                guard let tabManager else { return }
                tabManager.activeTab?.surfaceView.sendText(
                    "claude --resume \(resumeID) --permission-mode bypassPermissions"
                )
                tabManager.activeTab?.surfaceView.sendEnter()
            }

            // Update the session with the new tab ID
            if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[index].tabID = newTabID
            }
        }
    }

    /// Closes the terminal tab (if any) and removes the session from all indexes.
    /// Does **not** remove the session from the owning task or persist —
    /// callers (e.g. `BoardState.removeSession(from:sessionId:)`) are responsible
    /// for that.
    func deleteSession(sessionId: UUID) {
        // Close the associated tab
        if let session = session(for: sessionId), let tabID = session.tabID {
            tabManager?.closeTab(id: tabID)
        }

        // Remove from flat list
        sessions.removeAll { $0.id == sessionId }

        // Remove from task mappings
        if let taskID = sessionTaskMap[sessionId] {
            taskSessionIDs[taskID]?.remove(sessionId)
            sessionTaskMap.removeValue(forKey: sessionId)
        }
    }

    /// Called by `TerminalTabManager` (or an observer) when a tab is externally closed.
    /// Unlinks the tab from any session without removing the session itself.
    func unlinkTab(tabID: UUID) {
        if let index = sessions.firstIndex(where: { $0.tabID == tabID }) {
            sessions[index].tabID = nil
        }
    }

    // MARK: - Query

    /// Returns the sessions that belong to a given kanban task.
    func sessions(for taskID: UUID) -> [Session] {
        guard let ids = taskSessionIDs[taskID] else { return [] }
        return sessions.filter { ids.contains($0.id) }
    }

    /// Looks up a single session by its local UUID.
    func session(for sessionId: UUID) -> Session? {
        sessions.first { $0.id == sessionId }
    }

    // MARK: - Mutation

    /// Inserts or replaces a session in the flat list.
    func upsertSession(_ session: Session) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
    }

    /// Updates our local session record with data parsed from a Claude JSONL file.
    /// Matching is tried by:
    ///   1. `session.sessionId == parsed.sessionId`
    ///   2. `session.id.uuidString.uppercased() == parsed.sessionId.uppercased()`
    func updateSession(from parsed: ParsedSession) {
        if let index = sessions.firstIndex(where: { $0.sessionId == parsed.sessionId }) {
            applyParsed(parsed, to: &sessions[index])
            return
        }

        if let index = sessions.firstIndex(where: { $0.id.uuidString.uppercased() == parsed.sessionId.uppercased() }) {
            sessions[index].sessionId = parsed.sessionId
            applyParsed(parsed, to: &sessions[index])
        }
    }

    // MARK: - Workspace

    /// Sends `cd <path>` to ALL terminal tabs and updates session cwds.
    /// Called when the user switches to a new workspace folder.
    func broadcastWorkspaceChange(path: String) {
        guard let tabManager else { return }

        // Update cwd on all sessions
        for index in sessions.indices {
            sessions[index].cwd = path
        }

        // Send cd to every terminal tab, not just session-linked ones
        for tab in tabManager.tabs {
            tab.surfaceView.sendText("cd \(path)")
            tab.surfaceView.sendEnter()
        }
    }

    // MARK: - Reconciliation

    /// Rebuilds internal indexes from the full task list.
    /// Called by `BoardState` after loading tasks from disk.
    func reconcile(from tasks: [KanbanTask]) {
        var allSessions: [Session] = []
        var byTaskID: [UUID: Set<UUID>] = [:]
        var sessionToTask: [UUID: UUID] = [:]

        for task in tasks {
            var sessionIDs = Set<UUID>()
            for session in task.sessions {
                allSessions.append(session)
                sessionIDs.insert(session.id)
                sessionToTask[session.id] = task.id
            }
            byTaskID[task.id] = sessionIDs
        }

        sessions = allSessions
        taskSessionIDs = byTaskID
        sessionTaskMap = sessionToTask
    }

    // MARK: - Private helpers

    /// Applies `ParsedSession` fields onto a mutable `Session`.
    private func applyParsed(_ parsed: ParsedSession, to session: inout Session) {
        if !parsed.title.isEmpty {
            session.title = parsed.title
        }
        session.status = parsed.status
        session.timestamp = parsed.timestamp
        if let branch = parsed.branch, !branch.isEmpty {
            session.branch = branch
        }
        session.isWorkTree = parsed.isWorkTree
        if let cwd = parsed.cwd {
            session.cwd = cwd
        }
    }

    /// Registers a session ID under a given task ID in the internal indexes.
    private func appendToTask(taskID: UUID, sessionID: UUID) {
        var ids = taskSessionIDs[taskID] ?? []
        ids.insert(sessionID)
        taskSessionIDs[taskID] = ids
        sessionTaskMap[sessionID] = taskID
    }
}
