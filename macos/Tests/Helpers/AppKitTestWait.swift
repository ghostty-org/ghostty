import Foundation
import Testing

@MainActor
func waitForAppKit(
    timeout: Duration = .seconds(3),
    sourceLocation: SourceLocation = #_sourceLocation,
    until condition: () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        try #require(clock.now < deadline, "Timed out waiting for AppKit completion", sourceLocation: sourceLocation)
        try await Task.sleep(for: .milliseconds(10))
    }
}
