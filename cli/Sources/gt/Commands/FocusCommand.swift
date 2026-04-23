import ArgumentParser
import Foundation
import GhosttiesCore

struct FocusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "focus",
        abstract: "Mark a task as focused (writes its id to .ghostties/.focus)."
    )

    @Argument(help: "Task id or unambiguous prefix.")
    var id: String

    func run() throws {
        let dir = try TasksDirectory.require()
        let store = TaskStore(directory: dir)
        let (task, _) = try store.resolve(idOrPrefix: id)

        let stateDir = TasksDirectory.stateDirectory(from: dir)
        let focusFile = stateDir.appendingPathComponent(".focus")
        do {
            try task.id.write(to: focusFile, atomically: true, encoding: .utf8)
        } catch {
            throw CLIError.io("could not write \(focusFile.path): \(error.localizedDescription)")
        }
        print("focused: \(task.title)")
    }
}
