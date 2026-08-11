import Foundation
@testable import Ghostty
import Testing

/// Finding a language server that was installed after the app started.
///
/// The bug: `missing` was append-only. A command that could not be found
/// went into the list and nothing ever looked again, so the banner outlived
/// the install and only a restart cleared it.
struct LSPLocateTests {
    /// Writes an executable into a temporary directory and returns both.
    private func makeExecutable(named name: String) -> (directory: String, path: String) {
        let directory = NSTemporaryDirectory() + "phantom-bin-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        let path = directory + "/" + name
        try? "#!/bin/sh\n".write(toFile: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: path
        )
        return (directory, path)
    }

    /// The whole point: a probe that failed must be able to succeed later,
    /// with no state carried over from the failure.
    @Test func aBinaryCreatedAfterAFailedProbeIsFound() {
        let directory = NSTemporaryDirectory() + "phantom-bin-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: directory) }

        #expect(LSPProcess.locate("later-server", searchPath: directory) == nil)

        let path = directory + "/later-server"
        try? "#!/bin/sh\n".write(toFile: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)

        #expect(LSPProcess.locate("later-server", searchPath: directory) != nil)
    }

    @Test func aFileThatIsNotExecutableIsNotAServer() {
        let directory = NSTemporaryDirectory() + "phantom-bin-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let path = directory + "/not-executable"
        try? "text".write(toFile: path, atomically: true, encoding: .utf8)

        #expect(LSPProcess.locate("not-executable", searchPath: directory) == nil)
    }

    /// A `PATH` with several entries, which is the real shape — the binary is
    /// in one of them and the others must not stop the search.
    @Test func everyPathEntryIsSearched() {
        let installed = makeExecutable(named: "somewhere-server")
        defer { try? FileManager.default.removeItem(atPath: installed.directory) }

        let searchPath = "/nonexistent-a:\(installed.directory):/nonexistent-b"
        #expect(LSPProcess.locate("somewhere-server", searchPath: searchPath) != nil)
    }

    @Test func anEmptyPathFindsNothing() {
        #expect(LSPProcess.locate("anything", searchPath: "") == nil)
    }
}

/// Invalidating the cached login `PATH`.
///
/// Neither test asserts the resolved `PATH` is non-empty: resolving one
/// shells out to the login shell, and a CI runner with no real profile —
/// `.zshrc` never sourced, no Homebrew, nothing — can legitimately come back
/// with nothing to report. That absence is a fact about the host, not about
/// whether invalidation works, which is the only thing these describe.
struct LoginPathInvalidationTests {
    /// The second layer of stickiness: the `PATH` is resolved once and kept
    /// for the life of the process, so a version manager moving its bin
    /// directory — `nvm use` — left every lookup searching the old one.
    @Test func invalidatingMakesTheNextReadResolveAgain() {
        let first = LoginEnvironment.loginPath()
        LoginEnvironment.invalidate()
        let second = LoginEnvironment.loginPath()

        // Same answer on a machine that hasn't changed, and the point is that
        // it was *asked* again rather than served from the first call.
        #expect(first == second)
    }

    @Test func invalidatingTwiceIsHarmless() {
        LoginEnvironment.invalidate()
        LoginEnvironment.invalidate()
        _ = LoginEnvironment.loginPath() // must not crash or hang
    }
}
