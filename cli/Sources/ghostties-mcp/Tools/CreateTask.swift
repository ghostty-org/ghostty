import Foundation
import GhosttiesCore

func createTaskTool() -> Tool {
    Tool(
        name: "create_task",
        description: "Create a new task file in .ghostties/tasks/. Returns the created task's id.",
        inputSchema: S.object(
            properties: [
                ("title", S.string("Task title (required).")),
                ("source", S.string("Task source (e.g. linear, github, shell, sentry). Defaults to 'shell'.")),
                ("branch", S.string("Branch name to associate with the task.")),
                ("project", S.string("Project tag. Defaults to the tasks-dir's repo name.")),
                ("project_path", S.string("Absolute path to the project's root directory (e.g. ~/Code/ghostties). Stored raw — tildes are not expanded.")),
                ("template", S.string("Launch template name (e.g. \"Orchestrator\"). Stored verbatim.")),
                ("lane", S.string("Status lane.", enum: laneEnum)),
                ("priority", S.string("Task priority.", enum: priorityEnum)),
                ("notes", S.string("Initial note body to seed the ## Notes section."))
            ],
            required: ["title"]
        ),
        handler: { args, resolver in
            guard let title = args["title"]?.string, !title.isEmpty else {
                return .error("missing required argument: title")
            }
            let dir: URL
            do { dir = try resolver.resolve() }
            catch { return .error(error.localizedDescription) }

            let laneValue: TaskLane
            if let laneStr = args["lane"]?.string {
                guard let parsed = TaskLane.parse(laneStr) else {
                    return .error("unknown lane \"\(laneStr)\"")
                }
                laneValue = parsed
            } else {
                laneValue = .backlog
            }

            let source = args["source"]?.string ?? "shell"
            let branch = args["branch"]?.string ?? "null"
            let project = args["project"]?.string ?? defaultProject(from: dir)
            let projectPath = args["project_path"]?.string
            let template = args["template"]?.string
            // Validate priority against the typed enum; unknown values default to .none.
            let priorityValue: TaskPriority = {
                guard let raw = args["priority"]?.string, !raw.isEmpty else { return .none }
                return TaskPriority(rawValue: raw) ?? .none
            }()
            let seedNotes = args["notes"]?.string

            let id = makeID(title: title)
            let created = isoTimestamp()

            var pairs: [(String, String)] = [
                ("title", title),
                ("source", source),
                ("source-id", id),
                ("branch", branch),
                ("project", project),
                ("created", created),
                ("status", laneValue.rawValue)
            ]
            // Only write priority to disk when it is explicitly set (non-.none).
            // Omitting the key for .none keeps legacy fixtures clean.
            if priorityValue != .none {
                pairs.append(("priority", priorityValue.rawValue))
            }
            if let projectPath, !projectPath.isEmpty {
                pairs.append(("project-path", projectPath))
            }
            if let template, !template.isEmpty {
                pairs.append(("template", template))
            }

            let notesSeed: String
            if let seedNotes, !seedNotes.isEmpty {
                notesSeed = "- [\(humanStamp())] \(seedNotes)\n"
            } else {
                notesSeed = "\n"
            }
            let body = "\n## Goal\n\n\n## Notes\n\n\(notesSeed)\n## Activity\n\n- \(created) — Task created via ghostties-mcp\n"

            let store = TaskStore(directory: dir)
            do {
                let url = try store.create(id: id, pairs: pairs, body: body)
                Log.info("created task \(id) at \(url.path)")
                // Re-load the file so the returned shape matches other tools.
                guard let reloaded = store.loadFile(at: url) else {
                    return .json(.object(["id": .string(id), "path": .string(url.path)]))
                }
                return .json(taskDetail(reloaded))
            } catch let err as CLIError {
                return .error(err.errorDescription ?? "create failed")
            } catch {
                return .error(error.localizedDescription)
            }
        }
    )
}

// MARK: - Helpers — kept here so create_task doesn't depend on `gt` internals.

private func makeID(title: String) -> String {
    let slug = slugify(title)
    let suffix = String(UUID().uuidString.prefix(6)).lowercased()
    return slug.isEmpty ? "task-\(suffix)" : "\(slug)-\(suffix)"
}

private func slugify(_ s: String) -> String {
    let lowered = s.lowercased()
    var out = ""
    var lastWasDash = false
    for ch in lowered {
        if ch.isLetter || ch.isNumber {
            out.append(ch)
            lastWasDash = false
        } else if !lastWasDash {
            out.append("-")
            lastWasDash = true
        }
    }
    return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
}

private func defaultProject(from tasksDir: URL) -> String {
    let repo = tasksDir.deletingLastPathComponent().deletingLastPathComponent()
    let name = repo.lastPathComponent
    return name.isEmpty ? "ghostties" : name
}
