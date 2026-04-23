import Foundation

/// Flat YAML-ish frontmatter parser + serializer. Same shape as the macOS
/// app's `TaskFixtureParser` but round-trippable so we can read, tweak a few
/// keys, and write without losing the body or reordering unrelated keys.
///
/// Format assumptions (match fixtures in `.ghostties/tasks/`):
///   - File starts with `---\n`
///   - Frontmatter is a block of `key: value` lines, one per line
///   - Values may be quoted with `'` or `"`; quotes are stripped on read
///   - No nested maps, no arrays, no comments
///   - Closing `---\n` ends frontmatter; body follows
enum Frontmatter {
    /// Split raw file contents into (orderedPairs, body). Returns nil if the
    /// file does not start with a frontmatter block.
    static func split(_ raw: String) -> (pairs: [(String, String)], body: String)? {
        var lines = raw.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        lines.removeFirst()

        var fmLines: [String] = []
        var bodyLines: [String] = []
        var inBody = false
        for line in lines {
            if !inBody, line.trimmingCharacters(in: .whitespaces) == "---" {
                inBody = true
                continue
            }
            if inBody {
                bodyLines.append(line)
            } else {
                fmLines.append(line)
            }
        }
        guard inBody else { return nil }

        var pairs: [(String, String)] = []
        for line in fmLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            pairs.append((key, value))
        }

        return (pairs, bodyLines.joined(separator: "\n"))
    }

    /// Serialize ordered pairs + body back into a full file string.
    static func assemble(pairs: [(String, String)], body: String) -> String {
        var out = "---\n"
        for (k, v) in pairs {
            out += "\(k): \(v)\n"
        }
        out += "---\n"
        // Body in the fixtures starts with a blank line after the closing fence.
        // Preserve whatever body we were given — if it already leads with a
        // newline, don't double it.
        if body.hasPrefix("\n") {
            out += body
        } else {
            out += "\n" + body
        }
        return out
    }

    /// Look up a value by key in an ordered pair list.
    static func value(for key: String, in pairs: [(String, String)]) -> String? {
        pairs.first(where: { $0.0 == key })?.1
    }

    /// Return a new pair list with `key` set to `value`. Overwrites in place
    /// if the key exists; otherwise appends.
    static func set(_ key: String, _ value: String, in pairs: [(String, String)]) -> [(String, String)] {
        var copy = pairs
        if let idx = copy.firstIndex(where: { $0.0 == key }) {
            copy[idx] = (key, value)
        } else {
            copy.append((key, value))
        }
        return copy
    }
}
