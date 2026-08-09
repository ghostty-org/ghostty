import Foundation

/// One hit from a workspace search.
struct SearchHit: Identifiable, Equatable {
    let path: String
    let line: Int
    let column: Int
    let text: String

    var id: String { "\(path):\(line):\(column)" }

    var name: String { (path as NSString).lastPathComponent }

    /// The path relative to the searched root, which is what makes a
    /// result list readable — absolute paths in a 240pt column are all
    /// prefix and no information.
    func relativePath(to root: String) -> String {
        guard path.hasPrefix(root) else { return path }
        return String(path.dropFirst(root.count).drop(while: { $0 == "/" }))
    }
}

/// Searching the files under a folder.
///
/// Shells out rather than walking the tree here: `ripgrep` is enormously
/// faster than anything reasonable to write, and already knows to skip
/// `.git`, `node_modules` and whatever `.gitignore` says — which is the
/// difference between results in a moment and a minute of reading build
/// output nobody wanted.
enum WorkspaceSearch {
    /// `rg` when it is installed, else `grep`.
    ///
    /// The fallback is not merely a courtesy: `rg` is not on a stock macOS
    /// and the feature has to work before anyone installs anything.
    enum Tool: Equatable {
        case ripgrep(String)
        case grep(String)

        var path: String {
            switch self {
            case .ripgrep(let path), .grep(let path): return path
            }
        }
    }

    /// The arguments for a literal, case-insensitive search.
    ///
    /// `--` before the pattern in both cases: a query starting with `-` is
    /// something people type by accident, and without it the tool reads it
    /// as a flag and fails in a way that looks like the search is broken.
    static func arguments(for tool: Tool, query: String, root: String) -> [String] {
        switch tool {
        case .ripgrep:
            return [
                "--line-number", "--column", "--no-heading", "--color", "never",
                "--fixed-strings", "--ignore-case", "--max-count", "50",
                "--", query, root,
            ]
        case .grep:
            return [
                "-r", "-n", "-I", "-F", "-i",
                "--exclude-dir=.git", "--exclude-dir=node_modules",
                "--exclude-dir=.build", "--exclude-dir=zig-out",
                "--", query, root,
            ]
        }
    }

    /// Parses a line of `path:line:column:text` or `path:line:text`.
    ///
    /// Both shapes have to be handled because `grep` has no `--column`, and
    /// the parse is deliberately right-to-left off the *front*: a path can
    /// contain colons, so splitting on every colon and taking fields would
    /// mangle any file whose name has one.
    static func parse(line: String, hasColumn: Bool) -> SearchHit? {
        guard let firstColon = line.firstIndex(of: ":") else { return nil }
        var cursor = line.index(after: firstColon)
        let path = String(line[line.startIndex..<firstColon])
        guard !path.isEmpty else { return nil }

        guard let secondColon = line[cursor...].firstIndex(of: ":") else { return nil }
        guard let lineNumber = Int(line[cursor..<secondColon]) else { return nil }
        cursor = line.index(after: secondColon)

        var column = 1
        if hasColumn {
            guard let thirdColon = line[cursor...].firstIndex(of: ":") else { return nil }
            guard let parsed = Int(line[cursor..<thirdColon]) else { return nil }
            column = parsed
            cursor = line.index(after: thirdColon)
        }

        return SearchHit(
            path: path,
            line: lineNumber,
            column: column,
            text: String(line[cursor...])
        )
    }

    static func parse(output: String, hasColumn: Bool) -> [SearchHit] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { parse(line: String($0), hasColumn: hasColumn) }
    }

    /// Finds the search tool on the login shell's PATH.
    ///
    /// The same problem git had: a GUI app's PATH is `/usr/bin:/bin` and
    /// nothing installed by Homebrew is on it, so `rg` would look absent on
    /// a machine that has it.
    nonisolated static func locate() -> Tool {
        let common = ["/opt/homebrew/bin/rg", "/usr/local/bin/rg"]
        let fromPath = (LoginEnvironment.loginPath() ?? "")
            .split(separator: ":")
            .map { "\($0)/rg" }

        for candidate in common + fromPath
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return .ripgrep(candidate)
        }
        return .grep("/usr/bin/grep")
    }

    /// Runs the search. Blocking, so callers keep it off the main thread.
    nonisolated static func run(query: String, root: String) -> [SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !root.isEmpty else { return [] }

        let tool = locate()
        let hasColumn: Bool
        if case .ripgrep = tool { hasColumn = true } else { hasColumn = false }

        let result = ShellCommand.runResult(
            tool.path,
            arguments(for: tool, query: trimmed, root: root),
            environment: LoginEnvironment.environment(),
            timeout: 20
        )

        // Exit status 1 means "no matches" for both tools, which is an
        // answer rather than a failure — treating it as one would surface
        // an error every time somebody typed a word that isn't there.
        return parse(output: result.stdout, hasColumn: hasColumn)
    }
}
