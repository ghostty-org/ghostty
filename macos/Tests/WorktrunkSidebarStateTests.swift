import Testing
import SwiftUI
@testable import Ghostree

private struct FakeWorktrunkSidebarStore: WorktrunkSidebarReconcilingStore {
    var repositories: [WorktrunkStore.Repository]
    var worktreesByRepositoryID: [UUID: [WorktrunkStore.Worktree]]
    var sessionsByWorktreePath: [String: [AISession]]

    func worktrees(for repositoryID: UUID) -> [WorktrunkStore.Worktree] {
        worktreesByRepositoryID[repositoryID] ?? []
    }

    func sessions(for worktreePath: String) -> [AISession] {
        sessionsByWorktreePath[worktreePath] ?? []
    }
}

struct WorktrunkSidebarStateTests {
    @Test func reconcilePrunesExpandedSets() async throws {
        let repoID = UUID()
        let repo = WorktrunkStore.Repository(id: repoID, path: "/tmp/repo")
        let store = FakeWorktrunkSidebarStore(
            repositories: [repo],
            worktreesByRepositoryID: [
                repoID: [
                    .init(repositoryID: repoID, branch: "main", path: "/tmp/repo/main", isMain: true, isCurrent: false),
                ],
            ],
            sessionsByWorktreePath: [:]
        )

        let state = WorktrunkSidebarState()
        state.expandedRepoIDs = [repoID, UUID()]
        state.expandedWorktreePaths = ["/tmp/repo/main", "/tmp/repo/missing"]

        state.reconcile(with: store)

        #expect(state.expandedRepoIDs == [repoID])
        #expect(state.expandedWorktreePaths == ["/tmp/repo/main"])
    }

    @Test func reconcileWorktreeSelectionFallsBackToRepo() async throws {
        let repoID = UUID()
        let repo = WorktrunkStore.Repository(id: repoID, path: "/tmp/repo")
        let store = FakeWorktrunkSidebarStore(
            repositories: [repo],
            worktreesByRepositoryID: [repoID: []],
            sessionsByWorktreePath: [:]
        )

        let state = WorktrunkSidebarState()
        state.selection = .worktree(repoID: repoID, path: "/tmp/repo/missing")

        state.reconcile(with: store)

        #expect(state.selection == .repo(id: repoID))
    }

    @Test func reconcileSessionSelectionFallsBackToWorktreeWhenSessionMissing() async throws {
        let repoID = UUID()
        let worktreePath = "/tmp/repo/main"
        let repo = WorktrunkStore.Repository(id: repoID, path: "/tmp/repo")
        let store = FakeWorktrunkSidebarStore(
            repositories: [repo],
            worktreesByRepositoryID: [
                repoID: [
                    .init(repositoryID: repoID, branch: "main", path: worktreePath, isMain: true, isCurrent: false),
                ],
            ],
            sessionsByWorktreePath: [
                worktreePath: [
                    .init(
                        id: "s1",
                        source: .codex,
                        worktreePath: worktreePath,
                        cwd: worktreePath,
                        timestamp: Date(),
                        snippet: "Session",
                        sourcePath: "/tmp/s1.jsonl",
                        messageCount: 1
                    ),
                ],
            ]
        )

        let state = WorktrunkSidebarState()
        state.selection = .session(id: "missing", repoID: repoID, worktreePath: worktreePath)

        state.reconcile(with: store)

        #expect(state.selection == .worktree(repoID: repoID, path: worktreePath))
    }

    @Test func reconcileSessionSelectionFallsBackToRepoWhenWorktreeMissing() async throws {
        let repoID = UUID()
        let repo = WorktrunkStore.Repository(id: repoID, path: "/tmp/repo")
        let store = FakeWorktrunkSidebarStore(
            repositories: [repo],
            worktreesByRepositoryID: [repoID: []],
            sessionsByWorktreePath: [:]
        )

        let state = WorktrunkSidebarState()
        state.selection = .session(id: "s1", repoID: repoID, worktreePath: "/tmp/repo/missing")

        state.reconcile(with: store)

        #expect(state.selection == .repo(id: repoID))
    }

    @Test func didCollapseWorktreeDowngradesSessionSelection() async throws {
        let repoID = UUID()
        let worktreePath = "/tmp/repo/main"
        let state = WorktrunkSidebarState()
        state.selection = .session(id: "s1", repoID: repoID, worktreePath: worktreePath)

        state.didCollapseWorktree(repoID: repoID, path: worktreePath)

        #expect(state.selection == .worktree(repoID: repoID, path: worktreePath))
    }

    @Test func didCollapseRepoDowngradesDescendantSelection() async throws {
        let repoID = UUID()
        let state = WorktrunkSidebarState()
        state.selection = .worktree(repoID: repoID, path: "/tmp/repo/main")

        state.didCollapseRepo(id: repoID)

        #expect(state.selection == .repo(id: repoID))
    }
}

