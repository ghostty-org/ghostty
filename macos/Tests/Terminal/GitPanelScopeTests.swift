import Foundation
@testable import Ghostty
import Testing

/// What the Git panel is looking at, and which repositories start open.
///
/// The distinction these guard is the bug that prompted the whole feature:
/// "not in a repository" was treated as "nothing to show", so a terminal
/// sitting in a workspace full of checkouts got the empty state.
struct GitPanelScopeTests {
    // MARK: Scope

    @Test func aTerminalInsideARepositoryGetsThatRepository() {
        let scope = GitPanelScope.resolve(
            repoRoot: "/Projects/phantom",
            pwd: "/Projects/phantom/macos",
            discovered: nil
        )
        #expect(scope == .repository("/Projects/phantom"))
    }

    /// Being in a repo wins even when the scan found siblings — that case
    /// stays flat by design.
    @Test func aRepositoryOutranksAnythingDiscoveredBeneathIt() {
        let scope = GitPanelScope.resolve(
            repoRoot: "/Projects/phantom",
            pwd: "/Projects/phantom",
            discovered: ["/Projects/phantom/vendor/a", "/Projects/phantom/vendor/b"]
        )
        #expect(scope == .repository("/Projects/phantom"))
    }

    @Test func aFolderHoldingRepositoriesBecomesAWorkspace() {
        let scope = GitPanelScope.resolve(
            repoRoot: nil,
            pwd: "/Projects/Aurora",
            discovered: ["/Projects/Aurora/backend", "/Projects/Aurora/front"]
        )
        #expect(scope == .workspace(
            root: "/Projects/Aurora",
            repos: ["/Projects/Aurora/backend", "/Projects/Aurora/front"]
        ))
    }

    /// The regression this type exists for: a scan that hasn't answered yet
    /// must not read as "nothing here", or the empty state flashes on every
    /// tab switch before the workspace appears.
    @Test func anUnfinishedScanIsNotAnEmptyWorkspace() {
        let pending = GitPanelScope.resolve(repoRoot: nil, pwd: "/Projects/Aurora", discovered: nil)
        let answered = GitPanelScope.resolve(repoRoot: nil, pwd: "/Projects/Aurora", discovered: [])

        #expect(pending == .none)
        #expect(answered == .none)
        // Both render as "nothing", but only one of them is final — the
        // panel keeps asking while `discovered` is nil.
    }

    @Test func aFolderWithNoRepositoriesUnderItIsEmpty() {
        let scope = GitPanelScope.resolve(repoRoot: nil, pwd: "/Downloads", discovered: [])
        #expect(scope == .none)
    }

    @Test func noTerminalAtAllIsEmpty() {
        #expect(GitPanelScope.resolve(repoRoot: nil, pwd: nil, discovered: nil) == .none)
    }

    /// Empty strings reach here from a terminal that hasn't reported a pwd
    /// yet, and must not be treated as a real path.
    @Test func emptyPathsAreNotPaths() {
        #expect(GitPanelScope.resolve(repoRoot: "", pwd: "", discovered: ["/a"]) == .none)
    }

    @Test func scopeReportsEveryRepositoryItCovers() {
        #expect(GitPanelScope.repository("/a").repos == ["/a"])
        #expect(GitPanelScope.workspace(root: "/w", repos: ["/a", "/b"]).repos == ["/a", "/b"])
        #expect(GitPanelScope.none.repos.isEmpty)
    }

    // MARK: Expansion

    private func status(clean: Bool) -> GitStatus {
        let header = "# branch.head main"
        guard !clean else { return GitStatus.parse(porcelainV2: header) }
        return GitStatus.parse(
            porcelainV2: header + "\n1 M. N... 100644 100644 100644 abc def a.txt"
        )
    }

    @Test func aRepositoryWithChangesStartsOpen() {
        #expect(GitRepoExpansion.isExpanded(manual: nil, status: status(clean: false)))
    }

    @Test func aCleanRepositoryStartsClosed() {
        #expect(!GitRepoExpansion.isExpanded(manual: nil, status: status(clean: true)))
    }

    /// A status still loading must not pop the section open and then shut
    /// it again a moment later.
    @Test func aRepositoryWithNoStatusYetStaysClosed() {
        #expect(!GitRepoExpansion.isExpanded(manual: nil, status: nil))
    }

    /// The half that keeps the rule from fighting the user: a repo they
    /// collapsed stays collapsed even once it has changes, and one they
    /// opened stays open once it is clean again.
    @Test func aClickAlwaysBeatsTheAutomaticRule() {
        #expect(!GitRepoExpansion.isExpanded(manual: false, status: status(clean: false)))
        #expect(GitRepoExpansion.isExpanded(manual: true, status: status(clean: true)))
        #expect(GitRepoExpansion.isExpanded(manual: true, status: nil))
    }
}
