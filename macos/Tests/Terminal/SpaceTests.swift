import Testing
@testable import Ghostty

struct SpaceTests {
    @Test func clampKeepsSingleEmoji() {
        #expect(Space.clampIcon("💻") == "💻")
    }

    @Test func clampKeepsShortStrings() {
        #expect(Space.clampIcon("ab") == "ab")
        #expect(Space.clampIcon("0123456789") == "0123456789")
    }

    @Test func clampTruncatesToTenGraphemes() {
        #expect(Space.clampIcon("0123456789X") == "0123456789")
        #expect(Space.clampIcon("🌐🛠️🚀💻⚙️🌐🛠️🚀💻⚙️x") == "🌐🛠️🚀💻⚙️🌐🛠️🚀💻⚙️")
    }

    @Test func clampTrimsWhitespace() {
        #expect(Space.clampIcon("  x ") == "x")
    }

    @Test func clampFallsBackOnEmpty() {
        #expect(Space.clampIcon("   ") == "•")
        #expect(Space.clampIcon("") == "•")
    }

    @Test func initClampsIcon() {
        let space = Space(name: "Work", icon: "0123456789X")
        #expect(space.icon == "0123456789")
        #expect(space.name == "Work")
    }
}
