import AppKit
import Testing
@testable import Ghostty

@MainActor
struct KeyboardLayoutTests {
    @Test(arguments: [
        0x00, // W3C KeyA
        0x12, // W3C Digit1
        0x32, // W3C Backquote
    ])
    func characterHandlesKeyCode(keyCode: UInt16) {
        #expect(KeyboardLayout.character(for: keyCode, modifiers: []) != nil)
    }

    @Test func characterRejectsInvalidKeyCode() {
        #expect(KeyboardLayout.character(for: UInt16.max, modifiers: []) == nil)
    }

    @Test func characterAppliesModifiers() throws {
        let keyCode: UInt16 = 0x00 // W3C KeyA
        let unmodified = try #require(KeyboardLayout.character(for: keyCode, modifiers: []))
        let shifted = try #require(KeyboardLayout.character(for: keyCode, modifiers: .shift))
        #expect(shifted != unmodified)
        #expect(String(shifted).lowercased() == String(unmodified).lowercased())
    }
}
