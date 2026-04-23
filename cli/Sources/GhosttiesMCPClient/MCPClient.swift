import Foundation
import GhosttiesCore

/// Closure invoked for every JSON-RPC notification (message with no `id`) the
/// server sends. Pass `nil` to `MCPClient.init` to silently drop notifications.
public typealias MCPNotificationHandler = @Sendable (MCPNotification) async -> Void

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
    private let onNotification: MCPNotificationHandler?

    private var nextId: Int = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var receiveTask: _Concurrency.Task<Void, Never>?
    private var connected = false

    /// - Parameters:
    ///   - transport: A configured transport. Stdio transports must have
    ///     already had `start()` called.
    ///   - sourceId: Logical id (e.g. "linear", "sentry"). Surface-level.
    ///   - onNotification: Optional handler invoked for every server
    ///     notification (JSON-RPC message with no `id`). If `nil`,
    ///     notifications are parsed then dropped — preserves prior behavior.
    public init(
        transport: MCPTransport,
        sourceId: String,
        onNotification: MCPNotificationHandler? = nil
    ) {
        self.transport = transport
        self.sourceId = sourceId
        self.onNotification = onNotification
    }

    /// Perform the MCP handshake: send `initialize`, wait for the response,
    /// then fire the `notifications/initialized` notification. Throws if the
    /// server returns a protocol error, or `MCPError.connectionTimeout` if the
    /// handshake doesn't complete within `timeout`.
    ///
    /// - Parameter timeout: Maximum time to wait for the `initialize` response.
    ///   Default is 10 seconds — chosen to feel human-impatient without being
    ///   flaky over slow SSE-initiating servers.
    public func connect(
        timeout: Duration = .seconds(10),
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

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try await self.sendRequest(method: "initialize", params: params)
            }
            group.addTask {
                try await _Concurrency.Task.sleep(for: timeout)
                throw MCPError.connectionTimeout(timeout)
            }

            // Wait for whichever finishes first; cancel the loser.
            do {
                try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                // If the handshake is still in flight, fail its continuation
                // so the caller isn't left holding a zombie request.
                self.failPendingInitialize(error: error)
                throw error
            }
        }

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

    /// Fail any outstanding initialize continuation so the caller doesn't hang
    /// after a timeout. In practice `initialize` is always id=1 when `connect`
    /// is called on a fresh client, but we fail every pending request to be
    /// safe — nothing legitimate should be in flight during handshake.
    private func failPendingInitialize(error: Error) {
        for (_, cont) in pending {
            cont.resume(throwing: error)
        }
        pending.removeAll()
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

    private func handleIncoming(_ data: Data) async {
        // Peek at the raw shape: a notification is a message with no `id`
        // field at all. A response carries `result` or `error`. Checking the
        // raw dictionary avoids MCPResponse.decode succeeding on a
        // notification (which it does, because id defaults to .null).
        let hasId: Bool = {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            return obj["id"] != nil
        }()

        if hasId, let response = try? MCPResponse.decode(data) {
            guard case .int(let id) = response.id else {
                // String / null ids aren't something we issue; ignore.
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

        // No id → notification. Decode and route to the caller's handler.
        if let notification = try? MCPNotification.decode(data) {
            if let onNotification {
                await onNotification(notification)
            }
        }
    }

    private func handleStreamClosed() {
        connected = false
        for (_, cont) in pending {
            cont.resume(throwing: MCPError.transportFailed("transport stream closed"))
        }
        pending.removeAll()
    }
}
