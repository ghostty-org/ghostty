import Foundation
import GhosttiesCore

func readTaskNotesTool() -> Tool {
    Tool(
        name: "read_task_notes",
        description: "Return the content of the ## Notes section of a task as a single markdown string.",
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
                let notes = extractSection(named: "Notes", from: task.body) ?? ""
                return .json(.object([
                    "id": .string(task.id),
                    "notes": .string(notes)
                ]))
            } catch let err as CLIError {
                return .error(err.errorDescription ?? "lookup failed")
            } catch {
                return .error(error.localizedDescription)
            }
        }
    )
}

func appendTaskNotesTool() -> Tool {
    Tool(
        name: "append_task_notes",
        description: "Append a timestamped bullet to a task's ## Notes section. Returns the new notes content.",
        inputSchema: S.object(
            properties: [
                ("id", S.string("Task id or unambiguous prefix.")),
                ("text", S.string("The note text. Will be prefixed with the current timestamp."))
            ],
            required: ["id", "text"]
        ),
        handler: { args, resolver in
            guard let idArg = args["id"]?.string, !idArg.isEmpty else {
                return .error("missing required argument: id")
            }
            guard let text = args["text"]?.string, !text.isEmpty else {
                return .error("missing required argument: text")
            }

            let dir: URL
            do { dir = try resolver.resolve() }
            catch { return .error(error.localizedDescription) }

            let store = TaskStore(directory: dir)
            do {
                let (task, url) = try store.resolve(idOrPrefix: idArg)
                let bullet = "- [\(humanStamp())] \(text)"
                let newBody = appendToNotes(body: task.body, line: bullet)
                try store.write(pairs: task.frontmatter, body: newBody, to: url)
                Log.info("appended note to \(task.id)")

                let notes = extractSection(named: "Notes", from: newBody) ?? ""
                return .json(.object([
                    "id": .string(task.id),
                    "notes": .string(notes)
                ]))
            } catch let err as CLIError {
                return .error(err.errorDescription ?? "append failed")
            } catch {
                return .error(error.localizedDescription)
            }
        }
    )
}

/// Insert `line` at the end of the `## Notes` section. If the section doesn't
/// exist, append one. Mirrors the behavior of `gt notes append` so both
/// surfaces produce identical files.
private func appendToNotes(body: String, line: String) -> String {
    let lines = body.components(separatedBy: "\n")

    var notesIdx: Int?
    for (i, l) in lines.enumerated() {
        if l.hasPrefix("## ") && l.dropFirst(3).trimmingCharacters(in: .whitespaces) == "Notes" {
            notesIdx = i
            break
        }
    }

    guard let start = notesIdx else {
        var out = body
        if !out.hasSuffix("\n") { out += "\n" }
        if !out.hasSuffix("\n\n") { out += "\n" }
        out += "## Notes\n\n\(line)\n"
        return out
    }

    var end = lines.count
    for i in (start + 1)..<lines.count {
        if lines[i].hasPrefix("## ") {
            end = i
            break
        }
    }

    var insertAt = end
    while insertAt > start + 1, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty {
        insertAt -= 1
    }

    var newLines = lines
    newLines.insert(line, at: insertAt)
    return newLines.joined(separator: "\n")
}
