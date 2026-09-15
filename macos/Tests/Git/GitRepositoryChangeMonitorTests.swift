import Foundation
import Testing
@testable import Ghostty

@MainActor
struct GitRepositoryChangeMonitorTests {
    @Test func unchangedRepositoryUsesThirtySecondFallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = try #require(GitRepositoryChangeMonitor(paths: [root.path]))
        let now = Date()
        #expect(monitor.needsRefresh(now: now))
        #expect(!monitor.needsRefresh(now: now.addingTimeInterval(3)))
        #expect(!monitor.needsRefresh(now: now.addingTimeInterval(29)))
        #expect(monitor.needsRefresh(now: now.addingTimeInterval(30)))
    }

    @Test func nestedFilesAndExternalGitMetadataTriggerRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let worktree = root.appendingPathComponent("worktree/nested/deep")
        let metadata = root.appendingPathComponent("metadata")
        for directory in [worktree, metadata] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = try #require(GitRepositoryChangeMonitor(paths: [
            root.appendingPathComponent("worktree").path, metadata.path,
        ]))
        for file in [worktree.appendingPathComponent("new.txt"), metadata.appendingPathComponent("HEAD")] {
            try await Task.sleep(for: .milliseconds(500))
            _ = monitor.needsRefresh()
            try Data("changed".utf8).write(to: file)
            var observed = false
            for _ in 0..<30 {
                try await Task.sleep(for: .milliseconds(100))
                if monitor.needsRefresh() { observed = true; break }
            }
            #expect(observed)
        }
    }
}
