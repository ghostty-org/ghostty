import Foundation

/// The language servers this window is talking to, and what they said.
///
/// One server per (language, workspace root) rather than per file: a server
/// builds a project-wide index, and starting a second one for the next file
/// in the same project pays for that index twice and answers half the
/// questions — cross-file references need the whole workspace in one
/// process.
@MainActor
final class LSPCenter: ObservableObject {
    static let shared = LSPCenter()

    /// Problems per file path, which is what the editor draws.
    @Published private(set) var diagnostics: [String: [LSPDiagnostic]] = [:]

    /// Servers named in the registry that aren't installed, so the UI can
    /// say which one is missing and how to get it instead of appearing to
    /// do nothing.
    @Published private(set) var missing: [LSPServerDefinition] = []

    private struct Key: Hashable {
        let languageID: String
        let root: String
    }

    private var servers: [Key: LSPProcess] = [:]
    private var starting: Set<Key> = []

    /// Version per open document. The protocol requires it to increase on
    /// every change, and a server that sees it go backwards may discard the
    /// edit or desynchronise outright.
    private var versions: [String: Int] = [:]

    private var openDocuments: Set<String> = []

    /// Pending `didChange` per document.
    ///
    /// Full-document sync is deliberate — see `didChange` — but sending it
    /// on literally every keystroke means shipping the whole file down a
    /// pipe per character. Coalescing a burst of typing into one update
    /// keeps the safety and drops the cost by an order of magnitude.
    private var changeTasks: [String: Task<Void, Never>] = [:]

    /// The text each pending change would send. Held separately so a flush
    /// can *send* the waiting edit rather than cancel it — dropping it
    /// would desynchronise the server's copy permanently, which is the one
    /// failure full-document sync exists to rule out.
    private var pendingChanges: [String: String] = [:]

    private static let changeDebounce = Duration.milliseconds(180)

    private init() {}

    // MARK: Documents

    func didOpen(path: String, text: String) {
        guard let definition = LSPServerRegistry.server(forPath: path) else { return }
        let root = Self.workspaceRoot(for: path)
        let key = Key(languageID: definition.languageID, root: root)

        versions[path] = 1
        openDocuments.insert(path)

        Task { [weak self] in
            guard let server = await self?.server(for: key, definition: definition) else { return }
            try? server.notify("textDocument/didOpen", params: [
                "textDocument": [
                    "uri": .string(Self.uri(path)),
                    "languageId": .string(definition.languageID),
                    "version": .integer(1),
                    "text": .string(text),
                ],
            ])
        }
    }

    /// Sends the whole document rather than a delta.
    ///
    /// Incremental sync is faster on paper and is where desynchronisation
    /// bugs come from: one wrong range and the server's copy diverges from
    /// yours permanently, with every answer after that subtly wrong and no
    /// way to notice. Full sync is a few kilobytes per keystroke on a file
    /// this editor will open at all, and it cannot drift.
    func didChange(path: String, text: String) {
        guard let definition = LSPServerRegistry.server(forPath: path),
              openDocuments.contains(path)
        else { return }

        let key = Key(languageID: definition.languageID, root: Self.workspaceRoot(for: path))

        changeTasks[path]?.cancel()
        pendingChanges[path] = text
        changeTasks[path] = Task { [weak self] in
            try? await Task.sleep(for: Self.changeDebounce)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.flushChange(path: path, key: key) }
        }
    }

    /// Sends the pending change, and does it before anything that needs the
    /// server's answer to be about the text on screen.
    private func flushChange(path: String, key: Key) {
        guard let text = pendingChanges.removeValue(forKey: path) else { return }
        changeTasks.removeValue(forKey: path)?.cancel()

        guard let server = servers[key] else { return }
        let version = (versions[path] ?? 1) + 1
        versions[path] = version

        try? server.notify("textDocument/didChange", params: [
            "textDocument": ["uri": .string(Self.uri(path)), "version": .integer(version)],
            "contentChanges": [["text": .string(text)]],
        ])
    }

    func didSave(path: String, text: String) {
        guard let definition = LSPServerRegistry.server(forPath: path) else { return }
        let key = Key(languageID: definition.languageID, root: Self.workspaceRoot(for: path))
        // Before the save notification, so the server is not told a file was
        // saved while still holding the text from before the last edits.
        flushPending(for: key)
        try? servers[key]?.notify("textDocument/didSave", params: [
            "textDocument": ["uri": .string(Self.uri(path))],
            "text": .string(text),
        ])
    }

    func didClose(path: String) {
        guard let definition = LSPServerRegistry.server(forPath: path) else { return }
        let key = Key(languageID: definition.languageID, root: Self.workspaceRoot(for: path))
        openDocuments.remove(path)
        changeTasks.removeValue(forKey: path)?.cancel()
        pendingChanges.removeValue(forKey: path)
        versions.removeValue(forKey: path)
        diagnostics.removeValue(forKey: path)
        try? servers[key]?.notify("textDocument/didClose", params: [
            "textDocument": ["uri": .string(Self.uri(path))],
        ])
    }

    // MARK: Features

    func hover(path: String, position: LSPPosition) async -> String? {
        guard let result = await request("textDocument/hover", path: path, position: position)
        else { return nil }
        return Self.hoverText(from: result["contents"])
    }

    func definition(path: String, position: LSPPosition) async -> [LSPLocation] {
        guard let result = await request("textDocument/definition", path: path, position: position)
        else { return [] }
        return Self.locations(from: result)
    }

    func references(path: String, position: LSPPosition) async -> [LSPLocation] {
        guard let result = await request(
            "textDocument/references",
            path: path,
            position: position,
            extra: ["context": ["includeDeclaration": .bool(true)]]
        ) else { return [] }
        return Self.locations(from: result)
    }

    func completions(path: String, position: LSPPosition) async -> [LSPCompletion] {
        guard let result = await request("textDocument/completion", path: path, position: position)
        else { return [] }

        // A server answers with a bare list or with `{ items: [...] }`;
        // handling only one of them silently offers nothing on half of them.
        let items = result["items"]?.arrayValue ?? result.arrayValue ?? []
        return items.compactMap(LSPCompletion.init)
    }

    func formatting(path: String, tabSize: Int, insertSpaces: Bool) async -> [LSPTextEdit] {
        guard let server = await runningServer(forPath: path) else { return [] }
        let result = try? await server.request("textDocument/formatting", params: [
            "textDocument": ["uri": .string(Self.uri(path))],
            "options": [
                "tabSize": .integer(tabSize),
                "insertSpaces": .bool(insertSpaces),
            ],
        ])
        return (result?.arrayValue ?? []).compactMap(LSPTextEdit.init)
    }

    /// Edits per file path, since a rename crosses files by definition.
    func rename(path: String, position: LSPPosition, to newName: String) async
        -> [String: [LSPTextEdit]] {
        guard let result = await request(
            "textDocument/rename",
            path: path,
            position: position,
            extra: ["newName": .string(newName)]
        ) else { return [:] }

        return Self.workspaceEdits(from: result)
    }

    // MARK: Plumbing

    private func request(
        _ method: String,
        path: String,
        position: LSPPosition,
        extra: [String: LSPValue] = [:]
    ) async -> LSPValue? {
        guard let server = await runningServer(forPath: path) else { return nil }

        var params: [String: LSPValue] = [
            "textDocument": ["uri": .string(Self.uri(path))],
            "position": position.value,
        ]
        params.merge(extra) { _, new in new }

        return try? await server.request(method, params: .object(params))
    }

    private func server(forPath path: String) -> LSPProcess? {
        guard let definition = LSPServerRegistry.server(forPath: path) else { return nil }
        return servers[Key(languageID: definition.languageID, root: Self.workspaceRoot(for: path))]
    }

    /// The server for a file, waiting for it if it is still starting.
    ///
    /// The version that gave up when `servers` was empty made the first
    /// click after opening a file do nothing at all — the server was on its
    /// way, and the request arrived before it. Waiting is what makes the
    /// feature work the first time somebody tries it rather than the
    /// second.
    private func runningServer(forPath path: String) async -> LSPProcess? {
        guard let definition = LSPServerRegistry.server(forPath: path) else { return nil }
        let key = Key(languageID: definition.languageID, root: Self.workspaceRoot(for: path))

        if let existing = servers[key] {
            // Anything typed in the last moment is still queued behind the
            // debounce, and an answer about stale text is worse than a slow
            // one — it points at the wrong characters.
            flushPending(for: key)
            return existing
        }

        // Bounded: a server that never comes up must not leave a click
        // hanging forever.
        for _ in 0..<60 {
            guard starting.contains(key) else { break }
            try? await Task.sleep(for: .milliseconds(250))
            if let started = servers[key] { return started }
        }
        return servers[key]
    }

    /// Sends any debounced change for the documents this server owns.
    private func flushPending(for key: Key) {
        for path in pendingChanges.keys {
            guard let definition = LSPServerRegistry.server(forPath: path),
                  Key(languageID: definition.languageID, root: Self.workspaceRoot(for: path)) == key
            else { continue }
            flushChange(path: path, key: key)
        }
    }

    /// Starts a server, or hands back the running one.
    private func server(for key: Key, definition: LSPServerDefinition) async -> LSPProcess? {
        if let existing = servers[key] { return existing }
        guard !starting.contains(key) else { return nil }
        starting.insert(key)
        defer { starting.remove(key) }

        guard LSPProcess.locate(
            definition.command,
            searchPath: LoginEnvironment.loginPath() ?? ""
        ) != nil else {
            if !missing.contains(where: { $0.command == definition.command }) {
                missing.append(definition)
            }
            return nil
        }

        let process = LSPProcess(definition: definition)
        do {
            try await process.start()
            _ = try await process.initialize(rootURI: Self.uri(key.root))
        } catch {
            process.terminate()
            return nil
        }

        servers[key] = process
        listen(to: process, key: key)
        return process
    }

    /// Diagnostics arrive unprompted, so the only way to receive them is to
    /// keep reading the server's notifications for as long as it lives.
    private func listen(to process: LSPProcess, key: Key) {
        Task { [weak self] in
            for await event in process.events {
                guard case .notification(let notification) = event else {
                    if case .exited = event {
                        await MainActor.run { self?.servers.removeValue(forKey: key) }
                    }
                    continue
                }
                guard notification.method == "textDocument/publishDiagnostics",
                      let uri = notification.params?["uri"]?.stringValue
                else { continue }

                let reported = (notification.params?["diagnostics"]?.arrayValue ?? [])
                    .compactMap(LSPDiagnostic.init)
                let path = URL(string: uri)?.path ?? uri

                await MainActor.run { self?.diagnostics[path] = reported }
            }
        }
    }

    /// The enclosing repository, else the file's own folder.
    ///
    /// A server indexes what it is given, so pointing it at the repository
    /// is what makes cross-file answers possible at all — rooted at one
    /// file's directory, references would only ever find that directory.
    nonisolated static func workspaceRoot(for path: String) -> String {
        var directory = (path as NSString).deletingLastPathComponent
        while directory != "/", !directory.isEmpty {
            if FileManager.default.fileExists(atPath: directory + "/.git") { return directory }
            directory = (directory as NSString).deletingLastPathComponent
        }
        return (path as NSString).deletingLastPathComponent
    }

    nonisolated static func uri(_ path: String) -> String {
        URL(fileURLWithPath: path).absoluteString
    }

    /// Hover comes back as a string, a `{ value: }`, or an array of either.
    nonisolated static func hoverText(from contents: LSPValue?) -> String? {
        guard let contents else { return nil }
        if let text = contents.stringValue { return text.isEmpty ? nil : text }
        if let value = contents["value"]?.stringValue { return value.isEmpty ? nil : value }
        if let array = contents.arrayValue {
            let joined = array.compactMap { hoverText(from: $0) }.joined(separator: "\n\n")
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    /// Definition answers with one location or a list of them.
    nonisolated static func locations(from value: LSPValue) -> [LSPLocation] {
        if let array = value.arrayValue { return array.compactMap(LSPLocation.init) }
        return [LSPLocation(value)].compactMap { $0 }
    }

    /// A `WorkspaceEdit` carries its edits under `changes` keyed by uri, or
    /// under `documentChanges` as a list — servers pick one, and a client
    /// that reads only `changes` gets nothing from the others.
    nonisolated static func workspaceEdits(from value: LSPValue) -> [String: [LSPTextEdit]] {
        var result: [String: [LSPTextEdit]] = [:]

        if case .object(let changes)? = value["changes"] {
            for (uri, edits) in changes {
                let path = URL(string: uri)?.path ?? uri
                result[path] = (edits.arrayValue ?? []).compactMap(LSPTextEdit.init)
            }
        }

        for change in value["documentChanges"]?.arrayValue ?? [] {
            guard let uri = change["textDocument"]?["uri"]?.stringValue else { continue }
            let path = URL(string: uri)?.path ?? uri
            let edits = (change["edits"]?.arrayValue ?? []).compactMap(LSPTextEdit.init)
            result[path, default: []].append(contentsOf: edits)
        }

        return result
    }
}

/// One completion the server offered.
struct LSPCompletion: Identifiable, Equatable {
    let label: String
    let detail: String?
    let insertText: String
    let kind: Int?

    var id: String { label + (detail ?? "") }

    init?(_ value: LSPValue) {
        guard let label = value["label"]?.stringValue else { return nil }
        self.label = label
        self.detail = value["detail"]?.stringValue
        self.kind = value["kind"]?.intValue
        // `insertText` when given, else the label. A server may also send a
        // `textEdit` instead; falling back to the label keeps something
        // usable rather than inserting nothing.
        self.insertText = value["insertText"]?.stringValue
            ?? value["textEdit"]?["newText"]?.stringValue
            ?? label
    }
}
