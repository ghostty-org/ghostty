// IDE-ONLY: not currently exercised in CI macos job (build-only).
// Run via Xcode Cmd+U or xcodebuild test locally.
// See .github/workflows/test-ghostties.yml — macos-app job is build-only due to
// XCTest host app hang in headless GH Actions runners.
import XCTest
@testable import Ghostty

/// Tests for `RowClickRouter.computeLane(for:workspaceStore:)`.
///
/// Focus: the lane-derivation logic is the high-value testable unit in U3.
/// The dispatch side (handler bodies) is exercised manually / in integration
/// tests — it requires a live `SessionCoordinator` and AppKit world.
///
/// All 7 scenarios from the SEA-159 ticket are covered here.
@MainActor
final class RowClickRouterTests: XCTestCase {

    // MARK: - Fixtures

    /// A `WorkspaceStore` seeded with a single project named "ghostties".
    private var storeWithProject: WorkspaceStore!
    /// A `WorkspaceStore` with no projects registered.
    private var emptyStore: WorkspaceStore!

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
        emptyStore = WorkspaceStore(testingProjects: [])
    }

    override func tearDownWithError() throws {
        storeWithProject = nil
        emptyStore = nil
    }

    // MARK: - Helpers

    private func makeTask(
        id: String = "test-task",
        status: TaskStatus,
        project: String = "ghostties"
    ) -> TaskItem {
        TaskItem(
            id: id,
            title: "Test Task",
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

    // MARK: - SEA-159 Scenario 1: Inbox + project → startInboxTask

    func testInboxWithKnownProject_routesToInboxWithProject() {
        let task = makeTask(status: .inbox, project: knownProjectName)
        let lane = RowClickRouter.shared.computeLane(for: task, workspaceStore: storeWithProject)
        XCTAssertEqual(lane, .inboxWithProject,
                       "Inbox task with a matching WorkspaceStore project should be .inboxWithProject")
    }

    // MARK: - SEA-159 Scenario 2: Inbox + no project → triageOrphanTask

    func testInboxWithNoMatchingProject_routesToInboxOrphan() {
        let task = makeTask(status: .inbox, project: knownProjectName)
        let lane = RowClickRouter.shared.computeLane(for: task, workspaceStore: emptyStore)
        XCTAssertEqual(lane, .inboxOrphan,
                       "Inbox task without a matching WorkspaceStore project should be .inboxOrphan")
    }

    // MARK: - SEA-159 Scenario 3: running → focusRunningTask

    func testRunningStatus_routesToRunning() {
        let task = makeTask(status: .running)
        let lane = RowClickRouter.shared.computeLane(for: task, workspaceStore: storeWithProject)
        XCTAssertEqual(lane, .running,
                       "Running task should route to .running regardless of project context")
    }

    // MARK: - SEA-159 Scenario 4: needs-you → focusNeedsYouTask

    func testNeedsYouStatus_routesToNeedsYou() {
        let task = makeTask(status: .needsYou)
        let lane = RowClickRouter.shared.computeLane(for: task, workspaceStore: storeWithProject)
        XCTAssertEqual(lane, .needsYou,
                       "Needs-you task should route to .needsYou regardless of project context")
    }

    // MARK: - SEA-159 Scenario 5: done → expandGraveyardTask

    func testDoneStatus_routesToGraveyard() {
        let task = makeTask(status: .done)
        let lane = RowClickRouter.shared.computeLane(for: task, workspaceStore: storeWithProject)
        XCTAssertEqual(lane, .graveyard,
                       "Done task should route to .graveyard")
    }

    // MARK: - SEA-159 Scenario 6: project field set + matches WorkspaceStore → inboxWithProject

    func testProjectFieldMatchesStore_hasProjectContext() {
        let task = makeTask(status: .inbox, project: knownProjectName)
        let hasContext = RowClickRouter.shared.hasProjectContext(task, workspaceStore: storeWithProject)
        XCTAssertTrue(hasContext,
                      "Task whose project name matches a WorkspaceStore entry should have project context")
    }

    // MARK: - SEA-159 Scenario 7: same project name but no match → triageOrphanTask

    func testProjectFieldNoMatch_noProjectContext() {
        let task = makeTask(status: .inbox, project: "some-unknown-project")
        let hasContext = RowClickRouter.shared.hasProjectContext(task, workspaceStore: storeWithProject)
        XCTAssertFalse(hasContext,
                       "Task whose project name has no matching WorkspaceStore entry should not have project context")
    }

    // MARK: - Edge: empty project string → orphan

    func testEmptyProjectString_noProjectContext() {
        let task = makeTask(status: .inbox, project: "")
        let hasContext = RowClickRouter.shared.hasProjectContext(task, workspaceStore: storeWithProject)
        XCTAssertFalse(hasContext,
                       "Task with empty project string should not have project context")
    }

    // MARK: - Running + no project context still routes to .running (not .inboxOrphan)

    func testRunningWithNoProjectContext_stillRoutesToRunning() {
        let task = makeTask(status: .running, project: "unknown-project")
        let lane = RowClickRouter.shared.computeLane(for: task, workspaceStore: emptyStore)
        XCTAssertEqual(lane, .running,
                       "Running status should always route to .running — project context check is inbox-only")
    }
}
