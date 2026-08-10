import AppKit
import Foundation
@testable import Ghostty
import Testing

/// Editing a file and saving it.
///
/// This is the hole that let the editor ship unable to do the one thing an
/// editor is for. Every test here drove the seams around the buffer instead
/// of the buffer itself, so nothing noticed that the text a reader typed
/// never reached the document — `⌘S` wrote back what had been *loaded*, and
/// the next redraw put that on screen with the cursor at zero.
@MainActor
struct EditorSaveTests {
    private func document(_ contents: String) -> (EditorDocument, String) {
        let path = NSTemporaryDirectory() + "phantom-save-\(UUID().uuidString).swift"
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
        guard case .success(let document) = EditorDocument.load(url: URL(fileURLWithPath: path))
        else {
            Issue.record("the fixture could not be loaded")
            return (EditorDocument(url: URL(fileURLWithPath: path), text: contents), path)
        }
        return (document, path)
    }

    private func onDisk(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    @Test func whatWasTypedIsWhatGetsSaved() {
        let (document, path) = document("let a = 1")
        defer { try? FileManager.default.removeItem(atPath: path) }

        document.edited("let a = 2")
        #expect(document.save())
        #expect(onDisk(path) == "let a = 2")
    }

    @Test func typingMarksTheDocumentDirty() {
        let (document, path) = document("let a = 1")
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(!document.isDirty)
        document.edited("let a = 2")
        #expect(document.isDirty)
    }

    @Test func savingClearsTheDot() {
        let (document, path) = document("let a = 1")
        defer { try? FileManager.default.removeItem(atPath: path) }

        document.edited("let a = 2")
        _ = document.save()
        #expect(!document.isDirty)
    }

    /// Undoing back to the saved version is not a change, and the dot should
    /// go out — which is why the edit is compared rather than assumed.
    @Test func typingBackToTheSavedVersionIsNotDirty() {
        let (document, path) = document("let a = 1")
        defer { try? FileManager.default.removeItem(atPath: path) }

        document.edited("let a = 2")
        document.edited("let a = 1")
        #expect(!document.isDirty)
    }

    /// The revision is what tells the view "this came from the host, take
    /// it". Typing must not bump it, or the view would reload the text it
    /// just reported and lose the insertion point — the bug, exactly.
    @Test func typingDoesNotBumpTheRevision() {
        let (document, path) = document("let a = 1")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let before = document.revision
        document.edited("let a = 2")
        #expect(document.revision == before)
    }

    /// And a replacement from this side must bump it, or a formatted or
    /// renamed document would be saved correctly and shown stale.
    @Test func replacingTheTextBumpsTheRevision() {
        let (document, path) = document("let a = 1")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let before = document.revision
        document.replaceText("let a = formatted")
        #expect(document.revision == before + 1)
        #expect(document.currentText == "let a = formatted")
    }

    /// Saving twice in a row must not write the loaded text the second time.
    @Test func aSecondSaveKeepsTheLatestEdit() {
        let (document, path) = document("one")
        defer { try? FileManager.default.removeItem(atPath: path) }

        document.edited("two")
        _ = document.save()
        document.edited("three")
        _ = document.save()
        #expect(onDisk(path) == "three")
    }

    /// A reload replaces the buffer, so it does bump — and the text the
    /// document reports afterwards is the disk's.
    @Test func revertingTakesTheDiskVersion() {
        let (document, path) = document("original")
        defer { try? FileManager.default.removeItem(atPath: path) }

        document.edited("mine")
        try? "theirs".write(toFile: path, atomically: true, encoding: .utf8)

        let before = document.revision
        document.revert()
        #expect(document.currentText == "theirs")
        #expect(document.revision > before)
        #expect(!document.isDirty)
    }

    /// "Keep Mine" acknowledges their change without taking it: the buffer
    /// survives, the warning goes, and the document stays dirty because what
    /// is on screen still isn't what is on disk.
    @Test func keepingTheLocalVersionLeavesItDirty() {
        let (document, path) = document("original")
        defer { try? FileManager.default.removeItem(atPath: path) }

        document.edited("mine")
        try? "theirs".write(toFile: path, atomically: true, encoding: .utf8)
        document.keepLocalVersion()

        #expect(document.currentText == "mine")
        #expect(document.isDirty)
        #expect(!document.hasConflict)
    }
}

/// ⌘-click, which stopped working because the check was too strict.
@MainActor
struct JumpClickTests {
    /// The regression: demanding the flags equal exactly `.command` failed
    /// on a real event, which also carries caps lock, the function bit and
    /// the numeric-pad bit depending on the keyboard. Go-to-definition
    /// simply stopped responding.
    @Test func harmlessModifiersDoNotBlockAJump() {
        #expect(CodeNSTextView.isJumpClick(.command))
        #expect(CodeNSTextView.isJumpClick([.command, .capsLock]))
        #expect(CodeNSTextView.isJumpClick([.command, .function]))
        #expect(CodeNSTextView.isJumpClick([.command, .numericPad]))
    }

    /// The three that change what a click means keep meaning it: ⇧ extends a
    /// selection, ⌥ makes it rectangular, ⌃ opens a menu.
    @Test func modifiersThatMeanSomethingElseStillDo() {
        #expect(!CodeNSTextView.isJumpClick([.command, .shift]))
        #expect(!CodeNSTextView.isJumpClick([.command, .option]))
        #expect(!CodeNSTextView.isJumpClick([.command, .control]))
    }

    @Test func aClickWithoutCommandIsAnOrdinaryClick() {
        #expect(!CodeNSTextView.isJumpClick([]))
        #expect(!CodeNSTextView.isJumpClick(.shift))
        #expect(!CodeNSTextView.isJumpClick([.option, .control]))
    }
}
