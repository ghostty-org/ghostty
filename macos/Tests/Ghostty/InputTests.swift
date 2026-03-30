import SwiftUI
import Testing
@testable import Ghostty
@testable import GhosttyKit

@Suite
struct InputTests {

    // MARK: - equivalentToKey reverse map

    @Test func equivalentToKeyContainsAllArrowKeys() throws {
        let trigger = try #require(Ghostty.ghosttyTrigger(KeyboardShortcut(.upArrow, modifiers: [])))
        #expect(trigger.tag == GHOSTTY_TRIGGER_PHYSICAL)
        #expect(trigger.key.physical == GHOSTTY_KEY_ARROW_UP)
    }

    @Test func equivalentToKeyDistinguishesDeleteAndBackspace() throws {
        let backspace = try #require(Ghostty.ghosttyTrigger(KeyboardShortcut(.delete, modifiers: [])))
        #expect(backspace.tag == GHOSTTY_TRIGGER_PHYSICAL)
        #expect(backspace.key.physical == GHOSTTY_KEY_BACKSPACE)

        let forwardDelete = try #require(Ghostty.ghosttyTrigger(KeyboardShortcut(.deleteForward, modifiers: [])))
        #expect(forwardDelete.tag == GHOSTTY_TRIGGER_PHYSICAL)
        #expect(forwardDelete.key.physical == GHOSTTY_KEY_DELETE)
    }

    @Test func equivalentToKeyMapsAllSpecialKeys() throws {
        let expected: [(KeyEquivalent, ghostty_input_key_e)] = [
            (.upArrow, GHOSTTY_KEY_ARROW_UP),
            (.downArrow, GHOSTTY_KEY_ARROW_DOWN),
            (.leftArrow, GHOSTTY_KEY_ARROW_LEFT),
            (.rightArrow, GHOSTTY_KEY_ARROW_RIGHT),
            (.home, GHOSTTY_KEY_HOME),
            (.end, GHOSTTY_KEY_END),
            (.pageUp, GHOSTTY_KEY_PAGE_UP),
            (.pageDown, GHOSTTY_KEY_PAGE_DOWN),
            (.escape, GHOSTTY_KEY_ESCAPE),
            (.return, GHOSTTY_KEY_ENTER),
            (.tab, GHOSTTY_KEY_TAB),
            (.delete, GHOSTTY_KEY_BACKSPACE),
            (.deleteForward, GHOSTTY_KEY_DELETE),
            (.space, GHOSTTY_KEY_SPACE),
        ]

        for (equiv, expectedKey) in expected {
            let trigger = try #require(Ghostty.ghosttyTrigger(KeyboardShortcut(equiv, modifiers: [])))
            #expect(trigger.tag == GHOSTTY_TRIGGER_PHYSICAL)
            #expect(trigger.key.physical == expectedKey,
                "Expected \(expectedKey) for \(equiv), got \(String(describing: trigger.key.physical))")
        }
    }

    // MARK: - ghosttyTrigger

    @Test func ghosttyTriggerPhysicalKeyWithModifiers() throws {
        let trigger = try #require(Ghostty.ghosttyTrigger(KeyboardShortcut(.upArrow, modifiers: .command)))
        #expect(trigger.tag == GHOSTTY_TRIGGER_PHYSICAL)
        #expect(trigger.key.physical == GHOSTTY_KEY_ARROW_UP)
        #expect(trigger.mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0)
    }

    @Test func ghosttyTriggerUnicodeFallback() throws {
        // Regular letter keys are not in keyToEquivalent, so they fall through to unicode.
        let trigger = try #require(Ghostty.ghosttyTrigger(KeyboardShortcut("c", modifiers: .command)))
        #expect(trigger.tag == GHOSTTY_TRIGGER_UNICODE)
        #expect(trigger.key.unicode == UInt32(Character("c").asciiValue!))
        #expect(trigger.mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0)
    }

    // MARK: - roundtrip: keyboardShortcut → ghosttyTrigger

    @Test func roundtripPhysicalKeys() {
        // For physical keys, converting trigger → KeyboardShortcut → ghosttyTrigger
        // should produce the same physical key.
        let physicalKeys: [(ghostty_input_key_e, ghostty_input_mods_e)] = [
            (GHOSTTY_KEY_ARROW_UP, ghostty_input_mods_e(0)),
            (GHOSTTY_KEY_TAB, GHOSTTY_MODS_CTRL),
            (GHOSTTY_KEY_ENTER, GHOSTTY_MODS_SUPER),
        ]

        for (key, mods) in physicalKeys {
            let original = ghostty_input_trigger_s(
                tag: GHOSTTY_TRIGGER_PHYSICAL,
                key: .init(physical: key),
                mods: mods
            )

            guard let shortcut = Ghostty.keyboardShortcut(for: original) else {
                Issue.record("Could not create KeyboardShortcut for \(key)")
                continue
            }

            guard let back = Ghostty.ghosttyTrigger(shortcut) else {
                Issue.record("Could not convert KeyboardShortcut back for \(key)")
                continue
            }

            #expect(back.tag == GHOSTTY_TRIGGER_PHYSICAL)
            #expect(back.key.physical == key)
        }
    }
}
