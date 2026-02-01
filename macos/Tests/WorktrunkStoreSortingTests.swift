import Testing
@testable import Ghostree

struct WorktrunkStoreSortingTests {
    @Test func sortedWorktreesPinsMainWhenRequested() async throws {
        let repoID = UUID()
        let mainPath = "/tmp/repo/main"
        let featurePath = "/tmp/repo/feature"
        let main = WorktrunkStore.Worktree(
            repositoryID: repoID,
            branch: "main",
            path: mainPath,
            isMain: true,
            isCurrent: false
        )
        let feature = WorktrunkStore.Worktree(
            repositoryID: repoID,
            branch: "feature",
            path: featurePath,
            isMain: false,
            isCurrent: false
        )

        let dates: [String: Date] = [
            mainPath: Date(timeIntervalSince1970: 1),
            featurePath: Date(timeIntervalSince1970: 2),
        ]
        let latestActivityDate: (String) -> Date? = { dates[$0] }

        let pinned = WorktrunkStore.sortedWorktrees(
            [main, feature],
            sortOrder: .recentActivity,
            pinMain: true,
            latestActivityDate: latestActivityDate
        )
        #expect(pinned.map(\.branch) == ["main", "feature"])

        let unpinned = WorktrunkStore.sortedWorktrees(
            [main, feature],
            sortOrder: .recentActivity,
            pinMain: false,
            latestActivityDate: latestActivityDate
        )
        #expect(unpinned.map(\.branch) == ["feature", "main"])
    }

    @Test func sortedWorktreesAlwaysPinsCurrent() async throws {
        let repoID = UUID()
        let currentPath = "/tmp/repo/current"
        let otherPath = "/tmp/repo/other"
        let current = WorktrunkStore.Worktree(
            repositoryID: repoID,
            branch: "dev",
            path: currentPath,
            isMain: false,
            isCurrent: true
        )
        let other = WorktrunkStore.Worktree(
            repositoryID: repoID,
            branch: "zzz",
            path: otherPath,
            isMain: true,
            isCurrent: false
        )

        let dates: [String: Date] = [
            currentPath: Date(timeIntervalSince1970: 1),
            otherPath: Date(timeIntervalSince1970: 2),
        ]
        let latestActivityDate: (String) -> Date? = { dates[$0] }

        let sorted = WorktrunkStore.sortedWorktrees(
            [other, current],
            sortOrder: .recentActivity,
            pinMain: false,
            latestActivityDate: latestActivityDate
        )
        #expect(sorted.map(\.branch) == ["dev", "zzz"])
    }
}

