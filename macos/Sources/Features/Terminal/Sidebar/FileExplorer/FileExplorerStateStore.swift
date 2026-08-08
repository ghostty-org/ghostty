import Foundation

/// Remembers which folders were open, per workspace root.
///
/// Coming back to a project and finding the tree collapsed to nothing is a
/// small thing that gets annoying fast. Same JSON-in-Application-Support
/// shape as `SidebarGroupStore`, including the debounced write — expanding
/// a folder shouldn't hit the disk on every click.
@MainActor
final class FileExplorerStateStore {
    static let shared = FileExplorerStateStore()

    /// Roots are pruned to this many, most-recently-used first, so a store
    /// that's been through hundreds of projects doesn't grow forever.
    private static let maxRoots = 40

    /// A single root can only remember this many open folders. Expanding a
    /// deep tree in a monorepo is otherwise unbounded.
    private static let maxExpandedPerRoot = 500

    private struct State: Codable {
        /// Root path → open folder paths.
        var expanded: [String: [String]] = [:]

        /// Root paths, most recently used last — the prune order.
        var recency: [String] = []
    }

    private var state = State()
    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        load()
    }

    private static func defaultFileURL() -> URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("com.ipetinate.phantom", isDirectory: true)
        return dir.appendingPathComponent("file-explorer.json")
    }

    func expanded(forRoot root: String) -> Set<String> {
        Set(state.expanded[root] ?? [])
    }

    func setExpanded(_ paths: Set<String>, forRoot root: String) {
        if paths.isEmpty {
            state.expanded.removeValue(forKey: root)
            state.recency.removeAll { $0 == root }
        } else {
            state.expanded[root] = Array(paths.prefix(Self.maxExpandedPerRoot))
            state.recency.removeAll { $0 == root }
            state.recency.append(root)
            prune()
        }
        scheduleSave()
    }

    private func prune() {
        guard state.recency.count > Self.maxRoots else { return }
        let drop = state.recency.prefix(state.recency.count - Self.maxRoots)
        for root in drop { state.expanded.removeValue(forKey: root) }
        state.recency.removeFirst(drop.count)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(State.self, from: data)
        else { return }
        state = decoded
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
