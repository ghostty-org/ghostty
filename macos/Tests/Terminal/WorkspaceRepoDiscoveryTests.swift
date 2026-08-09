import Foundation
@testable import Ghostty
import Testing

/// The guards around workspace repository discovery.
///
/// The walk itself is `SidebarGroup.discoverRepoRoots`, covered by
/// `SidebarGroupTests`. What is new here is *when it is allowed to run*:
/// the Git panel calls this with whatever folder the terminal happens to
/// be in, and some folders are far too broad to scan.
struct WorkspaceRepoDiscoveryTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(dir.path, &buffer) != nil else { return dir }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }

    private func makeRepo(_ base: URL, _ name: String) throws -> String {
        let url = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        return url.path
    }

    @Test func repositoriesUnderAWorkspaceAreFound() throws {
        let base = try tempDir()
        _ = try makeRepo(base, "alpha")
        _ = try makeRepo(base, "beta")
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("not-a-repo"),
            withIntermediateDirectories: true
        )

        let found = GitCenter.discoverRepos(under: base.path)
        #expect(Set(found.map { ($0 as NSString).lastPathComponent }) == ["alpha", "beta"])
    }

    /// The home directory is the one that matters in practice: a `cd ~` is
    /// ordinary, and a two-level walk from there visits every folder in the
    /// home directory plus one level under each. Slow, and the result would
    /// be a list nobody asked for — somebody sitting in their home
    /// directory is not describing a project.
    @Test func theHomeDirectoryIsNeverScanned() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(GitCenter.discoverRepos(under: home).isEmpty)
    }

    /// The same guard must survive a path that means home without looking
    /// like it.
    @Test func theHomeDirectoryIsRecognizedThroughATrailingSlash() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(GitCenter.discoverRepos(under: home + "/").isEmpty)
        #expect(GitCenter.discoverRepos(under: home + "/.").isEmpty)
    }

    @Test func theFilesystemRootIsNeverScanned() {
        #expect(GitCenter.discoverRepos(under: "/").isEmpty)
    }

    /// A folder that doesn't exist has to answer empty rather than throw:
    /// the panel calls this with whatever pwd a terminal reports, and a
    /// terminal can outlive the directory it was opened in.
    @Test func aMissingFolderIsEmptyRatherThanAFailure() {
        #expect(GitCenter.discoverRepos(under: "/nope/not/here").isEmpty)
    }

    /// A folder one level up from home is fine — the guard is about the two
    /// specific roots, not about depth.
    @Test func anOrdinaryProjectsFolderIsStillScanned() throws {
        let base = try tempDir()
        let repo = try makeRepo(base, "only")
        #expect(GitCenter.discoverRepos(under: base.path) == [repo])
    }
}
