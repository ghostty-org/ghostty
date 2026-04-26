// IDE-ONLY: not currently exercised in CI macos job (build-only).
// Run via Xcode Cmd+U or xcodebuild test locally.
// See .github/workflows/test-ghostties.yml — macos-app job is build-only due to
// XCTest host app hang in headless GH Actions runners.
import XCTest
@testable import Ghostty

/// Tests for `NewTaskComposerStore` and the U8 inline new-task composer
/// mechanics (SEA-164). Exercises D-decisions: D6 (smart-default cascade),
/// D7 (empty projects → onboarding), D11 (single composer), D13 (inline error),
/// D20 (validation), D23 (copy strings).
///
/// Note: confirm flow requires a live `TaskStore` with a real tasks directory.
/// Those integration paths are not covered here — use the live app.
@MainActor
final class NewTaskComposerTests: XCTestCase {

    // MARK: - Fixtures

    private func makeStore() -> NewTaskComposerStore {
        NewTaskComposerStore(isolatedForTesting: ())
    }

    private func makeWorkspaceStore(projects: [Project] = []) -> WorkspaceStore {
        WorkspaceStore(testingProjects: projects)
    }

    private func makeProject(name: String = "ghostties", path: String = "/Users/sean/Code/ghostties") -> Project {
        Project(name: name, rootPath: path, isPinned: true, lastActiveAt: Date())
    }

    // MARK: - D11: single composer

    func testOpen_setsIsOpen() {
        let store = makeStore()
        let ws = makeWorkspaceStore(projects: [makeProject()])

        store.open(workspaceStore: ws)
        XCTAssertTrue(store.isOpen, "open() must set isOpen = true")
    }

    func testOpenWhileOpen_focusesTitleInsteadOfSecondCard() {
        let store = makeStore()
        let ws = makeWorkspaceStore(projects: [makeProject()])

        store.open(workspaceStore: ws)
        XCTAssertFalse(store.focusTitleFieldTrigger,
                       "trigger resets to false after first open cycle")

        // Second invocation while open.
        store.open(workspaceStore: ws)
        XCTAssertTrue(store.focusTitleFieldTrigger,
                      "D11: second open while open must set focusTitleFieldTrigger=true")
        XCTAssertTrue(store.isOpen, "D11: isOpen must remain true — no second composer")
    }

    func testOpenWhileOpen_doesNotResetTitle() {
        let store = makeStore()
        let ws = makeWorkspaceStore(projects: [makeProject()])

        store.open(workspaceStore: ws)
        store.titleText = "Refactor sidebar"

        store.open(workspaceStore: ws)
        // Title should NOT have been wiped on second open.
        XCTAssertEqual(store.titleText, "Refactor sidebar",
                       "D11: second open must not wipe in-progress title draft")
    }

    // MARK: - D20: validation

    func testCanConfirm_falseWhenTitleEmpty() {
        let store = makeStore()
        let ws = makeWorkspaceStore(projects: [makeProject()])
        store.open(workspaceStore: ws)

        store.titleText = ""
        XCTAssertFalse(store.canConfirm, "Empty title must disable confirm")
    }

    func testCanConfirm_falseWhenTitleWhitespaceOnly() {
        let store = makeStore()
        let ws = makeWorkspaceStore(projects: [makeProject()])
        store.open(workspaceStore: ws)

        store.titleText = "   "
        XCTAssertFalse(store.canConfirm,
                       "Whitespace-only title must disable confirm (D20)")
    }

    func testCanConfirm_falseWhenNoProjectSelected() {
        let store = makeStore()
        let ws = makeWorkspaceStore(projects: [makeProject()])
        store.open(workspaceStore: ws)

        store.titleText = "Do the thing"
        store.selectedProjectId = nil
        XCTAssertFalse(store.canConfirm,
                       "No project selected must disable confirm")
    }

    func testCanConfirm_trueWhenTitleAndProjectSet() {
        let store = makeStore()
        let proj = makeProject()
        let ws = makeWorkspaceStore(projects: [proj])
        store.open(workspaceStore: ws)

        store.titleText = "Refactor auth"
        store.selectedProjectId = proj.id
        XCTAssertTrue(store.canConfirm, "Non-empty title + project must enable confirm")
    }

    // MARK: - Cancel

    func testCancel_closesComposer() {
        let store = makeStore()
        let ws = makeWorkspaceStore(projects: [makeProject()])
        store.open(workspaceStore: ws)
        store.titleText = "Draft"

        store.cancel()
        XCTAssertFalse(store.isOpen, "cancel() must set isOpen=false")
        XCTAssertTrue(store.titleText.isEmpty, "cancel() must wipe title draft")
    }

    func testCancel_closesAndReopensClean() {
        let store = makeStore()
        let ws = makeWorkspaceStore(projects: [makeProject()])

        // Open, type, cancel, reopen — store must be clean.
        store.open(workspaceStore: ws)
        store.titleText = "Draft task"
        store.cancel()

        store.open(workspaceStore: ws)
        // After re-open writeError should be nil and title wiped on cancel.
        XCTAssertNil(store.writeError,
                     "Re-open after cancel must clear any prior writeError (D13)")
        XCTAssertTrue(store.isOpen, "Composer must be open again after second open()")
    }

    // MARK: - D6: smart-default cascade — most-recently-touched fallback

    func testSmartDefault_mostRecentlyTouchedFallback() {
        let store = makeStore()
        let older = Project(name: "older-project", rootPath: "/old",
                            isPinned: false, lastActiveAt: Date(timeIntervalSinceNow: -3600))
        let newer = Project(name: "newer-project", rootPath: "/new",
                            isPinned: false, lastActiveAt: Date(timeIntervalSinceNow: -60))
        let ws = makeWorkspaceStore(projects: [older, newer])

        store.open(workspaceStore: ws)
        XCTAssertEqual(store.selectedProjectId, newer.id,
                       "D6 step 3: should default to most-recently-touched project")
    }

    func testSmartDefault_nilWhenNoProjects() {
        let store = makeStore()
        let ws = makeWorkspaceStore(projects: [])

        store.open(workspaceStore: ws)
        XCTAssertNil(store.selectedProjectId,
                     "D7: no projects → selectedProjectId must be nil (onboarding state)")
    }

    // MARK: - D7: empty projects state

    func testEmptyProjects_canConfirmIsFalse() {
        let store = makeStore()
        let ws = makeWorkspaceStore(projects: [])
        store.open(workspaceStore: ws)

        store.titleText = "Some task"
        XCTAssertFalse(store.canConfirm,
                       "D7: title present but no project → confirm disabled")
    }
}
