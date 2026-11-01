import Foundation
import Testing
@testable import Ghostty

@Suite(.serialized)
struct AgentHermesLocalStatusCacheTests {
    private enum ProbeError: Error, Equatable, Sendable {
        case unavailable
    }

    private actor ControlledLoader {
        private var calls = 0
        private var pending: [Int: CheckedContinuation<[String: HermesPaneStatus.Snapshot], Error>] = [:]
        private var startWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

        func load() async throws -> [String: HermesPaneStatus.Snapshot] {
            calls += 1
            let call = calls
            let observers = startWaiters.removeValue(forKey: call) ?? []
            observers.forEach { $0.resume() }
            return try await withCheckedThrowingContinuation { continuation in
                pending[call] = continuation
            }
        }

        func callCount() -> Int { calls }

        func waitForCallCount(_ expected: Int) async {
            guard calls < expected else { return }
            await withCheckedContinuation { continuation in
                startWaiters[expected, default: []].append(continuation)
            }
        }

        func succeed(_ call: Int, with value: [String: HermesPaneStatus.Snapshot]) {
            pending.removeValue(forKey: call)?.resume(returning: value)
        }

        func fail(_ call: Int, with error: Error) {
            pending.removeValue(forKey: call)?.resume(throwing: error)
        }
    }

    private actor StartBarrier {
        private let participants: Int
        private var arrived = 0
        private var released = false
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
        private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

        init(participants: Int) {
            self.participants = participants
        }

        func arriveAndWait() async {
            arrived += 1
            if arrived == participants {
                released = true
                releaseWaiters.forEach { $0.resume() }
                arrivalWaiters.forEach { $0.resume() }
                releaseWaiters.removeAll()
                arrivalWaiters.removeAll()
                return
            }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        func waitUntilReleased() async {
            guard !released else { return }
            await withCheckedContinuation { arrivalWaiters.append($0) }
        }
    }

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant = ContinuousClock().now

        func now() -> ContinuousClock.Instant {
            lock.lock()
            defer { lock.unlock() }
            return instant
        }

        func advance(by duration: Duration) {
            lock.lock()
            instant = instant.advanced(by: duration)
            lock.unlock()
        }
    }

    private func makeCache(
        clock: TestClock,
        loader: ControlledLoader
    ) -> HermesLocalStatusCache {
        HermesLocalStatusCache(
            now: { clock.now() },
            load: { try await loader.load() }
        )
    }

    private func snapshot(
        _ pgid: Int,
        state: String = "working",
        revision: String? = nil
    ) -> HermesPaneStatus.Snapshot {
        .init(
            pgid: pgid,
            conversation: nil,
            cwd: "/tmp",
            state: state,
            revision: revision ?? "client:\(pgid)"
        )
    }

    @Test func seventyFiveConcurrentTTYRequestsShareOneProbe() async throws {
        let clock = TestClock()
        let loader = ControlledLoader()
        let cache = makeCache(clock: clock, loader: loader)
        let count = 75
        let barrier = StartBarrier(participants: count)
        let values = Dictionary(uniqueKeysWithValues: (0..<count).map {
            ("tty-\($0)", snapshot($0 + 100))
        })
        let requests = (0..<count).map { index in
            Task {
                await barrier.arriveAndWait()
                return try await cache.snapshot(tty: "tty-\(index)")
            }
        }

        await barrier.waitUntilReleased()
        await loader.waitForCallCount(1)
        for _ in 0..<5 { await Task.yield() }
        #expect(await loader.callCount() == 1)

        await loader.succeed(1, with: values)
        for (index, request) in requests.enumerated() {
            #expect(try await request.value == values["tty-\(index)"])
        }
        #expect(await loader.callCount() == 1)
    }

    @Test func successfulSnapshotIsReusedUntilTTLExpiresFromProbeStart() async throws {
        let clock = TestClock()
        let loader = ControlledLoader()
        let cache = makeCache(clock: clock, loader: loader)
        let old = snapshot(201)
        let first = Task { try await cache.snapshot(tty: "tty-a") }
        await loader.waitForCallCount(1)

        clock.advance(by: .seconds(1))
        await loader.succeed(1, with: ["tty-a": old])
        #expect(try await first.value == old)

        clock.advance(by: .milliseconds(900))
        #expect(try await cache.snapshot(tty: "tty-a") == old)
        #expect(await loader.callCount() == 1)

        clock.advance(by: .milliseconds(200))
        let refreshed = Task { try await cache.snapshot(tty: "tty-a") }
        await loader.waitForCallCount(2)
        let new = snapshot(202, state: "done")
        await loader.succeed(2, with: ["tty-a": new])
        #expect(try await refreshed.value == new)
        #expect(await loader.callCount() == 2)
    }

    @Test func cachedMapIsIsolatedByTTYAndMissingTTYReturnsNil() async throws {
        let clock = TestClock()
        let loader = ControlledLoader()
        let cache = makeCache(clock: clock, loader: loader)
        let first = Task { try await cache.snapshot(tty: "tty-a") }
        await loader.waitForCallCount(1)
        let values = [
            "tty-a": snapshot(301),
            "tty-b": snapshot(302, state: "idle"),
        ]
        await loader.succeed(1, with: values)

        #expect(try await first.value == values["tty-a"])
        #expect(try await cache.snapshot(tty: "tty-b") == values["tty-b"])
        #expect(try await cache.snapshot(tty: "tty-missing") == nil)
        #expect(await loader.callCount() == 1)
    }

    @Test func failedProbeThrowsAndRetriesOnlyAfterTwoSecondBackoff() async throws {
        let clock = TestClock()
        let loader = ControlledLoader()
        let cache = makeCache(clock: clock, loader: loader)
        let previous = snapshot(401)
        let seed = Task { try await cache.snapshot(tty: "tty-a") }
        await loader.waitForCallCount(1)
        await loader.succeed(1, with: ["tty-a": previous])
        #expect(try await seed.value == previous)

        clock.advance(by: .seconds(2.1))
        let failed = Task { try await cache.snapshot(tty: "tty-a") }
        await loader.waitForCallCount(2)
        clock.advance(by: .seconds(30))
        await loader.fail(2, with: ProbeError.unavailable)
        await #expect(throws: ProbeError.unavailable) {
            try await failed.value
        }

        await #expect(throws: ProbeError.unavailable) {
            try await cache.snapshot(tty: "tty-a")
        }
        #expect(await loader.callCount() == 2)

        clock.advance(by: .milliseconds(1_900))
        await #expect(throws: ProbeError.unavailable) {
            try await cache.snapshot(tty: "tty-a")
        }
        #expect(await loader.callCount() == 2)

        clock.advance(by: .milliseconds(200))
        let retry = Task { try await cache.snapshot(tty: "tty-a") }
        await loader.waitForCallCount(3)
        let recovered = snapshot(402, state: "working", revision: "new")
        await loader.succeed(3, with: ["tty-a": recovered])
        #expect(try await retry.value == recovered)
        #expect(await loader.callCount() == 3)
    }

    @Test func cancellingOneWaiterDoesNotCancelTheSharedProbe() async throws {
        let clock = TestClock()
        let loader = ControlledLoader()
        let cache = makeCache(clock: clock, loader: loader)
        let cancelledWaiter = Task { try await cache.snapshot(tty: "tty-a") }
        await loader.waitForCallCount(1)
        let survivingWaiter = Task { try await cache.snapshot(tty: "tty-b") }
        await Task.yield()
        cancelledWaiter.cancel()

        let expected = snapshot(501)
        await loader.succeed(1, with: ["tty-a": expected, "tty-b": expected])
        #expect(try await survivingWaiter.value == expected)
        await #expect(throws: CancellationError.self) {
            try await cancelledWaiter.value
        }
        #expect(await loader.callCount() == 1)
    }

    @Test func slowExpiredProbeIsFollowedByOneSharedRefresh() async throws {
        let clock = TestClock()
        let loader = ControlledLoader()
        let cache = makeCache(clock: clock, loader: loader)
        let old = snapshot(601)
        let first = Task { try await cache.snapshot(tty: "tty-a") }
        await loader.waitForCallCount(1)

        clock.advance(by: .seconds(3))
        await loader.succeed(1, with: ["tty-a": old])
        #expect(try await first.value == old)

        let barrier = StartBarrier(participants: 2)
        let refreshed = snapshot(602, state: "done")
        let refreshes = ["tty-a", "tty-b"].map { tty in
            Task {
                await barrier.arriveAndWait()
                return try await cache.snapshot(tty: tty)
            }
        }
        await barrier.waitUntilReleased()
        await loader.waitForCallCount(2)
        for _ in 0..<5 { await Task.yield() }
        #expect(await loader.callCount() == 2)
        await loader.succeed(2, with: ["tty-a": refreshed])
        #expect(try await refreshes[0].value == refreshed)
        #expect(try await refreshes[1].value == nil)
        #expect(await loader.callCount() == 2)
    }
}
