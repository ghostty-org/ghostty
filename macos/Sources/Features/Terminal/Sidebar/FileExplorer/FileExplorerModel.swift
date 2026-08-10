import Combine
import Foundation

/// One entry in the file tree.
struct FileNode: Identifiable, Equatable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool

    var id: String { url.path }
    var path: String { url.path }
}

/// A node flattened into the visible list, carrying how deep to indent it.
struct FileRow: Identifiable, Equatable {
    let node: FileNode
    let depth: Int

    /// True when this stands in for entries hidden by `childLimit` rather
    /// than being a real file.
    var isTruncationNotice: Bool = false

    var id: String { isTruncationNotice ? "\(node.path)#more" : node.path }
}

/// The file explorer's tree: which folder is the root, what's expanded, and
/// the children loaded so far.
///
/// One per window. Directory listings run off the main thread with the same
/// `Task.detached` + `MainActor.run` shape the sidebar's other background
/// work uses (`GitStatusCenter`, `DevServerCenter`), because a listing of a
/// cold or network directory can block for a noticeable moment and this
/// runs while the user is typing in the terminal next to it.
@MainActor
final class FileExplorerModel: ObservableObject {
    @Published private(set) var root: URL?
    @Published private(set) var rows: [FileRow] = []
    @Published private(set) var expanded: Set<String> = []
    @Published private(set) var loading: Set<String> = []

    /// The path to scroll to and highlight — the terminal's current folder,
    /// updated as the user `cd`s around.
    @Published private(set) var currentDirectory: String?

    /// What the search field holds.
    ///
    /// While it has text the tree shows *matches* instead of the hierarchy:
    /// a flat list is the right answer to "where is this file", because the
    /// folders in between are exactly what you didn't know.
    @Published var filter: String = "" {
        didSet {
            guard filter != oldValue else { return }
            scheduleFilter()
        }
    }

    /// The matches for `filter`, or nil while it is empty.
    @Published private(set) var matches: [FileRow]?

    @Published private(set) var isSearching = false

    private var filterTask: Task<Void, Never>?

    /// Long enough that typing a word is one search, short enough to feel
    /// immediate. The reader never presses anything to start it.
    private static let filterDebounce = Duration.milliseconds(180)

    /// A search walks the tree on disk, so it is bounded: enough results to
    /// find what you meant, few enough that the list stays a list.
    private static let matchLimit = 300

    @Published var showHiddenFiles: Bool = UserDefaults.standard.bool(forKey: showHiddenKey) {
        didSet {
            guard showHiddenFiles != oldValue else { return }
            UserDefaults.standard.set(showHiddenFiles, forKey: Self.showHiddenKey)
            children.removeAll()
            reloadVisible()
        }
    }

    @Published var rootMode: WorkspaceRootMode = .stored {
        didSet {
            guard rootMode != oldValue else { return }
            UserDefaults.standard.set(rootMode.rawValue, forKey: WorkspaceRootMode.defaultsKey)
            onRootModeChanged?()
        }
    }

    /// Re-resolves the root after the mode changes. Set by the view, which
    /// is what knows about the selected tab.
    var onRootModeChanged: (() -> Void)?

    static let showHiddenKey = "FileExplorerShowHiddenFiles"

    /// Directory path → its children. Absent means "not loaded yet".
    private var children: [String: [FileNode]] = [:]

    /// A directory with more entries than this renders a "N more" row
    /// instead of all of them. `node_modules` and friends are otherwise a
    /// reliable way to hang the sidebar on a directory nobody meant to open.
    private static let childLimit = 500

    private let watcher = DirectoryWatcher()
    private var store = FileExplorerStateStore.shared

    init() {
        watcher.onChange = { [weak self] changed in
            guard let self else { return }
            for path in changed where self.children[path] != nil {
                self.load(path)
            }
        }
    }

    // MARK: Root

    func setRoot(_ path: String?) {
        let url = path.map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard url?.path != root?.path else { return }

        root = url
        children.removeAll()
        loading.removeAll()
        expanded = url.map { store.expanded(forRoot: $0.path) } ?? []

        guard let url else {
            rows = []
            watcher.watch([])
            return
        }

        load(url.path)
        for path in expanded { load(path) }
        rebuildRows()
    }

    /// Points the highlight at the terminal's folder and opens every
    /// ancestor so it's actually on screen.
    ///
    /// The root deliberately doesn't move — `cd`-ing into a subdirectory
    /// shouldn't re-root the tree and lose the rest of the project.
    func reveal(_ path: String?) {
        currentDirectory = path

        guard let path, let root, path.hasPrefix(root.path) else { return }

        var toOpen: [String] = []
        var cursor = URL(fileURLWithPath: path, isDirectory: true)
        while cursor.path.count > root.path.count {
            toOpen.append(cursor.path)
            cursor = cursor.deletingLastPathComponent()
        }

        var changed = false
        for dir in toOpen where !expanded.contains(dir) {
            expanded.insert(dir)
            changed = true
        }

        guard changed else { return }
        persistExpansion()
        for dir in toOpen where children[dir] == nil { load(dir) }
        rebuildRows()
    }

    // MARK: Expansion

    func toggle(_ node: FileNode) {
        guard node.isDirectory else { return }

        if expanded.contains(node.path) {
            expanded.remove(node.path)
        } else {
            expanded.insert(node.path)
            if children[node.path] == nil { load(node.path) }
        }

        persistExpansion()
        rebuildRows()
    }

    func isExpanded(_ node: FileNode) -> Bool {
        expanded.contains(node.path)
    }

    /// Reloads every directory currently on screen — the refresh button,
    /// and how a hidden-files toggle takes effect.
    func reloadVisible() {
        guard let root else { return }
        load(root.path)
        for path in expanded { load(path) }
    }

    // MARK: Loading

    private func load(_ path: String) {
        guard !loading.contains(path) else { return }
        loading.insert(path)

        let url = URL(fileURLWithPath: path, isDirectory: true)
        let includeHidden = showHiddenFiles

        Task.detached(priority: .utility) {
            let scanned = Self.scan(directory: url, showHidden: includeHidden)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.loading.remove(path)
                self.children[path] = scanned
                self.rebuildRows()
                self.syncWatches()
            }
        }
    }

    /// Lists a directory. `nonisolated` and pure so it can run off the main
    /// actor; returns an empty list for anything unreadable rather than
    /// surfacing an error, since a permission-denied folder is a normal
    /// thing to scroll past.
    nonisolated static func scan(directory: URL, showHidden: Bool) -> [FileNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]

        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: options
        )) ?? []

        let nodes = entries.map { url -> FileNode in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            return FileNode(
                url: url,
                name: url.lastPathComponent,
                isDirectory: values?.isDirectory ?? false
            )
        }

        return sorted(nodes)
    }

    /// Directories first, then case-insensitive by name — the ordering
    /// every file explorer uses, and the one that makes a project's shape
    /// readable at a glance.
    nonisolated static func sorted(_ nodes: [FileNode]) -> [FileNode] {
        nodes.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.name < rhs.name
        }
    }

    // MARK: Rows

    private func scheduleFilter() {
        filterTask?.cancel()

        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            matches = nil
            isSearching = false
            return
        }
        guard let root else { return }

        isSearching = true
        filterTask = Task { [weak self] in
            try? await Task.sleep(for: Self.filterDebounce)
            guard !Task.isCancelled else { return }

            let showHidden = self?.showHiddenFiles ?? false
            let found = await Task.detached(priority: .userInitiated) {
                Self.search(query: query, under: root, showHidden: showHidden)
            }.value

            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.matches = found
                self?.isSearching = false
            }
        }
    }

    /// Finds files whose name contains `query`, breadth-first.
    ///
    /// Breadth-first on purpose: the file you are looking for is far more
    /// often near the top of a project than buried twenty levels down, and
    /// with a result cap that ordering decides *which* results you get.
    /// `.git`, `node_modules` and the other build directories are skipped —
    /// searching them finds thousands of matches nobody meant.
    nonisolated static func search(
        query: String,
        under root: URL,
        showHidden: Bool
    ) -> [FileRow] {
        let needle = query.lowercased()
        var results: [FileRow] = []
        var queue = [root.path]

        while !queue.isEmpty, results.count < matchLimit {
            let directory = queue.removeFirst()
            let children = scan(
                directory: URL(fileURLWithPath: directory),
                showHidden: showHidden
            )

            for child in children where results.count < matchLimit {
                if child.name.lowercased().contains(needle) {
                    // Depth zero: matches are a flat list, not a tree, so
                    // nothing is indented against a parent that isn't shown.
                    results.append(FileRow(node: child, depth: 0))
                }
                guard child.isDirectory, !skippedDirectories.contains(child.name) else { continue }
                queue.append(child.path)
            }
        }
        return results
    }

    /// Directories a filename search has no business walking into.
    nonisolated static let skippedDirectories: Set<String> = [
        ".git", "node_modules", ".build", "zig-out", ".zig-cache",
        "DerivedData", ".next", "dist", "build", "Pods", ".venv",
        "__pycache__", ".gradle", "target",
    ]

    private func rebuildRows() {
        guard let root else {
            rows = []
            return
        }
        var result: [FileRow] = []
        append(directory: root.path, depth: 0, into: &result)
        rows = result
    }

    private func append(directory: String, depth: Int, into result: inout [FileRow]) {
        guard let nodes = children[directory] else { return }

        for node in nodes.prefix(Self.childLimit) {
            result.append(FileRow(node: node, depth: depth))
            guard node.isDirectory, expanded.contains(node.path) else { continue }
            append(directory: node.path, depth: depth + 1, into: &result)
        }

        let hidden = nodes.count - Self.childLimit
        guard hidden > 0 else { return }
        result.append(FileRow(
            node: FileNode(
                url: URL(fileURLWithPath: directory, isDirectory: true),
                name: "\(hidden) more…",
                isDirectory: false
            ),
            depth: depth,
            isTruncationNotice: true
        ))
    }

    // MARK: Watching and persistence

    private func syncWatches() {
        guard let root else {
            watcher.watch([])
            return
        }
        var paths: Set<String> = [root.path]
        for path in expanded where children[path] != nil { paths.insert(path) }
        watcher.watch(paths)
    }

    private func persistExpansion() {
        guard let root else { return }
        store.setExpanded(expanded, forRoot: root.path)
        syncWatches()
    }
}
