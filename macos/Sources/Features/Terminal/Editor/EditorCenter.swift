import AppKit
import Combine
import SwiftUI

/// The open files for one window.
///
/// Per window, not app-wide: the editor takes over *that* terminal's pane,
/// so what is open belongs to it. Two windows on the same project keep
/// their own tabs, which is what makes "close everything and get my
/// terminal back" mean something local.
@MainActor
final class EditorCenter: ObservableObject {
    @Published private(set) var tabs = EditorTabSet()

    /// Documents by path. Kept alongside the tab set rather than inside it
    /// because the tab set stays a value type — every rule about ordering
    /// and selection is testable without a file existing.
    @Published private(set) var documents: [String: EditorDocument] = [:]

    /// What the terminal's own tab is labelled with.
    ///
    /// Kept here rather than read from the window at render time because the
    /// bar is SwiftUI and the title is AppKit state that changes whenever the
    /// shell says so — this is the seam where the two meet.
    @Published var terminalTitle: String = "Terminal"

    /// Raised when a file can't be opened, for the host to explain and
    /// offer the external editor instead.
    @Published var openFailure: OpenFailure?

    struct OpenFailure: Identifiable {
        let id = UUID()
        let url: URL
        let verdict: FileOpenGuard.Verdict
    }

    /// Whether the editor owns the pane right now.
    ///
    /// Derived from the *selection*, not from the tab count. Deriving it
    /// from the count is what made the terminal unreachable while a file was
    /// open — there was no way to say "a file is open and I am looking at
    /// the shell".
    var showsEditor: Bool { !tabs.showsTerminal }

    var selectedDocument: EditorDocument? {
        tabs.selectedPath.flatMap { documents[$0] }
    }

    /// The file to come back to when alternating away from the terminal.
    private var lastSelectedFile: String?

    private var documentObservers: [String: AnyCancellable] = [:]

    // MARK: Opening and closing

    /// Opens a file, optionally landing on a particular range.
    ///
    /// The range travels with the document rather than being applied here:
    /// a file opened for the first time has no text view yet, so the jump
    /// has to be something the view picks up when it appears.
    @discardableResult
    func open(_ url: URL, reveal: LSPRange? = nil) -> Bool {
        let path = url.path

        if let existing = documents[path] {
            if let reveal { existing.reveal = (id: UUID().uuidString, range: reveal) }
            tabs.select(path)
            lastSelectedFile = path
            return true
        }

        switch EditorDocument.load(url: url) {
        case .failure(let verdict):
            openFailure = OpenFailure(url: url, verdict: verdict)
            return false

        case .success(let document):
            documents[path] = document
            document.startWatching()
            // The tab's dirty dot follows the document, and the document is
            // its own observable object — a change inside it doesn't reach
            // this one on its own.
            documentObservers[path] = document.objectWillChange
                .sink { [weak self, weak document] (_: Void) in
                    // `objectWillChange` fires *before* the value is
                    // written, so reading `isDirty` here would see the old
                    // one. The hop is what makes the dot correct.
                    DispatchQueue.main.async {
                        guard let self, let document else { return }
                        self.tabs.setDirty(document.isDirty, for: path)
                    }
                }
            if let reveal { document.reveal = (id: UUID().uuidString, range: reveal) }
            tabs.open(path)
            lastSelectedFile = path
            return true
        }
    }

    func close(_ path: String) {
        documents[path]?.stopWatching()
        documents.removeValue(forKey: path)
        documentObservers.removeValue(forKey: path)
        tabs.close(path)
    }

    func closeSelected() {
        guard let path = tabs.selectedPath else { return }
        close(path)
    }

    /// Shows the terminal without closing anything.
    func selectTerminal() {
        tabs.selectTerminal()
    }

    /// Alternates terminal ⇄ the file last looked at.
    func toggleTerminal() {
        tabs.toggleTerminal(lastFile: lastSelectedFile)
    }

    func selectFile(at number: Int) {
        tabs.selectFile(at: number)
    }

    func closeAll() {
        documents.values.forEach { $0.stopWatching() }
        documents.removeAll()
        documentObservers.removeAll()
        tabs.closeAll()
    }

    func select(_ path: String) {
        tabs.select(path)
        lastSelectedFile = path
    }

    // MARK: Saving

    @discardableResult
    func saveSelected() -> Bool {
        guard let document = selectedDocument else { return false }
        let saved = document.save()
        if saved {
            tabs.setDirty(false, for: document.id)
            LSPCenter.shared.didSave(path: document.url.path, text: document.currentText)
        }
        return saved
    }

    func saveAll() {
        for document in documents.values where document.isDirty {
            guard document.save() else { continue }
            tabs.setDirty(false, for: document.id)
            LSPCenter.shared.didSave(path: document.url.path, text: document.currentText)
        }
    }
}
