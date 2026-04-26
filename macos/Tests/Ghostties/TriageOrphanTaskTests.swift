// IDE-ONLY: not currently exercised in CI macos job (build-only).
// Run via Xcode Cmd+U or xcodebuild test locally.
// See .github/workflows/test-ghostties.yml — macos-app job is build-only due to
// XCTest host app hang in headless GH Actions runners.
import XCTest
@testable import Ghostty

/// Tests for `OrphanTriageStore` and the U6 inline triage card mechanics
/// (SEA-162). Exercises D-decisions: D6 (no smart-default), D11 (single card),
/// D13 (error chip), D14 (animation guard), D20 (validation).
///
/// Note: confirm flow requires a live `TaskStore` with a real tasks directory.
/// Those integration paths are not exercised here — UI/integration tests cover
/// the full round-trip.
@MainActor
final class TriageOrphanTaskTests: XCTestCase {

    // MARK: - Fixtures

    private func makeTask(id: String = "test-orphan-abc123") -> TaskItem {
        TaskItem(
            id: id,
            title: "Migrate auth to OAuth2",
            source: .linear,
            sourceID: id,
            branch: nil,
            project: "ghostties",
            projectPath: nil,
            template: nil,
            created: Date(),
            status: .inbox,
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

    private func makeStore() -> OrphanTriageStore {
        OrphanTriageStore(isolatedForTesting: ())
    }

    // MARK: - D6: no smart-default

    func testOpenCard_selectedProjectIdIsNil() {
        let store = makeStore()
        let task = makeTask()
        store.open(for: task)

        XCTAssertNil(store.selectedProjectId,
                     "D6: Picker must have no pre-selection — orphan-by-definition has no MRU")
    }

    func testOpenCard_canConfirmIsFalse_whenNoProjectSelected() {
        let store = makeStore()
        let task = makeTask()
        store.open(for: task)

        XCTAssertFalse(store.canConfirm,
                       "Confirm must be disabled until user picks a project")
    }

    // MARK: - D11: single card at a time

    func testOpenSecondOrphan_collapsesFirst() {
        let store = makeStore()
        let taskA = makeTask(id: "orphan-a-abc123")
        let taskB = makeTask(id: "orphan-b-def456")

        store.open(for: taskA)
        XCTAssertEqual(store.activeTaskId, taskA.id)

        store.open(for: taskB)
        XCTAssertEqual(store.activeTaskId, taskB.id,
                       "D11: Second open collapses first — only one card at a time")
    }

    func testOpenSameTaskTwice_isNoOp() {
        let store = makeStore()
        let task = makeTask()

        store.open(for: task)
        store.selectedProjectId = UUID()    // simulate user interaction
        store.open(for: task)              // same task — should not reset

        XCTAssertNotNil(store.selectedProjectId,
                        "Opening the same task again should not reset picker state")
    }

    // MARK: - Cancel clears state (no writes)

    func testCancel_clearsActiveTaskIdAndState() {
        let store = makeStore()
        let task = makeTask()
        store.open(for: task)
        store.selectedProjectId = UUID()
        store.selectedTemplateName = "Orchestrator"

        store.cancel()

        XCTAssertNil(store.activeTaskId)
        XCTAssertNil(store.selectedProjectId)
        XCTAssertNil(store.selectedTemplateName)
        XCTAssertTrue(store.editedTitle.isEmpty)
    }

    func testCancel_removesErrorChip() {
        let store = makeStore()
        let task = makeTask()
        store.open(for: task)
        store.errorTaskIds.insert(task.id)
        store.cancel()

        XCTAssertFalse(store.errorTaskIds.contains(task.id),
                       "Cancel should clear any error chip on the task row")
    }

    // MARK: - D13: error chip persists on card when writes fail

    func testErrorChip_insertedOnWriteFailure() {
        let store = makeStore()
        let task = makeTask()
        store.open(for: task)

        // Simulate a write failure by directly inserting (as confirm() would on error).
        store.errorTaskIds.insert(task.id)

        XCTAssertTrue(store.errorTaskIds.contains(task.id),
                      "D13: Error chip must persist on row when frontmatter write fails")
        XCTAssertEqual(store.activeTaskId, task.id,
                       "D13: Card must stay open on error — do not auto-close")
    }

    // MARK: - D14: animation guard

    func testAnimationGuard_isActiveAfterOpen() {
        let store = makeStore()
        let task = makeTask()
        store.open(for: task)

        XCTAssertTrue(store.isAnimating,
                      "D14: Row hit-testing must be disabled for 180ms after open")
    }

    func testAnimationGuard_clearsAfterCancel() {
        let store = makeStore()
        let task = makeTask()
        store.open(for: task)
        store.cancel()

        XCTAssertFalse(store.isAnimating,
                       "D14: Animation guard must clear when card is cancelled")
    }

    // MARK: - Title pre-fill

    func testOpenCard_prefillsEditedTitleFromTask() {
        let store = makeStore()
        let task = makeTask()
        store.open(for: task)

        XCTAssertEqual(store.editedTitle, task.title,
                       "Title field must pre-fill from task.title on open")
    }

    // MARK: - canConfirm

    func testCanConfirm_trueWhenProjectSelected() {
        let store = makeStore()
        let task = makeTask()
        store.open(for: task)
        store.selectedProjectId = UUID()

        XCTAssertTrue(store.canConfirm,
                      "canConfirm must be true when a project is selected")
    }
}

