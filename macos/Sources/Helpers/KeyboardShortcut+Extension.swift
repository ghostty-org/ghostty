import SwiftUI

extension KeyboardShortcut: @retroactive CustomStringConvertible {
    public var keyList: [String] {
        var result: [String] = []

        if modifiers.contains(.control) {
            result.append("⌃")
        }
        if modifiers.contains(.option) {
            result.append("⌥")
        }
        if modifiers.contains(.shift) {
            result.append("⇧")
        }
        if modifiers.contains(.command) {
            result.append("⌘")
        }

        let keyString: String
        switch key {
        case .return: keyString = "⏎"
        case .escape: keyString = "⎋"
        case .delete: keyString = "⌫"
        case .space: keyString = "␣"
        case .tab: keyString = "⇥"
        case .upArrow: keyString = "▲"
        case .downArrow: keyString = "▼"
        case .leftArrow: keyString = "◀"
        case .rightArrow: keyString = "▶"
        case .pageUp: keyString = "↑"
        case .pageDown: keyString = "↓"
        case .home: keyString = "⤒"
        case .end: keyString = "⤓"
        default:
            keyString = String(key.character.uppercased())
        }

        result.append(keyString)
        return result
    }

    public var description: String {
        return self.keyList.joined()
    }
}

// This is available in macOS 14 so this only applies to early macOS versions.
extension KeyEquivalent: @retroactive Equatable {
    public static func == (lhs: KeyEquivalent, rhs: KeyEquivalent) -> Bool {
        lhs.character == rhs.character
    }
}
