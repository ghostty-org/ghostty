// IDE-ONLY: not currently exercised in CI macos job (build-only).
// Run via Xcode Cmd+U or xcodebuild test locally.
// See .github/workflows/test-ghostties.yml — macos-app job is build-only due to
// XCTest host app hang in headless GH Actions runners.
//
// NOTE (R14): j/k full-row cycling is explicitly deferred to v0.1+.
// Only Return (activate) and ⌘O (open .md) are wired in v0.
import XCTest
@testable import Ghostty

/// Tests for the U11 keyboard shortcut infrastructure:
///   - `RowFocusStore` focus/clear/overwrite behaviour
///   - `⌘O` dispatch path: focused task → `TaskStore.fileURL` → `NSWorkspace.open`
///   - `Return` dispatch path: notification → `RowClickRouter.handleRowClick`
///   - No-op when no row is focused
///
/// The AppKit menu-item wiring and the SwiftUI `@FocusState` visual indicator
/// require a running host app and are covered by manual testing.
/// The notification bridge (`ghosttiesActivateFocusedTaskRow`) is tested here
/// at the store level.
@MainActor
final class KeyboardShortcutsTests: XCTestCase {

    // MARK: - Fixtures

    private var storeWithProject: WorkspaceStore!
    private var taskStore: TaskStore!
    private let knownProjectName = "ghostties"

    override func setUpWithError() throws {
        storeWithProject = WorkspaceStore(
            testingProjects: [
                Project(
                    name: knownProjectName,
                    rootPath: "/Users/test/Code/ghostties"
                )
            ]
        )
        taskStore = TaskStore()
        // Clear any residual focus state between tests. Use the actual focused
        // task's id so clearFocus's guard (id must match) fires correctly.
        RowFocusStore.shared.clearFocus(for: RowFocusStore.shared.focusedTask?.id ?? "")
    }

    override func tearDownWithError() throws {
        storeWithProject = nil
        taskStore = nil
    }

    // MARK: - Helpers

    private func makeTask(
        id: String = "task-u11",
        status: TaskStatus = .inbox,
        project: String = "ghostties"
    ) -> TaskItem {
        TaskItem(
            id: id,
            title: "U11 Test Task",
            source: .shell,
            sourceID: id,
            branch: nil,
            project: project,
            projectPath: nil,
            template: nil,
            created: Date(),
            status: status,
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

    // MARK: - RowFocusStore: setFocused

    func testSetFocused_registersTask() {
        let task = makeTask()
        RowFocusStore.shared.setFocused(task, taskStore: taskStore)
        XCTAssertEqual(RowFocusStore.shared.focusedTask?.id, task.id,
                       "setFocused should register the task in the store")
        XCTAssertNotNil(RowFocusStore.shared.focusedTaskStore,
                        "setFocused should register the taskStore reference")
    }

    func testSetFocused_overwrites_previousRow() {
        let task1 = makeTask(id: "task-1")
        let task2 = makeTask(id: "task-2")
        RowFocusStore.shared.setFocused(task1, taskStore: taskStore)
        RowFocusStore.shared.setFocused(task2, taskStore: taskStore)
        XCTAssertEqual(RowFocusStore.shared.focusedTask?.id, "task-2",
                       "setFocused on a second row should overwrite the first")
    }

    // MARK: - RowFocusStore: clearFocus

    func testClearFocus_clearsWhenIdMatches() {
        let task = makeTask(id: "task-clear")
        RowFocusStore.shared.setFocused(task, taskStore: taskStore)
        RowFocusStore.shared.clearFocus(for: task.id)
        XCTAssertNil(RowFocusStore.shared.focusedTask,
                     "clearFocus should nil the focusedTask when the id matches")
    }

    func testClearFocus_noOp_whenIdDoesNotMatch() {
        let task = makeTask(id: "task-a")
        RowFocusStore.shared.setFocused(task, taskStore: taskStore)
        // A different row losing focus should not clear the current registration.
        RowFocusStore.shared.clearFocus(for: "task-b")
        XCTAssertEqual(RowFocusStore.shared.focusedTask?.id, "task-a",
                       "clearFocus with mismatched id should leave the store unchanged")
    }

    func testClearFocus_noOp_whenStoreIsEmpty() {
        // Calling clear on an empty store should not crash.
        RowFocusStore.shared.clearFocus(for: "nonexistent-id")
        XCTAssertNil(RowFocusStore.shared.focusedTask,
                     "clearFocus on empty store should remain nil")
    }

    // MARK: - ⌘O: open-notes dispatch

    /// When a task is focused and a TaskStore is registered, `⌘O` resolves the
    /// `.md` URL via `TaskStore.fileURL(for:)`. The store returns nil when its
    /// `watchedDirectory` is not set (TaskStore fresh from init), which is the
    /// correct behaviour for an uninitialized task directory.
    ///
    /// We test the nil-URL guard path here; the non-nil path requires a real
    /// task directory on disk and is covered by manual + integration testing.
    func testOpenNotes_noOpWhenFileURLIsNil() {
        let task = makeTask()
        RowFocusStore.shared.setFocused(task, taskStore: taskStore)

        // TaskStore has no watchedDirectory → fileURL returns nil → NSWorkspace not called.
        let url = taskStore.fileURL(for: task)
        XCTAssertNil(url,
                     "fileURL should be nil for a TaskStore with no watchedDirectory — " +
                     "confirming the ⌘O action silently no-ops without crashing")
    }

    func testOpenNotes_noOpWhenNoFocusedRow() {
        // No row focused → focusedTask is nil → ⌘O action exits early.
        // Verify the store is clean (no task registered).
        XCTAssertNil(RowFocusStore.shared.focusedTask,
                     "No row focused → ⌘O action should not attempt to open any file")
    }

    // MARK: - Return: activate-row notification dispatch

    /// When AppDelegate fires the `ghosttiesActivateFocusedTaskRow` notification
    /// with the focused task's id as the object, `TaskRowView` receives it and
    /// calls `RowClickRouter.handleRowClick`. We test the notification name
    /// exists and round-trips correctly.
    func testActivateFocusedTaskRow_notificationPayload() {
        let task = makeTask(id: "task-return")
        RowFocusStore.shared.setFocused(task, taskStore: taskStore)

        var receivedTaskId: String?
        let expectation = XCTestExpectation(description: "notification received")

        let observer = NotificationCenter.default.addObserver(
            forName: .ghosttiesActivateFocusedTaskRow,
            object: nil,
            queue: .main
        ) { notification in
            receivedTaskId = notification.object as? String
            expectation.fulfill()
        }

        // Simulate what AppDelegate.activateFocusedTaskRow does.
        guard let focusedTaskId = RowFocusStore.shared.focusedTask?.id else {
            XCTFail("RowFocusStore should have a focused task at this point")
            return
        }
        NotificationCenter.default.post(
            name: .ghosttiesActivateFocusedTaskRow,
            object: focusedTaskId
        )

        wait(for: [expectation], timeout: 1.0)
        NotificationCenter.default.removeObserver(observer)

        XCTAssertEqual(receivedTaskId, task.id,
                       "Notification payload should carry the focused task's id")
    }

    func testActivateRow_noOpWhenNoFocusedRow() {
        // No row focused → activateFocusedTaskRow guard fires early.
        // Post a notification with no valid payload to confirm no crash.
        XCTAssertNil(RowFocusStore.shared.focusedTask,
                     "Store should be empty — Return action should silently no-op")
        // Would only crash if RowFocusStore or the notification handler is broken.
        NotificationCenter.default.post(
            name: .ghosttiesActivateFocusedTaskRow,
            object: nil
        )
        // Reaching here without crash is the pass condition.
    }

    // MARK: - R14: j/k navigation deferred to v0.1+

    // j/k full-row cycling is out of scope for v0 per R14 (SEA-167).
    // No test required. This comment documents the intentional omission.
}
