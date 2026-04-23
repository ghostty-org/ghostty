import Foundation
import GhosttiesCore

/// A generic MCP client. Speaks JSON-RPC 2.0 over any `MCPTransport`. Not
/// Linear-specific, not Sentry-specific — vendor behavior lives outside this
/// type, in whatever logic walks the `tools/list` result.
///
/// Thread safety: as an `actor`, all mutable state (pending request map,
/// connection state) is isolated. `sourceId` is `nonisolated` so callers can
/// log without awaiting.
public actor MCPClient {
    /// Identifier of the source this client represents (e.g. "linear"). Used
    /// for logging so multi-source setups are easy to debug.
    public nonisolated let sourceId: String

    private let transport: MCPTransport

    private var nextId: Int = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var receiveTask: _Concurrency.Task<Void, Never>?
    private var connected = false

    /// - Parameters:
    ///   - transport: A configured transport. Stdio transports must have
    ///     already had `start()` called.
    ///   - sourceId: Logical id (e.g. "linear", "sentry"). Surface-level.
    public init(transport: MCPTransport, sourceId: String) {
        self.transport = transport
        self.sourceId = sourceId
    }

    /// Perform the MCP handshake: send `initialize`, wait for the response,
    /// then fire the `notifications/initialized` notification. Throws if the
    /// server returns a protocol error.
    public func connect(
        clientName: String = "ghostties",
        clientVersion: String = "0.1.0",
        protocolVersion: String = "2024-11-05"
    ) async throws {
        startReceiveLoop()

        let params: JSONValue = .object([
            "protocolVersion": .string(protocolVersion),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string(clientName),
                "version": .string(clientVersion)
            ])
        ])

        _ = try await sendRequest(method: "initialize", params: params)

        // Notify the server we're ready. No response expected.
        let initialized = MCPNotification(method: "notifications/initialized")
        try await transport.send(try initialized.encode())

        connected = true
    }

    /// List all tools exposed by the remote server.
    public func listTools() async throws -> [MCPTool] {
        try ensureConnected()
        let result = try await sendRequest(method: "tools/list", params: nil)
        guard case .array(let arr) = result["tools"] ?? .null else {
            throw MCPError.decodingFailed("tools/list result missing 'tools' array")
        }
        return arr.compactMap(MCPTool.from)
    }

    /// Call a tool by name. Returns the raw result object from the server.
    public func callTool(_ name: String, arguments: JSONValue? = nil) async throws -> JSONValue {
        try ensureConnected()
        let params: JSONValue = .object([
            "name": .string(name),
            "arguments": arguments ?? .object([:])
        ])
        return try await sendRequest(method: "tools/call", params: params)
    }

    /// Graceful shutdown. Cancels the receive loop and closes the transport.
    /// Any outstanding requests are failed with `.notConnected`.
    public func disconnect() async {
        connected = false
        for (_, cont) in pending {
            cont.resume(throwing: MCPError.notConnected)
        }
        pending.removeAll()
        receiveTask?.cancel()
        receiveTask = nil
        await transport.close()
    }

    // MARK: - Internal

    private func ensureConnected() throws {
        if !connected {
            throw MCPError.notConnected
        }
    }

    private func sendRequest(method: String, params: JSONValue?) async throws -> JSONValue {
        let id = nextId
        nextId += 1

        let req = MCPRequest(id: .int(id), method: method, params: params)
        let data: Data
        do {
            data = try req.encode()
        } catch {
            throw MCPError.decodingFailed("encode \(method): \(error.localizedDescription)")
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSONValue, Error>) in
            pending[id] = cont
            _Concurrency.Task {
                do {
                    try await transport.send(data)
                } catch {
                    if let waiter = pending.removeValue(forKey: id) {
                        waiter.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func startReceiveLoop() {
        guard receiveTask == nil else { return }
        let stream = transport.receive()
        receiveTask = _Concurrency.Task { [weak self] in
            for await chunk in stream {
                await self?.handleIncoming(chunk)
            }
            await self?.handleStreamClosed()
        }
    }

    private func handleIncoming(_ data: Data) {
        // Try response first (id + result/error). If no id, treat as a
        // notification — the client currently ignores server notifications
        // but parses them so the stream doesn't stall on malformed frames.
        if let response = try? MCPResponse.decode(data) {
            guard case .int(let id) = response.id else {
                // Null or string ids aren't something we issue; ignore.
                return
            }
            guard let cont = pending.removeValue(forKey: id) else {
                return
            }
            if let err = response.error {
                cont.resume(throwing: MCPError.protocolError(code: err.code, message: err.message))
            } else {
                cont.resume(returning: response.result ?? .null)
            }
            return
        }

        // Fall through: notifications, or unparseable. Nothing to do for now.
        _ = try? MCPNotification.decode(data)
    }

    private func handleStreamClosed() {
        connected = false
        for (_, cont) in pending {
            cont.resume(throwing: MCPError.transportFailed("transport stream closed"))
        }
        pending.removeAll()
    }
}
