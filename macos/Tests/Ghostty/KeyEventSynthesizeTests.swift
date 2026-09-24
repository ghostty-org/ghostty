import AppKit
import SwiftUI
import Testing
@testable import Ghostty
import GhosttyKit

/// Tests for `Ghostty.Input.KeyEvent.init(synthesizing:...)`, the derivation
/// used for programmatic key input such as AppleScript's `send key`.
///
/// Expected characters are computed through `KeyboardLayout` rather than
/// hardcoded so the tests hold on any keyboard layout; what's under test is
/// the text/consumed/unshifted derivation, not the layout itself.
@MainActor
struct KeyEventSynthesizeTests {
    private let keyCodeA: UInt16 = 0x00 // W3C KeyA

    @Test func pressHasLayoutText() throws {
        let event = Ghostty.Input.KeyEvent(
            synthesizing: .a, action: .press, mods: [], translationMods: [])
        let expected = try #require(KeyboardLayout.character(for: keyCodeA, modifiers: []))
        #expect(event.text == String(expected))
        #expect(event.unshiftedCodepoint == expected.unicodeScalars.first?.value)
        #expect(event.consumedMods == [])
    }

    @Test func shiftAppliesToTextAndIsConsumed() throws {
        let event = Ghostty.Input.KeyEvent(
            synthesizing: .a, action: .press, mods: .shift, translationMods: .shift)
        let expected = try #require(KeyboardLayout.character(for: keyCodeA, modifiers: .shift))
        let unshifted = try #require(KeyboardLayout.character(for: keyCodeA, modifiers: []))
        #expect(event.text == String(expected))
        #expect(event.consumedMods == .shift)
        #expect(event.unshiftedCodepoint == unshifted.unicodeScalars.first?.value)
    }

    @Test func controlIsNeverConsumedAndDoesNotAffectText() throws {
        // Core passes ctrl through translation mods; the event must still
        // produce the base character ("a", not 0x01) and not consume ctrl.
        let event = Ghostty.Input.KeyEvent(
            synthesizing: .a, action: .press, mods: .ctrl, translationMods: .ctrl)
        let expected = try #require(KeyboardLayout.character(for: keyCodeA, modifiers: []))
        #expect(event.text == String(expected))
        #expect(event.consumedMods == [])
    }

    @Test func optionFollowsTranslationMods() throws {
        // macos-option-as-alt=false: option participates in translation and
        // is consumed.
        let translated = Ghostty.Input.KeyEvent(
            synthesizing: .a, action: .press, mods: .alt, translationMods: .alt)
        let optionChar = try #require(KeyboardLayout.character(for: keyCodeA, modifiers: .option))
        #expect(translated.text == String(optionChar))
        #expect(translated.consumedMods == .alt)

        // macos-option-as-alt=true: option is excluded from translation and
        // remains unconsumed, so core can encode it (e.g. ESC prefix).
        let asAlt = Ghostty.Input.KeyEvent(
            synthesizing: .a, action: .press, mods: .alt, translationMods: [])
        let baseChar = try #require(KeyboardLayout.character(for: keyCodeA, modifiers: []))
        #expect(asAlt.text == String(baseChar))
        #expect(asAlt.consumedMods == [])
    }

    @Test func releaseHasNoText() throws {
        let event = Ghostty.Input.KeyEvent(
            synthesizing: .a, action: .release, mods: .shift, translationMods: .shift)
        let unshifted = try #require(KeyboardLayout.character(for: keyCodeA, modifiers: []))
        #expect(event.text == nil)
        #expect(event.unshiftedCodepoint == unshifted.unicodeScalars.first?.value)
        #expect(event.consumedMods == .shift)
    }

    /// Every functional key with a Mac keycode. Their layout translations are
    /// control characters (or nothing), which must never be attached as text
    /// or reported as an unshifted codepoint; core encodes them from the key
    /// enum. This also guards against a translation leaking through in some
    /// other form, such as a PUA function-key character.
    @Test(arguments: [
        Ghostty.Input.Key.enter, .numpadEnter, .escape, .tab, .backspace,
        .delete, .insert, .home, .end, .pageUp, .pageDown,
        .arrowUp, .arrowDown, .arrowLeft, .arrowRight,
        .contextMenu, .numLock,
        .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10,
        .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20,
    ])
    func controlKeyTranslationsProduceNoTextOrCodepoint(key: Ghostty.Input.Key) {
        let event = Ghostty.Input.KeyEvent(
            synthesizing: key, action: .press, mods: [], translationMods: [])
        #expect(event.text == nil)
        #expect(event.unshiftedCodepoint == 0)
    }
}

/// The menu-shortcut path must translate the key equivalent with only the
/// command modifier applied: command can select a distinct layout table, while
/// the other modifiers live in the shortcut's modifier mask.
@MainActor
struct KeyboardShortcutTranslationTests {
    @Test func keyEquivalentIgnoresNonCommandModifiers() throws {
        var trigger = ghostty_input_trigger_s()
        trigger.tag = GHOSTTY_TRIGGER_PHYSICAL
        trigger.key.physical = GHOSTTY_KEY_BACKQUOTE
        trigger.mods = ghostty_input_mods_e(
            GHOSTTY_MODS_SUPER.rawValue | GHOSTTY_MODS_SHIFT.rawValue | GHOSTTY_MODS_ALT.rawValue)

        let shortcut = try #require(Ghostty.keyboardShortcut(for: trigger))
        let expected = try #require(KeyboardLayout.character(
            for: 0x32, // W3C Backquote
            modifiers: .command))
        #expect(shortcut.key.character == expected)
        #expect(shortcut.modifiers.contains(.shift))
        #expect(shortcut.modifiers.contains(.option))
        #expect(shortcut.modifiers.contains(.command))
    }
}
