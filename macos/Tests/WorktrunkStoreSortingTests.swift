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
        let recencyDate: (String) -> Date? = { dates[$0] }

        let pinned = WorktrunkStore.sortedWorktrees(
            [main, feature],
            sortOrder: .recentActivity,
            pinMain: true,
            recencyDate: recencyDate
        )
        #expect(pinned.map(\.branch) == ["main", "feature"])

        let unpinned = WorktrunkStore.sortedWorktrees(
            [main, feature],
            sortOrder: .recentActivity,
            pinMain: false,
            recencyDate: recencyDate
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
        let recencyDate: (String) -> Date? = { dates[$0] }

        let sorted = WorktrunkStore.sortedWorktrees(
            [other, current],
            sortOrder: .recentActivity,
            pinMain: false,
            recencyDate: recencyDate
        )
        #expect(sorted.map(\.branch) == ["dev", "zzz"])
    }

    @Test func sortedWorktreesPlacesDatedAboveNil() async throws {
        let repoID = UUID()
        let datedPath = "/tmp/repo/dated"
        let nilPath = "/tmp/repo/nil"
        let dated = WorktrunkStore.Worktree(
            repositoryID: repoID,
            branch: "dated",
            path: datedPath,
            isMain: false,
            isCurrent: false
        )
        let nilDate = WorktrunkStore.Worktree(
            repositoryID: repoID,
            branch: "nil",
            path: nilPath,
            isMain: false,
            isCurrent: false
        )

        let dates: [String: Date] = [
            datedPath: Date(timeIntervalSince1970: 123),
        ]
        let recencyDate: (String) -> Date? = { dates[$0] }

        let sorted = WorktrunkStore.sortedWorktrees(
            [nilDate, dated],
            sortOrder: .recentActivity,
            pinMain: false,
            recencyDate: recencyDate
        )
        #expect(sorted.map(\.branch) == ["dated", "nil"])
    }
}
