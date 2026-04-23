import Foundation
import GhosttiesCore

func writeSessionNotesTool() -> Tool {
    Tool(
        name: "write_session_notes",
        description: "Append a full session summary as a timestamped block to a task's ## Notes section. Intended for bulk narrative (e.g. session-hybrid compact hook); use append_task_notes for single-bullet updates.",
        inputSchema: S.object(
            properties: [
                ("task_id", S.string("Task id (filename stem, or unique prefix).")),
                ("summary", S.string("Markdown-formatted session summary to append.")),
                ("header", S.string("Optional section header. Defaults to \"Session {ISO timestamp}\"."))
            ],
            required: ["task_id", "summary"]
        ),
        handler: { args, resolver in
            guard let idArg = args["task_id"]?.string, !idArg.isEmpty else {
                return .error("missing required argument: task_id")
            }
            guard let summary = args["summary"]?.string, !summary.isEmpty else {
                return .error("missing required argument: summary")
            }
            let headerArg = args["header"]?.string
            let header: String = {
                if let h = headerArg, !h.trimmingCharacters(in: .whitespaces).isEmpty {
                    return h
                }
                return "Session \(isoTimestamp())"
            }()

            let dir: URL
            do { dir = try resolver.resolve() }
            catch { return .error(error.localizedDescription) }

            let store = TaskStore(directory: dir)
            do {
                let (task, url) = try store.resolve(idOrPrefix: idArg)
                let newBody = appendSessionBlockToNotes(
                    body: task.body,
                    header: header,
                    summary: summary
                )
                try store.write(pairs: task.frontmatter, body: newBody, to: url)
                Log.info("wrote session notes to \(task.id)")

                let notes = extractSection(named: "Notes", from: newBody) ?? ""
                return .json(.object([
                    "id": .string(task.id),
                    "notes": .string(notes)
                ]))
            } catch let err as CLIError {
                return .error(err.errorDescription ?? "write failed")
            } catch {
                return .error(error.localizedDescription)
            }
        }
    )
}

/// Append a `### <header>\n\n<summary>\n` block to the task's `## Notes`
/// section, with a blank line before and after. If `## Notes` doesn't exist,
/// append it at end of file. If `## Notes` exists but is empty, insert right
/// under the heading.
///
/// Sibling of `appendToNotes` in Notes.swift — same section-finding logic,
/// different payload shape. Kept as a separate function because the block
/// structure (heading + body + surrounding blank lines) doesn't collapse
/// cleanly into the single-line bullet path.
func appendSessionBlockToNotes(body: String, header: String, summary: String) -> String {
    let block = "### \(header)\n\n\(summary)"
    let lines = body.components(separatedBy: "\n")

    // Find `## Notes` heading.
    var notesIdx: Int?
    for (i, l) in lines.enumerated() {
        if l.hasPrefix("## "), l.dropFirst(3).trimmingCharacters(in: .whitespaces) == "Notes" {
            notesIdx = i
            break
        }
    }

    // Case: no `## Notes` section — append one at end of file.
    guard let start = notesIdx else {
        var out = body
        if !out.hasSuffix("\n") { out += "\n" }
        if !out.hasSuffix("\n\n") { out += "\n" }
        out += "## Notes\n\n\(block)\n"
        return out
    }

    // Find section end (next `## ` or EOF).
    var end = lines.count
    for i in (start + 1)..<lines.count {
        if lines[i].hasPrefix("## ") {
            end = i
            break
        }
    }

    // Check whether the section has any real content.
    var hasContent = false
    for i in (start + 1)..<end {
        if !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
            hasContent = true
            break
        }
    }

    var newLines = lines

    if !hasContent {
        // Empty section: replace the entire inner slice with one blank line +
        // the block + one trailing blank line.
        let blockLines = block.components(separatedBy: "\n")
        var replacement: [String] = [""]
        replacement.append(contentsOf: blockLines)
        replacement.append("")
        newLines.replaceSubrange((start + 1)..<end, with: replacement)
        return newLines.joined(separator: "\n")
    }

    // Non-empty section: locate the last non-blank line, then insert a blank
    // separator + block + blank line right after it. Collapse any pre-existing
    // trailing blank lines inside the section so we don't stack `\n\n\n` before
    // the next `## ` heading.
    var lastContent = start
    for i in (start + 1)..<end {
        if !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
            lastContent = i
        }
    }

    let blockLines = block.components(separatedBy: "\n")
    var insertion: [String] = [""]
    insertion.append(contentsOf: blockLines)
    insertion.append("")

    // Replace range `(lastContent + 1)..<end` (all the section-trailing blanks)
    // with our insertion. Preserves whatever followed `end` (next `## ` or EOF).
    newLines.replaceSubrange((lastContent + 1)..<end, with: insertion)
    return newLines.joined(separator: "\n")
}
