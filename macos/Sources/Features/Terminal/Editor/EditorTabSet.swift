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

/// What the pane is showing.
///
/// The terminal is one of the choices rather than the absence of a choice.
/// It used to be the latter — the pane showed the editor whenever any file
/// was open — and that made the ordinary thing impossible: glance at the
/// terminal and come back. There was no way to express "a file is open and
/// I am looking at the shell".
enum EditorSelection: Equatable {
    case terminal
    case file(String)

    var path: String? {
        guard case .file(let path) = self else { return nil }
        return path
    }
}

/// The open files, in tab order, and what the pane is showing.
///
/// A value type with no view or file access in it, because every rule worth
/// getting right lives here: what happens to the selection when you close
/// the tab you were looking at, whether reopening a file duplicates it, and
/// what the pane falls back to when the last file closes.
struct EditorTabSet: Equatable {
    private(set) var tabs: [EditorTab] = []

    /// Starts on the terminal, which is what an empty pane means.
    private(set) var selection: EditorSelection = .terminal

    var isEmpty: Bool { tabs.isEmpty }

    /// Whether the pane is showing the terminal rather than a file.
    var showsTerminal: Bool { selection == .terminal }

    /// The bar appears only once there is something to switch *to*.
    ///
    /// With the terminal alone there is one surface and no choice to make,
    /// so the bar would be a control that does nothing — and it would cost
    /// the terminal a row of its own height to say so.
    var showsTabBar: Bool { !tabs.isEmpty }

    var selectedPath: String? { selection.path }

    var selected: EditorTab? {
        selectedPath.flatMap { id in tabs.first { $0.id == id } }
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
        selection = .file(path)
    }

    /// Closes a tab and picks what to show next.
    ///
    /// The neighbour to the *left*, or the new last tab when the first one
    /// closes — which is what every editor does, and what keeps closing
    /// several in a row from jumping around the bar. With nothing left, the
    /// terminal: it is the pane's home, not a fallback.
    mutating func close(_ path: String) {
        guard let index = tabs.firstIndex(where: { $0.path == path }) else { return }
        tabs.remove(at: index)

        guard selectedPath == path else { return }
        guard !tabs.isEmpty else {
            selection = .terminal
            return
        }
        selection = .file(tabs[max(0, index - 1)].id)
    }

    mutating func closeAll() {
        tabs.removeAll()
        selection = .terminal
    }

    mutating func select(_ path: String) {
        guard tabs.contains(where: { $0.path == path }) else { return }
        selection = .file(path)
    }

    mutating func selectTerminal() {
        selection = .terminal
    }

    /// Alternates between the terminal and the file you were last on.
    ///
    /// The whole point of the feature: peek at the shell and come back
    /// without losing your place. With no file open there is nothing to
    /// alternate with, so it stays put rather than doing something arbitrary.
    mutating func toggleTerminal(lastFile: String?) {
        if showsTerminal {
            guard let target = lastFile ?? tabs.last?.id else { return }
            select(target)
        } else {
            selection = .terminal
        }
    }

    /// Selects the nth file tab, one-based, ignoring a number with no tab.
    mutating func selectFile(at number: Int) {
        guard number >= 1, number <= tabs.count else { return }
        selection = .file(tabs[number - 1].id)
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
