import Foundation
import GhosttiesCore

// MARK: - Argv parsing
//
// Intentionally hand-rolled — ArgumentParser is overkill for a single optional
// --tasks-dir flag and would pull a dependency into this target for no win.

func parseArgs(_ argv: [String]) -> (override: URL?, help: Bool) {
    var override: URL?
    var i = 1
    while i < argv.count {
        let a = argv[i]
        switch a {
        case "--tasks-dir":
            i += 1
            if i >= argv.count {
                FileHandle.standardError.write(Data("error: --tasks-dir requires a path\n".utf8))
                exit(1)
            }
            let raw = argv[i]
            let path = (raw as NSString).expandingTildeInPath
            let url: URL
            if path.hasPrefix("/") {
                url = URL(fileURLWithPath: path, isDirectory: true)
            } else {
                let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                url = cwd.appendingPathComponent(path, isDirectory: true)
            }
            override = url
        case "-h", "--help":
            return (nil, true)
        case "--version":
            print(Server.serverVersion)
            exit(0)
        default:
            FileHandle.standardError.write(Data("error: unknown argument: \(a)\n".utf8))
            exit(1)
        }
        i += 1
    }
    return (override, false)
}

let args = parseArgs(CommandLine.arguments)

if args.help {
    print("""
    ghostties-mcp — Model Context Protocol server for Ghostties tasks.

    USAGE:
      ghostties-mcp [--tasks-dir <path>]

    OPTIONS:
      --tasks-dir <path>   Override the .ghostties/tasks/ directory.
                           Useful when launched by a Claude Code config
                           that doesn't run in the repo's cwd.
      --version            Print version and exit.
      -h, --help           Show this help.

    Talks JSON-RPC 2.0 over stdio. Logs go to stderr.
    """)
    exit(0)
}

let resolver = TasksDirectoryResolver(override: args.override)
let server = Server(resolver: resolver)
server.run()
