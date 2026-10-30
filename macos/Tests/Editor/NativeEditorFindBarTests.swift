import AppKit
import Testing
@testable import Ghostty

@MainActor
struct NativeEditorFindBarTests {
    @Test func deferredFocusAndEscapeRoutingSurviveLateWindowAttachment() async throws {
        var focused: [Bool] = []
        var closed = 0
        let bar = EditorFindBar(frame: .zero)
        let state = EditorFindBarState(
            query: "hello", replacement: "", summary: "1/2",
            isReplace: false, isGoToLine: false, isCaseSensitive: false,
            shouldFocus: true
        )
        let actions = EditorFindBarActions(
            queryChanged: { _ in }, replacementChanged: { _ in },
            caseChanged: { _ in }, focusChanged: { focused.append($0) },
            submit: {}, findPrevious: {}, findNext: {},
            replaceCurrent: {}, replaceAll: {}, close: { closed += 1 }
        )

        // SwiftUI may configure the representable before its NSView enters a window.
        bar.configure(state: state, actions: actions)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        bar.frame = NSRect(x: 80, y: 80, width: 360, height: 44)
        root.addSubview(bar)
        let window = NSWindow(contentRect: root.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(50))

        #expect(bar.searchField.stringValue == "hello")
        let editor = try #require(window.firstResponder as? NSTextView)
        #expect(editor === bar.searchField.currentEditor())
        #expect(bar.intrinsicContentSize.height == 44)
        #expect(bar.control(bar.searchField, textView: editor,
                            doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(closed == 1)

        bar.configure(
            state: .init(query: "hello", replacement: "world", summary: "1/2",
                         isReplace: true, isGoToLine: false,
                         isCaseSensitive: true, shouldFocus: false),
            actions: actions
        )
        #expect(bar.intrinsicContentSize.height == 76)
    }
}
