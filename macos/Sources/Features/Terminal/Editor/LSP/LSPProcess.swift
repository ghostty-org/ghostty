import Foundation

/// Everything that can go wrong around a server rather than inside it.
enum LSPProcessError: Error, Hashable, Sendable {
    /// Nothing by that name on the login shell's `PATH`. Carries the hint so
    /// the message can say what to install without a second lookup.
    case serverNotFound(command: String, installHint: String)

    case launchFailed(reason: String)

    /// Sent to a server that has not been started, or has already exited.
    case notRunning

    case alreadyStarted

    case timedOut(method: String, seconds: TimeInterval)

    /// The server answered, and the answer was an error.
    case server(LSPResponseError)

    /// The server died while a request was in flight.
    case terminated(status: Int32?)
}

extension LSPProcessError {
    /// A sentence a person can read in a banner — not a value anything
    /// parses back apart.
    var reason: String {
        switch self {
        case .serverNotFound(let command, let hint):
            return "\(command) isn't on PATH. \(hint)"
        case .launchFailed(let reason):
            return "the process didn't launch: \(reason)"
        case .notRunning:
            return "the server isn't running"
        case .alreadyStarted:
            return "the server was already starting"
        case .timedOut(let method, let seconds):
            return "\(method) didn't answer within \(Int(seconds))s"
        case .server(let error):
            return error.message
        case .terminated(let status):
            return "the server exited" + (status.map { " (status \($0))" } ?? "")
        }
    }
}

/// A language server on the other end of a pipe.
///
/// Owns the whole lifecycle — locating the binary, spawning it, pumping
/// both output streams, correlating replies, and the
/// `initialize` → `initialized` → `shutdown` → `exit` handshake — and
/// nothing above it. It has no opinion about editors, documents or
/// diagnostics; those arrive as `Event.notification` and are somebody
/// else's problem.
///
/// State is guarded by a plain lock rather than actor isolation on purpose.
/// The pipe callbacks arrive on Foundation's own queues, and hopping each
/// one into an actor with `Task { await … }` would lose their ordering:
/// tasks are not FIFO, and two chunks of stdout reordered by one hop is a
/// corrupted stream. Decoding therefore happens on the reader's own serial
/// queue, and only whole messages leave it.
///
/// Blocking work — resolving the login `PATH` — is kept off the caller by
/// `start()` being async.
final class LSPProcess: @unchecked Sendable {
    /// Anything the server says that wasn't an answer to something we
    /// asked.
    enum Event: Sendable {
        case notification(LSPNotification)

        /// A line the server wrote to stderr. Servers report their own
        /// misconfiguration there and nowhere else — a missing `tsconfig`,
        /// a plugin that failed to load — and losing it turns "no
        /// completions" into an unanswerable question.
        case log(String)

        case exited(status: Int32?)
    }

    enum State: Sendable {
        case idle
        case starting
        case initializing
        case running
        case shuttingDown
        case exited
    }

    /// Answers a question the *server* asked. Returning an error is a legal
    /// answer; returning nothing is not.
    typealias RequestHandler = @Sendable (LSPRequest) async -> Result<LSPValue, LSPResponseError>

    let definition: LSPServerDefinition

    /// Finishes when the server exits.
    let events: AsyncStream<Event>

    private let environmentProvider: @Sendable () -> [String: String]
    private let requestHandler: RequestHandler?
    private let eventContinuation: AsyncStream<Event>.Continuation
    private let decoder = LSPMessageDecoder()
    private let writeQueue: DispatchQueue
    private let timerQueue: DispatchQueue

    private let lock = NSLock()
    private var process: Process?
    private var standardInput: FileHandle?
    private var pending: [LSPRequestID: CheckedContinuation<LSPValue, Error>] = [:]
    private var nextID = 1
    private var state: State = .idle
    private var stderrTail: [String] = []

    /// Enough of a crash to be diagnosable, bounded so a server that logs
    /// every keystroke to stderr can't grow the app's memory forever.
    private static let stderrTailLimit = 100

    /// Dropping the oldest event would be worse than dropping the newest —
    /// `publishDiagnostics` for a file is superseded by the next one, but a
    /// buffer that grows without bound because nobody is consuming is a
    /// leak with no upper limit.
    private static let eventBufferLimit = 512

    /// - Parameter environmentProvider: Injected so the transport can be
    ///   exercised without spawning a login shell, and so this file keeps
    ///   no hard dependency on the app.
    init(
        definition: LSPServerDefinition,
        requestHandler: RequestHandler? = nil,
        environmentProvider: @escaping @Sendable () -> [String: String] = { LoginEnvironment.environment() }
    ) {
        self.definition = definition
        self.requestHandler = requestHandler
        self.environmentProvider = environmentProvider
        self.writeQueue = DispatchQueue(label: "lsp.stdin.\(definition.languageID)")
        self.timerQueue = DispatchQueue(label: "lsp.timeout.\(definition.languageID)")

        let (stream, continuation) = AsyncStream<Event>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.eventBufferLimit)
        )
        self.events = stream
        self.eventContinuation = continuation
    }

    deinit {
        eventContinuation.finish()
    }

    // MARK: Lifecycle

    var currentState: State {
        lock.withLock { state }
    }

    /// The most recent stderr lines, oldest first. Worth showing verbatim
    /// when a server exits during `initialize`.
    var recentLog: [String] {
        lock.withLock { stderrTail }
    }

    /// Spawns the server.
    ///
    /// The `PATH` is the login shell's, not the process's. A GUI app
    /// inherits `launchd`'s `/usr/bin:/bin:/usr/sbin:/sbin`, and every
    /// server in the registry lives somewhere else — Homebrew, a global
    /// npm prefix, `~/.cargo/bin`, a Go module cache. Without this, the
    /// entire feature reports "not installed" on a machine where all of it
    /// is installed.
    func start() async throws {
        try claimStart()

        let environment = await Task.detached(priority: .userInitiated) { [environmentProvider] in
            environmentProvider()
        }.value

        do {
            try launch(environment: environment)
        } catch {
            lock.withLock { state = .idle }
            throw error
        }
    }

    /// The handshake, in the order the specification requires it.
    ///
    /// A server may answer `initialize` and still refuse every request until
    /// it has seen `initialized`, so the notification is not optional and
    /// not deferrable.
    @discardableResult
    func initialize(
        rootURI: String?,
        capabilities: LSPValue = LSPProcess.defaultCapabilities,
        initializationOptions: LSPValue? = nil,
        timeout: TimeInterval = 30
    ) async throws -> LSPValue {
        lock.withLock { state = .initializing }

        var params: [String: LSPValue] = [
            "processId": .integer(Int(ProcessInfo.processInfo.processIdentifier)),
            "clientInfo": ["name": "Phantom"],
            "capabilities": capabilities
        ]
        if let rootURI {
            params["rootUri"] = .string(rootURI)
            params["workspaceFolders"] = [["uri": .string(rootURI), "name": .string(Self.folderName(of: rootURI))]]
        } else {
            params["rootUri"] = .null
            params["workspaceFolders"] = .null
        }
        if let initializationOptions {
            params["initializationOptions"] = initializationOptions
        }

        let result = try await request("initialize", params: .object(params), timeout: timeout)
        try notify("initialized", params: .object([:]))
        lock.withLock { state = .running }
        return result
    }

    /// Asks the server to stop, then makes sure it did.
    ///
    /// The polite sequence is `shutdown`, then `exit`, then EOF on stdin —
    /// three chances, because servers disagree about which one they honour
    /// and a few honour none of them. Whatever is still running after the
    /// grace period is signalled: an orphaned language server is a
    /// permanently pegged CPU core.
    func shutdown(gracePeriod: TimeInterval = 5) async {
        let running = lock.withLock { () -> Bool in
            guard state != .exited, state != .idle else { return false }
            state = .shuttingDown
            return true
        }
        guard running else { return }

        _ = try? await request("shutdown", timeout: gracePeriod)
        try? notify("exit")
        closeStandardInput()

        let deadline = Date().addingTimeInterval(gracePeriod)
        while Date() < deadline {
            guard lock.withLock({ process?.isRunning ?? false }) else { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        terminate()
    }

    /// Kills the server now and fails everything waiting on it.
    func terminate() {
        let victim = lock.withLock { () -> Process? in
            let current = process
            state = .exited
            return current
        }

        guard let victim, victim.isRunning else {
            finish(status: nil)
            return
        }
        victim.terminate()
    }

    // MARK: Sending

    /// Sends a request and waits for the matching reply.
    ///
    /// Cancelling the surrounding task sends `$/cancelRequest` as well as
    /// failing the call — a completion request abandoned by a keystroke is
    /// the common case, and a server left computing it is the reason
    /// language servers get a reputation for burning battery.
    @discardableResult
    func request(
        _ method: String,
        params: LSPValue? = nil,
        timeout: TimeInterval = 30
    ) async throws -> LSPValue {
        try Task.checkCancellation()
        let id = nextRequestID()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let accepted = lock.withLock { () -> Bool in
                    guard state != .idle, state != .exited else { return false }
                    pending[id] = continuation
                    return true
                }
                guard accepted else {
                    continuation.resume(throwing: LSPProcessError.notRunning)
                    return
                }

                do {
                    try send(.request(LSPRequest(id: id, method: method, params: params)))
                } catch {
                    takePending(id)?.resume(throwing: error)
                    return
                }

                scheduleTimeout(for: id, method: method, after: timeout)
            }
        } onCancel: {
            guard let waiter = takePending(id) else { return }
            try? notify("$/cancelRequest", params: ["id": id.value])
            waiter.resume(throwing: CancellationError())
        }
    }

    /// Sends a notification. Nothing comes back, including errors — the
    /// only failure surface is the pipe itself.
    func notify(_ method: String, params: LSPValue? = nil) throws {
        try send(.notification(LSPNotification(method: method, params: params)))
    }

    /// Answers a request the server made.
    func respond(to request: LSPRequest, with result: Result<LSPValue, LSPResponseError>) throws {
        switch result {
        case .success(let value):
            try send(.response(LSPResponse(id: request.id, result: value)))
        case .failure(let error):
            try send(.response(LSPResponse(id: request.id, error: error)))
        }
    }

    // MARK: Locating the binary

    /// Resolves a command against a `PATH`, the way a shell would.
    ///
    /// Pure and explicit about its search path so the lookup can be reasoned
    /// about (and tested) without a login shell in the picture. A command
    /// containing a slash is taken as a path and not searched for, matching
    /// shell behaviour.
    static func locate(_ command: String, searchPath: String) -> String? {
        let fileManager = FileManager.default

        if command.contains("/") {
            let expanded = (command as NSString).expandingTildeInPath
            return fileManager.isExecutableFile(atPath: expanded) ? expanded : nil
        }

        for directory in searchPath.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = (String(directory) as NSString).appendingPathComponent(command)
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: Private — launching

    private func claimStart() throws {
        try lock.withLock {
            guard state == .idle else { throw LSPProcessError.alreadyStarted }
            state = .starting
        }
    }

    private func launch(environment: [String: String]) throws {
        let searchPath = environment["PATH"] ?? ""
        guard let executable = Self.locate(definition.command, searchPath: searchPath) else {
            throw LSPProcessError.serverNotFound(
                command: definition.command,
                installHint: definition.installHint
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = definition.arguments
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        process.terminationHandler = { [weak self] process in
            self?.handleTermination(status: process.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            throw LSPProcessError.launchFailed(reason: error.localizedDescription)
        }

        Self.suppressSIGPIPE(on: input.fileHandleForWriting)

        lock.withLock {
            self.process = process
            self.standardInput = input.fileHandleForWriting
        }

        drain(output.fileHandleForReading) { [weak self] data in
            self?.ingestStandardOutput(data)
        }
        drain(errors.fileHandleForReading) { [weak self] data in
            self?.ingestStandardError(data)
        }
    }

    /// Writing to a pipe whose reader has gone raises `SIGPIPE`, which
    /// terminates the *editor*, not the server. `F_SETNOSIGPIPE` turns that
    /// into an `EPIPE` this code can catch, and does it per descriptor
    /// rather than by changing a process-wide signal disposition on
    /// somebody else's behalf.
    private static func suppressSIGPIPE(on handle: FileHandle) {
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    /// Both streams are drained, always, and each on its own handler.
    ///
    /// Reading only stdout is a deadlock with a delay fuse: a server that
    /// writes more than a pipe buffer of logs to stderr — every one of them
    /// does, on a large project — blocks in `write` and stops answering,
    /// and the symptom is a hang far away from the cause.
    private func drain(_ handle: FileHandle, into sink: @escaping @Sendable (Data) -> Void) {
        handle.readabilityHandler = { reader in
            let data = reader.availableData
            guard !data.isEmpty else {
                reader.readabilityHandler = nil
                return
            }
            sink(data)
        }
    }

    /// Runs on the stdout handler's serial queue, which is the only reason
    /// the decoder needs no lock of its own.
    private func ingestStandardOutput(_ data: Data) {
        for result in decoder.append(data) {
            switch result {
            case .success(let message):
                handle(message)
            case .failure(let error):
                eventContinuation.yield(.log("Malformed message from \(definition.command): \(error)"))
            }
        }
    }

    /// A read can land in the middle of a multi-byte character, so a chunk
    /// of stderr is not guaranteed to be valid UTF-8 on its own. Latin-1 is
    /// the fallback because it cannot fail: a log line with one mangled
    /// character is worth more than no log line at all, and this text is
    /// only ever shown to a human trying to find out why a server died.
    private func ingestStandardError(_ data: Data) {
        let text = String(bytes: data, encoding: .utf8)
            ?? String(bytes: data, encoding: .isoLatin1)
            ?? ""

        for line in text.split(whereSeparator: \.isNewline) {
            let entry = String(line)
            lock.withLock {
                stderrTail.append(entry)
                if stderrTail.count > Self.stderrTailLimit {
                    stderrTail.removeFirst(stderrTail.count - Self.stderrTailLimit)
                }
            }
            eventContinuation.yield(.log(entry))
        }
    }

    // MARK: Private — dispatch

    private func handle(_ message: LSPMessage) {
        switch message {
        case .response(let response):
            guard let id = response.id, let waiter = takePending(id) else { return }
            if let error = response.error {
                waiter.resume(throwing: LSPProcessError.server(error))
            } else {
                waiter.resume(returning: response.result ?? .null)
            }

        case .notification(let notification):
            eventContinuation.yield(.notification(notification))

        case .request(let request):
            Task { [weak self] in
                guard let self else { return }
                let answer = await self.answer(request)
                try? self.respond(to: request, with: answer)
            }
        }
    }

    /// A server request that goes unanswered is a hang, not a dropped
    /// message: `typescript-language-server` sends `client/registerCapability`
    /// immediately after `initialized` and waits for the reply before it
    /// will serve anything. So there is always an answer, even if it is a
    /// refusal.
    private func answer(_ request: LSPRequest) async -> Result<LSPValue, LSPResponseError> {
        if let requestHandler { return await requestHandler(request) }
        return Self.defaultAnswer(to: request)
    }

    /// Accepts the housekeeping requests every server sends and refuses the
    /// rest. `workspace/configuration` is answered with one null per item
    /// requested — "no opinion, use your defaults" — because the shape of
    /// the reply must match the request even when there is nothing to say.
    private static func defaultAnswer(to request: LSPRequest) -> Result<LSPValue, LSPResponseError> {
        switch request.method {
        case "client/registerCapability", "client/unregisterCapability",
             "window/workDoneProgress/create":
            return .success(.null)

        case "workspace/configuration":
            let items = request.params?["items"]?.arrayValue?.count ?? 0
            return .success(.array(Array(repeating: .null, count: items)))

        default:
            return .failure(.unhandled(request.method))
        }
    }

    // MARK: Private — pending requests

    private func nextRequestID() -> LSPRequestID {
        lock.withLock {
            let id = nextID
            nextID += 1
            return .number(id)
        }
    }

    /// Removing under the lock is what makes "resumed exactly once"
    /// structural: a timeout, a cancellation, a reply and a process death
    /// can all be racing for the same continuation, and only the one that
    /// gets it out of the table is allowed to resume it.
    @discardableResult
    private func takePending(_ id: LSPRequestID) -> CheckedContinuation<LSPValue, Error>? {
        lock.withLock { pending.removeValue(forKey: id) }
    }

    private func scheduleTimeout(for id: LSPRequestID, method: String, after seconds: TimeInterval) {
        guard seconds > 0 else { return }
        timerQueue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, let waiter = self.takePending(id) else { return }
            try? self.notify("$/cancelRequest", params: ["id": id.value])
            waiter.resume(throwing: LSPProcessError.timedOut(method: method, seconds: seconds))
        }
    }

    // MARK: Private — writing

    private func send(_ message: LSPMessage) throws {
        let data = try message.encoded()

        let handle = try lock.withLock { () -> FileHandle in
            guard let standardInput, state != .exited, process?.isRunning == true else {
                throw LSPProcessError.notRunning
            }
            return standardInput
        }

        try writeQueue.sync {
            try handle.write(contentsOf: data)
        }
    }

    private func closeStandardInput() {
        let handle = lock.withLock { () -> FileHandle? in
            let current = standardInput
            standardInput = nil
            return current
        }
        try? handle?.close()
    }

    // MARK: Private — teardown

    private func handleTermination(status: Int32) {
        finish(status: status)
    }

    /// Everything waiting is failed here rather than left to time out. A
    /// server that crashed will never answer, and thirty seconds of a
    /// spinner before admitting it is thirty seconds of a lie.
    private func finish(status: Int32?) {
        let waiters = lock.withLock { () -> [CheckedContinuation<LSPValue, Error>] in
            state = .exited
            standardInput = nil
            let current = Array(pending.values)
            pending.removeAll()
            return current
        }

        for waiter in waiters {
            waiter.resume(throwing: LSPProcessError.terminated(status: status))
        }

        eventContinuation.yield(.exited(status: status))
        eventContinuation.finish()
    }

    // MARK: Private — helpers

    private static func folderName(of uri: String) -> String {
        let path = URL(string: uri)?.path ?? uri
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }
}

extension LSPProcess {
    /// A deliberately small set: what a transport can honestly promise
    /// before any editor exists to honour it. Callers that implement more
    /// pass their own — announcing a capability the client does not have
    /// makes servers send things nobody reads, and in a few cases makes
    /// them wait for replies that never come.
    static let defaultCapabilities: LSPValue = [
        "general": ["positionEncodings": ["utf-16"]],
        "textDocument": [
            "synchronization": [
                "dynamicRegistration": false,
                "willSave": false,
                "didSave": true
            ],
            "publishDiagnostics": ["relatedInformation": true],
            "hover": ["contentFormat": ["markdown", "plaintext"]],
            "completion": [
                "completionItem": ["snippetSupport": false],
                "contextSupport": true
            ],
            "definition": ["dynamicRegistration": false],
            "references": ["dynamicRegistration": false],
            "formatting": ["dynamicRegistration": false],
            // No `prepareSupport`: this client asks to rename outright
            // rather than first asking whether it may. Claiming otherwise
            // makes a server wait for a `prepareRename` that never comes.
            "rename": ["dynamicRegistration": false, "prepareSupport": false]
        ],
        "workspace": [
            "workspaceFolders": true,
            "configuration": true,
            // Both shapes of `WorkspaceEdit` are understood, so declaring
            // `documentChanges` costs nothing and lets a server send the
            // richer one — some only ever send `changes` without it.
            "workspaceEdit": ["documentChanges": true]
        ]
    ]
}
