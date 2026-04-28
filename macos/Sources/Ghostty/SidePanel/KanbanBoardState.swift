import Foundation
import SwiftUI

final class BoardState: ObservableObject {
    @Published var tasks: [KanbanTask] = []
    @Published var isDarkMode: Bool = false

    private let persistence = Persistence.shared
    private var sessionWatcher: SessionFileWatcher?

    init() {
        load()
        loadTheme()
        sessionWatcher = SessionFileWatcher(sessionManager: SessionManager.shared)
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

    // MARK: - Helpers

    func tasks(for status: Status) -> [KanbanTask] {
        tasks.filter { $0.status == status }
    }
}
