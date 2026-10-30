import AppKit
import SwiftUI
import Testing

@testable import Ghostty

/// Regression coverage for issue #14: hiding the editor must really hide its
/// native hierarchy (`NSView.isHidden`), not just fade it out, so WebKit and
/// the scroll-view editors stop all visibility/occlusion activity while the
/// terminal underneath is scrolled.
@MainActor
struct EditorVisibilityHostTests {
    private var items: [EditorContentItem] {
        [.init(id: .terminal, content: AnyView(Text("terminal"))),
         .init(id: .workspace, content: AnyView(Text("editor")))]
    }

    @Test func restoredVisibleEditorStillMountsTheTerminal() throws {
        let deck = EditorContentDeckController()
        deck.update(items: items, selectedID: .workspace)
        #expect(try #require(deck.hosts[.terminal]).isHidden)
        #expect(try #require(deck.hosts[.workspace]).isHidden == false)
    }

    @Test func retogglingVisibilityKeepsSameNativeHierarchy() throws {
        let deck = EditorContentDeckController()
        deck.update(items: items, selectedID: .workspace)
        let editor = try #require(deck.hosts[.workspace])
        let terminal = try #require(deck.hosts[.terminal])
        deck.update(items: items, selectedID: .terminal)
        #expect(editor.isHidden)
        #expect(!terminal.isHidden)
        deck.update(items: items, selectedID: .workspace)
        #expect(!editor.isHidden)
        #expect(terminal.isHidden)
        #expect(deck.hosts[.workspace] === editor)
        #expect(deck.hosts[.terminal] === terminal)
    }

    @Test func closingDocumentsBoundsTheCacheAndPreservesVisitedSelection() throws {
        let deck = EditorContentDeckController()
        let first = EditorContentKey.diff(UUID()), second = EditorContentKey.diff(UUID())
        let documents = [EditorContentItem(id: first, content: AnyView(Text("first"))),
                         EditorContentItem(id: second, content: AnyView(Text("second")))]
        deck.update(items: documents, selectedID: first)
        #expect(deck.hosts[second] == nil)
        let original = try #require(deck.hosts[first])
        deck.update(items: documents, selectedID: second)
        #expect(original.isHidden)
        deck.update(items: documents, selectedID: first)
        #expect(deck.hosts[first] === original)
        deck.update(items: [documents[1]], selectedID: second)
        #expect(deck.hosts[first] == nil)
        #expect(original.superview == nil)
    }

    @Test func hostDoesNotSelfSizeFromAppKitConstraints() throws {
        let deck = EditorContentDeckController()
        deck.view.setFrameSize(CGSize(width: 640, height: 480))
        deck.update(items: items, selectedID: .workspace)
        deck.view.layoutSubtreeIfNeeded()
        let editor = try #require(deck.hosts[.workspace])
        #expect(editor.sizingOptions.isEmpty)
        #expect(editor.frame == deck.view.bounds)
        deck.view.setFrameSize(CGSize(width: 800, height: 600))
        deck.view.layoutSubtreeIfNeeded()
        #expect(editor.frame == deck.view.bounds)
    }
}
