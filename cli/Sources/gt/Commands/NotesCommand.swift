import ArgumentParser
import Foundation
import GhosttiesCore

struct NotesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notes",
        abstract: "Manage the ## Notes section of a task.",
        subcommands: [AppendNotes.self]
    )
}

struct AppendNotes: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "append",
        abstract: "Append a timestamped line to a task's ## Notes section."
    )

    @Argument(help: "Task id or unambiguous prefix.")
    var id: String

    @Argument(help: "Note text (quoted).")
    var text: String

    func run() throws {
        let dir = try TasksDirectory.require()
        let store = TaskStore(directory: dir)
        let (task, url) = try store.resolve(idOrPrefix: id)

        let stamp = humanTimestamp(Date())
        let bullet = "- [\(stamp)] \(text)"
        let newBody = appendToNotes(body: task.body, line: bullet)

        try store.write(pairs: task.frontmatter, body: newBody, to: url)
    }

    // MARK: - Body rewrite

    /// Insert `line` at the end of the `## Notes` section. If the section
    /// doesn't exist, append one at the end of the body.
    private func appendToNotes(body: String, line: String) -> String {
        let lines = body.components(separatedBy: "\n")

        // Find the Notes header line index.
        var notesIdx: Int?
        for (i, l) in lines.enumerated() {
            if l.hasPrefix("## ") && l.dropFirst(3).trimmingCharacters(in: .whitespaces) == "Notes" {
                notesIdx = i
                break
            }
        }

        guard let start = notesIdx else {
            // No Notes section; append one. Guarantee one blank line of
            // separation from whatever preceded.
            var out = body
            if !out.hasSuffix("\n") { out += "\n" }
            if !out.hasSuffix("\n\n") { out += "\n" }
            out += "## Notes\n\n\(line)\n"
            return out
        }

        // Find the end of the Notes section (next `## ` or EOF).
        var end = lines.count
        for i in (start + 1)..<lines.count {
            if lines[i].hasPrefix("## ") {
                end = i
                break
            }
        }

        // Walk back from `end` over trailing blank lines so the bullet sits
        // right under the existing content.
        var insertAt = end
        while insertAt > start + 1, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            insertAt -= 1
        }

        var newLines = lines
        newLines.insert(line, at: insertAt)
        return newLines.joined(separator: "\n")
    }

    /// Human-readable timestamp matching the spec: `YYYY-MM-DD HH:MM` in local time.
    private func humanTimestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }
}
