import SwiftUI

// MARK: EventModifiers to NSEvent and Back

extension EventModifiers {
    init(nsFlags: NSEvent.ModifierFlags) {
        var result: SwiftUI.EventModifiers = []
        // swiftlint:disable opening_brace
        if nsFlags.contains(.shift)     { result.insert(.shift) }
        if nsFlags.contains(.control)   { result.insert(.control) }
        if nsFlags.contains(.option)    { result.insert(.option) }
        if nsFlags.contains(.command)   { result.insert(.command) }
        if nsFlags.contains(.capsLock)  { result.insert(.capsLock) }
        // swiftlint:enable opening_brace
        self = result
    }
}

extension NSEvent.ModifierFlags {
    init(swiftUIFlags: SwiftUI.EventModifiers) {
        var result: NSEvent.ModifierFlags = []
        // swiftlint:disable opening_brace
        if swiftUIFlags.contains(.shift)     { result.insert(.shift) }
        if swiftUIFlags.contains(.control)   { result.insert(.control) }
        if swiftUIFlags.contains(.option)    { result.insert(.option) }
        if swiftUIFlags.contains(.command)   { result.insert(.command) }
        if swiftUIFlags.contains(.capsLock)  { result.insert(.capsLock) }
        // swiftlint:enable opening_brace
        self = result
    }
}
