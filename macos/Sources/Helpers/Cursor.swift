import Cocoa
import SwiftUI

/// This helps manage the stateful nature of NSCursor hiding and unhiding.
class Cursor {
    private static var counter: UInt = 0

    static var isVisible: Bool {
        counter == 0
    }

    static func hide() {
        counter += 1
        NSCursor.hide()
    }

    /// Unhide the cursor. Returns true if the cursor was previously hidden.
    static func unhide() -> Bool {
        // Its always safe to call unhide when the counter is zero because it
        // won't go negative.
        NSCursor.unhide()

        if counter > 0 {
            counter -= 1
            return true
        }

        return false
    }

    static func unhideCompletely() -> UInt {
        let counter = self.counter
        for _ in 0 ..< counter {
            assert(unhide())
        }
        assert(self.counter == 0)
        return counter
    }
}

enum CursorStyle {
    case `default`
    case grabIdle
    case grabActive
    case horizontalText
    case verticalText
    case link
    case resizeLeft
    case resizeRight
    case resizeUp
    case resizeDown
    case resizeUpDown
    case resizeLeftRight
    case contextMenu
    case crosshair
    case operationNotAllowed
}

extension CursorStyle {
    var cursor: NSCursor {
        switch self {
        case .default:
            return .arrow
        case .grabIdle:
            return .openHand
        case .grabActive:
            return .closedHand
        case .horizontalText:
            return .iBeam
        case .verticalText:
            return .iBeamCursorForVerticalLayout
        case .link:
            return .pointingHand
        case .resizeLeft:
            if #available(macOS 15.0, *) {
                return .columnResize(directions: .left)
            } else {
                return .resizeLeft
            }
        case .resizeRight:
            if #available(macOS 15.0, *) {
                return .columnResize(directions: .right)
            } else {
                return .resizeRight
            }
        case .resizeUp:
            if #available(macOS 15.0, *) {
                return .rowResize(directions: .up)
            } else {
                return .resizeUp
            }
        case .resizeDown:
            if #available(macOS 15.0, *) {
                return .rowResize(directions: .down)
            } else {
                return .resizeDown
            }
        case .resizeUpDown:
            if #available(macOS 15.0, *) {
                return .rowResize
            } else {
                return .resizeUpDown
            }
        case .resizeLeftRight:
            if #available(macOS 15.0, *) {
                return .columnResize
            } else {
                return .resizeLeftRight
            }
        case .contextMenu:
            return .contextualMenu
        case .crosshair:
            return .crosshair
        case .operationNotAllowed:
            return .operationNotAllowed
        }
    }
}
