import XCTest
import GhosttiesCore
@testable import GhosttiesMCPClient

/// Tests for `MCPClient` — notification routing and connect-timeout behavior.
///
/// Uses local mock transports; not promoted to shared code (YAGNI) — if a
/// second test file needs them, lift then.
final class MCPClientTests: XCTestCase {

    // MARK: - Fix 2: notification handler

    func testNotificationHandlerFiresOnIncomingNotification() async throws {
        let transport = MockTransport()
        let received = NotificationSink()

        let client = MCPClient(
            transport: transport,
            sourceId: "test",
            onNotification: { note in
                await received.record(note)
            }
        )

        // Drive the handshake in the background so we can answer it.
        let connectTask = _Concurrency.Task {
            try await client.connect(timeout: .seconds(2))
        }

        // Answer the initialize request so connect() returns.
        let initializeFrame = try await transport.awaitSentFrame()
        try transport.inject(response: initializeFrame.idForEchoedResponse, result: .object([:]))
        _ = try await transport.awaitSentFrame()  // notifications/initialized
        try await connectTask.value

        // Now inject a notification. No id → routes to handler.
        let notif = MCPNotification(
            method: "notifications/resources/updated",
            params: .object(["uri": .string("task://abc")])
        )
        try transport.inject(notification: notif)

        // Give the receive loop time to drain.
        try await _Concurrency.Task.sleep(for: .milliseconds(50))

        let count = await received.count()
        XCTAssertEqual(count, 1, "notification handler should have fired once")
        let first = await received.first()
        XCTAssertEqual(first?.method, "notifications/resources/updated")
        XCTAssertEqual(first?.params?["uri"]?.string, "task://abc")

        await client.disconnect()
    }

    // MARK: - Fix 3: connect timeout

    func testConnectThrowsTimeoutWhenServerNeverResponds() async throws {
        let transport = MockTransport()  // never injects a response
        let client = MCPClient(transport: transport, sourceId: "test")

        let start = ContinuousClock.now
        do {
            try await client.connect(timeout: .milliseconds(50))
            XCTFail("connect should have timed out")
        } catch let error as MCPError {
            guard case .connectionTimeout = error else {
                XCTFail("expected .connectionTimeout, got \(error)")
                return
            }
        }
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .milliseconds(500),
                          "timeout should fire promptly, not wait for the default")

        await client.disconnect()
    }
}

// MARK: - Mock transport

/// Minimal in-memory transport. Captures every `send()` for assertions and
/// exposes an `inject()` for pushing server-originated frames back to the
/// client. Not concurrent-safe for multiple writers; fine for one test at a time.
private final class MockTransport: MCPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sentFrames: [Data] = []
    private var sendWaiters: [CheckedContinuation<Data, Error>] = []
    private var continuation: AsyncStream<Data>.Continuation?
    private lazy var stream: AsyncStream<Data> = AsyncStream { cont in
        self.continuation = cont
    }

    func send(_ data: Data) async throws {
        lock.lock()
        sentFrames.append(data)
        let waiter = sendWaiters.isEmpty ? nil : sendWaiters.removeFirst()
        lock.unlock()
        waiter?.resume(returning: data)
    }

    func receive() -> AsyncStream<Data> {
        return stream
    }

    func close() async {
        continuation?.finish()
    }

    /// Wait for the next frame the client sends.
    func awaitSentFrame() async throws -> SentFrame {
        let data: Data = try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if !sentFrames.isEmpty {
                let d = sentFrames.removeFirst()
                lock.unlock()
                cont.resume(returning: d)
                return
            }
            sendWaiters.append(cont)
            lock.unlock()
        }
        return SentFrame(data: data)
    }

    /// Push a response back to the client, using the id from a captured frame.
    func inject(response id: MCPRequestId, result: JSONValue) throws {
        let resp = MCPResponse(id: id, result: result)
        let data = try resp.encode()
        continuation?.yield(data)
    }

    /// Push a notification back to the client.
    func inject(notification: MCPNotification) throws {
        let data = try notification.encode()
        continuation?.yield(data)
    }
}

private struct SentFrame {
    let data: Data

    /// Pull the `id` out of a sent request so the mock can echo it in a response.
    var idForEchoedResponse: MCPRequestId {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .null }
        return MCPRequestId.from(obj["id"])
    }
}

/// Actor-isolated sink so the `@Sendable` handler closure can record state.
private actor NotificationSink {
    private var notifications: [MCPNotification] = []

    func record(_ n: MCPNotification) {
        notifications.append(n)
    }

    func count() -> Int { notifications.count }
    func first() -> MCPNotification? { notifications.first }
}
