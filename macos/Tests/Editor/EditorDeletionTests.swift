import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView
import SwiftUI
import Testing
@testable import Ghostty

/// Regression coverage for the editor deleting large blocks of text.
///
/// Two dependency defects used to surface here: `TextLineStorage` lost red-black
/// tree metadata when a line node was removed (content rendered partially), and
/// the highlighter's style store indexed past the end of its rope while syncing
/// a deletion (Swift runtime trap, process exit). Both must stay unobservable.
@Suite(.serialized) @MainActor
struct EditorDeletionTests {
    /// Capture coordinator that keeps the controller reachable from the test.
    private final class ControllerCapture: TextViewCoordinator {
        weak var controller: TextViewController?
        func prepareCoordinator(controller: TextViewController) { self.controller = controller }
    }

    /// Mounts a real editor running both OMG highlight providers, mirroring
    /// `EditorCoordinator.highlightProviders`.
    private func mountedEditor(
        text: String,
        language: CodeLanguage
    ) throws -> (capture: ControllerCapture, host: NSHostingController<SourceEditor>, textView: TextView) {
        let capture = ControllerCapture()
        let providers: [any HighlightProviding] = [EditorSyntaxHighlightProvider(), MarkdownHighlightProvider()]
        let editor = EditorTestSupport.editor(
            text: .constant(text),
            language: language,
            highlightProviders: providers,
            coordinators: [capture]
        )
        let host = EditorTestSupport.hostedView(editor, size: NSSize(width: 720, height: 480))
        let textView = try #require(capture.controller?.textView)
        return (capture, host, textView)
    }

    @Test func deletingLargeSelectionKeepsLineStorageAndSelectionConsistent() async throws {
        let lineCount = 400
        let source = (0..<lineCount).map { "value_\($0) = compute(\($0))" }.joined(separator: "\n") + "\n"
        let (capture, host, textView) = try mountedEditor(text: source, language: .python)
        // Highlighting is asynchronous; let the initial full-document query land
        // so the style store already covers every line before we delete.
        try await Task.sleep(for: .milliseconds(300))
        #expect(textView.layoutManager.lineCount == lineCount + 1)

        let ns = source as NSString
        let start = ns.range(of: "value_40").location
        let end = ns.range(of: "value_339").location
        let deletion = NSRange(location: start, length: end - start)
        let remaining = ns.replacingCharacters(in: deletion, with: "") as NSString

        textView.selectionManager.setSelectedRange(deletion)
        textView.replaceCharacters(in: deletion, with: "")
        try await Task.sleep(for: .milliseconds(300))

        #expect(textView.string == remaining as String)
        // A lost line node shows up as fewer lines than the newline count.
        #expect(textView.layoutManager.lineCount == remaining.components(separatedBy: "\n").count)
        let selection = try #require(textView.selectionManager.textSelections.first?.range)
        #expect(selection.location != NSNotFound)
        #expect(NSMaxRange(selection) <= textView.textStorage.length)
        // The caret must still resolve to a laid-out position for IME and
        // completion anchoring.
        #expect(textView.layoutManager.rectForOffset(selection.location) != nil)
        // Keep the mount and coordinator alive for the whole test.
        withExtendedLifetime((capture, host)) {}
    }

    /// Deleting the tail of the document is the exact path that trapped the
    /// highlighter's style store.
    @Test(arguments: [true, false])
    func deletingDocumentTailDoesNotTrapTheHighlighter(atEndOfDocument: Bool) async throws {
        let lines = (0..<300).map { "row_\($0)" }
        var source = lines.joined(separator: "\n")
        if atEndOfDocument { source += "\n" }
        let (capture, host, textView) = try mountedEditor(text: source, language: .python)
        try await Task.sleep(for: .milliseconds(300))

        let ns = source as NSString
        let cut = atEndOfDocument
            ? NSRange(location: ns.range(of: "row_150").location, length: ns.length - ns.range(of: "row_150").location)
            : NSRange(location: ns.range(of: "row_120").location, length: ns.range(of: "row_180").location
                - ns.range(of: "row_120").location)
        let expected = ns.replacingCharacters(in: cut, with: "")
        textView.selectionManager.setSelectedRange(cut)
        textView.replaceCharacters(in: cut, with: "")
        try await Task.sleep(for: .milliseconds(300))

        #expect(textView.string == expected)
        #expect(textView.layoutManager.lineCount == (expected as NSString).components(separatedBy: "\n").count)
        // Keep the mount and coordinator alive for the whole test.
        withExtendedLifetime((capture, host)) {}
    }

    /// Repeated deletes keep exercising the same store; the bug only showed up
    /// after several hundred removed lines, so run the edit loop to completion.
    @Test func repeatedLineDeletionKeepsEveryLineReachable() async throws {
        let source = (0..<250).map { "item_\($0)" }.joined(separator: "\n") + "\n"
        let (capture, host, textView) = try mountedEditor(text: source, language: .markdown)
        try await Task.sleep(for: .milliseconds(300))

        for _ in 0..<20 {
            guard !textView.string.isEmpty else { break }
            let current = textView.string as NSString
            let lineRange = current.lineRange(for: NSRange(location: 0, length: 0))
            textView.selectionManager.setSelectedRange(lineRange)
            textView.replaceCharacters(in: lineRange, with: "")
        }
        try await Task.sleep(for: .milliseconds(200))

        let remaining = textView.string as NSString
        #expect(textView.layoutManager.lineCount == remaining.components(separatedBy: "\n").count)
        // Walk every line index; a corrupted tree returns nil or repeats ranges.
        var expectedLocation = 0
        for index in 0..<textView.layoutManager.lineCount {
            let line = try #require(textView.layoutManager.textLineForIndex(index))
            #expect(line.range.location == expectedLocation)
            expectedLocation = NSMaxRange(line.range)
        }
        #expect(expectedLocation == remaining.length)
        // Keep the mount and coordinator alive for the whole test.
        withExtendedLifetime((capture, host)) {}
    }
}
