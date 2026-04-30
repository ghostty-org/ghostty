import Foundation

final class Persistence {
    static let shared = Persistence()

    private let fileManager = FileManager.default

    /// Optional workspace path. When set, tasks.json is stored here.
    /// When nil, falls back to ~/Library/Application Support/KanbanBoard/tasks.json
    var workspacePath: String?

    private var tasksFileURL: URL {
        if let workspacePath {
            let url = URL(fileURLWithPath: workspacePath)
                .appendingPathComponent(".kanban")
                .appendingPathComponent("tasks.json")
            let dir = url.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: dir.path) {
                try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            return url
        }
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("KanbanBoard", isDirectory: true)

        if !fileManager.fileExists(atPath: appFolder.path) {
            try? fileManager.createDirectory(at: appFolder, withIntermediateDirectories: true)
        }

        return appFolder.appendingPathComponent("tasks.json")
    }

    private init() {}

    func load() -> [KanbanTask] {
        guard fileManager.fileExists(atPath: tasksFileURL.path) else {
            return sampleTasks()
        }

        do {
            let data = try Data(contentsOf: tasksFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([KanbanTask].self, from: data)
        } catch {
            print("Failed to load tasks: \(error)")
            return sampleTasks()
        }
    }

    func save(_ tasks: [KanbanTask]) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(tasks)
            try data.write(to: tasksFileURL, options: .atomic)
        } catch {
            print("Failed to save tasks: \(error)")
        }
    }

    private func sampleTasks() -> [KanbanTask] {
        [
            KanbanTask(
                title: "User Login Module",
                description: "Implement OAuth2.0 login flow",
                priority: .p1,
                status: .todo,
                sessions: [
                    Session(title: "Setup auth provider", status: .idle, timestamp: Date().addingTimeInterval(-7200), branch: "main"),
                    Session(title: "Implement callback", status: .running, timestamp: Date().addingTimeInterval(-1800), isWorkTree: true, branch: "feature/oauth")
                ]
            ),
            KanbanTask(
                title: "Database Optimization",
                description: "Index optimization and query refactoring",
                priority: .p2,
                status: .todo,
                sessions: []
            ),
            KanbanTask(
                title: "API Documentation",
                description: "Update Swagger docs",
                priority: .p3,
                status: .inProgress,
                sessions: [
                    Session(title: "Document endpoints", status: .running, timestamp: Date().addingTimeInterval(-3600), branch: "main")
                ]
            ),
            KanbanTask(
                title: "Payment Integration",
                description: "WeChat Pay integration",
                priority: .p0,
                status: .review,
                sessions: [
                    Session(title: "Sandbox testing", status: .idle, timestamp: Date().addingTimeInterval(-86400), branch: "main"),
                    Session(title: "Fix callback error", status: .needInput, timestamp: Date().addingTimeInterval(-10800), branch: "main")
                ]
            ),
            KanbanTask(
                title: "Unit Test Coverage",
                description: "Core business logic tests",
                priority: .p2,
                status: .done,
                sessions: [
                    Session(title: "Run all tests", status: .idle, timestamp: Date().addingTimeInterval(-18000), branch: "main")
                ]
            )
        ]
    }
}
