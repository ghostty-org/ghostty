import Foundation
@testable import Ghostty
import Testing

/// Splitting a single-file component into its blocks.
struct SFCRegionTests {
    private let component = """
    <script setup lang="ts">
    import { ref } from 'vue';
    const searchTerm = ref('');
    </script>

    <template>
      <div class="filters">
        <WButton @click="emit('create')">Novo</WButton>
      </div>
    </template>

    <style scoped lang="scss">
    .filters {
      display: flex;
    }
    </style>
    """

    private func language(at needle: String, in text: String) -> CodeLanguage? {
        guard let range = text.range(of: needle) else { return nil }
        let offset = text.distance(from: text.startIndex, to: range.lowerBound)
        return SFCRegions.language(at: offset, in: text)
    }

    @Test func eachBlockIsItsOwnLanguage() {
        #expect(language(at: "import { ref }", in: component) == .javascript)
        #expect(language(at: "<div class", in: component) == .html)
        #expect(language(at: "display: flex", in: component) == .css)
    }

    /// The blocks come back in the order they appear, whatever order they
    /// are searched for — a later pass over the document walks them.
    @Test func regionsAreOrderedByPosition() {
        let regions = SFCRegions.regions(in: component)
        #expect(regions.map(\.language) == [.javascript, .html, .css])
        #expect(regions.map(\.range.location) == regions.map(\.range.location).sorted())
    }

    /// The tags themselves are not part of the block: `<script>` is markup,
    /// and lexing it as JavaScript would make `script` an identifier.
    @Test func theOpeningTagIsNotInsideTheBlock() {
        guard let range = component.range(of: "<script setup") else {
            Issue.record("the fixture no longer contains the tag this asserts on")
            return
        }
        let offset = component.distance(from: component.startIndex, to: range.lowerBound)
        #expect(SFCRegions.language(at: offset, in: component) == nil)
    }

    /// The attributes on a block tag change what the compiler does, not how
    /// the body is lexed — `<script setup lang="ts">` is still JavaScript to
    /// a highlighter, and `<style scoped lang="scss">` still CSS.
    @Test func blockAttributesDoNotChangeTheLanguage() {
        let plain = "<script>\nconst a = 1;\n</script>"
        #expect(SFCRegions.regions(in: plain).first?.language == .javascript)

        let module = "<style module>\n.a { color: red; }\n</style>"
        #expect(SFCRegions.regions(in: module).first?.language == .css)
    }

    /// A `<template #slot>` inside the template is indented, which is how
    /// the outer block's end is told from an inner one's. This is the
    /// splitter's documented assumption, so it is worth an assertion.
    @Test func anIndentedNestedTemplateDoesNotEndTheOuterOne() {
        let nested = """
        <template>
          <WTable>
            <template #footer>
              <span>total</span>
            </template>
          </WTable>
        </template>
        """
        let regions = SFCRegions.regions(in: nested)
        #expect(regions.count == 1)
        // The whole body, nested block included.
        #expect(regions.first.map { NSMaxRange($0.range) > 60 } == true)
    }

    @Test func aFileWithNoBlocksHasNoRegions() {
        #expect(SFCRegions.regions(in: "just some text").isEmpty)
        #expect(SFCRegions.regions(in: "").isEmpty)
    }

    /// An unclosed block is not claimed. Half a file coloured as CSS while
    /// it is being typed reads worse than none of it.
    @Test func anUnclosedBlockIsIgnored() {
        #expect(SFCRegions.regions(in: "<style>\n.a { color: red;").isEmpty)
    }
}

/// What the highlighter makes of an SFC.
struct SFCTokenTests {
    private func kinds(of needle: String, in text: String, language: CodeLanguage) -> [TokenKind] {
        let ns = text as NSString
        let tokens = SyntaxHighlighter(language: language)
            .tokens(in: text, range: NSRange(location: 0, length: ns.length))
        let target = ns.range(of: needle)
        return tokens
            .filter { NSIntersectionRange($0.range, target).length > 0 }
            .map(\.kind)
    }

    /// `.vue` used to resolve straight to JavaScript, which is why the
    /// template's tags came out plain and `class` came out as a JavaScript
    /// keyword. A tag is a tag.
    @Test func templateTagsAreTags() {
        let text = "<template>\n<div class=\"a\"></div>\n</template>"
        #expect(kinds(of: "<div", in: text, language: .vue).contains(.keyword))
        #expect(kinds(of: "class", in: text, language: .vue).contains(.attribute))
    }

    /// Component tags too — they are the majority of the markup in this
    /// codebase, and capitalisation must not turn them into a type.
    @Test func componentTagsAreTagsAndNotTypes() {
        let text = "<template>\n<WButton variant=\"primary\" />\n</template>"
        let found = kinds(of: "<WButton", in: text, language: .vue)
        #expect(found.contains(.keyword))
        #expect(!found.contains(.type))
    }

    /// Vue's own attribute shapes: a bound prop, an event, a directive.
    @Test func boundPropsEventsAndDirectivesAreAttributes() {
        let text = """
        <template>
        <WPagination :total-pages="totalPages" @w-next="next" v-model="page" />
        </template>
        """
        #expect(kinds(of: ":total-pages", in: text, language: .vue).contains(.attribute))
        #expect(kinds(of: "@w-next", in: text, language: .vue).contains(.attribute))
        #expect(kinds(of: "v-model", in: text, language: .vue).contains(.attribute))
    }

    @Test func theScriptBlockIsStillJavaScript() {
        let text = "<script setup lang=\"ts\">\nconst a = 1;\n</script>"
        #expect(kinds(of: "const", in: text, language: .vue).contains(.keyword))
    }

    /// The stylesheet was not interpreted at all before.
    @Test func theStyleBlockIsInterpreted() {
        let text = """
        <style scoped lang="scss">
        .filters {
          display: flex;
          gap: var(--gl-spacing-06);
          width: 100%;
        }
        </style>
        """
        #expect(kinds(of: ".filters", in: text, language: .vue).contains(.type))
        #expect(kinds(of: "display", in: text, language: .vue).contains(.attribute))
        #expect(kinds(of: "flex", in: text, language: .vue).contains(.keyword))
        #expect(kinds(of: "100%", in: text, language: .vue).contains(.number))
        #expect(kinds(of: "var", in: text, language: .vue).contains(.function))
    }

    /// BEM nesting is most of the lines in these stylesheets, and `&__x` is
    /// not a class selector — the old pattern matched neither.
    @Test func scssNestingIsASelector() {
        let text = "<style lang=\"scss\">\n.a {\n  &__toolbar { display: flex; }\n}\n</style>"
        #expect(kinds(of: "&__toolbar", in: text, language: .vue).contains(.type))
    }

    @Test func scssLineCommentsAreComments() {
        let text = "<style lang=\"scss\">\n// a note\n.a { color: red; }\n</style>"
        #expect(kinds(of: "// a note", in: text, language: .vue).contains(.comment))
    }

    /// A property and a value spelled the same must not collide: `flex` is
    /// a value here and `display` a property, and the property rule takes
    /// precedence because it looks for the colon.
    @Test func aPropertyIsNotMistakenForAValue() {
        let text = "<style>\n.a { display: flex; }\n</style>"
        #expect(kinds(of: "display", in: text, language: .vue) == [.attribute])
    }

    /// Nothing outside a block is coloured — the container is markup the
    /// splitter deliberately declines to claim.
    @Test func textBetweenBlocksIsLeftAlone() {
        let text = "<script>\nlet a = 1;\n</script>\n\nfree text\n\n<style>\n.a { }\n</style>"
        #expect(kinds(of: "free text", in: text, language: .vue).isEmpty)
    }
}

/// Telling a local build from the installed app.
struct DevelopmentBuildTests {
    /// `zig build` writes to `zig-out`, and nothing installed runs from
    /// there — which is what makes this a property of how the copy was
    /// produced rather than of remembering to set a flag.
    @Test func aBuildOutputPathIsADevelopmentBuild() {
        #expect(DevelopmentBuild.isBuildOutputPath("/Users/x/Projects/phantom/zig-out/Phantom.app"))
        #expect(DevelopmentBuild.isBuildOutputPath("/Users/x/Library/Developer/Xcode/DerivedData/A/Phantom.app"))
    }

    @Test func anInstalledAppIsNot() {
        #expect(!DevelopmentBuild.isBuildOutputPath("/Applications/Phantom.app"))
        #expect(!DevelopmentBuild.isBuildOutputPath("/Users/x/Applications/Phantom.app"))
    }

    /// A folder that merely contains the word must not count — the check is
    /// on path components, not on a substring.
    @Test func aSimilarlyNamedFolderIsNotAMatch() {
        #expect(!DevelopmentBuild.isBuildOutputPath("/Users/x/my-zig-outputs/Phantom.app"))
        #expect(!DevelopmentBuild.isBuildOutputPath("/Applications/zig-outer/Phantom.app"))
    }
}
