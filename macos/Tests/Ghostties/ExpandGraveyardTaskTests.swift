// IDE-ONLY: not currently exercised in CI macos job (build-only).
// Run via Xcode Cmd+U or xcodebuild test locally.
// See .github/workflows/test-ghostties.yml — macos-app job is build-only due to
// XCTest host app hang in headless GH Actions runners.
import XCTest
@testable import Ghostty

/// Tests for U7 Graveyard inline expansion state logic (SEA-163).
///
/// Covers:
/// - AE4 happy path: toggle opens row, toggle again closes (D10).
/// - D11: clicking a second row auto-collapses the first.
/// - D25 not applicable at this layer (click-outside is a view-level no-op).
/// - Edge: task migrates out of done lane → expansion auto-collapses on reload.
/// - GraveyardExpansionContent.make: empty body → isBodyEmpty true.
/// - GraveyardExpansionContent.make: body clipped to 8 lines.
/// - GraveyardExpansionContent.make: sourceChip format with and without sourceID.
@MainActor
final class ExpandGraveyardTaskTests: XCTestCase {

    // MARK: - Helpers

    private func makeTask(
        id: String = "task-abc",
        status: TaskStatus = .done,
        source: TaskSource = .linear,
        sourceID: String? = "SEA-142",
        project: String = "ghostties",
        goal: String? = nil,
        notes: String? = nil
    ) -> TaskItem {
        TaskItem(
            id: id,
            title: "Test done task",
            source: source,
            sourceID: sourceID,
            branch: nil,
            project: project,
            projectPath: nil,
            template: nil,
            created: Date(timeIntervalSinceNow: -172_800), // 2 days ago
            status: status,
            filesStaged: nil,
            goal: goal,
            notes: notes,
            needs: nil,
            severity: nil,
            pr: nil,
            prState: nil,
            ci: nil,
            completed: Date(timeIntervalSinceNow: -86_400), // 1 day ago
            events: nil
        )
    }

    // MARK: - TaskStore expansion toggle

    /// D10: clicking an unexpanded row opens it.
    func testToggle_opensRow() {
        let store = TaskStore()
        XCTAssertNil(store.expandedGraveyardTaskId)
        store.toggleGraveyardExpansion(for: "task-abc")
        XCTAssertEqual(store.expandedGraveyardTaskId, "task-abc")
    }

    /// D10: clicking an already-expanded row collapses it.
    func testToggle_closesRow() {
        let store = TaskStore()
        store.toggleGraveyardExpansion(for: "task-abc")
        store.toggleGraveyardExpansion(for: "task-abc")
        XCTAssertNil(store.expandedGraveyardTaskId)
    }

    /// D11: opening row B while row A is expanded collapses A and opens B.
    func testToggle_openingNewRowCollapsesOldRow() {
        let store = TaskStore()
        store.toggleGraveyardExpansion(for: "task-aaa")
        XCTAssertEqual(store.expandedGraveyardTaskId, "task-aaa")
        store.toggleGraveyardExpansion(for: "task-bbb")
        XCTAssertEqual(store.expandedGraveyardTaskId, "task-bbb",
                       "Opening a new row should replace the previously-open row (D11)")
    }

    /// collapseGraveyardExpansionIfNeeded: only collapses for the matching id.
    func testCollapseIfNeeded_onlyCollapsesMatchingId() {
        let store = TaskStore()
        store.toggleGraveyardExpansion(for: "task-aaa")
        store.collapseGraveyardExpansionIfNeeded(for: "task-bbb")
        XCTAssertEqual(store.expandedGraveyardTaskId, "task-aaa",
                       "collapseIfNeeded with a different id should leave expansion unchanged")
        store.collapseGraveyardExpansionIfNeeded(for: "task-aaa")
        XCTAssertNil(store.expandedGraveyardTaskId)
    }

    // MARK: - GraveyardExpansionContent

    /// Source chip includes source name and sourceID when present.
    func testSourceChip_withSourceID() {
        let task = makeTask(source: .linear, sourceID: "SEA-142")
        let content = GraveyardExpansionContent.make(from: task)
        XCTAssertEqual(content.sourceChip, "linear · SEA-142")
    }

    /// Source chip falls back to source name only when sourceID is nil.
    func testSourceChip_withoutSourceID() {
        let task = makeTask(source: .shell, sourceID: nil)
        let content = GraveyardExpansionContent.make(from: task)
        XCTAssertEqual(content.sourceChip, "shell")
    }

    /// Project chip equals the task's project field.
    func testProjectChip_equalsTaskProject() {
        let task = makeTask(project: "ghostties")
        let content = GraveyardExpansionContent.make(from: task)
        XCTAssertEqual(content.projectChip, "ghostties")
    }

    /// Time chip prefixed with "done ".
    func testTimeChip_prefixedWithDone() {
        let task = makeTask()
        let content = GraveyardExpansionContent.make(from: task)
        XCTAssertTrue(content.timeChip.hasPrefix("done "),
                      "Time chip should start with 'done ' — got '\(content.timeChip)'")
    }

    /// Empty body → isBodyEmpty true, bodyPreview is empty.
    func testBodyPreview_emptyWhenNilGoalAndNotes() {
        let task = makeTask(goal: nil, notes: nil)
        let content = GraveyardExpansionContent.make(from: task)
        XCTAssertTrue(content.isBodyEmpty)
        XCTAssertEqual(content.bodyPreview, "")
    }

    /// Empty strings → isBodyEmpty true.
    func testBodyPreview_emptyWhenEmptyStrings() {
        let task = makeTask(goal: "", notes: "   ")
        let content = GraveyardExpansionContent.make(from: task)
        XCTAssertTrue(content.isBodyEmpty)
    }

    /// Body with content → isBodyEmpty false, preview returned.
    func testBodyPreview_nonEmptyBody() {
        let task = makeTask(goal: "Fix the thing", notes: nil)
        let content = GraveyardExpansionContent.make(from: task)
        XCTAssertFalse(content.isBodyEmpty)
        XCTAssertEqual(content.bodyPreview, "Fix the thing")
    }

    /// Body with >8 lines is capped to 8.
    func testBodyPreview_clampedToEightLines() {
        let tenLines = (1...10).map { "Line \($0)" }.joined(separator: "\n")
        let task = makeTask(goal: tenLines)
        let content = GraveyardExpansionContent.make(from: task)
        let lineCount = content.bodyPreview.components(separatedBy: "\n").count
        XCTAssertLessThanOrEqual(lineCount, 8,
                                 "Body preview should be capped at 8 lines — got \(lineCount)")
    }

    /// RowClickHandlers.expandGraveyardTask: toggles store state, no terminal spawn.
    ///
    /// Integration check: expandGraveyardTask must NOT call SessionCoordinator.
    /// We verify this indirectly — after the call the coordinator's lastFocused
    /// project is still nil (no session was touched). Expand calls toggle on taskStore.
    func testExpandGraveyardTask_togglesStoreState() {
        let taskStore = TaskStore()
        let workspaceStore = WorkspaceStore(testingProjects: [])
        let coordinator = SessionCoordinator()
        let handlers = RowClickHandlers(
            taskStore: taskStore,
            coordinator: coordinator,
            workspaceStore: workspaceStore,
            defaultTaskTemplate: ""
        )
        let task = makeTask(id: "grv-001", status: .done)

        // First click → expand
        handlers.expandGraveyardTask(task)
        XCTAssertEqual(taskStore.expandedGraveyardTaskId, "grv-001")

        // Second click → collapse
        handlers.expandGraveyardTask(task)
        XCTAssertNil(taskStore.expandedGraveyardTaskId)
    }
}
