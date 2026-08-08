import Foundation
@testable import Ghostty
import Testing

/// Which folder the file explorer opens on.
///
/// The precedence here is the answer to a real ambiguity: a "workspace" is
/// a project group's root when the user defined one, but for a loose
/// terminal it could reasonably be either the enclosing repository or the
/// exact directory the shell is sitting in. Both are offered; these tests
/// pin down which one each mode picks and, just as importantly, what
/// happens when the preferred source is missing.
struct WorkspaceRootResolverTests {
    private let group = "~/Projects/Aurora"
    private let repo = "/Users/test/Projects/Tools/phantom"
    private let pwd = "/Users/test/Projects/Tools/phantom/macos/Sources"

    private var expandedGroup: String {
        (("~/Projects/Aurora") as NSString).expandingTildeInPath
    }

    // MARK: auto

    @Test func autoPrefersTheProjectGroupRoot() {
        let result = WorkspaceRootResolver.resolve(
            mode: .auto, groupRoot: group, repoRoot: repo, pwd: pwd
        )
        #expect(result == expandedGroup)
    }

    @Test func autoFallsBackToTheRepositoryWithoutAGroup() {
        let result = WorkspaceRootResolver.resolve(
            mode: .auto, groupRoot: nil, repoRoot: repo, pwd: pwd
        )
        #expect(result == repo)
    }

    @Test func autoFallsBackToThePwdOutsideAnyRepository() {
        let result = WorkspaceRootResolver.resolve(
            mode: .auto, groupRoot: nil, repoRoot: nil, pwd: pwd
        )
        #expect(result == pwd)
    }

    // MARK: repository

    /// The point of this mode: a terminal deep inside a repo still shows
    /// the whole project, ignoring a group that might scope it wider.
    @Test func repositoryModeIgnoresTheGroupRoot() {
        let result = WorkspaceRootResolver.resolve(
            mode: .repository, groupRoot: group, repoRoot: repo, pwd: pwd
        )
        #expect(result == repo)
    }

    @Test func repositoryModeFallsBackToPwdOutsideARepository() {
        let result = WorkspaceRootResolver.resolve(
            mode: .repository, groupRoot: group, repoRoot: nil, pwd: pwd
        )
        #expect(result == pwd)
    }

    // MARK: terminalFolder

    @Test func terminalFolderModeUsesThePwdEvenInsideAGroupAndRepo() {
        let result = WorkspaceRootResolver.resolve(
            mode: .terminalFolder, groupRoot: group, repoRoot: repo, pwd: pwd
        )
        #expect(result == pwd)
    }

    @Test func terminalFolderModeHasNothingToFallBackTo() {
        let result = WorkspaceRootResolver.resolve(
            mode: .terminalFolder, groupRoot: group, repoRoot: repo, pwd: nil
        )
        #expect(result == nil)
    }

    // MARK: Normalization

    /// Group roots are stored tilde-abbreviated (that's what the folder
    /// picker writes), but every filesystem call needs the real path.
    @Test func tildesAreExpanded() {
        let result = WorkspaceRootResolver.resolve(
            mode: .auto, groupRoot: "~/Projects/Aurora", repoRoot: nil, pwd: nil
        )
        #expect(result?.hasPrefix("/") == true)
        #expect(result?.contains("~") == false)
    }

    @Test func emptyStringsAreTreatedAsAbsent() {
        let result = WorkspaceRootResolver.resolve(
            mode: .auto, groupRoot: "", repoRoot: "", pwd: pwd
        )
        #expect(result == pwd)
    }

    @Test func everythingMissingResolvesToNothing() {
        let result = WorkspaceRootResolver.resolve(
            mode: .auto, groupRoot: nil, repoRoot: nil, pwd: nil
        )
        #expect(result == nil)
    }
}
