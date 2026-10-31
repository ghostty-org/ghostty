import Foundation
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct AgentHookPresenceCacheTests {
    private actor Reads {
        var count = 0
        var pending: [Int: CheckedContinuation<Bool, Never>] = [:]
        func read() async -> Bool {
            let index = count
            count += 1
            return await withCheckedContinuation { pending[index] = $0 }
        }
        func finish(_ index: Int, value: Bool) { pending.removeValue(forKey: index)?.resume(returning: value) }
    }

    private func settle(_ condition: () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Background presence read did not settle")
    }

    @Test func panesShareOneReadAndExpiredResultsRefreshWithoutBlocking() async throws {
        let reads = Reads()
        let cache = AgentHookPresenceCache(maxAge: 5) { _ in await reads.read() }
        let now = Date()
        for _ in 0..<100 { #expect(cache.isInstalled(.hermes, now: now) == nil) }
        try await settle { await reads.count == 1 }
        await reads.finish(0, value: true)
        try await settle { cache.isInstalled(.hermes, now: now) == true }
        for _ in 0..<100 { #expect(cache.isInstalled(.hermes, now: now.addingTimeInterval(4)) == true) }
        #expect(await reads.count == 1)
        #expect(cache.isInstalled(.hermes, now: now.addingTimeInterval(6)) == true)
        try await settle { await reads.count == 2 }
        await reads.finish(1, value: false)
        try await settle { cache.isInstalled(.hermes, now: now.addingTimeInterval(6)) == false }
    }

    @Test func installationNotificationDiscardsAnObsoleteRead() async throws {
        let reads = Reads()
        let cache = AgentHookPresenceCache { _ in await reads.read() }
        #expect(cache.isInstalled(.hermes) == nil)
        try await settle { await reads.count == 1 }
        NotificationCenter.default.post(name: AgentHookInstaller.didChangeNotification, object: nil,
                                        userInfo: [AgentHookInstaller.changedAgentUserInfoKey: "hermes"])
        #expect(cache.isInstalled(.hermes) == nil)
        try await settle { await reads.count == 2 }
        await reads.finish(1, value: false)
        try await settle { cache.isInstalled(.hermes) == false }
        await reads.finish(0, value: true)
        try await Task.sleep(for: .milliseconds(20))
        #expect(cache.isInstalled(.hermes) == false)
    }

    @Test func yamlPresenceRetainsStaleInstallationSemanticsWithoutAuditingHelper() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = AgentHookInstaller(homeURL: home)
        try installer.install(.hermes)
        let helper = home.appendingPathComponent(".config/oh-my-ghostty/agent-status/hermes-hook.sh")
        try FileManager.default.removeItem(at: helper)
        #expect(installer.installationState(.hermes) == .updateAvailable)
        #expect(installer.isInstalled(.hermes))
        try installer.uninstall(.hermes)
        #expect(!installer.isInstalled(.hermes))
    }

    @Test func unicodeConfigurationPresenceScanIsBounded() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appendingPathComponent(".hermes/config.yaml")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = String(repeating: "# \u{4E2D}\u{6587} configuration\n", count: 20_000)
            + "# >>> OMG agent-status hooks (managed; do not edit) >>>\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        let installer = AgentHookInstaller(homeURL: home)
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<20 { #expect(installer.isInstalled(.hermes)) }
        let elapsed = start.duration(to: clock.now)
        print("20 YAML presence scans: \(elapsed)")
        #expect(elapsed < .seconds(1))
    }
}
