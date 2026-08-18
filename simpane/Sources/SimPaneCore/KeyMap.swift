//  NSEvent.keyCode -> USB HID keyboard usage code.
//
//  Determined empirically: sending HIToolbox virtual key codes straight through
//  produced "668k[e2=" for an intended "apple.com", and every character decodes
//  exactly as the HID usage with that numeric value. So the guest's keyboard
//  service reads HID Usage Page 0x07, not the "hardware independent" virtual
//  codes idb's header comment suggests.
//
//  Pure lookup, no simulator required — see KeyMapTests.

import Foundation

public enum KeyMap {

    /// HID Usage Page 0x07 (Keyboard/Keypad) usages for the keys a terminal user
    /// can actually press, keyed by the macOS virtual key code NSEvent reports.
    public static let virtualToHIDUsage: [UInt16: UInt32] = [
        // Letters
        0x00: 0x04, // a
        0x0B: 0x05, // b
        0x08: 0x06, // c
        0x02: 0x07, // d
        0x0E: 0x08, // e
        0x03: 0x09, // f
        0x05: 0x0A, // g
        0x04: 0x0B, // h
        0x22: 0x0C, // i
        0x26: 0x0D, // j
        0x28: 0x0E, // k
        0x25: 0x0F, // l
        0x2E: 0x10, // m
        0x2D: 0x11, // n
        0x1F: 0x12, // o
        0x23: 0x13, // p
        0x0C: 0x14, // q
        0x0F: 0x15, // r
        0x01: 0x16, // s
        0x11: 0x17, // t
        0x20: 0x18, // u
        0x09: 0x19, // v
        0x0D: 0x1A, // w
        0x07: 0x1B, // x
        0x10: 0x1C, // y
        0x06: 0x1D, // z

        // Digits
        0x12: 0x1E, // 1
        0x13: 0x1F, // 2
        0x14: 0x20, // 3
        0x15: 0x21, // 4
        0x17: 0x22, // 5
        0x16: 0x23, // 6
        0x1A: 0x24, // 7
        0x1C: 0x25, // 8
        0x19: 0x26, // 9
        0x1D: 0x27, // 0

        // Control and punctuation
        0x24: 0x28, // return
        0x35: 0x29, // escape
        0x33: 0x2A, // delete (backspace)
        0x30: 0x2B, // tab
        0x31: 0x2C, // space
        0x1B: 0x2D, // -
        0x18: 0x2E, // =
        0x21: 0x2F, // [
        0x1E: 0x30, // ]
        0x2A: 0x31, // backslash
        0x29: 0x33, // ;
        0x27: 0x34, // '
        0x32: 0x35, // `
        0x2B: 0x36, // ,
        0x2F: 0x37, // .
        0x2C: 0x38, // /
        0x39: 0x39, // caps lock

        // Navigation
        0x7B: 0x50, // left
        0x7C: 0x4F, // right
        0x7D: 0x51, // down
        0x7E: 0x52, // up
        0x75: 0x4C, // forward delete
        0x73: 0x4A, // home
        0x77: 0x4D, // end
        0x74: 0x4B, // page up
        0x79: 0x4E, // page down

        // Function row
        0x7A: 0x3A, 0x78: 0x3B, 0x63: 0x3C, 0x76: 0x3D, 0x60: 0x3E, 0x61: 0x3F,
        0x62: 0x40, 0x64: 0x41, 0x65: 0x42, 0x6D: 0x43, 0x67: 0x44, 0x6F: 0x45,

        // Modifiers
        0x3B: 0xE0, // left control
        0x38: 0xE1, // left shift
        0x3A: 0xE2, // left option
        0x37: 0xE3, // left command
        0x3E: 0xE4, // right control
        0x3C: 0xE5, // right shift
        0x3D: 0xE6, // right option
        0x36: 0xE7, // right command
    ]

    public static func hidUsage(forVirtualKeyCode code: UInt16) -> UInt32? {
        virtualToHIDUsage[code]
    }

    /// Convenience for tests and the CLI: maps ASCII to a HID usage, ignoring the
    /// shift state needed to produce it.
    public static func hidUsage(forCharacter character: Character) -> UInt32? {
        let lower = Character(character.lowercased())
        if let ascii = lower.asciiValue {
            switch ascii {
            case UInt8(ascii: "a")...UInt8(ascii: "z"):
                return UInt32(ascii - UInt8(ascii: "a")) + 0x04
            case UInt8(ascii: "1")...UInt8(ascii: "9"):
                return UInt32(ascii - UInt8(ascii: "1")) + 0x1E
            case UInt8(ascii: "0"):
                return 0x27
            default:
                break
            }
        }
        switch lower {
        case "\n", "\r": return 0x28
        case "\t": return 0x2B
        case " ": return 0x2C
        case "-": return 0x2D
        case "=": return 0x2E
        case "[": return 0x2F
        case "]": return 0x30
        case "\\": return 0x31
        case ";": return 0x33
        case "'": return 0x34
        case "`": return 0x35
        case ",": return 0x36
        case ".": return 0x37
        case "/": return 0x38
        default: return nil
        }
    }
}
