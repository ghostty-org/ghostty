import Foundation
import GhosttiesCore

func listTasksTool() -> Tool {
    Tool(
        name: "list_tasks",
        description: "List tasks in .ghostties/tasks/ with optional filters by lane, project, or source.",
        inputSchema: S.object(properties: [
            ("lane", S.string("Filter by lane. 'graveyard' is accepted as an alias for 'done'.", enum: laneEnum)),
            ("project", S.string("Filter by project tag.")),
            ("source", S.string("Filter by source (e.g. linear, github, shell, sentry)."))
        ]),
        handler: { args, resolver in
            let dir: URL
            do { dir = try resolver.resolve() }
            catch { return .error(error.localizedDescription) }

            let store = TaskStore(directory: dir)
            var tasks = store.loadAll()

            if let laneStr = args["lane"]?.string {
                guard let target = TaskLane.parse(laneStr) else {
                    return .error("unknown lane \"\(laneStr)\"")
                }
                tasks = tasks.filter { $0.lane == target }
            }
            if let project = args["project"]?.string {
                tasks = tasks.filter { ($0.project ?? "").lowercased() == project.lowercased() }
            }
            if let source = args["source"]?.string {
                tasks = tasks.filter { ($0.source ?? "").lowercased() == source.lowercased() }
            }

            tasks.sort { a, b in
                if a.lane.priority != b.lane.priority {
                    return a.lane.priority < b.lane.priority
                }
                return a.id < b.id
            }

            return .json(.array(tasks.map(taskSummary)))
        }
    )
}
