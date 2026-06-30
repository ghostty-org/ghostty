@testable import Ghostty
import Foundation
import Testing

struct OSSurfaceViewScreenTextTests {
    typealias ScreenText = Ghostty.OSSurfaceView.ScreenText

    @Test func emptyTextProducesEmpty() {
        let screenText = ScreenText(
            text: "",
            viewportStartByte: 0,
            viewportEndByte: 0
        )
        #expect(screenText == .empty)
    }

    @Test func asciiOffsetsAreIdentity() {
        let screenText = ScreenText(
            text: "hello\nworld",
            viewportStartByte: 6,
            viewportEndByte: 11
        )
        #expect(screenText.utf16Length == 11)
        #expect(screenText.viewportRange == NSRange(location: 6, length: 5))
    }

    @Test func emojiCountsAsTwoUTF16Units() {
        // U+1F600 ("😀") is 4 bytes in UTF-8 and a surrogate pair (two
        // code units) in UTF-16.
        let text = "a😀b"
        let screenText = ScreenText(
            text: text,
            viewportStartByte: 0,
            viewportEndByte: text.utf8.count
        )
        #expect(text.count == 3)
        #expect(screenText.utf16Length == 4)
        #expect(screenText.viewportRange == NSRange(location: 0, length: 4))
    }

    @Test func viewportRangeSkipsAcrossSurrogatePair() {
        let text = "a😀b"
        let screenText = ScreenText(
            text: text,
            viewportStartByte: 5,  // byte index of "b"
            viewportEndByte: 6     // byte index past "b"
        )
        #expect(screenText.viewportRange == NSRange(location: 3, length: 1))
    }

    @Test func cjkCharacterCountsAsOneUTF16Unit() {
        let text = "好"
        let screenText = ScreenText(
            text: text,
            viewportStartByte: 0,
            viewportEndByte: text.utf8.count
        )
        #expect(screenText.utf16Length == 1)
        #expect(screenText.viewportRange == NSRange(location: 0, length: 1))
    }

    @Test func viewportPastEndClampsToEndOfText() {
        let screenText = ScreenText(
            text: "hi",
            viewportStartByte: 10,
            viewportEndByte: 20
        )
        #expect(screenText.viewportRange.location == 2)
        #expect(screenText.viewportRange.length == 0)
    }

    @Test func reversedOffsetsCollapseToZeroLength() {
        // A negative NSRange.length is meaningless to AX clients; the
        // init normalizes to a zero-length range at start.
        let screenText = ScreenText(
            text: "abcdef",
            viewportStartByte: 4,
            viewportEndByte: 2
        )
        #expect(screenText.viewportRange.length == 0)
    }

    @Test func viewportInMiddleOfPureAscii() {
        let text = "scrollback\nviewport line\nmore content"
        let viewport = "viewport line\n"
        let start = text.utf8.distance(
            from: text.utf8.startIndex,
            to: text.range(of: viewport)!.lowerBound.samePosition(in: text.utf8)!
        )
        let screenText = ScreenText(
            text: text,
            viewportStartByte: start,
            viewportEndByte: start + viewport.utf8.count
        )
        #expect(screenText.utf16Length == (text as NSString).length)
        #expect(screenText.viewportRange.length == (viewport as NSString).length)
    }

    // MARK: lineStarts

    @Test(arguments: [
        // Empty-text case is covered by emptyTextProducesEmpty.
        ("hello", [0]),
        ("a\nb\nc", [0, 2, 4]),
        // CRLF is a single line terminator, not two.
        ("a\r\nb", [0, 3]),
        // Trailing newline creates an empty trailing line so the
        // past-end cursor is reported on its own line.
        ("a\nb\n", [0, 2, 4]),
    ])
    func lineStarts(text: String, expected: [Int]) {
        let screenText = ScreenText(
            text: text, viewportStartByte: 0, viewportEndByte: text.utf8.count
        )
        #expect(screenText.lineStarts == expected)
    }

    @Test(arguments: [
        (0, 0),  // before first char
        (1, 0),  // on the '\n'
        (2, 1),  // start of second line
        (3, 1),  // inside second line
        (4, 2),  // start of third line
        (5, 2),  // past end clamps to last line
        (100, 2) // way past end still clamps
    ])
    func lineAtIndex(index: Int, expected: Int) {
        let screenText = ScreenText(
            text: "a\nb\nc", viewportStartByte: 0, viewportEndByte: 5
        )
        #expect(screenText.line(at: index) == expected)
    }

    @Test func lineAtNegativeIndexClampsToZero() {
        let screenText = ScreenText(
            text: "a\nb", viewportStartByte: 0, viewportEndByte: 3
        )
        #expect(screenText.line(at: -1) == 0)
    }

    @Test func lineForEmptyText() {
        // Past-end indices clamp to line 0 when the text is empty;
        // the in-range `at: 0` case is covered by lineAtIndex.
        let screenText = ScreenText(
            text: "", viewportStartByte: 0, viewportEndByte: 0
        )
        #expect(screenText.line(at: 100) == 0)
    }

    // MARK: selectionRange

    @Test(arguments: [
        (2, 2),  // zero-length (also the default-args case)
        (4, 2),  // reversed
    ])
    func selectionMustBePositive(startByte: Int, endByte: Int) {
        let screenText = ScreenText(
            text: "hello",
            viewportStartByte: 0, viewportEndByte: 5,
            selectionStartByte: startByte, selectionEndByte: endByte
        )
        #expect(screenText.selectionRange == nil)
    }

    @Test func selectionAsciiOffsetsAreIdentity() {
        let screenText = ScreenText(
            text: "hello world",
            viewportStartByte: 0, viewportEndByte: 11,
            selectionStartByte: 6, selectionEndByte: 11
        )
        #expect(screenText.selectionRange == NSRange(location: 6, length: 5))
    }

    @Test func selectionAcrossSurrogatePair() {
        let text = "a😀b"
        let screenText = ScreenText(
            text: text,
            viewportStartByte: 0, viewportEndByte: text.utf8.count,
            selectionStartByte: 1, selectionEndByte: 5  // "😀"
        )
        // "😀" occupies a UTF-16 surrogate pair (locations 1..3).
        #expect(screenText.selectionRange == NSRange(location: 1, length: 2))
    }

    @Test func selectionPastEndClampsToEndOfText() {
        let screenText = ScreenText(
            text: "hi",
            viewportStartByte: 0, viewportEndByte: 2,
            selectionStartByte: 10, selectionEndByte: 20
        )
        #expect(screenText.selectionRange == NSRange(location: 2, length: 0))
    }
}
