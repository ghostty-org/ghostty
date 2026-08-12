import Foundation
@testable import Ghostty
import Testing

/// Resolving Volar's `tsdk` — the one piece of `initializationOptions`
/// this app builds automatically today.
///
/// `searchPath` is always passed explicitly here rather than left to
/// resolve from the login shell: a test that shells out to whatever `npm`
/// happens to be on the machine running it would pass or fail depending on
/// the developer's own setup, which is exactly the nondeterminism a test
/// exists to rule out.
struct LSPInitializationOptionsTests {
    private func makeDirectory() -> String {
        let directory = NSTemporaryDirectory() + "phantom-tsdk-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The project's own copy wins over the global one, so a workspace that
    /// pins a version is checked against that version.
    @Test func aProjectLocalTypeScriptWinsOverTheGlobalOne() {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let local = root + "/node_modules/typescript/lib"
        try? FileManager.default.createDirectory(atPath: local, withIntermediateDirectories: true)

        // An empty search path means `npm` itself can never be found, so a
        // success here can only have come from the local check.
        switch LSPInitializationOptions.vueTypeScriptSDK(root: root, searchPath: "") {
        case .success(let path): #expect(path == local)
        case .failure(let reason): Issue.record("expected the local path, got failure: \(reason)")
        }
    }

    /// Neither a local install nor a resolvable `npm` on `PATH` produces the
    /// concrete message this feature exists to show instead of silence.
    @Test func neitherLocalNorGlobalProducesTheNamedFailure() {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }

        switch LSPInitializationOptions.vueTypeScriptSDK(root: root, searchPath: "") {
        case .success(let path): Issue.record("expected failure, got a path: \(path)")
        case .failure(let reason): #expect(reason == LSPInitializationOptions.missingTypeScriptMessage)
        }
    }

    /// The value shape Volar's own docs specify: nested under `typescript`,
    /// not sent as a bare string.
    @Test func theValueNestsTsdkUnderTypescript() {
        let value = LSPInitializationOptions.vueValue(tsdk: "/path/to/lib")
        #expect(value["typescript"]?["tsdk"]?.stringValue == "/path/to/lib")
    }
}
