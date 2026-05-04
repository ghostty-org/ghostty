import Foundation
import Combine
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
    private var cancellables: Set<AnyCancellable> = []

    /// The workspace path to match new JSONL files against.
    private var currentWorkspacePath: String?

    /// Ordered list of sessions waiting to be matched with a real sessionId.
    /// We match the first one (FIFO) to new sessions from the JsonlWatcher.
    /// Each entry stores the localId, worktree flag, and creation time.
    private var pendingSessionQueue: [(localId: UUID, isWorkTree: Bool, createdAt: Date)] = []

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
        self.currentWorkspacePath = BoardState.shared.workspacePath

        // When BoardState removes a session, clean up our indexes and close the tab.
        BoardState.shared.$tasks
            .dropFirst()
            .sink { [weak self] newTasks in
                self?.handleBoardStateChange(newTasks: newTasks)
            }
            .store(in: &cancellables)
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

        // 2. Build session record (sessionId will be set by JsonlWatcher later)
        let localId = UUID()
        let session = Session(
            id: localId,
            title: "New Session",
            status: .running,
            timestamp: Date(),
            isWorkTree: worktree,
            isWorkTreeOverridden: worktree,  // user explicitly specified → protect from JSONL overwrite
            branch: branch,
            sessionId: nil,
            tabID: tabID,
            cwd: cwd
        )

        // 3. Send Claude command (no --session-id — Claude generates its own)
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

        // 4. Register in our indexes
        upsertSession(session)
        appendToTask(taskID: taskID, sessionID: session.id)
        pendingSessionQueue.append((localId: localId, isWorkTree: worktree, createdAt: Date()))

        // 5. Persist via BoardState
        boardState.addSession(to: taskID, session: session)

        return session
    }

    /// Brings an existing session to the foreground.
    /// - If the session still has a `tabID`, the tab is selected.
    /// - Otherwise a new tab is created and the Claude resume command is sent.
    func resumeSession(_ session: Session) {
        guard let tabManager else { return }

        if let tabID = session.tabID, tabManager.tabs.contains(where: { $0.id == tabID }) {
            // Tab still exists — just switch to it
            tabManager.selectTab(id: tabID)
        } else {
            // Tab was closed — create a new one and resume
            guard let ghosttyApp else { return }
            tabManager.newTab(app: ghosttyApp)
            let newTabID = tabManager.activeTabID!

            // cd to the workspace directory so claude --resume finds the session file
            let cwd = session.cwd ?? BoardState.shared.workspacePath

            let resumeID = session.sessionId ?? session.id.uuidString.uppercased()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak tabManager] in
                guard let tabManager else { return }
                if let cwd {
                    tabManager.activeTab?.surfaceView.sendText("cd \(cwd)")
                    tabManager.activeTab?.surfaceView.sendEnter()
                }
                tabManager.activeTab?.surfaceView.sendText(
                    "claude --resume \(resumeID) --permission-mode bypassPermissions"
                )
                tabManager.activeTab?.surfaceView.sendEnter()
            }

            // Update the session with the new tab ID in both SessionManager and BoardState
            if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[index].tabID = newTabID
                if let taskID = sessionTaskMap[session.id] {
                    BoardState.shared.updateSessionTabID(
                        taskId: taskID,
                        sessionId: session.id,
                        tabID: newTabID
                    )
                }
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
    /// If the session has never been matched to a real Claude session (`sessionId == nil`),
    /// the session is deleted entirely.  Otherwise the tab is unlinked from the session
    /// (tabID → nil) so the session can be resumed later in a new tab.
    func unlinkTab(tabID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.tabID == tabID }) else { return }
        let session = sessions[index]

        if session.sessionId == nil {
            // Session was created but Claude never started — wipe it completely.
            let sessionId = session.id
            let taskID = sessionTaskMap[sessionId]

            sessions.remove(at: index)
            if let taskID = taskID {
                taskSessionIDs[taskID]?.remove(sessionId)
                sessionTaskMap.removeValue(forKey: sessionId)
                BoardState.shared.removeSession(from: taskID, sessionId: sessionId)
            }

            // Dequeue any pending match for this session
            pendingSessionQueue.removeAll { $0.localId == sessionId }
        } else {
            sessions[index].tabID = nil
            if let taskID = sessionTaskMap[session.id] {
                BoardState.shared.updateSessionTabID(
                    taskId: taskID,
                    sessionId: session.id,
                    tabID: nil
                )
            }
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
    ///   3. `session.sessionId == nil` (safe: JsonlWatcher only processes the
    ///      current workspace's subdirectory, so any unmatched session belongs
    ///      to this workspace).
    ///
    /// After updating the local record, the change is also propagated to
    /// `BoardState.shared` for persistence.
    func updateSession(from parsed: ParsedSession) {
        var matchedIndex: Int?

        if let index = sessions.firstIndex(where: { $0.sessionId == parsed.sessionId }) {
            matchedIndex = index
        } else if let index = sessions.firstIndex(where: { $0.id.uuidString.uppercased() == parsed.sessionId.uppercased() }) {
            sessions[index].sessionId = parsed.sessionId
            matchedIndex = index
        } else if let index = sessions.firstIndex(where: { session in
            guard session.sessionId == nil else { return false }
            // Prefer cwd match when both sides have cwd info
            if let parsedCwd = parsed.cwd, let sessionCwd = session.cwd {
                return parsedCwd == sessionCwd
            }
            return true
        }) ?? sessions.firstIndex(where: { $0.sessionId == nil }) {
            sessions[index].sessionId = parsed.sessionId
            matchedIndex = index
        }

        if let matchedIndex {
            applyParsed(parsed, to: &sessions[matchedIndex])

            // Propagate to BoardState for persistence
            if let taskID = sessionTaskMap[sessions[matchedIndex].id] {
                BoardState.shared.updateSessionFromParsed(
                    taskId: taskID,
                    sessionId: sessions[matchedIndex].id,
                    parsed: parsed
                )
            }
        } else {
            // No match found — auto-create a new kanban session so
            // terminal-created Claude sessions don't disappear.
            autoCreateSession(from: parsed)
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

    // MARK: - BoardState sync

    /// Detects sessions removed from BoardState and cleans up our indexes + closes tabs.
    private func handleBoardStateChange(newTasks: [KanbanTask]) {
        let currentSessionIDs = Set(sessions.map { $0.id })
        let boardSessionIDs = Set(newTasks.flatMap { $0.sessions.map { $0.id } })
        let removedIDs = currentSessionIDs.subtracting(boardSessionIDs)

        for sessionId in removedIDs {
            // Close the terminal tab if one is linked
            if let session = session(for: sessionId), let tabID = session.tabID {
                tabManager?.closeTab(id: tabID)
            }

            // Clean up internal indexes
            sessions.removeAll { $0.id == sessionId }
            if let taskID = sessionTaskMap[sessionId] {
                taskSessionIDs[taskID]?.remove(sessionId)
                sessionTaskMap.removeValue(forKey: sessionId)
            }
        }
    }

    func matchNewSessionId(_ claudeSessionId: String, from parsed: ParsedSession) {
        guard !pendingSessionQueue.isEmpty else { return }

        // Priority 1: match by isWorkTree (preferred, not required)
        let entry: (localId: UUID, isWorkTree: Bool, createdAt: Date)
        if let match = pendingSessionQueue.first(where: { $0.isWorkTree == parsed.isWorkTree }) {
            entry = match
        } else {
            // Priority 2: any pending session (isWorkTree mismatch is common
            // when user creates kanban session without --worktree but Claude
            // auto-creates a worktree, or vice versa)
            entry = pendingSessionQueue.first!
        }

        // Update SessionManager's session
        if let index = sessions.firstIndex(where: { $0.id == entry.localId }) {
            sessions[index].sessionId = claudeSessionId

            // Propagate to BoardState for persistence
            if let taskID = sessionTaskMap[entry.localId] {
                BoardState.shared.updateSessionFromParsed(
                    taskId: taskID,
                    sessionId: entry.localId,
                    parsed: parsed
                )
            }
        }

        pendingSessionQueue.removeAll { $0.localId == entry.localId }
    }

    // MARK: - Private helpers

    /// Auto-creates a kanban session from an unmatched JSONL session.
    /// Adds it to the first task (by UUID sort order for determinism).
    private func autoCreateSession(from parsed: ParsedSession) {
        let session = Session(
            title: parsed.title.isEmpty ? "New Session" : parsed.title,
            status: parsed.status,
            timestamp: parsed.createdAt ?? Date(),
            isWorkTree: parsed.isWorkTree,
            branch: parsed.branch ?? "main",
            sessionId: parsed.sessionId,
            cwd: parsed.cwd
        )

        // Deterministic: pick the first task by UUID sort order
        guard let firstTaskID = sessionTaskMap.keys.sorted(by: { $0.uuidString < $1.uuidString }).first else { return }

        upsertSession(session)
        appendToTask(taskID: firstTaskID, sessionID: session.id)
        BoardState.shared.addSession(to: firstTaskID, session: session)
    }

    /// Applies `ParsedSession` fields onto a mutable `Session`.
    /// Note: timestamp is NOT overwritten — it represents session creation time.
    private func applyParsed(_ parsed: ParsedSession, to session: inout Session) {
        if !parsed.title.isEmpty {
            session.title = parsed.title
        }
        session.status = parsed.status
        if let branch = parsed.branch, !branch.isEmpty {
            session.branch = branch
        }
        if !session.isWorkTreeOverridden {
            session.isWorkTree = parsed.isWorkTree
        }
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
