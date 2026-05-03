import Foundation
import SwiftUI
import Combine
import UniformTypeIdentifiers

extension Notification.Name {
    static let workspacePathDidChange = Notification.Name("workspacePathDidChange")
}

@MainActor
final class BoardState: ObservableObject {
    static let shared = BoardState()

    @Published var tasks: [KanbanTask] = []
    @Published var isDarkMode: Bool = false
    @Published var workspacePath: String?

    private let persistence = Persistence.shared
    private var sessionManager: SessionManager?
    private var cancellables: Set<AnyCancellable> = []

    private let workspacePathKey = "kanban-workspace-path"

    private init() {
        loadWorkspacePath()
        load()
        loadTheme()
    }

    /// Configures the board state with a session manager.
    /// Must be called once during app launch (after tasks are loaded).
    /// Reconciles the session manager's internal indexes from the current task list.
    func configure(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
        sessionManager.reconcile(from: tasks)
    }

    // MARK: - Workspace

    private func loadWorkspacePath() {
        workspacePath = UserDefaults.standard.string(forKey: workspacePathKey)
        persistence.workspacePath = workspacePath
    }

    private func persistWorkspacePath() {
        if let path = workspacePath {
            UserDefaults.standard.set(path, forKey: workspacePathKey)
        } else {
            UserDefaults.standard.removeObject(forKey: workspacePathKey)
        }
    }

    /// Opens an NSOpenPanel for the user to select a workspace folder.
    /// On selection, saves the path to UserDefaults and launches a new
    /// app instance configured for that workspace, then closes the current app.
    func selectWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Select a workspace folder"
        panel.prompt = "Choose"

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }

        let path = selectedURL.path
        workspacePath = path
        persistence.workspacePath = path
        persistWorkspacePath()

        // Update the current app's JSONL watch path immediately
        NotificationCenter.default.post(name: .workspacePathDidChange, object: path)

        // Force sync so the new instance reads the fresh value
        UserDefaults.standard.synchronize()

        // Launch a new app instance alongside the current one
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config)
    }

    // MARK: - Persistence

    func load() {
        tasks = persistence.load()
    }

    func save() {
        persistence.save(tasks)
    }

    // MARK: - Theme

    private func loadTheme() {
        isDarkMode = UserDefaults.standard.bool(forKey: "kanban-dark-mode")
    }

    func toggleTheme() {
        isDarkMode.toggle()
        UserDefaults.standard.set(isDarkMode, forKey: "kanban-dark-mode")
    }

    // MARK: - Task CRUD

    func addTask(_ task: KanbanTask) {
        tasks.append(task)
        save()
    }

    func updateTask(_ task: KanbanTask) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
            save()
        }
    }

    func deleteTask(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        save()
    }

    func moveTask(_ id: UUID, to status: Status) {
        if let index = tasks.firstIndex(where: { $0.id == id }) {
            tasks[index].status = status
            save()
        }
    }

    func reorderTask(_ id: UUID, to newIndex: Int, in status: Status) {
        var taskIds = tasks.filter { $0.status == status }.map { $0.id }
        guard let fromIndex = taskIds.firstIndex(of: id) else { return }

        taskIds.remove(at: fromIndex)
        let insertAt = max(0, min(newIndex, taskIds.count))
        taskIds.insert(id, at: insertAt)

        var otherTasks = tasks.filter { $0.status != status }
        for taskId in taskIds {
            if let task = tasks.first(where: { $0.id == taskId }) {
                otherTasks.append(task)
            }
        }

        tasks = otherTasks
        save()
    }

    func toggleTaskExpanded(_ id: UUID) {
        if let index = tasks.firstIndex(where: { $0.id == id }) {
            tasks[index].isExpanded.toggle()
        }
    }

    // MARK: - Session CRUD

    func addSession(to taskId: UUID, session: Session) {
        if let index = tasks.firstIndex(where: { $0.id == taskId }) {
            tasks[index].sessions.append(session)
            tasks[index].isExpanded = true
            save()
        }
    }

    func removeSession(from taskId: UUID, sessionId: UUID) {
        // Note: SessionManager.deleteSession(sessionId:) is NOT called here.
        // TerminalTabManager is responsible for calling unlinkTab/deleteSession
        // on the SessionManager when a tab is closed externally.
        if let taskIndex = tasks.firstIndex(where: { $0.id == taskId }) {
            tasks[taskIndex].sessions.removeAll { $0.id == sessionId }
            save()
        }
    }

    func updateSessionStatus(taskId: UUID, sessionId: UUID, status: SessionStatus) {
        if let taskIndex = tasks.firstIndex(where: { $0.id == taskId }),
           let sessionIndex = tasks[taskIndex].sessions.firstIndex(where: { $0.id == sessionId }) {
            tasks[taskIndex].sessions[sessionIndex].status = status
            save()
        }
    }

    /// Updates a session's tabID (e.g., after resume creates a new tab, or unlink removes it).
    func updateSessionTabID(taskId: UUID, sessionId: UUID, tabID: UUID?) {
        if let taskIndex = tasks.firstIndex(where: { $0.id == taskId }),
           let sessionIndex = tasks[taskIndex].sessions.firstIndex(where: { $0.id == sessionId }) {
            tasks[taskIndex].sessions[sessionIndex].tabID = tabID
            save()
        }
    }

    /// Updates a session's metadata from a ParsedSession (JsonlWatcher data).
    /// Covers title, status, branch, isWorkTree, cwd, and sessionId.
    /// Note: timestamp is NOT overwritten — it represents session creation time.
    func updateSessionFromParsed(taskId: UUID, sessionId: UUID, parsed: ParsedSession) {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskId }),
              let sessionIndex = tasks[taskIndex].sessions.firstIndex(where: { $0.id == sessionId }) else {
            return
        }

        var session = tasks[taskIndex].sessions[sessionIndex]
        if !parsed.title.isEmpty {
            session.title = parsed.title
        }
        session.status = parsed.status
        if let branch = parsed.branch, !branch.isEmpty {
            session.branch = branch
        }
        if let branch = parsed.branch, !branch.isEmpty {
            session.branch = branch
        }
        session.isWorkTree = parsed.isWorkTree
        if let cwd = parsed.cwd {
            session.cwd = cwd
        }
        session.sessionId = parsed.sessionId

        tasks[taskIndex].sessions[sessionIndex] = session
        save()
    }

    // MARK: - Helpers

    func tasks(for status: Status) -> [KanbanTask] {
        tasks.filter { $0.status == status }
    }
}
