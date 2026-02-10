import Foundation
import Testing
@testable import Ghostree

struct DiffReviewDraftPersistenceTests {
    @Test func saveAndLoadRoundTrip() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostree-diff-review-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = DiffReviewDraftStore(baseDir: tmp)
        let ctx = DiffReviewContext(
            repoRoot: "/tmp/repo",
            source: .pullRequest,
            scope: nil,
            pullRequestNumber: 123
        )

        let now = Date()
        let draft = DiffReviewDraft(threads: [
            DiffThread(
                id: UUID(),
                path: "foo.swift",
                anchor: .line(newLine: 42),
                body: "Looks good but consider renaming this.",
                isResolved: false,
                createdAt: now,
                updatedAt: now
            ),
        ])

        try store.save(draft, context: ctx)

        let loaded = try store.load(context: ctx)
        #expect(loaded == draft)
    }

    @Test func exportJSONIncludesContextAndThreads() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostree-diff-review-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = DiffReviewDraftStore(baseDir: tmp)
        let ctx = DiffReviewContext(
            repoRoot: "/tmp/repo",
            source: .workingTree,
            scope: .all,
            pullRequestNumber: nil
        )

        let draft = DiffReviewDraft(threads: [
            DiffThread(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                path: "bar.ts",
                anchor: .line(newLine: 1),
                body: "Nit: add a blank line here.",
                isResolved: false,
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0)
            ),
        ])

        let json = store.exportJSONString(draft, context: ctx)
        #expect(json.contains("\"repoRoot\"") == true)
        #expect(json.contains("\"threads\"") == true)
        #expect(json.contains("Nit: add a blank line here.") == true)
    }
}

