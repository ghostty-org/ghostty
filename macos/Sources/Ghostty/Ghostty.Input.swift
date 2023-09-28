import Cocoa
import GhosttyKit

extension Ghostty {
    /// Returns the "keyEquivalent" string for a given input key. This doesn't always have a corresponding key.
    static func keyEquivalent(key: ghostty_input_key_e) -> String? {
        return Self.keyToEquivalent[key]
    }

    /// Returns the event modifier flags set for the Ghostty mods enum.
    static func eventModifierFlags(mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags(rawValue: 0);
        if (mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0) { flags.insert(.shift) }
        if (mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0) { flags.insert(.control) }
        if (mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0) { flags.insert(.option) }
        if (mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0) { flags.insert(.command) }
        return flags
    }

    /// A map from the Ghostty key enum to the keyEquivalent string for shortcuts.
    static let keyToEquivalent: [ghostty_input_key_e : String] = [
        // 0-9
        GHOSTTY_KEY_ZERO: "0",
        GHOSTTY_KEY_ONE: "1",
        GHOSTTY_KEY_TWO: "2",
        GHOSTTY_KEY_THREE: "3",
        GHOSTTY_KEY_FOUR: "4",
        GHOSTTY_KEY_FIVE: "5",
        GHOSTTY_KEY_SIX: "6",
        GHOSTTY_KEY_SEVEN: "7",
        GHOSTTY_KEY_EIGHT: "8",
        GHOSTTY_KEY_NINE: "9",

        // a-z
        GHOSTTY_KEY_A: "a",
        GHOSTTY_KEY_B: "b",
        GHOSTTY_KEY_C: "c",
        GHOSTTY_KEY_D: "d",
        GHOSTTY_KEY_E: "e",
        GHOSTTY_KEY_F: "f",
        GHOSTTY_KEY_G: "g",
        GHOSTTY_KEY_H: "h",
        GHOSTTY_KEY_I: "i",
        GHOSTTY_KEY_J: "j",
        GHOSTTY_KEY_K: "k",
        GHOSTTY_KEY_L: "l",
        GHOSTTY_KEY_M: "m",
        GHOSTTY_KEY_N: "n",
        GHOSTTY_KEY_O: "o",
        GHOSTTY_KEY_P: "p",
        GHOSTTY_KEY_Q: "q",
        GHOSTTY_KEY_R: "r",
        GHOSTTY_KEY_S: "s",
        GHOSTTY_KEY_T: "t",
        GHOSTTY_KEY_U: "u",
        GHOSTTY_KEY_V: "v",
        GHOSTTY_KEY_W: "w",
        GHOSTTY_KEY_X: "x",
        GHOSTTY_KEY_Y: "y",
        GHOSTTY_KEY_Z: "z",

        // Symbols
        GHOSTTY_KEY_APOSTROPHE: "'",
        GHOSTTY_KEY_BACKSLASH: "\\",
        GHOSTTY_KEY_COMMA: ",",
        GHOSTTY_KEY_EQUAL: "=",
        GHOSTTY_KEY_GRAVE_ACCENT: "`",
        GHOSTTY_KEY_LEFT_BRACKET: "[",
        GHOSTTY_KEY_MINUS: "-",
        GHOSTTY_KEY_PERIOD: ".",
        GHOSTTY_KEY_RIGHT_BRACKET: "]",
        GHOSTTY_KEY_SEMICOLON: ";",
        GHOSTTY_KEY_SLASH: "/",

        // Function keys
        GHOSTTY_KEY_UP: "\u{F700}",
        GHOSTTY_KEY_DOWN: "\u{F701}",
        GHOSTTY_KEY_LEFT: "\u{F702}",
        GHOSTTY_KEY_RIGHT: "\u{F703}",
        GHOSTTY_KEY_HOME: "\u{F729}",
        GHOSTTY_KEY_END: "\u{F72B}",
        GHOSTTY_KEY_INSERT: "\u{F727}",
        GHOSTTY_KEY_DELETE: "\u{F728}",
        GHOSTTY_KEY_PAGE_UP: "\u{F72C}",
        GHOSTTY_KEY_PAGE_DOWN: "\u{F72D}",
        GHOSTTY_KEY_ESCAPE: "\u{1B}",
        GHOSTTY_KEY_ENTER: "\r",
        GHOSTTY_KEY_TAB: "\t",
        GHOSTTY_KEY_BACKSPACE: "\u{7F}",
        GHOSTTY_KEY_PRINT_SCREEN: "\u{F72E}",
        GHOSTTY_KEY_PAUSE: "\u{F72F}",

        GHOSTTY_KEY_F1: "\u{F704}",
        GHOSTTY_KEY_F2: "\u{F705}",
        GHOSTTY_KEY_F3: "\u{F706}",
        GHOSTTY_KEY_F4: "\u{F707}",
        GHOSTTY_KEY_F5: "\u{F708}",
        GHOSTTY_KEY_F6: "\u{F709}",
        GHOSTTY_KEY_F7: "\u{F70A}",
        GHOSTTY_KEY_F8: "\u{F70B}",
        GHOSTTY_KEY_F9: "\u{F70C}",
        GHOSTTY_KEY_F10: "\u{F70D}",
        GHOSTTY_KEY_F11: "\u{F70E}",
        GHOSTTY_KEY_F12: "\u{F70F}",
        GHOSTTY_KEY_F13: "\u{F710}",
        GHOSTTY_KEY_F14: "\u{F711}",
        GHOSTTY_KEY_F15: "\u{F712}",
        GHOSTTY_KEY_F16: "\u{F713}",
        GHOSTTY_KEY_F17: "\u{F714}",
        GHOSTTY_KEY_F18: "\u{F715}",
        GHOSTTY_KEY_F19: "\u{F716}",
        GHOSTTY_KEY_F20: "\u{F717}",
        GHOSTTY_KEY_F21: "\u{F718}",
        GHOSTTY_KEY_F22: "\u{F719}",
        GHOSTTY_KEY_F23: "\u{F71A}",
        GHOSTTY_KEY_F24: "\u{F71B}",
        GHOSTTY_KEY_F25: "\u{F71C}",
    ]

    static let asciiToKey: [UInt8 : ghostty_input_key_e] = [
        // 0-9
        0x30: GHOSTTY_KEY_ZERO,
        0x31: GHOSTTY_KEY_ONE,
        0x32: GHOSTTY_KEY_TWO,
        0x33: GHOSTTY_KEY_THREE,
        0x34: GHOSTTY_KEY_FOUR,
        0x35: GHOSTTY_KEY_FIVE,
        0x36: GHOSTTY_KEY_SIX,
        0x37: GHOSTTY_KEY_SEVEN,
        0x38: GHOSTTY_KEY_EIGHT,
        0x39: GHOSTTY_KEY_NINE,

        // A-Z
        0x41: GHOSTTY_KEY_A,
        0x42: GHOSTTY_KEY_B,
        0x43: GHOSTTY_KEY_C,
        0x44: GHOSTTY_KEY_D,
        0x45: GHOSTTY_KEY_E,
        0x46: GHOSTTY_KEY_F,
        0x47: GHOSTTY_KEY_G,
        0x48: GHOSTTY_KEY_H,
        0x49: GHOSTTY_KEY_I,
        0x4A: GHOSTTY_KEY_J,
        0x4B: GHOSTTY_KEY_K,
        0x4C: GHOSTTY_KEY_L,
        0x4D: GHOSTTY_KEY_M,
        0x4E: GHOSTTY_KEY_N,
        0x4F: GHOSTTY_KEY_O,
        0x50: GHOSTTY_KEY_P,
        0x51: GHOSTTY_KEY_Q,
        0x52: GHOSTTY_KEY_R,
        0x53: GHOSTTY_KEY_S,
        0x54: GHOSTTY_KEY_T,
        0x55: GHOSTTY_KEY_U,
        0x56: GHOSTTY_KEY_V,
        0x57: GHOSTTY_KEY_W,
        0x58: GHOSTTY_KEY_X,
        0x59: GHOSTTY_KEY_Y,
        0x5A: GHOSTTY_KEY_Z,

        // a-z
        0x61: GHOSTTY_KEY_A,
        0x62: GHOSTTY_KEY_B,
        0x63: GHOSTTY_KEY_C,
        0x64: GHOSTTY_KEY_D,
        0x65: GHOSTTY_KEY_E,
        0x66: GHOSTTY_KEY_F,
        0x67: GHOSTTY_KEY_G,
        0x68: GHOSTTY_KEY_H,
        0x69: GHOSTTY_KEY_I,
        0x6A: GHOSTTY_KEY_J,
        0x6B: GHOSTTY_KEY_K,
        0x6C: GHOSTTY_KEY_L,
        0x6D: GHOSTTY_KEY_M,
        0x6E: GHOSTTY_KEY_N,
        0x6F: GHOSTTY_KEY_O,
        0x70: GHOSTTY_KEY_P,
        0x71: GHOSTTY_KEY_Q,
        0x72: GHOSTTY_KEY_R,
        0x73: GHOSTTY_KEY_S,
        0x74: GHOSTTY_KEY_T,
        0x75: GHOSTTY_KEY_U,
        0x76: GHOSTTY_KEY_V,
        0x77: GHOSTTY_KEY_W,
        0x78: GHOSTTY_KEY_X,
        0x79: GHOSTTY_KEY_Y,
        0x7A: GHOSTTY_KEY_Z,

        // Symbols
        0x27: GHOSTTY_KEY_APOSTROPHE,
        0x5C: GHOSTTY_KEY_BACKSLASH,
        0x2C: GHOSTTY_KEY_COMMA,
        0x3D: GHOSTTY_KEY_EQUAL,
        0x60: GHOSTTY_KEY_GRAVE_ACCENT,
        0x5B: GHOSTTY_KEY_LEFT_BRACKET,
        0x2D: GHOSTTY_KEY_MINUS,
        0x2E: GHOSTTY_KEY_PERIOD,
        0x5D: GHOSTTY_KEY_RIGHT_BRACKET,
        0x3B: GHOSTTY_KEY_SEMICOLON,
        0x2F: GHOSTTY_KEY_SLASH,
    ]
}

