import Foundation
@testable import Ghostty
import Testing

/// Closing a tab that still has edits.
///
/// `hasUnsavedChanges` had been sitting in the model since the editor shipped
/// with nothing reading it, so closing a dirty tab threw the work away without
/// a word — the one thing an editor must never do quietly.
@MainActor
struct EditorCloseGuardTests {
    private func center(with contents: String) -> (EditorCenter, String) {
        let path = NSTemporaryDirectory() + "phantom-close-\(UUID().uuidString).swift"
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
        let center = EditorCenter()
        _ = center.open(URL(fileURLWithPath: path))
        return (center, path)
    }

    @Test func aCleanTabClosesWithoutAsking() {
        let (center, path) = center(with: "let a = 1")
        defer { try? FileManager.default.removeItem(atPath: path) }

        center.requestClose(path)
        #expect(center.closeConfirmation == nil)
        #expect(center.tabs.isEmpty)
    }

    @Test func aDirtyTabAsksInsteadOfClosing() {
        let (center, path) = center(with: "let a = 1")
        defer { try? FileManager.default.removeItem(atPath: path) }

        center.documents[path]?.edited("let a = 2")
        center.requestClose(path)

        #expect(center.closeConfirmation?.path == path)
        #expect(!center.tabs.isEmpty, "nothing may close before the answer")
    }

    /// "Save" writes and then closes — both, and in that order.
    @Test func savingClosesAndKeepsTheEdit() {
        let (center, path) = center(with: "let a = 1")
        defer { try? FileManager.default.removeItem(atPath: path) }

        center.documents[path]?.edited("let a = 2")
        center.saveAndClose(path)

        #expect(center.tabs.isEmpty)
        #expect((try? String(contentsOfFile: path, encoding: .utf8)) == "let a = 2")
    }

    /// "Don't Save" closes and leaves the file alone.
    @Test func discardingClosesAndLeavesTheFile() {
        let (center, path) = center(with: "let a = 1")
        defer { try? FileManager.default.removeItem(atPath: path) }

        center.documents[path]?.edited("let a = 2")
        center.close(path)

        #expect(center.tabs.isEmpty)
        #expect((try? String(contentsOfFile: path, encoding: .utf8)) == "let a = 1")
    }

    /// The confirmation names the file, because with several tabs open "this
    /// file" is not an answer.
    @Test func theQuestionNamesTheFile() {
        let (center, path) = center(with: "let a = 1")
        defer { try? FileManager.default.removeItem(atPath: path) }

        center.documents[path]?.edited("changed")
        center.requestClose(path)

        #expect(center.closeConfirmation?.name.hasSuffix(".swift") == true)
        #expect(center.closeConfirmation?.name.contains("/") == false)
    }
}

/// The minimap switch, which did nothing until the file was reopened.
struct MinimapToggleTests {
    /// It lives in the configuration so the appearance pass compares it. As a
    /// property of its own it was read once, when the view was made.
    @Test func theMinimapIsPartOfTheConfiguration() {
        var off = CodeEditorConfiguration.default
        off.showsMinimap = false
        #expect(off != CodeEditorConfiguration.default)
    }

    @Test func itDefaultsToShown() {
        #expect(CodeEditorConfiguration.default.showsMinimap)
    }
}
