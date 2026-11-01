import Foundation

private enum HermesLocalStatusProbe {
    static func load() async throws -> [String: HermesPaneStatus.Snapshot] {
        let result = try await GitProcessRunner().run(
            executablePath: "/usr/bin/python3",
            arguments: ["-"],
            workingDirectory: "/tmp",
            stdin: Data(HermesPaneStatus.localScript.utf8),
            maxOutputBytes: 1_048_576,
            timeout: 5
        )
        guard result.isSuccess else {
            throw GitExecutionError.processFailed(
                exitCode: result.exitCode,
                stderr: result.stderrString
            )
        }
        do {
            return try JSONDecoder().decode(
                [String: HermesPaneStatus.Snapshot].self,
                from: result.stdout
            )
        } catch {
            throw GitExecutionError.executionFailed(
                "Could not decode the local Hermes status snapshot: \(error.localizedDescription)"
            )
        }
    }
}

/// Shares a single local process-table probe across every terminal controller.
actor HermesLocalStatusCache {
    typealias Instant = ContinuousClock.Instant
    typealias SnapshotMap = [String: HermesPaneStatus.Snapshot]
    typealias Loader = @Sendable () async throws -> SnapshotMap

    static let shared = HermesLocalStatusCache()
    static let successTTL = Duration.seconds(2)
    static let failureBackoff = Duration.seconds(2)

    private struct CachedSnapshots {
        let values: SnapshotMap
        let expiresAt: Instant
    }

    private struct CachedFailure {
        let error: Error
        let retryAfter: Instant
    }

    private struct Flight {
        let token: UUID
        let task: Task<SnapshotMap, Error>
    }

    private let now: @Sendable () -> Instant
    private let load: Loader
    private var cachedSnapshots: CachedSnapshots?
    private var cachedFailure: CachedFailure?
    private var inFlight: Flight?

    init(
        now: @escaping @Sendable () -> Instant = { ContinuousClock.now },
        load: Loader? = nil
    ) {
        self.now = now
        self.load = load ?? { try await HermesLocalStatusProbe.load() }
    }

    func snapshot(tty: String) async throws -> HermesPaneStatus.Snapshot? {
        try Task.checkCancellation()
        let requestTime = now()
        if let cachedSnapshots {
            if requestTime < cachedSnapshots.expiresAt {
                return cachedSnapshots.values[tty]
            }
            self.cachedSnapshots = nil
        }
        if let cachedFailure {
            if requestTime < cachedFailure.retryAfter {
                throw cachedFailure.error
            }
            self.cachedFailure = nil
        }

        let flight: Flight
        if let inFlight {
            flight = inFlight
        } else {
            let token = UUID()
            let startedAt = now()
            let load = self.load
            let task = Task.detached(priority: .utility) { [weak self] in
                do {
                    let values = try await load()
                    await self?.finishSuccess(
                        token: token,
                        startedAt: startedAt,
                        values: values
                    )
                    return values
                } catch {
                    await self?.finishFailure(token: token, error: error)
                    throw error
                }
            }
            let startedFlight = Flight(token: token, task: task)
            inFlight = startedFlight
            flight = startedFlight
        }

        let values = try await flight.task.value
        try Task.checkCancellation()
        return values[tty]
    }

    private func finishSuccess(token: UUID, startedAt: Instant, values: SnapshotMap) {
        guard inFlight?.token == token else { return }
        cachedSnapshots = CachedSnapshots(
            values: values,
            expiresAt: startedAt.advanced(by: Self.successTTL)
        )
        cachedFailure = nil
        inFlight = nil
    }

    private func finishFailure(token: UUID, error: Error) {
        guard inFlight?.token == token else { return }
        cachedFailure = CachedFailure(
            error: error,
            retryAfter: now().advanced(by: Self.failureBackoff)
        )
        inFlight = nil
    }
}
