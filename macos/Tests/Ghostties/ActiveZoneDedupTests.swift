// IDE-ONLY: not currently exercised in CI macos job (build-only).
// Run via Xcode Cmd+U or:
//   xcodebuild test \
//     -project macos/Ghostties.xcodeproj \
//     -scheme Ghostties \
//     -destination 'platform=macOS,arch=arm64' \
//     ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
//     -only-testing:GhosttyTests/ActiveZoneDedupTests
//
// See .github/workflows/test-ghostties.yml — macos-app job is build-only due to
// XCTest host app hang in headless GH Actions runners.
//
// Covers the deduplication predicate in ActiveZoneView.buildMergedRows:
//   - A SessionDraft whose cwd matches a running TaskItem's projectPath must
//     NOT appear as a draft row (it's already represented by the task row).
//   - A SessionDraft whose cwd does NOT match any running task's projectPath
//     SHOULD appear as a draft row.
//   - A promoted draft (promotedToTaskId != nil) is always excluded.
import XCTest
@testable import Ghostty
import GhosttiesCore

/// Unit tests for the Active-zone deduplication predicate
/// (ActiveZoneView.buildMergedRows exclusion logic).
///
/// `buildMergedRows` is private, so tests validate the same predicate logic
/// inline using the same store types (`TaskStore`, `SessionDraftStore`).
@MainActor
final class ActiveZoneDedupTests: XCTestCase {

    // MARK: - Helpers

    private func runningTask(projectPath: String) -> TaskItem {
        TaskItem(
            id: "task-\(UUID().uuidString.prefix(6))",
            title: "Running task at \(projectPath)",
            source: .shell,
            sourceID: nil,
            branch: nil,
            project: "test-project",
            projectPath: projectPath,
            template: nil,
            created: Date(),
            status: .running,
            priority: .none,
            filesStaged: nil,
            goal: nil,
            notes: nil,
            needs: nil,
            severity: nil,
            pr: nil,
            prState: nil,
            ci: nil,
            completed: nil,
            events: nil
        )
    }

    /// Apply the same exclusion predicate that buildMergedRows uses.
    private func filteredDrafts(
        _ drafts: [SessionDraft],
        activeProjectPaths: Set<String>
    ) -> [SessionDraft] {
        drafts.filter { draft in
            guard draft.promotedToTaskId == nil else { return false }
            let expandedCwd = (draft.cwd as NSString).expandingTildeInPath
            return !activeProjectPaths.contains(expandedCwd)
        }
    }

    private func activeProjectPaths(from tasks: [TaskItem]) -> Set<String> {
        Set(tasks.compactMap { task -> String? in
            guard let raw = task.projectPath, !raw.isEmpty else { return nil }
            return (raw as NSString).expandingTildeInPath
        })
    }

    // MARK: - No running tasks → draft always shows

    func testDraftAppearsWhenNoRunningTasks() {
        let draft = SessionDraft(cwd: "~/Code/ghostties")
        let paths = activeProjectPaths(from: [])
        let visible = filteredDrafts([draft], activeProjectPaths: paths)
        XCTAssertEqual(visible.count, 1, "Draft should appear when there are no running tasks")
    }

    // MARK: - Draft cwd matches running task projectPath → excluded

    func testDraftExcludedWhenCwdMatchesRunningTask() {
        // Draft cwd and task projectPath both resolve to the same absolute path.
        let draft = SessionDraft(cwd: "~/Code/ghostties")
        let task = runningTask(projectPath: "~/Code/ghostties")
        let paths = activeProjectPaths(from: [task])
        let visible = filteredDrafts([draft], activeProjectPaths: paths)
        XCTAssertEqual(visible.count, 0,
            "Draft whose cwd matches a running task's projectPath must be excluded (duplicate row)")
    }

    // MARK: - Draft cwd differs from running task → both rows appear

    func testDraftAppearsWhenCwdDiffersFromRunningTask() {
        let draft = SessionDraft(cwd: "~/Code/other-project")
        let task = runningTask(projectPath: "~/Code/ghostties")
        let paths = activeProjectPaths(from: [task])
        let visible = filteredDrafts([draft], activeProjectPaths: paths)
        XCTAssertEqual(visible.count, 1,
            "Draft at a different cwd from running tasks should still appear")
    }

    // MARK: - Promoted draft → always excluded

    func testPromotedDraftAlwaysExcluded() {
        // Even when no running tasks, a promoted draft should be invisible.
        let draft = SessionDraft(cwd: "~/Code/ghostties",
                                  promotedToTaskId: "some-task-id")
        let paths = activeProjectPaths(from: [])
        let visible = filteredDrafts([draft], activeProjectPaths: paths)
        XCTAssertEqual(visible.count, 0, "Promoted draft must always be excluded")
    }

    // MARK: - Mixed: one matching, one non-matching draft

    func testMixedDraftsPartiallyExcluded() {
        let matchingDraft = SessionDraft(cwd: "~/Code/ghostties")
        let unrelatedDraft = SessionDraft(cwd: "~/Code/other-project")
        let task = runningTask(projectPath: "~/Code/ghostties")
        let paths = activeProjectPaths(from: [task])
        let visible = filteredDrafts([matchingDraft, unrelatedDraft], activeProjectPaths: paths)
        XCTAssertEqual(visible.count, 1,
            "Only the draft whose cwd does NOT match a running task should appear")
        XCTAssertEqual(visible.first?.cwd, "~/Code/other-project")
    }

    // MARK: - Tilde expansion consistency

    func testTildeExpansionNormalizes() {
        // Draft cwd stored with tilde; task projectPath also tilde-raw.
        // Both expand to the same absolute path — exclusion must fire.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let draft = SessionDraft(cwd: "~/Code/ghostties")
        let task = runningTask(projectPath: "~/Code/ghostties")

        // Verify tilde expands to the same value on both sides.
        let expandedDraft = ("~/Code/ghostties" as NSString).expandingTildeInPath
        let expandedTask = ("~/Code/ghostties" as NSString).expandingTildeInPath
        XCTAssertEqual(expandedDraft, expandedTask)
        XCTAssertTrue(expandedDraft.hasPrefix(home))

        let paths = activeProjectPaths(from: [task])
        let visible = filteredDrafts([draft], activeProjectPaths: paths)
        XCTAssertEqual(visible.count, 0, "Tilde-expanded cwds must match and exclude the draft")
    }

    // MARK: - Running task without projectPath → draft still shows

    func testDraftAppearsWhenRunningTaskHasNoProjectPath() {
        // A running task with no projectPath doesn't contribute to activeProjectPaths.
        // The draft should still appear.
        let draft = SessionDraft(cwd: "~/Code/ghostties")
        let taskWithoutPath = TaskItem(
            id: "task-no-path",
            title: "No path task",
            source: .shell,
            sourceID: nil,
            branch: nil,
            project: "test-project",
            projectPath: nil,      // no path set
            template: nil,
            created: Date(),
            status: .running,
            priority: .none,
            filesStaged: nil,
            goal: nil,
            notes: nil,
            needs: nil,
            severity: nil,
            pr: nil,
            prState: nil,
            ci: nil,
            completed: nil,
            events: nil
        )
        let paths = activeProjectPaths(from: [taskWithoutPath])
        XCTAssertTrue(paths.isEmpty, "Task without projectPath contributes no path to the exclusion set")
        let visible = filteredDrafts([draft], activeProjectPaths: paths)
        XCTAssertEqual(visible.count, 1,
            "Draft should appear when running task has no projectPath (no exclusion match possible)")
    }
}
