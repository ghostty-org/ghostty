import Foundation
import GhosttiesCore

func updateTaskStatusTool() -> Tool {
    Tool(
        name: "update_task_status",
        description: "Move a task to a different lane. 'graveyard' is accepted as an alias for 'done' (matches the gt CLI). Returns the updated task.",
        inputSchema: S.object(
            properties: [
                ("id", S.string("Task id or unambiguous prefix.")),
                ("status", S.string("Target lane.", enum: laneEnum))
            ],
            required: ["id", "status"]
        ),
        handler: { args, resolver in
            guard let idArg = args["id"]?.string, !idArg.isEmpty else {
                return .error("missing required argument: id")
            }
            guard let statusArg = args["status"]?.string, !statusArg.isEmpty else {
                return .error("missing required argument: status")
            }
            guard let laneValue = TaskLane.parse(statusArg) else {
                return .error("unknown status \"\(statusArg)\"")
            }

            let dir: URL
            do { dir = try resolver.resolve() }
            catch { return .error(error.localizedDescription) }

            let store = TaskStore(directory: dir)
            do {
                let (task, url) = try store.resolve(idOrPrefix: idArg)

                var pairs = Frontmatter.set("status", laneValue.rawValue, in: task.frontmatter)
                let now = isoTimestamp()
                pairs = Frontmatter.set("updated", now, in: pairs)
                if laneValue == .done && Frontmatter.value(for: "completed", in: pairs) == nil {
                    pairs = Frontmatter.set("completed", now, in: pairs)
                }

                try store.write(pairs: pairs, body: task.body, to: url)
                Log.info("moved \(task.id) to lane \(laneValue.rawValue)")

                guard let reloaded = store.loadFile(at: url) else {
                    return .error("wrote file but could not re-read it")
                }
                return .json(taskDetail(reloaded))
            } catch let err as CLIError {
                return .error(err.errorDescription ?? "update failed")
            } catch {
                return .error(error.localizedDescription)
            }
        }
    )
}
