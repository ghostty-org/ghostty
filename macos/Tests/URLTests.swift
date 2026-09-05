import Foundation
import Testing
@testable import Ghostty

struct URLTests {
    @Test func pathWithoutTrailingSlash() {
        let url = URL(string: "file:///tmp/example/")!
        #expect(url.pathWithoutTrailingSlash == "/tmp/example")
    }

    @Test func pathWithoutMultipleTrailingSlashes() {
        let url = URL(string: "file:///tmp/example///")!
        #expect(url.pathWithoutTrailingSlash == "/tmp/example")
    }

    @Test func pathWithoutTrailingSlashDecodesPath() {
        let url = URL(string: "file:///tmp/example%20directory/")!
        #expect(url.pathWithoutTrailingSlash == "/tmp/example directory")
    }

    @Test func pathWithoutTrailingSlashPreservesRoot() {
        let url = URL(string: "file:///")!
        #expect(url.pathWithoutTrailingSlash == "/")
    }
}
