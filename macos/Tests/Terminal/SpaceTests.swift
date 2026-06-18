import Testing
@testable import Ghostty

struct SpaceTests {
    @Test func clampKeepsSingleEmoji() {
        #expect(Space.clampIcon("💻") == "💻")
    }

    @Test func clampKeepsTwoCharacters() {
        #expect(Space.clampIcon("ab") == "ab")
    }

    @Test func clampTruncatesToTwoGraphemes() {
        #expect(Space.clampIcon("abc") == "ab")
        #expect(Space.clampIcon("🌐🛠️x") == "🌐🛠️")
    }

    @Test func clampTrimsWhitespace() {
        #expect(Space.clampIcon("  x ") == "x")
    }

    @Test func clampFallsBackOnEmpty() {
        #expect(Space.clampIcon("   ") == "•")
        #expect(Space.clampIcon("") == "•")
    }

    @Test func initClampsIcon() {
        let space = Space(name: "Work", icon: "abc")
        #expect(space.icon == "ab")
        #expect(space.name == "Work")
    }
}
