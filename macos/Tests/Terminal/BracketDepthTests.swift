import AppKit
import Foundation
@testable import Ghostty
import Testing

/// Pairing brackets by nesting depth.
struct BracketDepthTests {
    private func spans(_ source: String, skipping: [NSRange] = []) -> [BracketDepth.Span] {
        BracketDepth.spans(
            in: source as NSString,
            range: NSRange(location: 0, length: (source as NSString).length),
            skipping: skipping
        )
    }

    private func depths(_ source: String, skipping: [NSRange] = []) -> [Int] {
        spans(source, skipping: skipping).map(\.depth)
    }

    /// Both halves of a pair carry the depth of the pair, so a brace and its
    /// closing brace come out the same colour.
    @Test func aPairSharesItsDepth() {
        #expect(depths("{}") == [0, 0])
        #expect(depths("{{}}") == [0, 1, 1, 0])
    }

    @Test func mixedBracketsNestTogether() {
        // ( 0  [ 1  { 2  } 2  ] 1  ) 0
        #expect(depths("([{}])") == [0, 1, 2, 2, 1, 0])
    }

    @Test func siblingsShareADepth() {
        #expect(depths("{} {}") == [0, 0, 0, 0])
        #expect(depths("{{} {}}") == [0, 1, 1, 1, 1, 0])
    }

    /// The bug this guards, and the reason the pass takes the highlighter's
    /// tokens: a brace inside a string opens a level that never closes, and
    /// every colour after it in the file is wrong — worse than no colours,
    /// because it looks deliberate.
    @Test func aBraceInsideAStringIsIgnored() {
        let source = #"let a = "{"; { }"#
        let string = (source as NSString).range(of: #""{""#)

        #expect(depths(source, skipping: [string]) == [0, 0])
    }

    @Test func aBraceInsideACommentIsIgnored() {
        let source = "// {\n{ }"
        let comment = (source as NSString).range(of: "// {")

        #expect(depths(source, skipping: [comment]) == [0, 0])
    }

    /// A file being typed is unbalanced most of the time. An unmatched closer
    /// must not take the count negative and poison everything after it.
    @Test func anUnmatchedCloserDoesNotGoNegative() {
        #expect(depths("}}{}").allSatisfy { $0 >= 0 })
        #expect(depths("}}{}") == [0, 0, 0, 0])
    }

    @Test func anUnmatchedOpenerIsStillColoured() {
        #expect(depths("{{") == [0, 1])
    }

    /// The cycle repeats at the fourth level rather than running out of
    /// colours.
    @Test func theColorCycleWrapsAtThree() {
        #expect(BracketDepth.colorCount == 3)
        #expect(BracketDepth.slot(for: 0) == 0)
        #expect(BracketDepth.slot(for: 3) == 0)
        #expect(BracketDepth.slot(for: 4) == 1)
    }

    /// Defensive: a negative depth can only come from a bug elsewhere, and
    /// the answer must be a valid slot rather than a crash on a modulo.
    @Test func aNegativeDepthStillYieldsAValidSlot() {
        #expect(BracketDepth.slot(for: -1) == 0)
    }

    /// Depth is counted from the start of the document, not the start of the
    /// range — a viewport in the middle of a file has to agree with the one
    /// above it, or scrolling would recolour everything.
    @Test func depthIsCountedFromTheDocumentStart() {
        let source = "{{{ x }}}"
        let inner = (source as NSString).range(of: "x")
        let found = BracketDepth.spans(
            in: source as NSString,
            range: NSRange(location: inner.location, length: 4),
            skipping: []
        )

        // Only the closers in range, and they know they are 2, 1 deep.
        #expect(found.map(\.depth) == [2, 1])
    }

    @Test func textWithNoBracketsYieldsNothing() {
        #expect(spans("let a = 1").isEmpty)
        #expect(spans("").isEmpty)
    }
}

/// The gaps in the JavaScript and TypeScript rules.
struct TypeScriptHighlightTests {
    private func kinds(of needle: String, in source: String) -> [TokenKind] {
        let ns = source as NSString
        let tokens = SyntaxHighlighter(language: .javascript)
            .tokens(in: source, range: NSRange(location: 0, length: ns.length))
        let target = ns.range(of: needle)
        return tokens
            .filter { NSIntersectionRange($0.range, target).length > 0 }
            .map(\.kind)
    }

    /// A call whose argument is a type. Most of what a `<script setup>` block
    /// does, and it came out plain because the rule wanted `(` immediately.
    @Test func aGenericCallIsAFunction() {
        #expect(kinds(of: "defineProps", in: "const p = defineProps<{ a: string }>();")
            .contains(.function))
        #expect(kinds(of: "defineEmits", in: "const e = defineEmits<{ go: [] }>();")
            .contains(.function))
    }

    @Test func anOrdinaryCallStillWorks() {
        #expect(kinds(of: "computed", in: "const a = computed(() => 1);").contains(.function))
    }

    /// The documented edge of the `<` branch: a spaced comparison must not
    /// become a call.
    @Test func aSpacedComparisonIsNotACall() {
        #expect(!kinds(of: "page", in: "const ok = page < total;").contains(.function))
    }

    @Test func typescriptPrimitivesAreTypes() {
        #expect(kinds(of: "string", in: "let a: string;").contains(.type))
        #expect(kinds(of: "number", in: "let a: number;").contains(.type))
        #expect(kinds(of: "boolean", in: "let a: boolean;").contains(.type))
    }

    @Test func capitalizedTypesStillWork() {
        #expect(kinds(of: "FilterOption", in: "let a: FilterOption[];").contains(.type))
    }

    @Test func anObjectKeyIsAProperty() {
        let source = "const a = {\n  label: 1,\n};"
        #expect(kinds(of: "label", in: source).contains(.attribute))
    }

    @Test func anOptionalMemberIsAProperty() {
        let source = "type A = {\n  totalPages?: number;\n};"
        #expect(kinds(of: "totalPages", in: source).contains(.attribute))
    }

    /// The false positive the anchoring exists to prevent: `attribute`
    /// outranks `keyword`, so a bare "name before a colon" would paint the
    /// middle of a ternary as a property.
    @Test func aTernaryIsNotAProperty() {
        let source = "const a = ok ? first : second;"
        #expect(!kinds(of: "first", in: source).contains(.attribute))
    }

    /// And the keywords that legitimately precede a colon keep their slot.
    @Test func switchLabelsStayKeywords() {
        let source = "switch (a) {\ndefault:\n  break;\n}"
        let found = kinds(of: "default", in: source)
        #expect(found.contains(.keyword))
        #expect(!found.contains(.attribute))
    }

    @Test func decoratorsStillWork() {
        #expect(kinds(of: "@Input", in: "@Input() name: string;").contains(.attribute))
    }
}
