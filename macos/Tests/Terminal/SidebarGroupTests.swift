import Foundation
@testable import Ghostty
import Testing

/// `SidebarGroup.discoverRepoRoots` against a throwaway directory tree —
/// this is the fix for a real report: a project group's root was a
/// *workspace* folder holding several repos side by side
/// (`~/Projects/Aurora/aurora-backend`, `.../front-app-aurora`), and the PR
/// popover showed "No repositories in this group" because it only looked
/// at tabs' own pwds, never at the group's root.
struct SidebarGroupTests {
    private func makeDir(_ base: URL, _ path: String, isRepo: Bool = false) throws -> URL {
        let url = base.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if isRepo {
            try FileManager.default.createDirectory(
                at: url.appendingPathComponent(".git"),
                withIntermediateDirectories: true
            )
        }
        return url
    }

    /// Resolved once, up front, via the POSIX `realpath` rather than
    /// `URL.resolvingSymlinksInPath()` — Foundation leaves the `/var` ->
    /// `/private/var` symlink `/tmp` sits behind alone (it's special-cased
    /// as already "canonical enough"), but `FileManager.contentsOfDirectory`
    /// returns the fully resolved form once a scan crosses that boundary.
    /// Building expected paths from the unresolved form would fail these
    /// tests over a difference the real feature never hits — `~/Projects`
    /// isn't behind a symlink.
    private func tempWorkspace() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(dir.path, &buffer) != nil else { return dir }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }

    @Test func findsRepoAtTheRootItself() throws {
        let base = try tempWorkspace()
        _ = try makeDir(base, ".", isRepo: true)

        let found = SidebarGroup.discoverRepoRoots(under: base.path)
        #expect(found == [base.path])
    }

    /// The exact shape this exists for: a workspace one level up from its
    /// member repos.
    @Test func findsRepoRootsOneLevelDown() throws {
        let base = try tempWorkspace()
        let repoA = try makeDir(base, "aurora-backend", isRepo: true)
        let repoB = try makeDir(base, "front-app-aurora", isRepo: true)
        _ = try makeDir(base, "not-a-repo")

        let found = Set(SidebarGroup.discoverRepoRoots(under: base.path))
        #expect(found == [repoA.path, repoB.path])
    }

    @Test func findsRepoRootsTwoLevelsDownWithinDefaultDepth() throws {
        let base = try tempWorkspace()
        let repo = try makeDir(base, "team/repoC", isRepo: true)

        let found = SidebarGroup.discoverRepoRoots(under: base.path)
        #expect(found == [repo.path])
    }

    @Test func doesNotDescendPastTheDefaultDepth() throws {
        let base = try tempWorkspace()
        _ = try makeDir(base, "a/b/c", isRepo: true) // three levels down

        let found = SidebarGroup.discoverRepoRoots(under: base.path)
        #expect(found.isEmpty)
    }

    /// Once a directory is recognized as a repo it's a leaf: a `.git`
    /// somewhere inside it (a submodule, a nested checkout) must not be
    /// reported as a second, separate repo of this group.
    @Test func stopsDescendingOnceARepoIsFound() throws {
        let base = try tempWorkspace()
        let outer = try makeDir(base, "outer", isRepo: true)
        _ = try makeDir(outer, "inner", isRepo: true)

        let found = SidebarGroup.discoverRepoRoots(under: base.path)
        #expect(found == [outer.path])
    }

    @Test func ignoresPlainFilesAmongTheEntries() throws {
        let base = try tempWorkspace()
        let repo = try makeDir(base, "repoA", isRepo: true)
        try "hello".write(
            to: base.appendingPathComponent("readme.txt"),
            atomically: true,
            encoding: .utf8
        )

        let found = SidebarGroup.discoverRepoRoots(under: base.path)
        #expect(found == [repo.path])
    }

    @Test func emptyWorkspaceFindsNothing() throws {
        let base = try tempWorkspace()
        let found = SidebarGroup.discoverRepoRoots(under: base.path)
        #expect(found.isEmpty)
    }

    @Test func aNonexistentRootFindsNothingRatherThanCrashing() {
        let found = SidebarGroup.discoverRepoRoots(under: "/nonexistent/\(UUID().uuidString)")
        #expect(found.isEmpty)
    }
}
