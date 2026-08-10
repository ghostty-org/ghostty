import Foundation

/// A file path found in terminal output, and where in it to land.
///
/// Ghostty already detects bare paths — `src/config/url.zig` has branches for
/// rooted and relative ones — so ⌘-clicking `src/main.ts` in a `grep` result
/// already does something. What it does is hand the path to Launch Services,
/// which opens the system's text editor. This is the piece that lets the
/// click go where the reader chose in Settings instead.
///
/// It also reads the `path:line:column` form that every compiler, linter and
/// stack trace prints, because arriving in the file and having to find the
/// line by hand is most of the work the click was supposed to save.
struct TerminalPathTarget: Equatable {
    let path: String

    /// One-based, as tools print them. Nil when the text carried no line.
    let line: Int?
    let column: Int?

    /// Reads the trailing `:line` and `:column`, if any.
    ///
    /// Pure, and separated from any filesystem check, because the parsing is
    /// where the mistakes are: a Windows-style `C:\…`, a path that genuinely
    /// ends in a colon, and a number that is part of the name all have to
    /// come out right.
    static func parse(_ text: String) -> TerminalPathTarget {
        var path = text
        var numbers: [Int] = []

        // At most twice: `file:12:5`. A third would be part of the name.
        while numbers.count < 2 {
            guard let colon = path.lastIndex(of: ":") else { break }
            let suffix = String(path[path.index(after: colon)...])
            guard !suffix.isEmpty, let number = Int(suffix), number > 0 else { break }

            // A single character before the colon is a drive letter, not a
            // path that happens to end in one.
            let head = String(path[..<colon])
            guard head.count > 1 else { break }

            numbers.insert(number, at: 0)
            path = head
        }

        return TerminalPathTarget(
            path: path,
            line: numbers.first,
            column: numbers.count > 1 ? numbers[1] : nil
        )
    }

    /// The target as a resolved file, or nil when it is not one.
    ///
    /// Terminal output is untrusted text: it can name anything, including a
    /// directory or something that does not exist. Only a real file is worth
    /// opening, and anything else falls back to what the app did before.
    func resolvedFile(relativeTo directory: String?) -> URL? {
        let expanded = (path as NSString).expandingTildeInPath
        let candidates: [String]

        if expanded.hasPrefix("/") {
            candidates = [expanded]
        } else if let directory {
            candidates = [(directory as NSString).appendingPathComponent(expanded)]
        } else {
            return nil
        }

        for candidate in candidates {
            let standardized = (candidate as NSString).standardizingPath
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: standardized,
                isDirectory: &isDirectory
            ), !isDirectory.boolValue else { continue }
            return URL(fileURLWithPath: standardized)
        }
        return nil
    }
}
