import Foundation
import GhosttiesCore

func getTaskTool() -> Tool {
    Tool(
        name: "get_task",
        description: "Fetch a single task by id or unambiguous prefix. Returns full task including the parsed ## Notes section.",
        inputSchema: S.object(
            properties: [
                ("id", S.string("Task id or unambiguous prefix."))
            ],
            required: ["id"]
        ),
        handler: { args, resolver in
            guard let idArg = args["id"]?.string, !idArg.isEmpty else {
                return .error("missing required argument: id")
            }
            let dir: URL
            do { dir = try resolver.resolve() }
            catch { return .error(error.localizedDescription) }

            let store = TaskStore(directory: dir)
            do {
                let (task, _) = try store.resolve(idOrPrefix: idArg)
                return .json(taskDetail(task))
            } catch let err as CLIError {
                return .error(err.errorDescription ?? "lookup failed")
            } catch {
                return .error(error.localizedDescription)
            }
        }
    )
}
