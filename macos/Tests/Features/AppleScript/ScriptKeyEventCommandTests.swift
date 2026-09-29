import AppKit
import Testing

@testable import Ghostty

/// Tests for `ScriptKeyEventCommand.parse`, which turns the scripting
/// arguments of the `send key` AppleScript command into the
/// `Ghostty.Input.KeyEvent` delivered to the surface.
///
/// Printable keys must carry the text and codepoints a real NSEvent-based key
/// press would, derived from the current keyboard layout; otherwise the key
/// produces no terminal output. Expected characters are computed through
/// `KeyboardLayout` rather than hardcoded so the tests hold on any layout.
@MainActor
struct ScriptKeyEventCommandTests {
    private let keyCodeA: UInt16 = 0x00  // W3C KeyA

    /// Parse a `send key` command the way the scripting runtime delivers it.
    private func parse(
        _ keyName: Any?,
        modifiers: String? = nil,
        action: UInt32? = nil,
        translationMods: (Ghostty.Input.Mods) -> Ghostty.Input.Mods = { $0 },
    ) throws -> Ghostty.Input.KeyEvent {
        var arguments: [String: Any] = [:]
        if let modifiers { arguments["modifiers"] = modifiers }
        if let action { arguments["action"] = action }
        return try ScriptKeyEventCommand.parse(
            directParameter: keyName,
            evaluatedArguments: arguments.isEmpty ? nil : arguments,
            translationMods: translationMods,
        )
    }

    // MARK: Argument parsing

    @Test func defaultsToPressWithNoModifiers() throws {
        let event = try parse("a")
        #expect(event.key == .a)
        #expect(event.action == .press)
        #expect(event.mods == [])
    }

    @Test func parsesActionCodes() throws {
        try #expect(
            parse("enter", action: "GIpr".fourCharCode).action == .press
        )
        try #expect(
            parse("enter", action: "GIrl".fourCharCode).action == .release
        )
    }

    @Test func unknownActionCodeFallsBackToPress() throws {
        try #expect(parse("a", action: 0).action == .press)
    }

    @Test(
        arguments: [
            ("shift", Ghostty.Input.Mods.shift),
            ("control", .ctrl),
            ("option", .alt),
            ("command", .super),
            ("shift, command", [.shift, .super]),
            ("SHIFT,Option", [.shift, .alt]),
            (" control , shift ", [.ctrl, .shift]),
            ("", []),
        ] as [(String, Ghostty.Input.Mods)]
    )
    func parsesModifiers(string: String, expected: Ghostty.Input.Mods) throws {
        try #expect(parse("a", modifiers: string).mods == expected)
    }

    @Test(arguments: [nil, 42, NSNull()] as [Any?])
    func missingOrNonStringKeyThrows(directParameter: Any?) {
        #expect(throws: ScriptKeyEventCommand.ArgumentError.missingKey) {
            try parse(directParameter)
        }
    }

    @Test func unknownKeyNameThrows() {
        #expect(
            throws: ScriptKeyEventCommand.ArgumentError.unknownKey("banana")
        ) {
            try parse("banana")
        }
    }

    @Test func unknownModifierThrows() {
        #expect(
            throws: ScriptKeyEventCommand.ArgumentError.unknownModifiers(
                "shift, hyper"
            )
        ) {
            try parse("a", modifiers: "shift, hyper")
        }
    }

    /// The sdef's documented key name examples must all resolve.
    @Test(arguments: ["enter", "a", "space"])
    func documentedKeyNamesResolve(name: String) throws {
        _ = try parse(name)
    }

    // MARK: Produced key event

    // These record known issues until `send key` derives text and codepoints
    // from the keyboard layout the way real NSEvent-based input does.
    // Uncomment the expectations and remove the Issue.record calls once the
    // fix lands.

    @Test func pressCarriesLayoutText() throws {
        let event = try parse("a")
        let expected = try #require(KeyboardLayout.character(for: keyCodeA, modifiers: []))
        #expect(event.text == String(expected))
        #expect(event.unshiftedCodepoint == expected.unicodeScalars.first?.value)
        #expect(event.consumedMods == [])
    }

    @Test func shiftShiftsTextAndIsConsumed() throws {
        let event = try parse("a", modifiers: "shift")
        let expected = try #require(KeyboardLayout.character(for: keyCodeA, modifiers: .shift))
        let unshifted = try #require(KeyboardLayout.character(for: keyCodeA, modifiers: []))
        #expect(event.text == String(expected))
        #expect(event.consumedMods == .shift)
        #expect(event.unshiftedCodepoint == unshifted.unicodeScalars.first?.value)
    }

    /// The original bug scenario: `send key "c" with modifiers "control"`
    /// must produce the base character as text ("c", not 0x03) with control
    /// unconsumed, so core can encode the control sequence itself.
    @Test func controlKeepsBaseTextAndIsNotConsumed() throws {
        let event = try parse("c", modifiers: "control")
        let expected = try #require(KeyboardLayout.character(
            for: 0x08, // W3C KeyC
            modifiers: []))
        #expect(event.text == String(expected))
        #expect(event.mods == .ctrl)
        #expect(event.consumedMods == [])
    }

    @Test func optionIncludedInTranslationIsConsumed() throws {
        // macos-option-as-alt=false: option participates in translation.
        let event = try parse("a", modifiers: "option")
        let expected = try #require(KeyboardLayout.character(for: keyCodeA, modifiers: .option))
        #expect(event.text == String(expected))
        #expect(event.consumedMods == .alt)
    }

    @Test func optionExcludedFromTranslationIsNotConsumed() throws {
        // macos-option-as-alt=true: the surface's translation mods exclude
        // option, so it stays unconsumed and core can encode it (e.g. ESC
        // prefix).
        let event = try parse("a", modifiers: "option") { $0.subtracting(.alt) }
        let expected = try #require(KeyboardLayout.character(for: keyCodeA, modifiers: []))
        #expect(event.text == String(expected))
        #expect(event.consumedMods == [])
    }

    @Test func releaseCarriesNoText() throws {
        let event = try parse(
            "a",
            modifiers: "shift",
            action: "GIrl".fourCharCode
        )
        let unshifted = try #require(KeyboardLayout.character(for: keyCodeA, modifiers: []))
        #expect(event.text == nil)
        #expect(event.unshiftedCodepoint == unshifted.unicodeScalars.first?.value)
    }

    /// Keys whose layout translation is a control character (or a PUA
    /// function-key character) must carry no text and no unshifted codepoint;
    /// core encodes them from the key enum.
    @Test(arguments: [
        Ghostty.Input.Key.enter, .escape, .tab, .backspace, .arrowUp, .f1,
        .home, .delete,
    ])
    func functionalKeysCarryNoTextOrCodepoint(key: Ghostty.Input.Key) throws {
        let event = try parse(key.rawValue)
        #expect(event.text == nil)
        #expect(event.unshiftedCodepoint == 0)
    }

    @Test func modsPassThroughUnchanged() throws {
        let event = try parse("a", modifiers: "control, shift")
        #expect(event.mods == [.ctrl, .shift])
    }
}
