import Foundation

/// One file open in the editor.
struct EditorTab: Identifiable, Equatable {
    /// The file's path, which is also its identity: opening a file that is
    /// already open selects the existing tab instead of making a second one.
    let path: String

    /// Unsaved edits.
    var isDirty: Bool = false

    var id: String { path }

    var name: String { (path as NSString).lastPathComponent }

    /// The containing directory, shown only to tell apart two tabs that
    /// share a name — `index.ts` twice is the ordinary case, not the edge.
    var directory: String { (path as NSString).deletingLastPathComponent }
}

/// The open files, in tab order, and which one is showing.
///
/// A value type with no view or file access in it, because every rule worth
/// getting right lives here: what happens to the selection when you close
/// the tab you were looking at, whether reopening a file duplicates it, and
/// — the one the whole feature hangs on — that emptying the set is what
/// gives the terminal its pane back.
struct EditorTabSet: Equatable {
    private(set) var tabs: [EditorTab] = []
    private(set) var selection: String?

    var isEmpty: Bool { tabs.isEmpty }

    var selected: EditorTab? {
        selection.flatMap { id in tabs.first { $0.id == id } }
    }

    var hasUnsavedChanges: Bool { tabs.contains(where: \.isDirty) }

    /// Opens a file, or selects it if it is already open.
    ///
    /// Reopening must not duplicate: the file explorer's whole interaction
    /// is clicking names, and clicking one twice is something people do
    /// without thinking.
    mutating func open(_ path: String) {
        if !tabs.contains(where: { $0.path == path }) {
            tabs.append(EditorTab(path: path))
        }
        selection = path
    }

    /// Closes a tab and picks what to show next.
    ///
    /// The neighbour to the *left*, or the new last tab when the first one
    /// closes — which is what every editor does, and what keeps closing
    /// several in a row from jumping around the bar.
    mutating func close(_ path: String) {
        guard let index = tabs.firstIndex(where: { $0.path == path }) else { return }
        tabs.remove(at: index)

        guard selection == path else { return }
        guard !tabs.isEmpty else {
            selection = nil
            return
        }
        selection = tabs[max(0, index - 1)].id
    }

    mutating func closeAll() {
        tabs.removeAll()
        selection = nil
    }

    mutating func select(_ path: String) {
        guard tabs.contains(where: { $0.path == path }) else { return }
        selection = path
    }

    mutating func setDirty(_ isDirty: Bool, for path: String) {
        guard let index = tabs.firstIndex(where: { $0.path == path }) else { return }
        tabs[index].isDirty = isDirty
    }

    /// A file deleted or renamed outside the app stops being a tab.
    mutating func remove(missing paths: [String]) {
        paths.forEach { close($0) }
    }

    /// Whether two open tabs share a name, which is when the directory has
    /// to be shown to tell them apart.
    func needsDirectory(for tab: EditorTab) -> Bool {
        tabs.contains { $0.id != tab.id && $0.name == tab.name }
    }
}
