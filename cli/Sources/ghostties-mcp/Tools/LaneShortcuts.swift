import Foundation
import GhosttiesCore

/// `get_active`, `get_needs_you`, and `get_inbox` are convenience shortcuts for
/// `list_tasks` filtered to one lane. They all share the same handler shape.
private func laneShortcut(name: String, description: String, lane: TaskLane) -> Tool {
    Tool(
        name: name,
        description: description,
        inputSchema: S.object(properties: []),
        handler: { _, resolver in
            let dir: URL
            do { dir = try resolver.resolve() }
            catch { return .error(error.localizedDescription) }

            let store = TaskStore(directory: dir)
            var tasks = store.loadAll().filter { $0.lane == lane }
            tasks.sort { $0.id < $1.id }
            return .json(.array(tasks.map(taskSummary)))
        }
    )
}

func getActiveTool() -> Tool {
    laneShortcut(
        name: "get_active",
        description: "Return tasks currently in the 'running' lane.",
        lane: .running
    )
}

func getNeedsYouTool() -> Tool {
    laneShortcut(
        name: "get_needs_you",
        description: "Return tasks currently in the 'needs-you' lane — tasks waiting on the user.",
        lane: .needsYou
    )
}

func getInboxTool() -> Tool {
    laneShortcut(
        name: "get_inbox",
        description: "Return tasks currently in the 'inbox' lane.",
        lane: .inbox
    )
}
