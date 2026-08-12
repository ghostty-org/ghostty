import Foundation

/// Matching a Claude Code plan to the terminals it belongs to.
///
/// A plan file in `~/.claude/plans` is plain markdown: no front matter, no
/// working directory, no session id. Nothing in it says where it came from.
/// The link exists sideways — a session transcript lives at
/// `~/.claude/projects/<encoded-cwd>/<session>.jsonl` and mentions the plan's
/// path, and the *directory name* encodes the project's working directory.
///
/// **The encoding is lossy.** `-Users-isac-petinate-Projects` could be
/// `/Users/isac.petinate/Projects` or `/Users/isac/petinate/Projects`,
/// because the dot became a dash like the slashes did. So nothing here ever
/// decodes a directory name. It encodes the terminal's own path and compares,
/// which is exact — and works because the encoding replaces one character
/// with one character, so it preserves prefixes: if a directory is inside a
/// project, its encoded form starts with the project's encoded form.
enum ClaudePlanIndex {
    /// Where Claude Code keeps plans and session transcripts.
    static var plansDirectory: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude/plans")
    }

    static var projectsDirectory: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
    }

    /// The directory-name form of a filesystem path.
    ///
    /// Both the separator and the dot become a dash, which is what makes the
    /// mapping one-way. Deliberately not inverted anywhere.
    static func encode(_ path: String) -> String {
        String(path.map { character in
            character == "/" || character == "." ? "-" : character
        })
    }

    /// Whether `terminalPath` is inside the project a transcript directory
    /// names.
    ///
    /// Prefix on the *encoded* form, with the separator required, so
    /// `/Projects/Tools` doesn't match a project called `/Projects/ToolsX`.
    static func project(_ encodedProject: String, contains terminalPath: String) -> Bool {
        guard !terminalPath.isEmpty else { return false }
        let encoded = encode(terminalPath)
        if encoded == encodedProject { return true }
        return encoded.hasPrefix(encodedProject + "-")
    }

    /// One plan on disk.
    struct Plan: Equatable, Identifiable {
        let path: String
        let modified: Date

        var id: String { path }

        /// The plan's own title, read from its first heading, falling back to
        /// the file's name — the names are random slugs, so the heading is
        /// the only part a reader recognises.
        var title: String {
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
                return (path as NSString).deletingPathExtension
            }
            for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
                guard line.hasPrefix("# ") else { continue }
                return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        }
    }

    /// The plans on disk, newest first.
    static func plans() -> [Plan] {
        let directory = plansDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory)
        else { return [] }

        return names
            .filter { $0.hasSuffix(".md") }
            .compactMap { name -> Plan? in
                let path = (directory as NSString).appendingPathComponent(name)
                let attributes = try? FileManager.default.attributesOfItem(atPath: path)
                let modified = attributes?[.modificationDate] as? Date ?? .distantPast
                return Plan(path: path, modified: modified)
            }
            .sorted { $0.modified > $1.modified }
    }

    /// The encoded project a plan belongs to, by finding the transcript that
    /// mentions it.
    ///
    /// Bounded on purpose. Transcripts reach tens of megabytes, so only the
    /// **tail** of each is read, and only transcripts touched around the same
    /// time as the plan are considered — a plan is written *during* a session,
    /// so anything much older cannot be the one.
    static func encodedProject(for plan: Plan) -> String? {
        let needle = ((plan.path as NSString).lastPathComponent as NSString)
            .deletingPathExtension
        guard !needle.isEmpty else { return nil }

        let projects = projectsDirectory
        guard let directories = try? FileManager.default.contentsOfDirectory(atPath: projects)
        else { return nil }

        for directory in directories {
            let full = (projects as NSString).appendingPathComponent(directory)
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: full)
            else { continue }

            for file in files where file.hasSuffix(".jsonl") {
                let transcript = (full as NSString).appendingPathComponent(file)
                let attributes = try? FileManager.default.attributesOfItem(atPath: transcript)
                let touched = attributes?[.modificationDate] as? Date ?? .distantPast
                // A transcript that stopped being written before the plan
                // existed cannot be the session that wrote it.
                guard touched >= plan.modified.addingTimeInterval(-3600) else { continue }

                if tail(of: transcript, contains: needle) { return directory }
            }
        }
        return nil
    }

    /// How much of a transcript to read. Generous enough to hold a long
    /// session's recent turns, small enough to be free.
    private static let tailBytes = 4 * 1024 * 1024

    /// Whether the last few megabytes of a file contain `needle`.
    static func tail(of path: String, contains needle: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd() else { return false }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)

        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        else { return false }

        return text.contains(needle)
    }
}
