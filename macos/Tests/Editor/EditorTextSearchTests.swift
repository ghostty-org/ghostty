import AppKit
import Foundation
import Testing
import CodeEditTextView
import CodeEditSourceEditor
import CodeEditLanguages
@testable import Ghostty

struct EditorTextSearchTests {
    @Test func searchUsesUTF16RangesAndCaseOption() {
        let text = "😀Foo foo"
        #expect(EditorTextSearch.matches(in: text, query: "foo", caseSensitive: true) == [
            NSRange(location: 6, length: 3),
        ])
        #expect(EditorTextSearch.matches(in: text, query: "foo", caseSensitive: false) == [
            NSRange(location: 2, length: 3),
            NSRange(location: 6, length: 3),
        ])
    }

    @Test func emptyQueryHasNoMatches() {
        #expect(EditorTextSearch.matches(in: "text", query: "", caseSensitive: false).isEmpty)
    }

    @Test func replaceAllOrdersUTF16RangesFromEnd() {
        let matches = EditorTextSearch.matches(in: "😀 a a", query: "a", caseSensitive: true)
        #expect(EditorTextSearch.rangesForReplacement(matches) == [
            NSRange(location: 5, length: 1),
            NSRange(location: 3, length: 1),
        ])
    }

    @Test func lineJumpUsesLFAndUTF16Columns() {
        let text = "one\n😀two\nthree"
        #expect(EditorTextSearch.range(forLine: 2, column: 3, in: text) == NSRange(location: 6, length: 0))
        #expect(EditorTextSearch.range(forLine: 2, column: 2, in: text) == NSRange(location: 4, length: 0))
        #expect(EditorTextSearch.range(forLine: 2, column: 99, in: text) == NSRange(location: 9, length: 0))
        #expect(EditorTextSearch.range(forLine: 4, column: 1, in: text) == nil)
        #expect(EditorTextSearch.lineAndColumn(from: "2:3")?.line == 2)
        #expect(EditorTextSearch.lineAndColumn(from: "2:3")?.column == 3)
        #expect(EditorTextSearch.lineAndColumn(from: "") == nil)
        #expect(EditorTextSearch.lineAndColumn(from: "2:0") == nil)
    }

    @Test func nextAndPreviousMatchesWrap() {
        let matches = [NSRange(location: 1, length: 2), NSRange(location: 5, length: 2)]
        #expect(EditorTextSearch.matchIndex(
            in: matches, selection: matches[1], searchingForward: true
        ) == 0)
        #expect(EditorTextSearch.matchIndex(
            in: matches, selection: matches[0], searchingForward: false
        ) == 1)
    }

    @Test func selectedLineRangeIncludesWholeTouchedLines() {
        let text = "one\ntwo\nthree"
        #expect(EditorTextSearch.lineRange(
            containing: NSRange(location: 5, length: 0), in: text
        ) == NSRange(location: 4, length: 4))
        #expect(EditorTextSearch.lineRange(
            containing: NSRange(location: 5, length: 5), in: text
        ) == NSRange(location: 4, length: 9))
    }

    @Test @MainActor func lineActionsAtTrailingEmptyLineDoNotModifyPreviousLine() {
        #expect(EditorTextSearch.lineRange(
            containing: NSRange(location: 4, length: 0), in: "one\n"
        ) == NSRange(location: 4, length: 0))
        let textView = TextView(string: "one\n")
        textView.selectionManager.setSelectedRange(NSRange(location: 4, length: 0))
        #expect(EditorNativeTextActions.perform(.deleteLine, on: textView))
        #expect(textView.string == "one\n")
        #expect(EditorNativeTextActions.perform(.duplicateLine, on: textView))
        #expect(textView.string == "one\n\n")
        #expect(textView.selectionManager.textSelections.first?.range.location == 5)
        #expect(EditorNativeTextActions.perform(.undo, on: textView))
        #expect(textView.string == "one\n")
    }

    @Test @MainActor func nativeSelectionCopyCutPasteAndUndoUseTheEditorTextView() {
        let textView = TextView(string: "alpha beta")
        #expect(EditorNativeTextActions.select(NSRange(location: 0, length: 5), on: textView))
        #expect(textView.selectionManager.textSelections.first?.range == NSRange(location: 0, length: 5))

        #expect(EditorNativeTextActions.perform(.copy, on: textView))
        #expect(NSPasteboard.general.string(forType: .string) == "alpha")
        #expect(EditorNativeTextActions.perform(.cut, on: textView))
        #expect(textView.string == " beta")
        #expect(EditorNativeTextActions.perform(.undo, on: textView))
        #expect(textView.string == "alpha beta")

        textView.selectionManager.setSelectedRange(NSRange(location: 6, length: 4))
        #expect(EditorNativeTextActions.perform(.paste, on: textView))
        #expect(textView.string == "alpha alpha")
    }

    @Test @MainActor func nativeLineActionsUpdateTextSelectionAndUndoStack() {
        let textView = TextView(string: "one\ntwo\nthree")
        textView.selectionManager.setSelectedRange(NSRange(location: 5, length: 0))

        #expect(EditorNativeTextActions.perform(.duplicateLine, on: textView))
        #expect(textView.string == "one\ntwo\ntwo\nthree")
        #expect(textView.selectionManager.textSelections.first?.range.location == 9)
        #expect(EditorNativeTextActions.perform(.undo, on: textView))
        #expect(textView.string == "one\ntwo\nthree")

        textView.selectionManager.setSelectedRange(NSRange(location: 5, length: 0))
        #expect(EditorNativeTextActions.perform(.deleteLine, on: textView))
        #expect(textView.string == "one\nthree")
        #expect(textView.selectionManager.textSelections.first?.range == NSRange(location: 4, length: 0))

        #expect(EditorNativeTextActions.perform(.undo, on: textView))
        #expect(textView.string == "one\ntwo\nthree")

        textView.selectionManager.setSelectedRange(NSRange(location: 5, length: 0))
        #expect(EditorNativeTextActions.perform(.moveLineUp, on: textView))
        #expect(textView.string == "two\none\nthree")
        #expect(EditorNativeTextActions.perform(.moveLineDown, on: textView))
        #expect(textView.string == "one\ntwo\nthree")

        textView.selectionManager.setSelectedRange(NSRange(location: 5, length: 0))
        #expect(EditorNativeTextActions.perform(.copy, on: textView))
        #expect(NSPasteboard.general.string(forType: .string) == "two\n")
    }

    @Test @MainActor func multiCursorLineActionsOperateOncePerLineAndPreserveSelections() {
        let textView = TextView(string: "line1\nline2\nline3\nline4\n")
        let sel1 = NSRange(location: 2, length: 0)
        let sel2 = NSRange(location: 14, length: 0)
        textView.selectionManager.setSelectedRanges([sel1, sel2])
        #expect(textView.selectionManager.textSelections.count == 2)

        #expect(EditorNativeTextActions.perform(.copy, on: textView))
        #expect(NSPasteboard.general.string(forType: .string) == "line1\nline3\n")

        #expect(EditorNativeTextActions.perform(.duplicateLine, on: textView))
        #expect(textView.string == "line1\nline1\nline2\nline3\nline3\nline4\n")
        #expect(textView.selectionManager.textSelections.count == 2)

        textView.undoManager?.undo()
        #expect(textView.string == "line1\nline2\nline3\nline4\n")

        textView.selectionManager.setSelectedRanges([NSRange(location: 2, length: 0), NSRange(location: 14, length: 0)])
        #expect(EditorNativeTextActions.perform(.deleteLine, on: textView))
        #expect(textView.string == "line2\nline4\n")
        #expect(textView.selectionManager.textSelections.count == 2)

        textView.undoManager?.undo()
        #expect(textView.string == "line1\nline2\nline3\nline4\n")

        let same1 = NSRange(location: 1, length: 0)
        let same2 = NSRange(location: 3, length: 0)
        textView.selectionManager.setSelectedRanges([same1, same2])
        #expect(EditorNativeTextActions.perform(.deleteLine, on: textView))
        #expect(textView.string == "line2\nline3\nline4\n")
    }

    @Test @MainActor func commandRouterKeepsMultipleWeakOwnersIndependent() throws {
        final class Owner {}
        let first = Owner()
        let second = Owner()
        let router = EditorCommandRouter()
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "s",
            charactersIgnoringModifiers: "s",
            isARepeat: false,
            keyCode: 1
        ))
        var calls: [String] = []
        router.register(owner: first) { _ in
            calls.append("first")
            return false
        }
        router.register(owner: second) { _ in
            calls.append("second")
            return true
        }

        #expect(router.handle(event))
        #expect(calls == ["first", "second"])
        calls.removeAll()
        router.unregister(owner: second)
        #expect(!router.handle(event))
        #expect(calls == ["first"])
    }

    @Test @MainActor func replaceAllIsOneNativeUndoAndRedoOperation() {
        let textView = TextView(string: "a a")
        textView.replaceCharacters(in: NSRange(location: 3, length: 0), with: "!")
        let ranges = EditorTextSearch.matches(in: textView.string, query: "a", caseSensitive: true)

        #expect(EditorTextEditing.replace(on: textView, ranges: ranges, with: "long"))
        #expect(textView.string == "long long!")
        textView.undoManager?.undo()
        #expect(textView.string == "a a!")
        #expect(textView.undoManager?.canUndo == true)
        textView.undoManager?.redo()
        #expect(textView.string == "long long!")
    }

    @Test @MainActor func replaceDoesNotDeleteAdjacentUnmatchedBracketViaFilter() {
        final class SimulatedDeleteCloseDelegate: NSObject, TextViewDelegate {
            var shouldReplaceContentsInInvoked = false
            var willReplaceInvoked = false
            var didReplaceInvoked = false

            func textView(_ textView: TextView, shouldReplaceContentsIn range: NSRange, with string: String) -> Bool {
                MainActor.assumeIsolated {
                    shouldReplaceContentsInInvoked = true
                    if string.isEmpty && (textView.string as NSString).substring(with: range) == "(" {
                        let closeRange = NSRange(location: range.location + 1, length: 1)
                        if closeRange.location + closeRange.length <= textView.textStorage.length,
                           (textView.string as NSString).substring(with: closeRange) == ")" {
                            textView.textStorage.replaceCharacters(in: closeRange, with: "")
                        }
                    }
                    return true
                }
            }

            func textView(_ textView: TextView, willReplaceContentsIn range: NSRange, with string: String) {
                willReplaceInvoked = true
            }

            func textView(_ textView: TextView, didReplaceContentsIn range: NSRange, with string: String) {
                didReplaceInvoked = true
            }
        }

        let textView = TextView(string: "foo()")
        let delegate = SimulatedDeleteCloseDelegate()
        textView.delegate = delegate

        let openParenRanges = EditorTextSearch.matches(in: textView.string, query: "(", caseSensitive: true)
        #expect(openParenRanges.count == 1)

        #expect(EditorTextEditing.replace(on: textView, ranges: openParenRanges, with: ""))
        // Closing parenthesis must not be deleted.
        #expect(textView.string == "foo)")
        #expect(!delegate.shouldReplaceContentsInInvoked)
        #expect(delegate.willReplaceInvoked)
        #expect(delegate.didReplaceInvoked)

        textView.undoManager?.undo()
        #expect(textView.string == "foo()")

        // Replace all with multiple brackets
        let multiTextView = TextView(string: "foo() bar() baz()")
        multiTextView.delegate = delegate
        let multiOpen = EditorTextSearch.matches(in: multiTextView.string, query: "(", caseSensitive: true)
        #expect(multiOpen.count == 3)
        #expect(EditorTextEditing.replace(on: multiTextView, ranges: multiOpen, with: ""))
        #expect(multiTextView.string == "foo) bar) baz)")

        multiTextView.undoManager?.undo()
        #expect(multiTextView.string == "foo() bar() baz()")
    }

    @Test @MainActor func replacementDoesNotEditReadOnlyTextView() {
        let textView = TextView(string: "a a", isEditable: false)
        let ranges = EditorTextSearch.matches(in: textView.string, query: "a", caseSensitive: true)

        #expect(!EditorTextEditing.replace(on: textView, ranges: ranges, with: "b"))
        #expect(textView.string == "a a")
        #expect(textView.undoManager?.canUndo == false)
    }

    @Test @MainActor func markdownEditInvalidationAccountsForShiftedOffsets() {
        let textView = TextView(string: "# First\nchanged\n# Last\n")
        let provider = MarkdownHighlightProvider()
        provider.setUp(textView: textView, codeLanguage: .markdown)
        var invalidated = IndexSet()
        provider.applyEdit(textView: textView, range: NSRange(location: 8, length: 7), delta: 0) {
            invalidated = (try? $0.get()) ?? IndexSet()
        }
        #expect(invalidated == IndexSet(integersIn: 8..<16))
        provider.applyEdit(textView: textView, range: NSRange(location: 8, length: 3), delta: 4) {
            invalidated = (try? $0.get()) ?? IndexSet()
        }
        #expect(invalidated == IndexSet(integersIn: 8..<23))
        // Deleting the newline joins two lines and must invalidate the resulting whole line.
        let joined = TextView(string: "# Firstchanged\n# Last\n")
        provider.applyEdit(textView: joined, range: NSRange(location: 7, length: 1), delta: -1) {
            invalidated = (try? $0.get()) ?? IndexSet()
        }
        #expect(invalidated == IndexSet(integersIn: 0..<22))
    }

    @Test @MainActor func markdownHighlightProviderRecognizesHeadingsCodeAndLinks() async throws {
        let text = "# Title\n\n> quote\n\n```swift\nlet x = 1\n```\n\n[link](https://example.com)"
        let textView = TextView(string: text)
        let provider = MarkdownHighlightProvider()
        provider.setUp(textView: textView, codeLanguage: .markdown)

        let highlights: [HighlightRange] = try await withCheckedThrowingContinuation { continuation in
            provider.queryHighlightsFor(textView: textView, range: NSRange(location: 0, length: (text as NSString).length)) { result in
                continuation.resume(with: result)
            }
        }

        #expect(!highlights.isEmpty)
        #expect(highlights.contains { $0.capture == .keyword })
        #expect(highlights.contains { $0.capture == .comment })
        #expect(highlights.contains { $0.capture == .string })
    }

    @Test @MainActor func deleteLineWithOverlappingExpandedLineRangesDoesNotCrash() {
        let textView = TextView(string: "aaa\nbbb\nccc\nddd\n")
        // Selections (1, 4) ("aa\nb") and (6, 4) ("b\ncc") overlap when expanded to lines.
        textView.selectionManager.setSelectedRanges([
            NSRange(location: 1, length: 4),
            NSRange(location: 6, length: 4),
        ])

        #expect(EditorNativeTextActions.perform(.deleteLine, on: textView))
        #expect(textView.string == "ddd\n")
        #expect(textView.selectionManager.textSelections.first?.range.location == 0)

        #expect(EditorNativeTextActions.perform(.undo, on: textView))
        #expect(textView.string == "aaa\nbbb\nccc\nddd\n")
    }

    @Test @MainActor func insertLineBelowPlacesCursorOnNewLineAndAccountsForCumulativeOffsets() {
        // Single cursor on first line of "a\nb\n"
        let textView = TextView(string: "a\nb\n")
        textView.selectionManager.setSelectedRange(NSRange(location: 0, length: 0))

        #expect(EditorNativeTextActions.perform(.insertLineBelow, on: textView))
        #expect(textView.string == "a\n\nb\n")
        // Cursor must be on the newly inserted blank line (index 2), not before 'b' (index 3).
        #expect(textView.selectionManager.textSelections.first?.range.location == 2)

        // Multi-cursor test
        let multiTextView = TextView(string: "a\nb\n")
        multiTextView.selectionManager.setSelectedRanges([
            NSRange(location: 0, length: 0),
            NSRange(location: 2, length: 0),
        ])

        #expect(EditorNativeTextActions.perform(.insertLineBelow, on: multiTextView))
        #expect(multiTextView.string == "a\n\nb\n\n")
        let caretLocations = multiTextView.selectionManager.textSelections.map(\.range.location).sorted()
        #expect(caretLocations == [2, 5])
    }

    @Test @MainActor func moveLineMultipleNonContiguousBlocksSingleUndo() {
        let textView = TextView(string: "a\nb\nc\nd\ne\n")
        // Cursors in line 1 ("b\n" at loc 2) and line 3 ("d\n" at loc 6)
        textView.selectionManager.setSelectedRanges([
            NSRange(location: 2, length: 0),
            NSRange(location: 6, length: 0),
        ])

        #expect(EditorNativeTextActions.perform(.moveLineUp, on: textView))
        #expect(textView.string == "b\na\nd\nc\ne\n")

        // Single undo step must revert all moved blocks
        #expect(EditorNativeTextActions.perform(.undo, on: textView))
        #expect(textView.string == "a\nb\nc\nd\ne\n")
    }

}
