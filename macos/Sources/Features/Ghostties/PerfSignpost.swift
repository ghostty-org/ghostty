import OSLog

/// Lightweight perf instrumentation. All signposts land in Instruments
/// under Points of Interest (subsystem: com.mitchellh.ghostty, category: perf).
/// Zero cost when Instruments is not attached.
enum Perf {
    static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "perf"
    )

    /// Wrap a synchronous block in a begin/end signpost interval.
    @inlinable @discardableResult
    static func measure<T>(_ name: StaticString, _ block: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try block()
    }

    /// Publish only when `current` differs from the last-published snapshot.
    ///
    /// Emits a "suppressed" event when the value hasn't changed so Instruments
    /// can show the would-have-fired rate alongside actual publishes. This is
    /// the fix pattern for objectWillChange-per-tick churn (SEA-214 shape).
    static func publishIfChanged<T: Equatable>(
        _ name: StaticString,
        current: T,
        cached: inout T?,
        publish: () -> Void
    ) {
        guard cached != current else {
            signposter.emitEvent("no-op publish suppressed", "\(name, privacy: .public)")
            return
        }
        cached = current
        publish()
    }
}
