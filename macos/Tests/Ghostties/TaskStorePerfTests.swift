import XCTest
@testable import Ghostty

/// Performance baselines for TaskStore's lane recomputation and load path.
///
/// Run with:  xcodebuild test -scheme Ghostties -only-testing GhosttyTests/TaskStorePerfTests
///
/// XCTest records timing baselines automatically. If recomputeLanes() regresses
/// (e.g. computed props re-introduced instead of stored @Published arrays), these
/// tests will show a measurable timing increase.
@MainActor
final class TaskStorePerfTests: XCTestCase {

    // MARK: - Helpers

    private func makeMarkdown(id: String, status: String, source: String = "shell") -> String {
        """
        ---
        title: Stress task \(id)
        source: \(source)
        source-id: \(id)
        project: ghostties
        created: 2026-01-01T00:00:00Z
        status: \(status)
        ---

        Goal body for task \(id).
        """
    }

    private func makeTasks(count: Int) -> [TaskItem] {
        let statuses = ["running", "backlog", "done", "needsYou", "inbox", "review"]
        return (0..<count).compactMap { i in
            let status = statuses[i % statuses.count]
            let markdown = makeMarkdown(id: "STRESS-\(i)", status: status, source: i % 2 == 0 ? "shell" : "github")
            return TaskFixtureParser.parse(markdown: markdown, filename: "stress-\(i)")
        }
    }

    // MARK: - Lane recomputation at scale

    func testRecomputeLanes_10Tasks() async {
        let store = TaskStore()
        store.injectTasksForTesting(makeTasks(count: 10))
        measure {
            store.recomputeLanesForTesting()
        }
    }

    func testRecomputeLanes_50Tasks() async {
        let store = TaskStore()
        store.injectTasksForTesting(makeTasks(count: 50))
        measure {
            store.recomputeLanesForTesting()
        }
    }

    func testRecomputeLanes_100Tasks() async {
        let store = TaskStore()
        store.injectTasksForTesting(makeTasks(count: 100))
        measure {
            store.recomputeLanesForTesting()
        }
    }

    func testRecomputeLanes_200Tasks() async {
        let store = TaskStore()
        store.injectTasksForTesting(makeTasks(count: 200))
        measure {
            store.recomputeLanesForTesting()
        }
    }

    // MARK: - Parse throughput (simulates loadFromDisk file loop)

    func testParseThroughput_100Files() {
        let markdowns = (0..<100).map { makeMarkdown(id: "P-\($0)", status: "backlog") }
        measure {
            for (i, md) in markdowns.enumerated() {
                _ = TaskFixtureParser.parse(markdown: md, filename: "p-\(i)")
            }
        }
    }
}
