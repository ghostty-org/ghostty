import Foundation

/// Read/write `.md` task files in a resolved tasks directory.
public struct TaskStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    // MARK: - Read

    /// Load all tasks in the directory. Silently skips files that don't parse;
    /// a malformed fixture should never take down `gt list`.
    public func loadAll() -> [Task] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory,
                                                       includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles]) else {
            return []
        }
        var tasks: [Task] = []
        for url in entries where url.pathExtension.lowercased() == "md" {
            if let task = loadFile(at: url) {
                tasks.append(task)
            }
        }
        return tasks
    }

    /// Load a single file by URL. Returns nil if missing or unparseable.
    public func loadFile(at url: URL) -> Task? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        guard let (pairs, body) = Frontmatter.split(raw) else { return nil }

        guard let title = Frontmatter.value(for: "title", in: pairs),
              let statusRaw = Frontmatter.value(for: "status", in: pairs),
              let lane = TaskLane.parse(statusRaw) else {
            return nil
        }

        let id = Frontmatter.value(for: "source-id", in: pairs)
            ?? url.deletingPathExtension().lastPathComponent

        // Parse priority with strict-with-skip: unknown value → .none, never crash.
        let priority: TaskPriority = {
            guard let raw = Frontmatter.value(for: "priority", in: pairs),
                  !raw.isEmpty else { return .none }
            return TaskPriority(rawValue: raw) ?? .none
        }()

        return Task(
            id: id,
            title: title,
            lane: lane,
            priority: priority,
            project: Frontmatter.value(for: "project", in: pairs),
            source: Frontmatter.value(for: "source", in: pairs),
            sourceID: Frontmatter.value(for: "source-id", in: pairs),
            branch: Frontmatter.value(for: "branch", in: pairs),
            frontmatter: pairs,
            body: body,
            projectPath: Frontmatter.value(for: "project-path", in: pairs),
            template: Frontmatter.value(for: "template", in: pairs)
        )
    }

    /// Resolve a task by full id or unambiguous prefix. Matches file stems
    /// first (the authoritative filename), falling back to `source-id` or the
    /// `id` we return from `loadFile`.
    public func resolve(idOrPrefix needle: String) throws -> (task: Task, url: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory,
                                                       includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles]) else {
            throw CLIError.io("could not read \(directory.path)")
        }

        let lowerNeedle = needle.lowercased()
        var exact: [(URL, Task)] = []
        var prefix: [(URL, Task)] = []

        for url in entries where url.pathExtension.lowercased() == "md" {
            guard let task = loadFile(at: url) else { continue }
            let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            let tid = task.id.lowercased()
            if stem == lowerNeedle || tid == lowerNeedle {
                exact.append((url, task))
            } else if stem.hasPrefix(lowerNeedle) || tid.hasPrefix(lowerNeedle) {
                prefix.append((url, task))
            }
        }

        if let only = exact.first, exact.count == 1 {
            return (only.1, only.0)
        }
        if exact.count > 1 {
            throw CLIError.ambiguousID(prefix: needle, matches: exact.map { $0.1.id })
        }
        if prefix.count == 1 {
            return (prefix[0].1, prefix[0].0)
        }
        if prefix.count > 1 {
            throw CLIError.ambiguousID(prefix: needle, matches: prefix.map { $0.1.id })
        }
        throw CLIError.notFound("no task matches \"\(needle)\"")
    }

    // MARK: - Write

    /// Overwrite a task's file with the given frontmatter pairs + body.
    public func write(pairs: [(String, String)], body: String, to url: URL) throws {
        let out = Frontmatter.assemble(pairs: pairs, body: body)
        do {
            try out.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw CLIError.io("could not write \(url.path): \(error.localizedDescription)")
        }
    }

    /// Write a brand-new file. Errors if a file with the same id already exists.
    public func create(id: String, pairs: [(String, String)], body: String) throws -> URL {
        let url = directory.appendingPathComponent("\(id).md")
        if FileManager.default.fileExists(atPath: url.path) {
            throw CLIError.io("file already exists: \(url.path)")
        }
        try write(pairs: pairs, body: body, to: url)
        return url
    }
}
