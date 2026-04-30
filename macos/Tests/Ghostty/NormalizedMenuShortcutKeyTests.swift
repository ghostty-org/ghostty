import AppKit
import Testing
@testable import Ghostty

@Suite
struct NormalizedMenuShortcutKeyTests {
    typealias Key = Ghostty.MenuShortcutManager.MenuShortcutKey

    // MARK: - Init from keyEquivalent + modifiers

    @Test func returnsNilForEmptyKeyEquivalent() {
        let key = Key(keyEquivalent: "", modifiers: .command)
        #expect(key == nil)
    }

    @Test func lowercasesKeyEquivalent() {
        let key = Key(keyEquivalent: "A", modifiers: .command)
        #expect(key?.keyEquivalent == "a")
    }

    @Test func stripsNonShortcutModifiers() {
        // .capsLock and .function should be stripped
        let key = Key(keyEquivalent: "c", modifiers: [.command, .capsLock, .function])
        let expected = Key(keyEquivalent: "c", modifiers: .command)
        #expect(key == expected)
    }

    @Test func preservesShortcutModifiers() {
        let key = Key(keyEquivalent: "c", modifiers: [.shift, .control, .option, .command])
        let allMods: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
        #expect(key?.modifierFlags == allMods)
    }

    @Test func uppercaseLetterInsertsShift() {
        // "A" is uppercase and case-sensitive, so .shift should be added
        let key = Key(keyEquivalent: "A", modifiers: .command)
        let expected = NSEvent.ModifierFlags([.command, .shift])
        #expect(key?.modifierFlags == expected)
    }

    @Test func lowercaseLetterDoesNotInsertShift() {
        let key = Key(keyEquivalent: "a", modifiers: .command)
        let expected = NSEvent.ModifierFlags.command
        #expect(key?.modifierFlags == expected)
    }

    @Test func nonCaseSensitiveCharacterDoesNotInsertShift() {
        // "1" is not case-sensitive (uppercased == lowercased is false for digits,
        // but "1".uppercased() == "1".lowercased() == "1" so isCaseSensitive is false)
        let key = Key(keyEquivalent: "1", modifiers: .command)
        let expected = NSEvent.ModifierFlags.command
        #expect(key?.modifierFlags == expected)
    }

    // MARK: - Equality / Hashing

    @Test func sameKeyAndModsAreEqual() {
        let a = Key(keyEquivalent: "c", modifiers: .command)
        let b = Key(keyEquivalent: "c", modifiers: .command)
        #expect(a == b)
    }

    @Test func uppercaseAndLowercaseWithShiftAreEqual() {
        // "C" with .command should equal "c" with [.command, .shift]
        // because the uppercase init auto-inserts .shift
        let fromUpper = Key(keyEquivalent: "C", modifiers: .command)
        let fromLowerWithShift = Key(keyEquivalent: "c", modifiers: [.command, .shift])
        #expect(fromUpper == fromLowerWithShift)
    }

    @Test func differentKeysAreNotEqual() {
        let a = Key(keyEquivalent: "a", modifiers: .command)
        let b = Key(keyEquivalent: "b", modifiers: .command)
        #expect(a != b)
    }

    @Test func differentModifiersAreNotEqual() {
        let a = Key(keyEquivalent: "c", modifiers: .command)
        let b = Key(keyEquivalent: "c", modifiers: .option)
        #expect(a != b)
    }

    @Test func canBeUsedAsDictionaryKey() {
        let key = Key(keyEquivalent: "c", modifiers: .command)!
        var dict: [Key: String] = [:]
        dict[key] = "copy"
        #expect(dict[key] == "copy")

        // Same key created separately should find the same entry
        let key2 = Key(keyEquivalent: "c", modifiers: .command)!
        #expect(dict[key2] == "copy")
    }
}
