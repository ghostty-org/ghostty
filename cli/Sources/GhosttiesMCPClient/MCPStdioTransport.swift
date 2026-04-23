import Foundation

/// Launches an external MCP server as a subprocess and talks to it over stdin/
/// stdout with line-delimited JSON. Per MCP spec, stderr is reserved for
/// diagnostic output — we route it to a logger and DO NOT consume it as
/// messages. See Fragile Area #13 in ORCHESTRATOR.md.
public final class MCPStdioTransport: MCPTransport, @unchecked Sendable {
    /// A handler invoked for each stderr line the subprocess emits.
    public typealias StderrLogger = @Sendable (String) -> Void

    /// A handler invoked once when the subprocess terminates.
    public typealias TerminationHandler = @Sendable (Int32) -> Void

    private let process: Process
    private let stdin: Pipe
    private let stdout: Pipe
    private let stderr: Pipe

    private let stderrLogger: StderrLogger?
    private let terminationHandler: TerminationHandler?

    /// Serializes `send` calls so two writes don't interleave on the pipe.
    private let sendQueue = DispatchQueue(label: "ghostties.mcp.stdio.send")

    private var receiveContinuation: AsyncStream<Data>.Continuation?
    private let stateLock = NSLock()
    private var closed = false

    /// - Parameters:
    ///   - executable: Absolute path to the MCP server binary.
    ///   - arguments: Argv passed to the binary (excluding argv[0]).
    ///   - environment: Environment variables for the child process. When nil,
    ///     the parent's environment is inherited.
    ///   - workingDirectory: Optional cwd for the child. Default is the
    ///     parent's cwd.
    ///   - stderrLogger: Called with each stderr line. Default: no-op.
    ///   - terminationHandler: Called once with the exit code when the process
    ///     exits.
    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil,
        stderrLogger: StderrLogger? = nil,
        terminationHandler: TerminationHandler? = nil
    ) {
        self.process = Process()
        self.stdin = Pipe()
        self.stdout = Pipe()
        self.stderr = Pipe()
        self.stderrLogger = stderrLogger
        self.terminationHandler = terminationHandler

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        if let environment {
            process.environment = environment
        }
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }
    }

    /// Start the subprocess. Must be called before `send` / `receive`.
    public func start() throws {
        do {
            try process.run()
        } catch {
            throw MCPError.transportFailed("failed to launch \(process.executableURL?.path ?? "?"): \(error.localizedDescription)")
        }

        // Route stderr to the logger — per MCP spec, stderr is diagnostic only.
        let loggerRef = stderrLogger
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let logger = loggerRef else { return }
            if let text = String(data: data, encoding: .utf8) {
                for line in text.split(whereSeparator: { $0.isNewline }) where !line.isEmpty {
                    logger(String(line))
                }
            }
        }

        // Observe termination once.
        let termRef = terminationHandler
        process.terminationHandler = { [weak self] proc in
            termRef?(proc.terminationStatus)
            self?.finishReceiveStream()
        }
    }

    // MARK: - MCPTransport

    public func send(_ data: Data) async throws {
        if isClosed() {
            throw MCPError.notConnected
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sendQueue.async { [stdin] in
                do {
                    try stdin.fileHandleForWriting.write(contentsOf: data)
                    try stdin.fileHandleForWriting.write(contentsOf: Data([0x0A]))
                    cont.resume()
                } catch {
                    cont.resume(throwing: MCPError.transportFailed("write failed: \(error.localizedDescription)"))
                }
            }
        }
    }

    public func receive() -> AsyncStream<Data> {
        AsyncStream { continuation in
            self.setReceiveContinuation(continuation)

            var buffer = Data()
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { return }
                buffer.append(chunk)

                while let nlIdx = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<nlIdx)
                    buffer.removeSubrange(buffer.startIndex...nlIdx)
                    // Trim any trailing \r (Windows-line endings defensively).
                    var clean = lineData
                    if clean.last == 0x0D { clean.removeLast() }
                    if clean.isEmpty { continue }
                    continuation.yield(clean)
                }
            }

            continuation.onTermination = { [weak self] _ in
                self?.stdout.fileHandleForReading.readabilityHandler = nil
            }
        }
    }

    public func close() async {
        guard markClosed() else { return }

        // Closing stdin signals EOF to a well-behaved server, which should then
        // exit. Don't force-terminate unless the caller wants to.
        try? stdin.fileHandleForWriting.close()
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil

        finishReceiveStream()
    }

    /// Force terminate the subprocess. Use as a last resort.
    public func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }

    private func finishReceiveStream() {
        stateLock.lock()
        let cont = receiveContinuation
        receiveContinuation = nil
        stateLock.unlock()
        cont?.finish()
    }

    // Synchronous helpers so the async `send`/`close` paths don't touch NSLock
    // directly (unavailable from async contexts in Swift 6).
    private func isClosed() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return closed
    }

    /// Returns true if this call transitioned the transport to closed (so the
    /// caller should proceed with cleanup); false if it was already closed.
    private func markClosed() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        if closed { return false }
        closed = true
        return true
    }

    private func setReceiveContinuation(_ cont: AsyncStream<Data>.Continuation) {
        stateLock.lock()
        defer { stateLock.unlock() }
        receiveContinuation = cont
    }
}
