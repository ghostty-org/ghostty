// IDE-ONLY: not currently exercised in CI macos job (build-only).
// Run via Xcode Cmd+U or xcodebuild test locally.
// See .github/workflows/test-ghostties.yml — macos-app job is build-only due to
// XCTest host app hang in headless GH Actions runners.
import XCTest
@testable import Ghostty

/// Tests for `RowClickHandlers.focusRunningTask` and `focusNeedsYouTask` (U5, SEA-161).
///
/// Both handlers delegate to the private `routeToExistingSession(_:)` helper and are
/// therefore identical in v0. Tests cover:
///
/// - Lane routing: Running + Needs-you rows map to the correct handler via the router.
/// - D9 detection: the WorkspaceStore global-status gate used by `routeToExistingSession`
///   to distinguish "dead locally, alive in another window" from "dead everywhere".
/// - R7 lane membership: Needs-you lane is `task.status == .needsYou` from frontmatter;
///   no code change to `isLikelyPromptingForInput` heuristic.
///
/// Note — the "focus existing session", "D8 respawn", and "no-op cross-window" branches
/// of `routeToExistingSession` require a live `SessionCoordinator` backed by a real
/// `Ghostty.App`. Those paths are verified manually per SEA-161's AE3 acceptance criteria.
@MainActor
final class FocusRunningTaskTests: XCTestCase {

    // MARK: - Fixtures

    private let knownProjectName = "ghostties"
    private var storeWithProject: WorkspaceStore!
    private var emptyStore: WorkspaceStore!

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
        project: String = "ghostties",
        projectPath: String? = nil
    ) -> TaskItem {
        TaskItem(
            id: id,
            title: "Test Task",
            source: .shell,
            sourceID: id,
            branch: nil,
            project: project,
            projectPath: projectPath,
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

    // MARK: - Lane routing

    /// Running status → router returns .running regardless of project context.
    func testRunningStatus_lanesAsRunning() {
        let task = makeTask(status: .running)
        let lane = RowClickRouter.shared.computeLane(for: task, workspaceStore: storeWithProject)
        XCTAssertEqual(lane, .running,
                       "Running task should route to .running")
    }

    /// Needs-you status → router returns .needsYou regardless of project context (R7).
    func testNeedsYouStatus_lanesAsNeedsYou() {
        let task = makeTask(status: .needsYou)
        let lane = RowClickRouter.shared.computeLane(for: task, workspaceStore: storeWithProject)
        XCTAssertEqual(lane, .needsYou,
                       "Needs-you task should route to .needsYou (R7 — from frontmatter status, not heuristic)")
    }

    /// Running + no project context still routes to .running (not .inboxOrphan).
    func testRunningWithNoProjectContext_stillLanesAsRunning() {
        let task = makeTask(status: .running, project: "unknown-project")
        let lane = RowClickRouter.shared.computeLane(for: task, workspaceStore: emptyStore)
        XCTAssertEqual(lane, .running,
                       "Running row should always be .running — project lookup is inbox-only")
    }

    /// Needs-you + no project context still routes to .needsYou.
    func testNeedsYouWithNoProjectContext_stillLanesAsNeedsYou() {
        let task = makeTask(status: .needsYou, project: "unknown-project")
        let lane = RowClickRouter.shared.computeLane(for: task, workspaceStore: emptyStore)
        XCTAssertEqual(lane, .needsYou,
                       "Needs-you row should always be .needsYou — project lookup is inbox-only")
    }

    // MARK: - D9: Global-status gate

    /// D9 detection: when a session is globally alive (in another window) the
    /// `routeToExistingSession` helper reads `workspaceStore.globalStatuses` to
    /// detect the cross-window case and no-op. This test verifies the gate signal
    /// is readable from `WorkspaceStore` as expected.
    func testGlobalStatusRunning_isDetectableForD9Guard() {
        // Arrange: seed a session under the project and mark it running globally.
        let project = storeWithProject.projects.first(where: { $0.name == knownProjectName })!
        let session = storeWithProject.addSession(
            name: "Agent 1",
            templateId: AgentTemplate.shell.id,
            projectId: project.id
        )
        storeWithProject.updateSessionStatus(id: session.id, status: .running)

        // Assert: globalStatuses reflects the running status the D9 guard reads.
        XCTAssertEqual(
            storeWithProject.globalStatuses[session.id],
            .running,
            "globalStatuses should reflect the running state that D9 gate reads"
        )
    }

    /// D9 inverse: when no session is alive globally (dead session — D8 path),
    /// globalStatuses must NOT contain a running entry for the project.
    func testGlobalStatusDead_notRunning_d8RespawnPath() {
        let project = storeWithProject.projects.first(where: { $0.name == knownProjectName })!
        let session = storeWithProject.addSession(
            name: "Agent 1",
            templateId: AgentTemplate.shell.id,
            projectId: project.id
        )
        // Exited status — the D9 guard returns false, falling through to D8 respawn.
        storeWithProject.updateSessionStatus(id: session.id, status: .exited)

        let isAliveGlobally = storeWithProject.sessions(for: project.id).contains {
            storeWithProject.globalStatuses[$0.id]?.isAlive == true
        }
        XCTAssertFalse(isAliveGlobally,
                       "Exited session should not satisfy isAlive — D8 respawn path should trigger")
    }

    /// No sessions registered → isAliveGlobally is false → D8 path.
    func testNoSessionsForProject_d8PathShouldTrigger() {
        let project = storeWithProject.projects.first(where: { $0.name == knownProjectName })!
        let sessions = storeWithProject.sessions(for: project.id)
        XCTAssertTrue(sessions.isEmpty, "Precondition: no sessions seeded")

        let isAliveGlobally = sessions.contains {
            storeWithProject.globalStatuses[$0.id]?.isAlive == true
        }
        XCTAssertFalse(isAliveGlobally,
                       "No sessions → isAliveGlobally is false → D8 respawn path")
    }

    // MARK: - R7 lane membership (heuristic wiring unchanged)

    /// The live `isLikelyPromptingForInput` heuristic is per-session indicator only.
    /// Needs-you task row lane membership is driven purely by `task.status == .needsYou`
    /// (from frontmatter). A shell-status task never routes as .needsYou.
    func testRunningStatusNeverRoutesAsNeedsYou() {
        // A task that has `running` frontmatter status must route to .running,
        // even if the underlying session indicator would say needsAttention.
        // The indicator heuristic and the lane router are independent (R7).
        let task = makeTask(status: .running)
        let lane = RowClickRouter.shared.computeLane(for: task, workspaceStore: storeWithProject)
        XCTAssertNotEqual(lane, .needsYou,
                          "Running frontmatter status must not route to .needsYou (R7 independence)")
    }
}
