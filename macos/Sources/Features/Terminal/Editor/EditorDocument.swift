import AppKit
import Combine
import Foundation

/// One open file: its text, whether it has been changed, and what has
/// happened to it on disk.
///
/// The disk half matters more here than in an ordinary editor. The terminal
/// this pane belongs to is *right there*, and a branch switch or a `git
/// stash` rewrites the very file being looked at. Noticing that is the
/// difference between saving your work and saving over somebody else's.
@MainActor
final class EditorDocument: ObservableObject, Identifiable {
    let url: URL

    @Published var text: String
    @Published private(set) var isDirty = false

    /// The file changed underneath an edited buffer, so neither version can
    /// be thrown away without asking.
    @Published private(set) var hasConflict = false

    @Published private(set) var loadError: String?

    /// Where to put the cursor when this document next appears, set by a
    /// jump to a definition or a click on a search result. Carries an id so
    /// asking for the same place twice still moves the view.
    @Published var reveal: (id: String, range: LSPRange)?

    var id: String { url.path }

    var language: CodeLanguage {
        CodeLanguage.resolve(fileName: url.lastPathComponent)
    }

    /// What was last read from or written to disk. Compared against the
    /// file to tell "somebody else changed this" from "I changed this",
    /// which a modification date alone can't do — saving moves the date too.
    private var diskText: String

    private var watcher: DirectoryWatcher?

    init(url: URL, text: String) {
        self.url = url
        self.text = text
        self.diskText = text
    }

    /// Reads the file, refusing anything the editor can't usefully show.
    static func load(url: URL) -> Result<EditorDocument, FileOpenGuard.Verdict> {
        let verdict = FileOpenGuard.verdict(for: url)
        guard verdict.canOpen else { return .failure(verdict) }

        guard let data = try? Data(contentsOf: url) else { return .failure(.binary) }

        // Latin-1 as the fallback rather than a refusal: it maps every byte
        // to some character, so a file in an encoding nobody can identify
        // still opens and stays editable instead of being called binary.
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""

        return .success(EditorDocument(url: url, text: text))
    }

    func markEdited() {
        let changed = text != diskText
        if isDirty != changed { isDirty = changed }
    }

    @discardableResult
    func save() -> Bool {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            diskText = text
            isDirty = false
            hasConflict = false
            loadError = nil
            return true
        } catch {
            loadError = error.localizedDescription
            return false
        }
    }

    /// Takes the version on disk, dropping local edits.
    func revert() {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        else { return }

        self.text = text
        self.diskText = text
        isDirty = false
        hasConflict = false
    }

    /// Watches for changes made outside the app.
    ///
    /// A clean buffer reloads silently — that is the behavior that makes
    /// the editor usable next to a terminal, since `git checkout` updating
    /// what you are reading should just work. A dirty buffer raises a
    /// conflict instead, because the only other options are losing your
    /// edits or hiding theirs.
    func startWatching() {
        guard watcher == nil else { return }

        // The containing directory, not the file: an atomic save — which is
        // what most editors and every `git` operation do — replaces the
        // inode, and a descriptor held on the old one stops hearing about
        // anything. Watching the directory survives that.
        let watcher = DirectoryWatcher()
        watcher.onChange = { [weak self] _ in
            Task { @MainActor in self?.diskDidChange() }
        }
        watcher.watch([url.deletingLastPathComponent().path])
        self.watcher = watcher
    }

    func stopWatching() {
        watcher = nil
    }

    private func diskDidChange() {
        guard let data = try? Data(contentsOf: url),
              let onDisk = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        else { return }

        guard onDisk != diskText else { return }

        if isDirty {
            hasConflict = true
        } else {
            text = onDisk
            diskText = onDisk
        }
    }
}
