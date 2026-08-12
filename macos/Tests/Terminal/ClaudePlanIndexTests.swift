import Foundation
@testable import Ghostty
import Testing

/// Matching a plan to the terminals it belongs to.
///
/// The plan file says nothing about where it came from, so the link runs
/// through the session transcript's directory name — which encodes a working
/// directory *lossily*. Every test here exists because the obvious approach,
/// decoding that name back into a path, cannot work.
struct ClaudePlanEncodingTests {
    @Test func slashesAndDotsBothBecomeDashes() {
        #expect(
            ClaudePlanIndex.encode("/Users/isac.petinate/Projects")
                == "-Users-isac-petinate-Projects"
        )
    }

    /// The ambiguity, stated: two different paths encode to the same name.
    /// This is why nothing decodes — the answer would be a guess.
    @Test func theEncodingIsNotReversible() {
        let withDot = ClaudePlanIndex.encode("/Users/isac.petinate/Projects")
        let withSlash = ClaudePlanIndex.encode("/Users/isac/petinate/Projects")
        #expect(withDot == withSlash)
    }

    /// And why comparing encoded forms is still sound: the map is
    /// character-for-character, so it preserves prefixes.
    @Test func aDirectoryInsideAProjectMatchesIt() {
        let project = ClaudePlanIndex.encode("/Users/x/Projects")
        #expect(ClaudePlanIndex.project(project, contains: "/Users/x/Projects"))
        #expect(ClaudePlanIndex.project(project, contains: "/Users/x/Projects/Tools/phantom"))
    }

    /// The separator is required, or a project would claim its siblings.
    @Test func aSiblingWithASharedPrefixDoesNotMatch() {
        let project = ClaudePlanIndex.encode("/Users/x/Tools")
        #expect(!ClaudePlanIndex.project(project, contains: "/Users/x/ToolsX"))
        #expect(!ClaudePlanIndex.project(project, contains: "/Users/x/ToolsX/inner"))
    }

    @Test func aDirectoryOutsideTheProjectDoesNotMatch() {
        let project = ClaudePlanIndex.encode("/Users/x/Projects")
        #expect(!ClaudePlanIndex.project(project, contains: "/Users/x/Documents"))
        #expect(!ClaudePlanIndex.project(project, contains: "/Users/x"))
    }

    @Test func anEmptyPathMatchesNothing() {
        let project = ClaudePlanIndex.encode("/Users/x/Projects")
        #expect(!ClaudePlanIndex.project(project, contains: ""))
    }

    /// A path with a dot in a directory name still matches its project, which
    /// is the case that made decoding tempting in the first place.
    @Test func aDottedDirectoryNameStillMatches() {
        let project = ClaudePlanIndex.encode("/Users/isac.petinate/Projects")
        #expect(
            ClaudePlanIndex.project(project, contains: "/Users/isac.petinate/Projects/Tools")
        )
    }
}

/// Reading the tail of a transcript.
struct ClaudePlanTranscriptTests {
    private func write(_ contents: String) -> String {
        let path = NSTemporaryDirectory() + "phantom-transcript-\(UUID().uuidString).jsonl"
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test func theNeedleIsFoundInASmallFile() {
        let path = write("{\"text\":\"plan at fizzy-frolicking-haven.md\"}")
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(ClaudePlanIndex.tail(of: path, contains: "fizzy-frolicking-haven"))
        #expect(!ClaudePlanIndex.tail(of: path, contains: "some-other-plan"))
    }

    /// Only the tail is read, because these files reach tens of megabytes.
    /// A mention near the *end* is what a plan written during the session
    /// looks like.
    @Test func aMentionNearTheEndIsFound() {
        let padding = String(repeating: "x", count: 200_000)
        let path = write(padding + "\nmentions moonlit-popcorn\n")
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(ClaudePlanIndex.tail(of: path, contains: "moonlit-popcorn"))
    }

    @Test func aMissingFileIsNotAMatchAndDoesNotCrash() {
        #expect(!ClaudePlanIndex.tail(of: "/nowhere/\(UUID()).jsonl", contains: "anything"))
    }

    @Test func anEmptyFileIsNotAMatch() {
        let path = write("")
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(!ClaudePlanIndex.tail(of: path, contains: "anything"))
    }
}

/// The title shown on the tag's tooltip.
struct ClaudePlanTitleTests {
    private func plan(_ contents: String) -> (ClaudePlanIndex.Plan, String) {
        let path = NSTemporaryDirectory() + "phantom-plan-\(UUID().uuidString).md"
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
        return (ClaudePlanIndex.Plan(path: path, modified: Date(timeIntervalSince1970: 0)), path)
    }

    /// The file names are random slugs, so the heading is the only part a
    /// reader recognises.
    @Test func theFirstHeadingIsTheTitle() {
        let (plan, path) = plan("# Painel direito com abas\n\nsome text")
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(plan.title == "Painel direito com abas")
    }

    @Test func aPlanWithNoHeadingFallsBackToItsName() {
        let (plan, path) = plan("no heading here")
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(plan.title.hasPrefix("phantom-plan-"))
        #expect(!plan.title.hasSuffix(".md"))
    }

    @Test func aDeeperHeadingIsNotTheTitle() {
        let (plan, path) = plan("## Context\n\n# Real Title\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(plan.title == "Real Title")
    }
}
