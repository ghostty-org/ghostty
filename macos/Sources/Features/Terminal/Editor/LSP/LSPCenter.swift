import AppKit
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

    /// What each server is doing right now, keyed by (language, workspace
    /// root). See `LSPServerStatus` for why this replaced a plain
    /// "installed or not" flag.
    ///
    /// Fully `private` rather than `private(set)`: `Key` is private to
    /// this type, so a getter any less restricted than that couldn't
    /// expose this property's type at all. Nothing outside this class
    /// reads it directly anyway — `status(forPath:)` below is the surface.
    @Published private var status: [Key: LSPServerStatus] = [:]

    private struct Key: Hashable, Sendable {
        let languageID: String
        let root: String
    }

    private var servers: [Key: LSPProcess] = [:]
    private var starting: Set<Key> = []

    /// What `initialize` answered with, so a feature can tell "the server
    /// answered empty" apart from "the server never claimed to offer this".
    private var serverCapabilities: [Key: LSPValue] = [:]

    /// The server's recent stderr, kept after the process exits or fails to
    /// start — that is precisely when it is worth reading. Cleared when a
    /// fresh attempt starts, so a crash from three runs ago doesn't linger
    /// under a server that is now healthy.
    private var serverLogs: [Key: [String]] = [:]

    /// Consecutive timeouts on requests to a running server. Reset on any
    /// answer; past the threshold the server is reported `unresponsive`
    /// rather than each caller silently getting nothing back.
    private var consecutiveTimeouts: [Key: Int] = [:]
    private static let unresponsiveThreshold = 3
    private static let logTailLimit = 200

    /// Version per open document. The protocol requires it to increase on
    /// every change, and a server that sees it go backwards may discard the
    /// edit or desynchronise outright.
    private var versions: [String: Int] = [:]

    private var openDocuments: Set<String> = []

    /// Which server each open document has been announced to.
    ///
    /// `didOpen` twice for the same document is a protocol violation, and a
    /// server that starts *after* a file was opened has never heard of it —
    /// both are true at once, so "is it open" is not a property of the
    /// document but of the pair.
    private var announced: [String: Key] = [:]

    /// Bumped whenever a server that was missing becomes available, so the
    /// open documents can introduce themselves to it.
    ///
    /// A counter rather than the text: this object does not keep a copy of
    /// any buffer, and it should not start now — the documents own their
    /// text and can hand it over when asked.
    @Published private(set) var availabilityGeneration = 0

    /// Watches the directories on the login `PATH` for a server appearing.
    private var pathWatcher: DirectoryWatcher?

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

    private init() {
        watchPathForInstalls()

        // Installing happens in the terminal and is followed by coming back
        // to the editor. Free to check, and it is the actual gesture.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationBecameActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func applicationBecameActive() {
        recheckMissingServers()
    }

    /// Watches the `PATH` directories so an install is noticed as it happens.
    ///
    /// Reactive rather than polled: `npm i -g` and `brew install` both end by
    /// creating an entry in a bin directory, which is a filesystem event. The
    /// watched set is the login `PATH` — about fifteen directories — and the
    /// only thing done with an event is re-probing the commands already known
    /// to be missing. Nothing is scanned.
    private func watchPathForInstalls() {
        Task { [weak self] in
            let directories = await Task.detached(priority: .utility) {
                Set((LoginEnvironment.loginPath() ?? "").split(separator: ":").map(String.init))
            }.value

            await MainActor.run {
                guard let self, !directories.isEmpty else { return }
                let watcher = DirectoryWatcher()
                watcher.onChange = { [weak self] _ in
                    Task { @MainActor in self?.recheckMissingServers() }
                }
                watcher.watch(directories)
                self.pathWatcher = watcher
            }
        }
    }

    /// Looks again for the servers that were not installed.
    ///
    /// The bug this fixes: a command that could not be found used to go
    /// into an append-only list and nothing ever looked again, so the
    /// banner outlived the install and only a restart cleared it — the
    /// signature of a cache with no invalidation.
    func recheckMissingServers() {
        let notInstalledCommands = Set(status.compactMap { key, value -> String? in
            guard case .notInstalled = value else { return nil }
            return LSPServerRegistry.server(forLanguage: key.languageID).map(Self.effectiveDefinition)?.command
        })
        guard !notInstalledCommands.isEmpty else { return }

        Task { [weak self] in
            let found = await Task.detached(priority: .utility) { () -> Set<String> in
                var searchPath = LoginEnvironment.loginPath() ?? ""
                var located = notInstalledCommands.filter {
                    LSPProcess.locate($0, searchPath: searchPath) != nil
                }

                // Nothing found could mean nothing installed — or a `PATH`
                // captured before the version manager moved the directory.
                // One retry on a fresh resolve tells the two apart.
                if located.isEmpty {
                    LoginEnvironment.invalidate()
                    searchPath = LoginEnvironment.loginPath() ?? ""
                    located = notInstalledCommands.filter {
                        LSPProcess.locate($0, searchPath: searchPath) != nil
                    }
                }
                return located
            }.value

            guard !found.isEmpty else { return }
            await MainActor.run {
                guard let self else { return }
                for key in Array(self.status.keys) {
                    guard case .notInstalled = self.status[key],
                          let base = LSPServerRegistry.server(forLanguage: key.languageID),
                          found.contains(Self.effectiveDefinition(base).command)
                    else { continue }
                    self.status.removeValue(forKey: key)
                }
                // The open documents have to introduce themselves: a server
                // starting now has never heard of a file opened before it.
                self.availabilityGeneration += 1
            }
        }
    }

    // MARK: Documents

    func didOpen(path: String, text: String) {
        guard let base = LSPServerRegistry.server(forPath: path) else { return }
        let definition = Self.effectiveDefinition(base)
        let root = Self.workspaceRoot(for: path)
        let key = Key(languageID: definition.languageID, root: root)

        // Already announced to *this* server: a second `didOpen` for the same
        // pair is a protocol violation. Announced to a different one — or to
        // none — means this is the introduction.
        guard announced[path] != key else { return }

        versions[path] = 1
        openDocuments.insert(path)

        Task { [weak self] in
            guard let server = await self?.server(for: key, definition: definition) else { return }
            await MainActor.run { self?.announced[path] = key }
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
        announced.removeValue(forKey: path)
        changeTasks.removeValue(forKey: path)?.cancel()
        pendingChanges.removeValue(forKey: path)
        versions.removeValue(forKey: path)
        diagnostics.removeValue(forKey: path)
        try? servers[key]?.notify("textDocument/didClose", params: [
            "textDocument": ["uri": .string(Self.uri(path))],
        ])
    }

    // MARK: Server status

    /// What the server for this file's language is doing right now. Nil
    /// when no server — registry or override — is known for this language
    /// at all, which is the ordinary case for most files a terminal opens.
    func status(forPath path: String) -> LSPServerStatus? {
        guard let key = key(forPath: path) else { return nil }
        return status[key]
    }

    /// The registry's definition plus any override, for the language this
    /// file would use. What a banner names and what "Check Again" or a log
    /// panel act on.
    func definition(forPath path: String) -> LSPServerDefinition? {
        guard let base = LSPServerRegistry.server(forPath: path) else { return nil }
        return Self.effectiveDefinition(base)
    }

    /// The server's recent stderr, oldest first. Kept after the process
    /// exits or fails to start — that is precisely when it is worth
    /// reading.
    func log(forPath path: String) -> [String] {
        guard let key = key(forPath: path) else { return [] }
        return serverLogs[key] ?? []
    }

    /// Whether the server running for this file's language advertised a
    /// given LSP capability (`hoverProvider`, `definitionProvider`, …).
    /// False for any server not `running`, including one still starting.
    func hasCapability(_ name: String, forPath path: String) -> Bool {
        guard let key = key(forPath: path), let value = serverCapabilities[key]?[name] else { return false }
        if let bool = value.boolValue { return bool }
        return !value.isNull
    }

    /// The registry's definition for a language, with any user override
    /// applied.
    ///
    /// Command and arguments are replaced outright when overridden — a
    /// user pointing at a different binary presumably wants different
    /// arguments too, or none. `initializationOptionsKind` is untouched;
    /// an override's own `initializationOptionsJSON`, when present, is
    /// applied later, where a resolution failure can also be reported —
    /// see `resolvedInitializationOptions`.
    static func effectiveDefinition(_ definition: LSPServerDefinition) -> LSPServerDefinition {
        guard let override = LSPServerOverrideStore.override(for: definition.command) else { return definition }

        var command = definition.command
        let trimmedCommand = override.command.trimmingCharacters(in: .whitespaces)
        if !trimmedCommand.isEmpty { command = trimmedCommand }

        var arguments = definition.arguments
        let trimmedArguments = override.arguments.trimmingCharacters(in: .whitespaces)
        if !trimmedArguments.isEmpty {
            arguments = trimmedArguments.split(separator: " ").map(String.init)
        }

        return LSPServerDefinition(
            languageID: definition.languageID,
            displayName: definition.displayName,
            command: command,
            arguments: arguments,
            installHint: definition.installHint,
            initializationOptionsKind: definition.initializationOptionsKind
        )
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
        guard let key = key(forPath: path), let server = await runningServer(forPath: path) else { return [] }
        do {
            let result = try await server.request("textDocument/formatting", params: [
                "textDocument": ["uri": .string(Self.uri(path))],
                "options": [
                    "tabSize": .integer(tabSize),
                    "insertSpaces": .bool(insertSpaces),
                ],
            ])
            noteRequestSucceeded(for: key)
            return (result.arrayValue ?? []).compactMap(LSPTextEdit.init)
        } catch {
            noteRequestFailed(error, for: key)
            return []
        }
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
        guard let key = key(forPath: path), let server = await runningServer(forPath: path) else { return nil }

        var params: [String: LSPValue] = [
            "textDocument": ["uri": .string(Self.uri(path))],
            "position": position.value,
        ]
        params.merge(extra) { _, new in new }

        do {
            let result = try await server.request(method, params: .object(params))
            noteRequestSucceeded(for: key)
            return result
        } catch {
            noteRequestFailed(error, for: key)
            return nil
        }
    }

    /// Resets the failure count on any answer, and — since a server that
    /// answers again is no longer the problem `unresponsive` described —
    /// clears that state too.
    private func noteRequestSucceeded(for key: Key) {
        consecutiveTimeouts[key] = 0
        if case .unresponsive = status[key] {
            status[key] = .running
        }
    }

    /// Only a timeout counts here. A crash is reported through the
    /// `.exited` event instead, and cancellation is the caller giving up,
    /// not the server failing anybody.
    private func noteRequestFailed(_ error: Error, for key: Key) {
        guard case LSPProcessError.timedOut = error else { return }
        let count = (consecutiveTimeouts[key] ?? 0) + 1
        consecutiveTimeouts[key] = count
        guard count >= Self.unresponsiveThreshold, case .running = status[key] else { return }
        status[key] = .unresponsive
    }

    private func server(forPath path: String) -> LSPProcess? {
        guard let key = key(forPath: path) else { return nil }
        return servers[key]
    }

    private func key(forPath path: String) -> Key? {
        guard let definition = LSPServerRegistry.server(forPath: path) else { return nil }
        return Key(languageID: definition.languageID, root: Self.workspaceRoot(for: path))
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

        let searchPath = LoginEnvironment.loginPath() ?? ""
        guard LSPProcess.locate(definition.command, searchPath: searchPath) != nil else {
            status[key] = .notInstalled
            return nil
        }

        // A fresh attempt gets a fresh log and a fresh failure count — a
        // crash from three runs ago must not linger under a server that
        // has since been fixed.
        serverLogs[key] = []
        consecutiveTimeouts[key] = 0
        status[key] = .starting

        let initializationOptions: LSPValue?
        switch await resolvedInitializationOptions(for: definition, key: key, searchPath: searchPath) {
        case .failure(let reason):
            status[key] = .failedToStart(reason: reason)
            return nil
        case .success(let value):
            initializationOptions = value
        }

        let process = LSPProcess(definition: definition)
        do {
            try await process.start()
            let result = try await process.initialize(
                rootURI: Self.uri(key.root),
                initializationOptions: initializationOptions
            )
            serverCapabilities[key] = result["capabilities"]
        } catch {
            serverLogs[key] = process.recentLog
            status[key] = .failedToStart(reason: (error as? LSPProcessError)?.reason ?? String(describing: error))
            process.terminate()
            return nil
        }

        status[key] = .running
        servers[key] = process
        listen(to: process, key: key)
        return process
    }

    /// `initializationOptions` to send: a user override's raw JSON when
    /// there is one, else the language's own resolution — Vue's `tsdk`
    /// lookup today, nothing for everyone else.
    ///
    /// The override lookup uses the registry's *default* command for this
    /// language rather than `definition.command` — `definition` here may
    /// already be the overridden one, and the override's own identity has
    /// to stay independent of what it changes the command to.
    private func resolvedInitializationOptions(
        for definition: LSPServerDefinition,
        key: Key,
        searchPath: String
    ) async -> LSPOutcome<LSPValue?> {
        let defaultCommand = LSPServerRegistry.server(forLanguage: key.languageID)?.command ?? definition.command
        if let override = LSPServerOverrideStore.override(for: defaultCommand) {
            let raw = override.initializationOptionsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty {
                switch Self.parseInitializationOptions(raw) {
                case .success(let value): return .success(value)
                case .failure(let reason): return .failure(reason)
                }
            }
        }

        switch definition.initializationOptionsKind {
        case .none:
            return .success(nil)
        case .vueTypeScriptSDK:
            let root = key.root
            let resolved = await Task.detached(priority: .utility) {
                LSPInitializationOptions.vueTypeScriptSDK(root: root, searchPath: searchPath)
            }.value
            switch resolved {
            case .success(let tsdk): return .success(LSPInitializationOptions.vueValue(tsdk: tsdk))
            case .failure(let reason): return .failure(reason)
            }
        }
    }

    private static func parseInitializationOptions(_ json: String) -> LSPOutcome<LSPValue> {
        guard let data = json.data(using: .utf8) else {
            return .failure("initializationOptions isn't valid text.")
        }
        do {
            return .success(try JSONDecoder().decode(LSPValue.self, from: data))
        } catch {
            return .failure("initializationOptions isn't valid JSON: \(error.localizedDescription)")
        }
    }

    /// Diagnostics arrive unprompted, so the only way to receive them is to
    /// keep reading the server's notifications for as long as it lives —
    /// and, now, its log lines and its exit.
    private func listen(to process: LSPProcess, key: Key) {
        Task { [weak self] in
            for await event in process.events {
                switch event {
                case .notification(let notification):
                    await MainActor.run { self?.handle(notification) }
                case .log(let line):
                    await MainActor.run { self?.appendLog(line, for: key) }
                case .exited(let exitStatus):
                    await MainActor.run { self?.handleExit(exitStatus: exitStatus, key: key) }
                }
            }
        }
    }

    private func handle(_ notification: LSPNotification) {
        guard notification.method == "textDocument/publishDiagnostics",
              let uri = notification.params?["uri"]?.stringValue
        else { return }

        let reported = (notification.params?["diagnostics"]?.arrayValue ?? [])
            .compactMap(LSPDiagnostic.init)
        let path = URL(string: uri)?.path ?? uri
        diagnostics[path] = reported
    }

    private func appendLog(_ line: String, for key: Key) {
        serverLogs[key, default: []].append(line)
        if let count = serverLogs[key]?.count, count > Self.logTailLimit {
            serverLogs[key]?.removeFirst(count - Self.logTailLimit)
        }
    }

    /// The process exited after having run — as opposed to `server(for:)`'s
    /// own `catch`, which is a server that never got this far at all.
    private func handleExit(exitStatus: Int32?, key: Key) {
        servers.removeValue(forKey: key)
        serverCapabilities.removeValue(forKey: key)
        status[key] = .crashed(status: exitStatus)
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
