import ArgumentParser
import Foundation
import GhosttiesCore

struct GT: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gt",
        abstract: "Ghostties task CLI — manipulate .ghostties/tasks/ from any shell.",
        version: "0.1.0",
        subcommands: [
            NewCommand.self,
            ListCommand.self,
            FocusCommand.self,
            DoneCommand.self,
            NotesCommand.self,
            MCPCommand.self,
            SmokeCommand.self
        ]
    )
}

// Top-level entry. ArgumentParser dispatches, prints help, and maps thrown
// `CLIError` values to the process exit code via `CLIError.exitCode`.
do {
    var command = try GT.parseAsRoot()
    try command.run()
} catch let err as CLIError {
    FileHandle.standardError.write(Data((err.errorDescription ?? "error: unknown").utf8 + [0x0A]))
    GT.exit(withError: ExitCode(err.exitCode))
} catch {
    GT.exit(withError: error)
}
