import AppKit
import GhosttyKit
import Testing
@testable import Ghostty

@MainActor struct SurfaceView_SearchStateTests {
    typealias SearchState = Ghostty.OSSurfaceView.SearchState
    typealias StartSearch = Ghostty.Action.StartSearch

    /// A unique pasteboard for each test case prevents flakiness.
    let pasteboard = NSPasteboard.withUniqueName()

    /// libghostty reports a search with no needle as an empty string.
    var emptyStartSearch: StartSearch {
        "".withCString { StartSearch(c: .init(needle: $0)) }
    }

    init() {
        pasteboard.setString("pb", forType: .string)
    }

    @Test func init_withEmptyNeedle_readsPasteboardNeedle() {
        let sut = SearchState(
            from: emptyStartSearch,
            pasteboard: pasteboard
        )
        #expect(sut.needle.text == "pb")
    }

    @Test func init_withNeedle_setsNeedle() {
        "start".withCString { needle in
            let sut = SearchState(
                from: StartSearch(c: .init(needle: needle)),
                pasteboard: pasteboard
            )
            #expect(sut.needle.text == "start")
        }
    }

    @Test func init_withNeedle_writesPasteboard() {
        "start".withCString { needle in
            _ = SearchState(
                from: StartSearch(c: .init(needle: needle)),
                pasteboard: pasteboard
            )
            #expect(pasteboard.string(forType: .string) == "start")
        }
    }

    @Test func writePasteboardNeedle_writesPasteboard() {
        let sut = SearchState(
            from: emptyStartSearch,
            pasteboard: pasteboard
        )
        sut.setNeedle("sut")
        sut.writePasteboardNeedle()
        #expect(pasteboard.string(forType: .string) == "sut")
    }

    @Test func setNeedle_clearsNeedleSelection() {
        let sut = SearchState(
            from: emptyStartSearch,
            pasteboard: pasteboard
        )
        sut.needle.selection = sut.needle.text.startIndex..<sut.needle.text.endIndex

        sut.setNeedle("x")

        #expect(sut.needle.text == "x")
        #expect(sut.needle.selection == nil)
    }

    @Test func readPasteboardNeedle_whenPasteboardNeedleIsNil() {
        let sut = SearchState(
            from: emptyStartSearch,
            pasteboard: pasteboard
        )
        pasteboard.clearContents()
        sut.setNeedle("sut")
        sut.readPasteboardNeedle()
        #expect(sut.needle.text == "sut")
    }

    @Test func readPasteboardNeedle_whenPasteboardNeedleIsValid() {
        let sut = SearchState(
            from: emptyStartSearch,
            pasteboard: pasteboard
        )
        sut.setNeedle("sut")
        sut.readPasteboardNeedle()
        #expect(sut.needle.text == "pb")
    }

    @Test func readPasteboardNeedle_setsNeedleSelectionRange() {
        let sut = SearchState(
            from: emptyStartSearch,
            pasteboard: pasteboard
        )
        sut.setNeedle("sut")
        sut.readPasteboardNeedle()

        let expected = "pb".startIndex..<"pb".endIndex
        #expect(sut.needle.selection == expected)
    }
}
