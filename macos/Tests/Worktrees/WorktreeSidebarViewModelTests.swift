import Foundation
import Testing
@testable import Ghostty

#if os(macOS)

/// Tests for the M2 sidebar view-model and its pure presentation helpers.
///
/// The view-model path is driven by a command-aware fake `GitCommandRunning`
/// so the full pipeline (repo detection → worktree enumeration → active
/// resolution → empty state) is exercised deterministically without touching a
/// real git repository. Presentation logic is additionally tested directly via
/// the pure `WorktreeSidebar` helpers.
@MainActor
struct WorktreeSidebarViewModelTests {
    // A repository at /repo/main with a linked "feature" worktree and a
    // detached-HEAD worktree.
    private static let commonDir = "/repo/main/.git"
    private static let porcelain = """
    worktree /repo/main
    HEAD 1111111111111111111111111111111111111111
    branch refs/heads/main

    worktree /repo/feature
    HEAD 2222222222222222222222222222222222222222
    branch refs/heads/feature

    worktree /repo/detached-head
    HEAD 3333333333333333333333333333333333333333
    detached
    """
    private static let porcelainWithCreated = """
    worktree /repo/main
    HEAD 1111111111111111111111111111111111111111
    branch refs/heads/main

    worktree /repo/main-new-flow
    HEAD 4444444444444444444444444444444444444444
    branch refs/heads/new/flow
    """

    private func repoModel() -> GitWorktreeModel {
        GitWorktreeModel(runner: FakeGitRunner(
            commonDir: Self.commonDir,
            porcelain: Self.porcelain
        ))
    }

    // MARK: View model

    @Test func mainPinnedFirstAndDetachedNaming() async {
        let viewModel = WorktreeSidebarViewModel(model: repoModel())

        // A window opened directly inside a linked worktree still resolves to
        // the main repository's full list.
        await viewModel.refresh(cwd: URL(fileURLWithPath: "/repo/feature"))

        #expect(viewModel.worktrees.map { $0.path.standardizedFileURL.path } == [
            "/repo/main", "/repo/feature", "/repo/detached-head",
        ])
        #expect(viewModel.worktrees.first?.isMain == true)

        // Detached HEAD falls back to the directory name for its row title.
        let detached = viewModel.worktrees.last
        #expect(detached?.isDetached == true)
        #expect(detached?.branch == "detached-head")
        #expect(WorktreeSidebar.displayName(for: detached!) == "detached-head")
    }

    @Test func activeWorktreeSelectedFromCwd() async {
        let viewModel = WorktreeSidebarViewModel(model: repoModel())

        // A cwd nested inside the feature worktree selects that worktree.
        await viewModel.refresh(cwd: URL(fileURLWithPath: "/repo/feature/src/nested"))

        #expect(viewModel.selectedWorktree?.path.standardizedFileURL.path == "/repo/feature")
        #expect(viewModel.isEmptyState == false)
    }

    @Test func nonRepoEmptyState() async {
        let viewModel = WorktreeSidebarViewModel(model: GitWorktreeModel(
            runner: FakeGitRunner(commonDir: nil, porcelain: nil)
        ))

        await viewModel.refresh(cwd: URL(fileURLWithPath: "/not/a/repo"))

        #expect(viewModel.worktrees.isEmpty)
        #expect(viewModel.isEmptyState == true)
        #expect(viewModel.selectedWorktree == nil)
    }

    @Test func nilCwdIsEmptyState() async {
        let viewModel = WorktreeSidebarViewModel(model: repoModel())

        await viewModel.refresh(cwd: nil)

        #expect(viewModel.worktrees.isEmpty)
        #expect(viewModel.isEmptyState == true)
    }

    @Test func filterNarrowsThroughViewModel() async {
        let viewModel = WorktreeSidebarViewModel(model: repoModel())
        await viewModel.refresh(cwd: URL(fileURLWithPath: "/repo/main"))

        viewModel.filterText = "feat"
        #expect(viewModel.filteredWorktrees.map { $0.path.lastPathComponent } == ["feature"])

        // Case-insensitive, and matches directory names too.
        viewModel.filterText = "DETACHED"
        #expect(viewModel.filteredWorktrees.map { $0.path.lastPathComponent } == ["detached-head"])

        viewModel.filterText = ""
        #expect(viewModel.filteredWorktrees.count == 3)
    }

    @Test func selectionPreservedAcrossRefreshWhenStillPresent() async {
        let viewModel = WorktreeSidebarViewModel(model: repoModel())
        await viewModel.refresh(cwd: URL(fileURLWithPath: "/repo/feature"))
        #expect(viewModel.selectedWorktree?.path.standardizedFileURL.path == "/repo/feature")

        // A later refresh (e.g. window focus) with a cwd that isn't inside any
        // worktree keeps the existing selection rather than clearing it.
        await viewModel.refresh(cwd: URL(fileURLWithPath: "/repo/main/.."))
        #expect(viewModel.selectedWorktree?.path.standardizedFileURL.path == "/repo/feature")
    }

    @Test func createWorktreeRefreshesSelectsAndClearsMessage() async {
        let viewModel = WorktreeSidebarViewModel(model: GitWorktreeModel(runner: FakeGitRunner(
            commonDir: Self.commonDir,
            porcelain: Self.porcelainWithCreated,
            addResult: .success("")
        )))
        await viewModel.refresh(cwd: URL(fileURLWithPath: "/repo/main"))

        let created = await viewModel.createWorktree(branchName: "new/flow")

        #expect(created?.branch == "new/flow")
        #expect(created?.path.standardizedFileURL.path == "/repo/main-new-flow")
        #expect(viewModel.selectedWorktree?.branch == "new/flow")
        #expect(viewModel.sidebarMessage == nil)
        #expect(viewModel.isCreatingWorktree == false)
    }

    @Test func createWorktreeFailureShowsInlineError() async {
        let viewModel = WorktreeSidebarViewModel(model: GitWorktreeModel(runner: FakeGitRunner(
            commonDir: Self.commonDir,
            porcelain: Self.porcelain,
            addResult: .failure(status: 128, stderr: "fatal: bad branch")
        )))
        await viewModel.refresh(cwd: URL(fileURLWithPath: "/repo/main"))

        let created = await viewModel.createWorktree(branchName: "bad branch")

        #expect(created == nil)
        #expect(viewModel.sidebarMessage == .error("fatal: bad branch"))
        #expect(viewModel.isCreatingWorktree == false)
    }

    // MARK: Pure helpers

    @Test func displayNameFallsBackToDirectoryForDetached() {
        let branch = Worktree(path: URL(fileURLWithPath: "/w/feature"), branch: "feature", isMain: false, isDetached: false)
        let detached = Worktree(path: URL(fileURLWithPath: "/w/spike"), branch: nil, isMain: false, isDetached: true)

        #expect(WorktreeSidebar.displayName(for: branch) == "feature")
        #expect(WorktreeSidebar.displayName(for: detached) == "spike")
    }

    @Test func activeWorktreeUsesLongestPrefix() {
        let main = Worktree(path: URL(fileURLWithPath: "/repo"), branch: "main", isMain: true, isDetached: false)
        let feature = Worktree(path: URL(fileURLWithPath: "/repo/wt/feature"), branch: "feature", isMain: false, isDetached: false)
        let worktrees = [main, feature]

        // Nested cwd resolves to the more specific (longer prefix) worktree.
        #expect(WorktreeSidebar.activeWorktree(in: worktrees, cwd: URL(fileURLWithPath: "/repo/wt/feature/src"))?.branch == "feature")
        // A cwd only under the main root resolves to main.
        #expect(WorktreeSidebar.activeWorktree(in: worktrees, cwd: URL(fileURLWithPath: "/repo/src"))?.branch == "main")
        // Exact match.
        #expect(WorktreeSidebar.activeWorktree(in: worktrees, cwd: URL(fileURLWithPath: "/repo/wt/feature"))?.branch == "feature")
        // Outside any worktree, and nil cwd.
        #expect(WorktreeSidebar.activeWorktree(in: worktrees, cwd: URL(fileURLWithPath: "/elsewhere")) == nil)
        #expect(WorktreeSidebar.activeWorktree(in: worktrees, cwd: nil) == nil)
        // A sibling that merely shares a name prefix must not match ("/repofoo").
        #expect(WorktreeSidebar.activeWorktree(in: worktrees, cwd: URL(fileURLWithPath: "/repofoo")) == nil)
    }

    @Test func filterMatchesBranchAndDirectoryCaseInsensitively() {
        let worktrees = [
            Worktree(path: URL(fileURLWithPath: "/w/main"), branch: "main", isMain: true, isDetached: false),
            Worktree(path: URL(fileURLWithPath: "/w/review-notes"), branch: "review/design", isMain: false, isDetached: false),
        ]

        #expect(WorktreeSidebar.filter(worktrees, query: "MAIN").map(\.branch) == ["main"])
        #expect(WorktreeSidebar.filter(worktrees, query: "design").map(\.branch) == ["review/design"])
        #expect(WorktreeSidebar.filter(worktrees, query: "notes").map(\.branch) == ["review/design"])
        #expect(WorktreeSidebar.filter(worktrees, query: "   ").count == 2)
        #expect(WorktreeSidebar.filter(worktrees, query: "zzz").isEmpty)
    }

    @Test func resolveCwdPrefersPwdThenConfiguredDirectory() {
        #expect(WorktreeSidebar.resolveCwd(pwd: "/live/pwd", configuredWorkingDirectory: "/config")?.path == "/live/pwd")
        #expect(WorktreeSidebar.resolveCwd(pwd: nil, configuredWorkingDirectory: "/config")?.path == "/config")
        #expect(WorktreeSidebar.resolveCwd(pwd: "", configuredWorkingDirectory: "/config")?.path == "/config")
        #expect(WorktreeSidebar.resolveCwd(pwd: nil, configuredWorkingDirectory: nil) == nil)
        #expect(WorktreeSidebar.resolveCwd(pwd: nil, configuredWorkingDirectory: "") == nil)
    }
}

/// A `GitCommandRunning` that answers the two commands the model issues:
/// `rev-parse --git-common-dir` and `worktree list --porcelain`. A nil
/// `commonDir` simulates a non-repository directory.
private struct FakeGitRunner: GitCommandRunning {
    let commonDir: String?
    let porcelain: String?
    var addResult: GitCommandResult = .success("")

    func runGit(arguments: [String], cwd: URL, timeout: TimeInterval) async -> GitCommandResult {
        if arguments.contains("rev-parse") {
            guard let commonDir else { return .failure(status: 128, stderr: "not a git repository") }
            return .success(commonDir)
        }
        if arguments.contains("list") {
            guard let porcelain else { return .failure(status: 128, stderr: "not a git repository") }
            return .success(porcelain)
        }
        if arguments.starts(with: ["worktree", "add"]) {
            return addResult
        }
        return .failure(status: 1, stderr: "unexpected command \(arguments)")
    }
}

#endif
