import Testing
import Foundation
@testable import Ghostty

struct ReleaseNotesTests {
    /// Test tagged release (semantic version)
    @Test func testTaggedRelease() async throws {
        let notes = UpdateState.ReleaseNotes(
            displayVersionString: "1.2.3",
            currentCommit: nil
        )
        
        #expect(notes != nil)
        if case .tagged(let url) = notes {
            #expect(url.absoluteString == "https://ghostty.org/docs/install/release-notes/1-2-3")
            #expect(notes?.label == "View Release Notes")
        } else {
            Issue.record("Expected tagged case")
        }
    }
    
    /// Test tip release comparison with current commit
    @Test func testTipReleaseComparison() async throws {
        let notes = UpdateState.ReleaseNotes(
            displayVersionString: "tip-abc1234",
            currentCommit: "def5678"
        )
        
        #expect(notes != nil)
        if case .compareTip(let url) = notes {
            #expect(url.absoluteString == "https://github.com/ghostty-org/ghostty/compare/def5678...abc1234")
            #expect(notes?.label == "Changes Since This Tip Release")
        } else {
            Issue.record("Expected compareTip case")
        }
    }
    
    /// Test tip release without current commit
    @Test func testTipReleaseWithoutCurrentCommit() async throws {
        let notes = UpdateState.ReleaseNotes(
            displayVersionString: "tip-abc1234",
            currentCommit: nil
        )
        
        #expect(notes != nil)
        if case .commit(let url) = notes {
            #expect(url.absoluteString == "https://github.com/ghostty-org/ghostty/commit/abc1234")
            #expect(notes?.label == "View GitHub Commit")
        } else {
            Issue.record("Expected commit case")
        }
    }
    
    /// Test tip release with empty current commit
    @Test func testTipReleaseWithEmptyCurrentCommit() async throws {
        let notes = UpdateState.ReleaseNotes(
            displayVersionString: "tip-abc1234",
            currentCommit: ""
        )
        
        #expect(notes != nil)
        if case .commit(let url) = notes {
            #expect(url.absoluteString == "https://github.com/ghostty-org/ghostty/commit/abc1234")
        } else {
            Issue.record("Expected commit case")
        }
    }
    
    /// Test version with full 40-character hash
    @Test func testFullGitHash() async throws {
        let notes = UpdateState.ReleaseNotes(
            displayVersionString: "tip-1234567890abcdef1234567890abcdef12345678",
            currentCommit: nil
        )
        
        #expect(notes != nil)
        if case .commit(let url) = notes {
            #expect(url.absoluteString == "https://github.com/ghostty-org/ghostty/commit/1234567890abcdef1234567890abcdef12345678")
        } else {
            Issue.record("Expected commit case")
        }
    }
    
    /// Test version with no recognizable pattern
    @Test func testInvalidVersion() async throws {
        let notes = UpdateState.ReleaseNotes(
            displayVersionString: "unknown-version",
            currentCommit: nil
        )
        
        #expect(notes == nil)
    }
    
    /// Test semantic version with prerelease suffix should not match
    @Test func testSemanticVersionWithSuffix() async throws {
        let notes = UpdateState.ReleaseNotes(
            displayVersionString: "1.2.3-beta",
            currentCommit: nil
        )
        
        // Should not match semantic version pattern, falls back to hash detection
        #expect(notes == nil)
    }
    
    /// Test semantic version with 4 components should not match
    @Test func testSemanticVersionFourComponents() async throws {
        let notes = UpdateState.ReleaseNotes(
            displayVersionString: "1.2.3.4",
            currentCommit: nil
        )
        
        // Should not match pattern
        #expect(notes == nil)
    }
    
    /// Test version string with git hash embedded
    @Test func testVersionWithEmbeddedHash() async throws {
        let notes = UpdateState.ReleaseNotes(
            displayVersionString: "v2024.01.15-abc1234",
            currentCommit: "def5678"
        )
        
        #expect(notes != nil)
        if case .compareTip(let url) = notes {
            #expect(url.absoluteString == "https://github.com/ghostty-org/ghostty/compare/def5678...abc1234")
        } else {
            Issue.record("Expected compareTip case")
        }
    }
}
