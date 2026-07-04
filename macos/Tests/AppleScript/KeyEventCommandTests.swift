import Testing
@testable import Ghostty

fileprivate extension Ghostty.Input.Key {
    var printableCharacter: String? {
        switch self {
        case .a: return "a"
        case .b: return "b"
        case .c: return "c"
        case .d: return "d"
        case .e: return "e"
        case .f: return "f"
        case .g: return "g"
        case .h: return "h"
        case .i: return "i"
        case .j: return "j"
        case .k: return "k"
        case .l: return "l"
        case .m: return "m"
        case .n: return "n"
        case .o: return "o"
        case .p: return "p"
        case .q: return "q"
        case .r: return "r"
        case .s: return "s"
        case .t: return "t"
        case .u: return "u"
        case .v: return "v"
        case .w: return "w"
        case .x: return "x"
        case .y: return "y"
        case .z: return "z"
        case .space: return " "
        default: return nil
        }
    }
}

@Suite
struct ScriptKeyEventTranslatorTests {
    typealias Key = Ghostty.Input.Key

    @Test func letterKeyTranslation() {
        let a = ScriptKeyEventTranslator.translate(key: .a, mods: [])
        #expect(a.text == "a")
        #expect(a.unshiftedCodepoint == UInt32(("a" as UnicodeScalar).value))

        let shiftedA = ScriptKeyEventTranslator.translate(key: .a, mods: [.shift])
        #expect(shiftedA.text == "A")
        #expect(shiftedA.unshiftedCodepoint == UInt32(("a" as UnicodeScalar).value))

        let j = ScriptKeyEventTranslator.translate(key: .j, mods: [])
        #expect(j.text == "j")
        #expect(j.unshiftedCodepoint == UInt32(("j" as UnicodeScalar).value))
    }

    @Test func spaceKeyTranslation() {
        let space = ScriptKeyEventTranslator.translate(key: .space, mods: [])
        #expect(space.text == " ")
        #expect(space.unshiftedCodepoint == 32)
    }

    @Test func enterKeyTranslation() {
        let enter = ScriptKeyEventTranslator.translate(key: .enter, mods: [])
        #expect(enter.text == "\r")
        #expect(enter.unshiftedCodepoint == 13) // Carriage Return
    }

    @Test func tabKeyTranslation() {
        let tab = ScriptKeyEventTranslator.translate(key: .tab, mods: [])
        #expect(tab.text == "\t")
        #expect(tab.unshiftedCodepoint == 9)
    }
}
