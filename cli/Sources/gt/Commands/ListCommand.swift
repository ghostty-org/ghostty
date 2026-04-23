import ArgumentParser
import Foundation
import GhosttiesCore

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List tasks in the current .ghostties/tasks/ directory."
    )

    @Option(name: .long, help: "Filter by lane.")
    var lane: String?

    @Option(name: .long, help: "Filter by source (linear, github, shell, ...).")
    var source: String?

    @Option(name: .long, help: "Filter by project.")
    var project: String?

    func run() throws {
        let dir = try TasksDirectory.require()
        let store = TaskStore(directory: dir)
        var tasks = store.loadAll()

        if let lane {
            guard let target = TaskLane.parse(lane) else {
                throw CLIError.usage("unknown lane \"\(lane)\"")
            }
            tasks = tasks.filter { $0.lane == target }
        }
        if let source {
            tasks = tasks.filter { ($0.source ?? "").lowercased() == source.lowercased() }
        }
        if let project {
            tasks = tasks.filter { ($0.project ?? "").lowercased() == project.lowercased() }
        }

        tasks.sort { a, b in
            if a.lane.priority != b.lane.priority {
                return a.lane.priority < b.lane.priority
            }
            return a.id < b.id
        }

        let useColor = isStdoutATTY() && termSupportsColor()

        for t in tasks {
            let laneCol = padRight(t.lane.display, width: 10)
            let laneStyled = useColor ? colorize(laneCol, lane: t.lane) : laneCol
            let idCol = padRight(t.id, width: 14)
            var line = "\(idCol)  \(laneStyled)  \(t.title)"
            if let p = t.project, !p.isEmpty {
                line += "  [project: \(p)]"
            }
            print(line)
        }
    }

    // MARK: - ANSI helpers

    private func padRight(_ s: String, width: Int) -> String {
        if s.count >= width { return s }
        return s + String(repeating: " ", count: width - s.count)
    }

    private func isStdoutATTY() -> Bool {
        isatty(fileno(stdout)) != 0
    }

    private func termSupportsColor() -> Bool {
        guard let term = ProcessInfo.processInfo.environment["TERM"]?.lowercased() else {
            return false
        }
        if term == "dumb" { return false }
        return term.contains("color") || term.contains("xterm") || term.contains("screen") || term.contains("tmux") || term.contains("ghostty")
    }

    private func colorize(_ s: String, lane: TaskLane) -> String {
        let reset = "\u{001B}[0m"
        let code: String
        switch lane {
        case .needsYou: code = "\u{001B}[38;5;203m"  // terracotta-ish red
        case .running:  code = "\u{001B}[38;5;114m"  // soft green
        case .review:   code = "\u{001B}[38;5;179m"  // amber
        case .inbox:    code = "\u{001B}[38;5;110m"  // cool blue
        case .backlog:  code = "\u{001B}[38;5;244m"  // neutral gray
        case .done:     code = "\u{001B}[38;5;240m"  // dim gray
        }
        return "\(code)\(s)\(reset)"
    }
}

#if canImport(Darwin)
import Darwin
private let stdout = Darwin.stdout
#elseif canImport(Glibc)
import Glibc
private let stdout = Glibc.stdout
#endif
