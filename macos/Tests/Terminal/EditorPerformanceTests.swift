import AppKit
import Foundation
@testable import Ghostty
import Testing

/// The line index, which exists because converting a batch of positions one
/// at a time walked the document once per position.
struct LSPLineIndexTests {
    private func document(lines: Int) -> NSString {
        (0..<lines).map { "let value\($0) = \($0)" }.joined(separator: "\n") as NSString
    }

    @Test func itAgreesWithTheOneShotHelpers() {
        let text = document(lines: 200)
        let index = LSPLineIndex(text)

        for line in [0, 1, 57, 199] {
            let position = LSPPosition(line: line, character: 4)
            #expect(index.offset(of: position) == LSPTextCoordinates.offset(of: position, in: text))
        }
    }

    @Test func positionsRoundTrip() {
        let text = document(lines: 500)
        let index = LSPLineIndex(text)

        for offset in [0, 13, 900, 4_000, text.length] {
            let position = index.position(at: offset)
            #expect(index.offset(of: position) == offset)
        }
    }

    /// The binary search replaced a linear walk. Both must answer the same
    /// thing at a line boundary, which is where an off-by-one hides.
    @Test func aPositionExactlyOnALineStartBelongsToThatLine() {
        let text = "aa\nbb\ncc" as NSString
        let index = LSPLineIndex(text)

        #expect(index.position(at: 3) == LSPPosition(line: 1, character: 0))
        #expect(index.position(at: 2) == LSPPosition(line: 0, character: 2))
        #expect(index.position(at: 6) == LSPPosition(line: 2, character: 0))
    }

    @Test func anEmptyDocumentHasOneLine() {
        let index = LSPLineIndex("" as NSString)
        #expect(index.position(at: 0) == LSPPosition(line: 0, character: 0))
        #expect(index.offset(of: LSPPosition(line: 0, character: 0)) == 0)
    }

    @Test func outOfRangeClampsRatherThanCrashing() {
        let index = LSPLineIndex("short" as NSString)
        #expect(index.offset(of: LSPPosition(line: 0, character: 999)) == 5)
        #expect(index.offset(of: LSPPosition(line: 99, character: 0)) == nil)
        #expect(index.position(at: -5) == LSPPosition(line: 0, character: 0))
        #expect(index.position(at: 999) == LSPPosition(line: 0, character: 5))
    }

    /// The bug this guards, stated as a budget: converting many positions
    /// must not cost one document scan each. A thousand conversions over a
    /// ten-thousand-line file is ~10 million character visits the old way,
    /// and effectively free with a shared index.
    @Test func aBatchOfConversionsDoesNotRescanTheDocument() {
        let text = document(lines: 10_000)
        let index = LSPLineIndex(text)

        let started = ContinuousClock.now
        for line in stride(from: 0, to: 10_000, by: 10) {
            _ = index.offset(of: LSPPosition(line: line, character: 2))
        }
        let elapsed = ContinuousClock.now - started

        #expect(elapsed < .seconds(1))
    }
}

/// Drawing the map of a file the highlighter has nothing to say about.
struct MinimapPlainRowTests {
    /// The bug: plain rows take the foreground colour, and a file with no
    /// tokens at all is *entirely* plain — so every line was drawn as a
    /// near-full-width bar in the text colour and the minimap came out a
    /// solid white column.
    @Test func plainRowsAreDrawnFainterThanTokens() {
        let plain = CodeMinimapView.alpha(for: .plain)
        #expect(plain < CodeMinimapView.alpha(for: .keyword))
        #expect(plain < CodeMinimapView.alpha(for: .string))
        #expect(plain < CodeMinimapView.alpha(for: .comment))
    }

    /// Faint, but still drawn: a map with no plain rows would lose the
    /// shape of the file, which is the only thing it is for.
    @Test func plainRowsAreStillVisible() {
        #expect(CodeMinimapView.alpha(for: .plain) > 0.05)
    }

    /// Every kind carries the same weight as every other token kind, so no
    /// single language reads louder than another.
    @Test func everyTokenKindSharesOneWeight() {
        let kinds: [TokenKind] = [.keyword, .string, .comment, .number, .type, .function, .attribute]
        let weights = Set(kinds.map { CodeMinimapView.alpha(for: $0) })
        #expect(weights.count == 1)
    }
}

/// Which files the highlighter recognises.
struct SwiftInterfaceLanguageTests {
    /// Where go-to-definition lands when the symbol lives in a framework.
    /// Arriving as plain text made the whole file unhighlighted — and, via
    /// the minimap, visibly broken.
    @Test func aModuleInterfaceIsSwift() {
        #expect(CodeLanguage.resolve(fileName: "AppIntents.swiftinterface") == .swift)
        #expect(CodeLanguage.resolve(fileName: "Foundation.private.swiftinterface") == .swift)
    }

    @Test func ordinarySwiftIsUnaffected() {
        #expect(CodeLanguage.resolve(fileName: "EditorPaneView.swift") == .swift)
    }
}

/// Colouring a document that is too big to colour all at once.
@MainActor
struct LargeDocumentHighlightTests {
    /// The threshold has to sit above anything a person writes and below the
    /// generated files — a module interface is where go-to-definition lands,
    /// and it is tens of thousands of lines.
    @Test func thresholdSeparatesHandWrittenFromGenerated() {
        let handWritten = 60 * 1024
        let generated = 2 * 1024 * 1024
        let budget = 256 * 1024

        #expect(handWritten < budget)
        #expect(generated > budget)
    }

    /// The visible region is widened to whole lines before it is coloured;
    /// starting mid-token would colour half a keyword.
    @Test func theColouredRegionCoversWholeLines() {
        let text = "let alpha = 1\nlet beta = 2\nlet gamma = 3" as NSString
        let middleOfLineTwo = NSRange(location: 18, length: 2)
        let widened = CodeTextStorage.invalidationRange(
            for: middleOfLineTwo,
            in: text
        )

        #expect(widened.location <= 14)
        #expect(NSMaxRange(widened) >= 27)
    }

    /// And it never runs past the end, whatever the viewport reports.
    @Test func theColouredRegionStaysInsideTheDocument() {
        let text = "short document" as NSString
        let beyond = NSRange(location: 10, length: 500)
        let widened = CodeTextStorage.invalidationRange(for: beyond, in: text)

        #expect(NSMaxRange(widened) <= text.length)
    }
}

/// Fitting a long document into a map that is only so tall.
struct MinimapCompressionTests {
    private func rows(_ count: Int, kind: TokenKind = .plain) -> [CodeMinimapView.Row] {
        (0..<count).map { CodeMinimapView.Row(indent: 0, length: $0 % 90 + 1, kind: kind) }
    }

    /// A document that fits is left exactly as it is — no reduction, no
    /// rounding, one bar per line.
    @Test func aShortDocumentIsNotReduced() {
        #expect(CodeMinimapView.bucketSize(for: 300, into: 550) == 1)
        #expect(CodeMinimapView.compress(rows(300), into: 550).count == 300)
    }

    /// The bug: 50,000 lines in a map 550 bars tall used to shrink each row
    /// to 0.02 points while still drawing it half a point tall, so twenty-
    /// five lines painted over each other and the map saturated solid.
    /// Reducing is what keeps one bar one bar.
    @Test func aLongDocumentIsReducedToWhatFits() {
        let drawn = CodeMinimapView.compress(rows(50_000), into: 550)
        #expect(drawn.count <= 550)
        #expect(CodeMinimapView.bucketSize(for: 50_000, into: 550) == 91)
    }

    /// Every line is still represented — the last group must not be dropped
    /// because it is short.
    @Test func theTailOfTheDocumentIsKept() {
        let bucket = CodeMinimapView.bucketSize(for: 1_001, into: 100)
        let drawn = CodeMinimapView.compress(rows(1_001), into: 100)
        #expect(drawn.count == (1_001 + bucket - 1) / bucket)
        #expect(drawn.count * bucket >= 1_001)
    }

    /// A bar stands for the widest line in its group, so a block of code
    /// among blank lines still shows up as code.
    @Test func aBarTakesTheWidestLineItStandsFor() {
        let group = [
            CodeMinimapView.Row(indent: 0, length: 2, kind: .plain),
            CodeMinimapView.Row(indent: 0, length: 80, kind: .plain),
        ]
        #expect(CodeMinimapView.compress(group, into: 1).first?.length == 80)
    }

    /// And it takes the first kind that isn't plain, so a run of comments
    /// reads as comments instead of being averaged into nothing.
    @Test func aBarPrefersATokenKindOverPlain() {
        let group = [
            CodeMinimapView.Row(indent: 0, length: 1, kind: .plain),
            CodeMinimapView.Row(indent: 0, length: 1, kind: .comment),
            CodeMinimapView.Row(indent: 0, length: 1, kind: .keyword),
        ]
        #expect(CodeMinimapView.compress(group, into: 1).first?.kind == .comment)
    }

    @Test func anEmptyDocumentReducesToNothing() {
        #expect(CodeMinimapView.compress([], into: 550).isEmpty)
        #expect(CodeMinimapView.bucketSize(for: 0, into: 550) == 1)
    }

    /// A map with no height must not divide by zero on its way to drawing
    /// nothing.
    @Test func aMapWithNoRoomDoesNotDivideByZero() {
        #expect(CodeMinimapView.bucketSize(for: 5_000, into: 0) == 1)
    }
}

/// Scrubbing the minimap.
@MainActor
struct MinimapScrollTests {
    /// The bug: the map used to move the insertion point on its way to
    /// scrolling, so dragging it silently relocated the cursor and the next
    /// keystroke landed where the reader had been looking. A minimap moves
    /// the viewport and nothing else — which is why it now reports a
    /// fraction rather than a line to select.
    @Test func aFractionIsMeasuredAgainstTheBarsNotTheView() {
        // A short file fills only the top of the map; a click below its last
        // bar is the end of the document, not somewhere past it.
        #expect(CodeMinimapView.fraction(at: 50, drawnHeight: 100) == 0.5)
        #expect(CodeMinimapView.fraction(at: 200, drawnHeight: 100) == 1)
        #expect(CodeMinimapView.fraction(at: -10, drawnHeight: 100) == 0)
    }

    @Test func anEmptyMapReportsTheTop() {
        #expect(CodeMinimapView.fraction(at: 40, drawnHeight: 0) == 0)
    }

    /// The target centres the requested part of the file in the viewport.
    @Test func theTargetCentresWhatWasPointedAt() {
        let target = CodeTextView.Coordinator.scrollTarget(
            fraction: 0.5,
            documentHeight: 1_000,
            visibleHeight: 200
        )
        #expect(target == 400)
    }

    /// And stops at the ends rather than overscrolling into blank space.
    @Test func theTargetStopsAtBothEnds() {
        let top = CodeTextView.Coordinator.scrollTarget(
            fraction: 0,
            documentHeight: 1_000,
            visibleHeight: 200
        )
        let bottom = CodeTextView.Coordinator.scrollTarget(
            fraction: 1,
            documentHeight: 1_000,
            visibleHeight: 200
        )
        #expect(top == 0)
        #expect(bottom == 800)
    }

    /// A document shorter than the viewport has nowhere to scroll to.
    @Test func aDocumentThatFitsDoesNotScroll() {
        let target = CodeTextView.Coordinator.scrollTarget(
            fraction: 1,
            documentHeight: 100,
            visibleHeight: 400
        )
        #expect(target == 0)
    }
}
