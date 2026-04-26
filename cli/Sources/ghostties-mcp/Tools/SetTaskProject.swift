import Foundation
import GhosttiesCore

func setTaskProjectTool() -> Tool {
    Tool(
        name: "set_task_project",
        description: "Update the project-path (and optionally template) on an existing task. Returns the updated task.",
        inputSchema: S.object(
            properties: [
                ("id", S.string("Task id or unambiguous prefix.")),
                ("project_path", S.string("Absolute path to the project's root directory (e.g. ~/Code/ghostties). Stored raw — tildes are not expanded.")),
                ("template", S.string("Launch template name (e.g. \"Orchestrator\"). Stored verbatim. Omit to leave the existing value unchanged."))
            ],
            required: ["id", "project_path"]
        ),
        handler: { args, resolver in
            guard let idArg = args["id"]?.string, !idArg.isEmpty else {
                return .error("missing required argument: id")
            }
            guard let projectPath = args["project_path"]?.string, !projectPath.isEmpty else {
                return .error("missing required argument: project_path")
            }

            let dir: URL
            do { dir = try resolver.resolve() }
            catch { return .error(error.localizedDescription) }

            let store = TaskStore(directory: dir)
            do {
                let (task, url) = try store.resolve(idOrPrefix: idArg)

                var pairs = Frontmatter.set("project-path", projectPath, in: task.frontmatter)
                // Only update template when the caller explicitly supplies it.
                if let template = args["template"]?.string, !template.isEmpty {
                    pairs = Frontmatter.set("template", template, in: pairs)
                }
                let now = isoTimestamp()
                pairs = Frontmatter.set("updated", now, in: pairs)

                try store.write(pairs: pairs, body: task.body, to: url)
                Log.info("set project-path for \(task.id) to \(projectPath)")

                guard let reloaded = store.loadFile(at: url) else {
                    return .error("wrote file but could not re-read it")
                }
                return .json(taskDetail(reloaded))
            } catch let err as CLIError {
                return .error(err.errorDescription ?? "set-project failed")
            } catch {
                return .error(error.localizedDescription)
            }
        }
    )
}
