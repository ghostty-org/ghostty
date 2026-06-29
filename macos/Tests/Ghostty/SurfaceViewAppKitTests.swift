@testable import Ghostty
import AppKit
import GhosttyKit
import Testing

struct SurfaceViewAppKitTests {
    @Test(arguments: [
        ("\u{0008}", true),
        ("\u{001F}", true),
        ("\u{007F}", false),
        (" ", false),
        ("h", false),
        ("", false),
        ("\u{0009}x", false),
        ("\u{0009}\u{0009}", false),
    ])
    func suppressesOnlySingleC0ControlTextWhileComposing(
        text: String,
        expected: Bool
    ) {
        #expect(
            Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                text,
                composing: true
            ) == expected
        )
    }

    @Test func doesNotSuppressControlTextWhenNotComposing() {
        #expect(
            Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                "\u{0008}",
                composing: false
            ) == false
        )
    }

    @Test func doesNotSuppressMissingText() {
        #expect(
            Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                nil,
                composing: true
            ) == false
        )
    }

    @Test func modifierActionPressesBaseModifier() throws {
        let mod = try #require(Ghostty.SurfaceView.modifierMask(for: 0x3A))
        let flags = NSEvent.ModifierFlags.option
        let mods = Ghostty.ghosttyMods(flags)

        #expect(
            Ghostty.SurfaceView.modifierAction(
                keyCode: 0x3A,
                flags: flags,
                mod: mod,
                mods: mods
            ) == GHOSTTY_ACTION_PRESS
        )
    }

    @Test func modifierActionReleasesSideModifierWhenOtherSideRemainsPressed() throws {
        let mod = try #require(Ghostty.SurfaceView.modifierMask(for: 0x3D))
        let flags = NSEvent.ModifierFlags.option
        let mods = Ghostty.ghosttyMods(flags)

        #expect(
            Ghostty.SurfaceView.modifierAction(
                keyCode: 0x3D,
                flags: flags,
                mod: mod,
                mods: mods
            ) == GHOSTTY_ACTION_RELEASE
        )
    }
}
