import ArgumentParser
import Foundation
import GhosttiesCore

struct DoneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "done",
        abstract: "Move a task to the graveyard (done) lane and stamp completion time."
    )

    @Argument(help: "Task id or unambiguous prefix.")
    var id: String

    func run() throws {
        let dir = try TasksDirectory.require()
        let store = TaskStore(directory: dir)
        let (task, url) = try store.resolveByFilename(idOrPrefix: id)

        let nowISO = isoFormatter.string(from: Date())
        var pairs = Frontmatter.set("status", TaskLane.done.rawValue, in: task.frontmatter)
        pairs = Frontmatter.set("completed", nowISO, in: pairs)

        try store.write(pairs: pairs, body: task.body, to: url)
        print("✓ marked done: \(task.title)")
    }
}
