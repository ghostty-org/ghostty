import AppIntents
import Cocoa
import SwiftUI
import GhosttyKit

extension Ghostty {
    struct Input {}

    // MARK: Keyboard Shortcuts

    /// Return the key equivalent for the given trigger.
    ///
    /// Returns nil if the trigger doesn't have an equivalent KeyboardShortcut. This is possible
    /// because Ghostty input triggers are a superset of what can be represented by a macOS
    /// KeyboardShortcut. For example, macOS doesn't have any way to represent function keys
    /// (F1, F2, ...) with a KeyboardShortcut. This doesn't represent a practical issue because input
    /// handling for Ghostty is handled at a lower level (usually). This function should generally only
    /// be used for things like NSMenu that only support keyboard shortcuts anyways.
    static func keyboardShortcut(for trigger: ghostty_input_trigger_s) -> KeyboardShortcut? {
        let key: KeyEquivalent
        switch (trigger.tag) {
        case GHOSTTY_TRIGGER_PHYSICAL:
            // Only functional keys can be converted to a KeyboardShortcut. Other physical
            // mappings cannot because KeyboardShortcut in Swift is inherently layout-dependent.
            if let equiv = Self.keyToEquivalent[trigger.key.physical] {
                key = equiv
            } else {
                return nil
            }

        case GHOSTTY_TRIGGER_UNICODE:
            guard let scalar = UnicodeScalar(trigger.key.unicode) else { return nil }
            key = KeyEquivalent(Character(scalar))

        default:
            return nil
        }

        return KeyboardShortcut(
            key,
            modifiers: EventModifiers(nsFlags: Ghostty.eventModifierFlags(mods: trigger.mods)))
    }

    // MARK: Mods

    /// Returns the event modifier flags set for the Ghostty mods enum.
    static func eventModifierFlags(mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags(rawValue: 0);
        if (mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0) { flags.insert(.shift) }
        if (mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0) { flags.insert(.control) }
        if (mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0) { flags.insert(.option) }
        if (mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0) { flags.insert(.command) }
        return flags
    }

    /// Translate event modifier flags to a ghostty mods enum.
    static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue

        if (flags.contains(.shift)) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if (flags.contains(.control)) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if (flags.contains(.option)) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if (flags.contains(.command)) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if (flags.contains(.capsLock)) { mods |= GHOSTTY_MODS_CAPS.rawValue }

        // Handle sided input. We can't tell that both are pressed in the
        // Ghostty structure but thats okay -- we don't use that information.
        let rawFlags = flags.rawValue
        if (rawFlags & UInt(NX_DEVICERSHIFTKEYMASK) != 0) { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if (rawFlags & UInt(NX_DEVICERCTLKEYMASK) != 0) { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if (rawFlags & UInt(NX_DEVICERALTKEYMASK) != 0) { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if (rawFlags & UInt(NX_DEVICERCMDKEYMASK) != 0) { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }

        return ghostty_input_mods_e(mods)
    }

    /// A map from the Ghostty key enum to the keyEquivalent string for shortcuts. Note that
    /// not all ghostty key enum values are represented here because not all of them can be
    /// mapped to a KeyEquivalent.
    static let keyToEquivalent: [ghostty_input_key_e : KeyEquivalent] = [
        // Function keys
        GHOSTTY_KEY_ARROW_UP: .upArrow,
        GHOSTTY_KEY_ARROW_DOWN: .downArrow,
        GHOSTTY_KEY_ARROW_LEFT: .leftArrow,
        GHOSTTY_KEY_ARROW_RIGHT: .rightArrow,
        GHOSTTY_KEY_HOME: .home,
        GHOSTTY_KEY_END: .end,
        GHOSTTY_KEY_DELETE: .delete,
        GHOSTTY_KEY_PAGE_UP: .pageUp,
        GHOSTTY_KEY_PAGE_DOWN: .pageDown,
        GHOSTTY_KEY_ESCAPE: .escape,
        GHOSTTY_KEY_ENTER: .return,
        GHOSTTY_KEY_TAB: .tab,
        GHOSTTY_KEY_BACKSPACE: .delete,
        GHOSTTY_KEY_SPACE: .space,
    ]
}

// MARK: Ghostty.Input.KeyEvent

extension Ghostty.Input {
    /// `ghostty_input_key_s`
    struct KeyEvent {
        let action: Action
        let key: Key
        let text: String?
        let composing: Bool
        let mods: Mods
        let consumedMods: Mods
        let unshiftedCodepoint: UInt32

        init(
            key: Key,
            action: Action = .press,
            text: String? = nil,
            composing: Bool = false,
            mods: Mods = [],
            consumedMods: Mods = [],
            unshiftedCodepoint: UInt32 = 0
        ) {
            self.key = key
            self.action = action
            self.text = text
            self.composing = composing
            self.mods = mods
            self.consumedMods = consumedMods
            self.unshiftedCodepoint = unshiftedCodepoint
        }

        init?(cValue: ghostty_input_key_s) {
            // Convert action
            switch cValue.action {
            case GHOSTTY_ACTION_PRESS: self.action = .press
            case GHOSTTY_ACTION_RELEASE: self.action = .release
            case GHOSTTY_ACTION_REPEAT: self.action = .repeat
            default: self.action = .press
            }
            
            // Convert key from keycode
            guard let key = Key(keyCode: UInt16(cValue.keycode)) else { return nil }
            self.key = key

            // Convert text
            if let textPtr = cValue.text {
                self.text = String(cString: textPtr)
            } else {
                self.text = nil
            }
            
            // Set composing state
            self.composing = cValue.composing
            
            // Convert modifiers
            self.mods = Mods(cMods: cValue.mods)
            self.consumedMods = Mods(cMods: cValue.consumed_mods)
            
            // Set unshifted codepoint
            self.unshiftedCodepoint = cValue.unshifted_codepoint
        }
        
        /// Executes a closure with a temporary C representation of this KeyEvent.
        ///
        /// This method safely converts the Swift KeyEntity to a C `ghostty_input_key_s` struct
        /// and passes it to the provided closure. The C struct is only valid within the closure's
        /// execution scope. The text field's C string pointer is managed automatically and will
        /// be invalid after the closure returns.
        ///
        /// - Parameter execute: A closure that receives the C struct and returns a value
        /// - Returns: The value returned by the closure
        @discardableResult
        func withCValue<T>(execute: (ghostty_input_key_s) -> T) -> T {
            var keyEvent = ghostty_input_key_s()
            keyEvent.action = action.cAction
            keyEvent.keycode = UInt32(key.keyCode ?? 0)
            keyEvent.composing = composing
            keyEvent.mods = mods.cMods
            keyEvent.consumed_mods = consumedMods.cMods
            keyEvent.unshifted_codepoint = unshiftedCodepoint
            
            // Handle text with proper memory management
            if let text = text {
                return text.withCString { textPtr in
                    keyEvent.text = textPtr
                    return execute(keyEvent)
                }
            } else {
                keyEvent.text = nil
                return execute(keyEvent)
            }
        }
    }
}

// MARK: Ghostty.Input.Action

extension Ghostty.Input {
    /// `ghostty_input_action_e`
    enum Action: String, CaseIterable {
        case release
        case press
        case `repeat`
        
        var cAction: ghostty_input_action_e {
            switch self {
            case .release: GHOSTTY_ACTION_RELEASE
            case .press: GHOSTTY_ACTION_PRESS
            case .repeat: GHOSTTY_ACTION_REPEAT
            }
        }
    }
}

extension Ghostty.Input.Action: AppEnum {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Key Action")

    static var caseDisplayRepresentations: [Ghostty.Input.Action : DisplayRepresentation] = [
        .release: "Release",
        .press: "Press",
        .repeat: "Repeat"
    ]
}

// MARK: Ghostty.Input.MouseEvent

extension Ghostty.Input {
    /// Represents a mouse input event with button state, button type, and modifier keys.
    struct MouseButtonEvent {
        let action: MouseState
        let button: MouseButton
        let mods: Mods
        
        init(
            action: MouseState,
            button: MouseButton,
            mods: Mods = []
        ) {
            self.action = action
            self.button = button
            self.mods = mods
        }
        
        /// Creates a MouseEvent from C enum values.
        ///
        /// This initializer converts C-style mouse input enums to Swift types.
        /// Returns nil if any of the C enum values are invalid or unsupported.
        ///
        /// - Parameters:
        ///   - state: The mouse button state (press/release)
        ///   - button: The mouse button that was pressed/released
        ///   - mods: The modifier keys held during the mouse event
        init?(state: ghostty_input_mouse_state_e, button: ghostty_input_mouse_button_e, mods: ghostty_input_mods_e) {
            // Convert state
            switch state {
            case GHOSTTY_MOUSE_RELEASE: self.action = .release
            case GHOSTTY_MOUSE_PRESS: self.action = .press
            default: return nil
            }
            
            // Convert button
            switch button {
            case GHOSTTY_MOUSE_UNKNOWN: self.button = .unknown
            case GHOSTTY_MOUSE_LEFT: self.button = .left
            case GHOSTTY_MOUSE_RIGHT: self.button = .right
            case GHOSTTY_MOUSE_MIDDLE: self.button = .middle
            default: return nil
            }
            
            // Convert modifiers
            self.mods = Mods(cMods: mods)
        }
    }

    /// Represents a mouse position/movement event with coordinates and modifier keys.
    struct MousePosEvent {
        let x: Double
        let y: Double
        let mods: Mods
        
        init(
            x: Double,
            y: Double,
            mods: Mods = []
        ) {
            self.x = x
            self.y = y
            self.mods = mods
        }
    }

    /// Represents a mouse scroll event with scroll deltas and modifier keys.
    struct MouseScrollEvent {
        let x: Double
        let y: Double
        let mods: ScrollMods

        init(
            x: Double,
            y: Double,
            mods: ScrollMods = .init(rawValue: 0)
        ) {
            self.x = x
            self.y = y
            self.mods = mods
        }
    }
}

// MARK: Ghostty.Input.MouseState

extension Ghostty.Input {
    /// `ghostty_input_mouse_state_e`
    enum MouseState: String, CaseIterable {
        case release
        case press
        
        var cMouseState: ghostty_input_mouse_state_e {
            switch self {
            case .release: GHOSTTY_MOUSE_RELEASE
            case .press: GHOSTTY_MOUSE_PRESS
            }
        }
    }
}

extension Ghostty.Input.MouseState: AppEnum {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Mouse State")

    static var caseDisplayRepresentations: [Ghostty.Input.MouseState : DisplayRepresentation] = [
        .release: "Release",
        .press: "Press"
    ]
}

// MARK: Ghostty.Input.MouseButton

extension Ghostty.Input {
    /// `ghostty_input_mouse_button_e`
    enum MouseButton: String, CaseIterable {
        case unknown
        case left
        case right
        case middle
        
        var cMouseButton: ghostty_input_mouse_button_e {
            switch self {
            case .unknown: GHOSTTY_MOUSE_UNKNOWN
            case .left: GHOSTTY_MOUSE_LEFT
            case .right: GHOSTTY_MOUSE_RIGHT
            case .middle: GHOSTTY_MOUSE_MIDDLE
            }
        }
    }
}

extension Ghostty.Input.MouseButton: AppEnum {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Mouse Button")

    static var caseDisplayRepresentations: [Ghostty.Input.MouseButton : DisplayRepresentation] = [
        .unknown: "Unknown",
        .left: "Left",
        .right: "Right",
        .middle: "Middle"
    ]

    static var allCases: [Ghostty.Input.MouseButton] = [
        .left,
        .right,
        .middle,
    ]
}

// MARK: Ghostty.Input.ScrollMods

extension Ghostty.Input {
    /// `ghostty_input_scroll_mods_t` - Scroll event modifiers
    ///
    /// This is a packed bitmask that contains precision and momentum information
    /// for scroll events, matching the Zig `ScrollMods` packed struct.
    struct ScrollMods {
        let rawValue: Int32
        
        /// True if this is a high-precision scroll event (e.g., trackpad, Magic Mouse)
        var precision: Bool {
            rawValue & 0b0000_0001 != 0
        }
        
        /// The momentum phase of the scroll event for inertial scrolling
        var momentum: Momentum {
            let momentumBits = (rawValue >> 1) & 0b0000_0111
            return Momentum(rawValue: UInt8(momentumBits)) ?? .none
        }
        
        init(precision: Bool = false, momentum: Momentum = .none) {
            var value: Int32 = 0
            if precision {
                value |= 0b0000_0001
            }
            value |= Int32(momentum.rawValue) << 1
            self.rawValue = value
        }
        
        init(rawValue: Int32) {
            self.rawValue = rawValue
        }
        
        var cScrollMods: ghostty_input_scroll_mods_t {
            rawValue
        }
    }
}

// MARK: Ghostty.Input.Momentum

extension Ghostty.Input {
    /// `ghostty_input_mouse_momentum_e` - Momentum phase for scroll events
    enum Momentum: UInt8, CaseIterable {
        case none = 0
        case began = 1
        case stationary = 2
        case changed = 3
        case ended = 4
        case cancelled = 5
        case mayBegin = 6
        
        var cMomentum: ghostty_input_mouse_momentum_e {
            switch self {
            case .none: GHOSTTY_MOUSE_MOMENTUM_NONE
            case .began: GHOSTTY_MOUSE_MOMENTUM_BEGAN
            case .stationary: GHOSTTY_MOUSE_MOMENTUM_STATIONARY
            case .changed: GHOSTTY_MOUSE_MOMENTUM_CHANGED
            case .ended: GHOSTTY_MOUSE_MOMENTUM_ENDED
            case .cancelled: GHOSTTY_MOUSE_MOMENTUM_CANCELLED
            case .mayBegin: GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
            }
        }
    }
}

extension Ghostty.Input.Momentum: AppEnum {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Scroll Momentum")
    
    static var caseDisplayRepresentations: [Ghostty.Input.Momentum : DisplayRepresentation] = [
        .none: "None",
        .began: "Began",
        .stationary: "Stationary",
        .changed: "Changed",
        .ended: "Ended",
        .cancelled: "Cancelled",
        .mayBegin: "May Begin"
    ]
}

#if canImport(AppKit)
import AppKit

extension Ghostty.Input.Momentum {
    /// Create a Momentum from an NSEvent.Phase
    init(_ phase: NSEvent.Phase) {
        switch phase {
        case .began: self = .began
        case .stationary: self = .stationary
        case .changed: self = .changed
        case .ended: self = .ended
        case .cancelled: self = .cancelled
        case .mayBegin: self = .mayBegin
        default: self = .none
        }
    }
}
#endif

// MARK: Ghostty.Input.Mods

extension Ghostty.Input {
    /// `ghostty_input_mods_e`
    struct Mods: OptionSet {
        let rawValue: UInt32
        
        static let none = Mods(rawValue: GHOSTTY_MODS_NONE.rawValue)
        static let shift = Mods(rawValue: GHOSTTY_MODS_SHIFT.rawValue)
        static let ctrl = Mods(rawValue: GHOSTTY_MODS_CTRL.rawValue)
        static let alt = Mods(rawValue: GHOSTTY_MODS_ALT.rawValue)
        static let `super` = Mods(rawValue: GHOSTTY_MODS_SUPER.rawValue)
        static let caps = Mods(rawValue: GHOSTTY_MODS_CAPS.rawValue)
        static let shiftRight = Mods(rawValue: GHOSTTY_MODS_SHIFT_RIGHT.rawValue)
        static let ctrlRight = Mods(rawValue: GHOSTTY_MODS_CTRL_RIGHT.rawValue)
        static let altRight = Mods(rawValue: GHOSTTY_MODS_ALT_RIGHT.rawValue)
        static let superRight = Mods(rawValue: GHOSTTY_MODS_SUPER_RIGHT.rawValue)
        
        var cMods: ghostty_input_mods_e {
            ghostty_input_mods_e(rawValue)
        }
        
        init(rawValue: UInt32) {
            self.rawValue = rawValue
        }
        
        init(cMods: ghostty_input_mods_e) {
            self.rawValue = cMods.rawValue
        }
        
        init(nsFlags: NSEvent.ModifierFlags) {
            self.init(cMods: Ghostty.ghosttyMods(nsFlags))
        }
        
        var nsFlags: NSEvent.ModifierFlags {
            Ghostty.eventModifierFlags(mods: cMods)
        }
    }
}

// MARK: Ghostty.Input.Key

extension Ghostty.Input {
    /// `ghostty_input_key_e`
    enum Key: String {
        // Writing System Keys
        case backquote
        case backslash
        case bracketLeft
        case bracketRight
        case comma
        case digit0
        case digit1
        case digit2
        case digit3
        case digit4
        case digit5
        case digit6
        case digit7
        case digit8
        case digit9
        case equal
        case intlBackslash
        case intlRo
        case intlYen
        case a
        case b
        case c
        case d
        case e
        case f
        case g
        case h
        case i
        case j
        case k
        case l
        case m
        case n
        case o
        case p
        case q
        case r
        case s
        case t
        case u
        case v
        case w
        case x
        case y
        case z
        case minus
        case period
        case quote
        case semicolon
        case slash

        // Functional Keys
        case altLeft
        case altRight
        case backspace
        case capsLock
        case contextMenu
        case controlLeft
        case controlRight
        case enter
        case metaLeft
        case metaRight
        case shiftLeft
        case shiftRight
        case space
        case tab
        case convert
        case kanaMode
        case nonConvert

        // Control Pad Section
        case delete
        case end
        case help
        case home
        case insert
        case pageDown
        case pageUp

        // Arrow Pad Section
        case arrowDown
        case arrowLeft
        case arrowRight
        case arrowUp

        // Numpad Section
        case numLock
        case numpad0
        case numpad1
        case numpad2
        case numpad3
        case numpad4
        case numpad5
        case numpad6
        case numpad7
        case numpad8
        case numpad9
        case numpadAdd
        case numpadBackspace
        case numpadClear
        case numpadClearEntry
        case numpadComma
        case numpadDecimal
        case numpadDivide
        case numpadEnter
        case numpadEqual
        case numpadMemoryAdd
        case numpadMemoryClear
        case numpadMemoryRecall
        case numpadMemoryStore
        case numpadMemorySubtract
        case numpadMultiply
        case numpadParenLeft
        case numpadParenRight
        case numpadSubtract
        case numpadSeparator
        case numpadUp
        case numpadDown
        case numpadRight
        case numpadLeft
        case numpadBegin
        case numpadHome
        case numpadEnd
        case numpadInsert
        case numpadDelete
        case numpadPageUp
        case numpadPageDown

        // Function Section
        case escape
        case f1
        case f2
        case f3
        case f4
        case f5
        case f6
        case f7
        case f8
        case f9
        case f10
        case f11
        case f12
        case f13
        case f14
        case f15
        case f16
        case f17
        case f18
        case f19
        case f20
        case f21
        case f22
        case f23
        case f24
        case f25
        case fn
        case fnLock
        case printScreen
        case scrollLock
        case pause

        // Media Keys
        case browserBack
        case browserFavorites
        case browserForward
        case browserHome
        case browserRefresh
        case browserSearch
        case browserStop
        case eject
        case launchApp1
        case launchApp2
        case launchMail
        case mediaPlayPause
        case mediaSelect
        case mediaStop
        case mediaTrackNext
        case mediaTrackPrevious
        case power
        case sleep
        case audioVolumeDown
        case audioVolumeMute
        case audioVolumeUp
        case wakeUp

        // Legacy, Non-standard, and Special Keys
        case copy
        case cut
        case paste

        /// Get a key from a keycode
        init?(keyCode: UInt16) {
            if let key = Key.allCases.first(where: { $0.keyCode == keyCode }) {
                self = key
                return
            }

            return nil
        }

        var cKey: ghostty_input_key_e {
            switch self {
            // Writing System Keys
            case .backquote: GHOSTTY_KEY_BACKQUOTE
            case .backslash: GHOSTTY_KEY_BACKSLASH
            case .bracketLeft: GHOSTTY_KEY_BRACKET_LEFT
            case .bracketRight: GHOSTTY_KEY_BRACKET_RIGHT
            case .comma: GHOSTTY_KEY_COMMA
            case .digit0: GHOSTTY_KEY_DIGIT_0
            case .digit1: GHOSTTY_KEY_DIGIT_1
            case .digit2: GHOSTTY_KEY_DIGIT_2
            case .digit3: GHOSTTY_KEY_DIGIT_3
            case .digit4: GHOSTTY_KEY_DIGIT_4
            case .digit5: GHOSTTY_KEY_DIGIT_5
            case .digit6: GHOSTTY_KEY_DIGIT_6
            case .digit7: GHOSTTY_KEY_DIGIT_7
            case .digit8: GHOSTTY_KEY_DIGIT_8
            case .digit9: GHOSTTY_KEY_DIGIT_9
            case .equal: GHOSTTY_KEY_EQUAL
            case .intlBackslash: GHOSTTY_KEY_INTL_BACKSLASH
            case .intlRo: GHOSTTY_KEY_INTL_RO
            case .intlYen: GHOSTTY_KEY_INTL_YEN
            case .a: GHOSTTY_KEY_A
            case .b: GHOSTTY_KEY_B
            case .c: GHOSTTY_KEY_C
            case .d: GHOSTTY_KEY_D
            case .e: GHOSTTY_KEY_E
            case .f: GHOSTTY_KEY_F
            case .g: GHOSTTY_KEY_G
            case .h: GHOSTTY_KEY_H
            case .i: GHOSTTY_KEY_I
            case .j: GHOSTTY_KEY_J
            case .k: GHOSTTY_KEY_K
            case .l: GHOSTTY_KEY_L
            case .m: GHOSTTY_KEY_M
            case .n: GHOSTTY_KEY_N
            case .o: GHOSTTY_KEY_O
            case .p: GHOSTTY_KEY_P
            case .q: GHOSTTY_KEY_Q
            case .r: GHOSTTY_KEY_R
            case .s: GHOSTTY_KEY_S
            case .t: GHOSTTY_KEY_T
            case .u: GHOSTTY_KEY_U
            case .v: GHOSTTY_KEY_V
            case .w: GHOSTTY_KEY_W
            case .x: GHOSTTY_KEY_X
            case .y: GHOSTTY_KEY_Y
            case .z: GHOSTTY_KEY_Z
            case .minus: GHOSTTY_KEY_MINUS
            case .period: GHOSTTY_KEY_PERIOD
            case .quote: GHOSTTY_KEY_QUOTE
            case .semicolon: GHOSTTY_KEY_SEMICOLON
            case .slash: GHOSTTY_KEY_SLASH

            // Functional Keys
            case .altLeft: GHOSTTY_KEY_ALT_LEFT
            case .altRight: GHOSTTY_KEY_ALT_RIGHT
            case .backspace: GHOSTTY_KEY_BACKSPACE
            case .capsLock: GHOSTTY_KEY_CAPS_LOCK
            case .contextMenu: GHOSTTY_KEY_CONTEXT_MENU
            case .controlLeft: GHOSTTY_KEY_CONTROL_LEFT
            case .controlRight: GHOSTTY_KEY_CONTROL_RIGHT
            case .enter: GHOSTTY_KEY_ENTER
            case .metaLeft: GHOSTTY_KEY_META_LEFT
            case .metaRight: GHOSTTY_KEY_META_RIGHT
            case .shiftLeft: GHOSTTY_KEY_SHIFT_LEFT
            case .shiftRight: GHOSTTY_KEY_SHIFT_RIGHT
            case .space: GHOSTTY_KEY_SPACE
            case .tab: GHOSTTY_KEY_TAB
            case .convert: GHOSTTY_KEY_CONVERT
            case .kanaMode: GHOSTTY_KEY_KANA_MODE
            case .nonConvert: GHOSTTY_KEY_NON_CONVERT

            // Control Pad Section
            case .delete: GHOSTTY_KEY_DELETE
            case .end: GHOSTTY_KEY_END
            case .help: GHOSTTY_KEY_HELP
            case .home: GHOSTTY_KEY_HOME
            case .insert: GHOSTTY_KEY_INSERT
            case .pageDown: GHOSTTY_KEY_PAGE_DOWN
            case .pageUp: GHOSTTY_KEY_PAGE_UP

            // Arrow Pad Section
            case .arrowDown: GHOSTTY_KEY_ARROW_DOWN
            case .arrowLeft: GHOSTTY_KEY_ARROW_LEFT
            case .arrowRight: GHOSTTY_KEY_ARROW_RIGHT
            case .arrowUp: GHOSTTY_KEY_ARROW_UP

            // Numpad Section
            case .numLock: GHOSTTY_KEY_NUM_LOCK
            case .numpad0: GHOSTTY_KEY_NUMPAD_0
            case .numpad1: GHOSTTY_KEY_NUMPAD_1
            case .numpad2: GHOSTTY_KEY_NUMPAD_2
            case .numpad3: GHOSTTY_KEY_NUMPAD_3
            case .numpad4: GHOSTTY_KEY_NUMPAD_4
            case .numpad5: GHOSTTY_KEY_NUMPAD_5
            case .numpad6: GHOSTTY_KEY_NUMPAD_6
            case .numpad7: GHOSTTY_KEY_NUMPAD_7
            case .numpad8: GHOSTTY_KEY_NUMPAD_8
            case .numpad9: GHOSTTY_KEY_NUMPAD_9
            case .numpadAdd: GHOSTTY_KEY_NUMPAD_ADD
            case .numpadBackspace: GHOSTTY_KEY_NUMPAD_BACKSPACE
            case .numpadClear: GHOSTTY_KEY_NUMPAD_CLEAR
            case .numpadClearEntry: GHOSTTY_KEY_NUMPAD_CLEAR_ENTRY
            case .numpadComma: GHOSTTY_KEY_NUMPAD_COMMA
            case .numpadDecimal: GHOSTTY_KEY_NUMPAD_DECIMAL
            case .numpadDivide: GHOSTTY_KEY_NUMPAD_DIVIDE
            case .numpadEnter: GHOSTTY_KEY_NUMPAD_ENTER
            case .numpadEqual: GHOSTTY_KEY_NUMPAD_EQUAL
            case .numpadMemoryAdd: GHOSTTY_KEY_NUMPAD_MEMORY_ADD
            case .numpadMemoryClear: GHOSTTY_KEY_NUMPAD_MEMORY_CLEAR
            case .numpadMemoryRecall: GHOSTTY_KEY_NUMPAD_MEMORY_RECALL
            case .numpadMemoryStore: GHOSTTY_KEY_NUMPAD_MEMORY_STORE
            case .numpadMemorySubtract: GHOSTTY_KEY_NUMPAD_MEMORY_SUBTRACT
            case .numpadMultiply: GHOSTTY_KEY_NUMPAD_MULTIPLY
            case .numpadParenLeft: GHOSTTY_KEY_NUMPAD_PAREN_LEFT
            case .numpadParenRight: GHOSTTY_KEY_NUMPAD_PAREN_RIGHT
            case .numpadSubtract: GHOSTTY_KEY_NUMPAD_SUBTRACT
            case .numpadSeparator: GHOSTTY_KEY_NUMPAD_SEPARATOR
            case .numpadUp: GHOSTTY_KEY_NUMPAD_UP
            case .numpadDown: GHOSTTY_KEY_NUMPAD_DOWN
            case .numpadRight: GHOSTTY_KEY_NUMPAD_RIGHT
            case .numpadLeft: GHOSTTY_KEY_NUMPAD_LEFT
            case .numpadBegin: GHOSTTY_KEY_NUMPAD_BEGIN
            case .numpadHome: GHOSTTY_KEY_NUMPAD_HOME
            case .numpadEnd: GHOSTTY_KEY_NUMPAD_END
            case .numpadInsert: GHOSTTY_KEY_NUMPAD_INSERT
            case .numpadDelete: GHOSTTY_KEY_NUMPAD_DELETE
            case .numpadPageUp: GHOSTTY_KEY_NUMPAD_PAGE_UP
            case .numpadPageDown: GHOSTTY_KEY_NUMPAD_PAGE_DOWN

            // Function Section
            case .escape: GHOSTTY_KEY_ESCAPE
            case .f1: GHOSTTY_KEY_F1
            case .f2: GHOSTTY_KEY_F2
            case .f3: GHOSTTY_KEY_F3
            case .f4: GHOSTTY_KEY_F4
            case .f5: GHOSTTY_KEY_F5
            case .f6: GHOSTTY_KEY_F6
            case .f7: GHOSTTY_KEY_F7
            case .f8: GHOSTTY_KEY_F8
            case .f9: GHOSTTY_KEY_F9
            case .f10: GHOSTTY_KEY_F10
            case .f11: GHOSTTY_KEY_F11
            case .f12: GHOSTTY_KEY_F12
            case .f13: GHOSTTY_KEY_F13
            case .f14: GHOSTTY_KEY_F14
            case .f15: GHOSTTY_KEY_F15
            case .f16: GHOSTTY_KEY_F16
            case .f17: GHOSTTY_KEY_F17
            case .f18: GHOSTTY_KEY_F18
            case .f19: GHOSTTY_KEY_F19
            case .f20: GHOSTTY_KEY_F20
            case .f21: GHOSTTY_KEY_F21
            case .f22: GHOSTTY_KEY_F22
            case .f23: GHOSTTY_KEY_F23
            case .f24: GHOSTTY_KEY_F24
            case .f25: GHOSTTY_KEY_F25
            case .fn: GHOSTTY_KEY_FN
            case .fnLock: GHOSTTY_KEY_FN_LOCK
            case .printScreen: GHOSTTY_KEY_PRINT_SCREEN
            case .scrollLock: GHOSTTY_KEY_SCROLL_LOCK
            case .pause: GHOSTTY_KEY_PAUSE

            // Media Keys
            case .browserBack: GHOSTTY_KEY_BROWSER_BACK
            case .browserFavorites: GHOSTTY_KEY_BROWSER_FAVORITES
            case .browserForward: GHOSTTY_KEY_BROWSER_FORWARD
            case .browserHome: GHOSTTY_KEY_BROWSER_HOME
            case .browserRefresh: GHOSTTY_KEY_BROWSER_REFRESH
            case .browserSearch: GHOSTTY_KEY_BROWSER_SEARCH
            case .browserStop: GHOSTTY_KEY_BROWSER_STOP
            case .eject: GHOSTTY_KEY_EJECT
            case .launchApp1: GHOSTTY_KEY_LAUNCH_APP_1
            case .launchApp2: GHOSTTY_KEY_LAUNCH_APP_2
            case .launchMail: GHOSTTY_KEY_LAUNCH_MAIL
            case .mediaPlayPause: GHOSTTY_KEY_MEDIA_PLAY_PAUSE
            case .mediaSelect: GHOSTTY_KEY_MEDIA_SELECT
            case .mediaStop: GHOSTTY_KEY_MEDIA_STOP
            case .mediaTrackNext: GHOSTTY_KEY_MEDIA_TRACK_NEXT
            case .mediaTrackPrevious: GHOSTTY_KEY_MEDIA_TRACK_PREVIOUS
            case .power: GHOSTTY_KEY_POWER
            case .sleep: GHOSTTY_KEY_SLEEP
            case .audioVolumeDown: GHOSTTY_KEY_AUDIO_VOLUME_DOWN
            case .audioVolumeMute: GHOSTTY_KEY_AUDIO_VOLUME_MUTE
            case .audioVolumeUp: GHOSTTY_KEY_AUDIO_VOLUME_UP
            case .wakeUp: GHOSTTY_KEY_WAKE_UP

            // Legacy, Non-standard, and Special Keys
            case .copy: GHOSTTY_KEY_COPY
            case .cut: GHOSTTY_KEY_CUT
            case .paste: GHOSTTY_KEY_PASTE
            }
        }

        // Based on src/input/keycodes.zig
        var keyCode: UInt16? {
            switch self {
            // Writing System Keys
            case .backquote: return 0x0032
            case .backslash: return 0x002a
            case .bracketLeft: return 0x0021
            case .bracketRight: return 0x001e
            case .comma: return 0x002b
            case .digit0: return 0x001d
            case .digit1: return 0x0012
            case .digit2: return 0x0013
            case .digit3: return 0x0014
            case .digit4: return 0x0015
            case .digit5: return 0x0017
            case .digit6: return 0x0016
            case .digit7: return 0x001a
            case .digit8: return 0x001c
            case .digit9: return 0x0019
            case .equal: return 0x0018
            case .intlBackslash: return 0x000a
            case .intlRo: return 0x005e
            case .intlYen: return 0x005d
            case .a: return 0x0000
            case .b: return 0x000b
            case .c: return 0x0008
            case .d: return 0x0002
            case .e: return 0x000e
            case .f: return 0x0003
            case .g: return 0x0005
            case .h: return 0x0004
            case .i: return 0x0022
            case .j: return 0x0026
            case .k: return 0x0028
            case .l: return 0x0025
            case .m: return 0x002e
            case .n: return 0x002d
            case .o: return 0x001f
            case .p: return 0x0023
            case .q: return 0x000c
            case .r: return 0x000f
            case .s: return 0x0001
            case .t: return 0x0011
            case .u: return 0x0020
            case .v: return 0x0009
            case .w: return 0x000d
            case .x: return 0x0007
            case .y: return 0x0010
            case .z: return 0x0006
            case .minus: return 0x001b
            case .period: return 0x002f
            case .quote: return 0x0027
            case .semicolon: return 0x0029
            case .slash: return 0x002c

            // Functional Keys
            case .altLeft: return 0x003a
            case .altRight: return 0x003d
            case .backspace: return 0x0033
            case .capsLock: return 0x0039
            case .contextMenu: return 0x006e
            case .controlLeft: return 0x003b
            case .controlRight: return 0x003e
            case .enter: return 0x0024
            case .metaLeft: return 0x0037
            case .metaRight: return 0x0036
            case .shiftLeft: return 0x0038
            case .shiftRight: return 0x003c
            case .space: return 0x0031
            case .tab: return 0x0030
            case .convert: return nil // No Mac keycode
            case .kanaMode: return nil // No Mac keycode
            case .nonConvert: return nil // No Mac keycode

            // Control Pad Section
            case .delete: return 0x0075
            case .end: return 0x0077
            case .help: return nil // No Mac keycode
            case .home: return 0x0073
            case .insert: return 0x0072
            case .pageDown: return 0x0079
            case .pageUp: return 0x0074

            // Arrow Pad Section
            case .arrowDown: return 0x007d
            case .arrowLeft: return 0x007b
            case .arrowRight: return 0x007c
            case .arrowUp: return 0x007e

            // Numpad Section
            case .numLock: return 0x0047
            case .numpad0: return 0x0052
            case .numpad1: return 0x0053
            case .numpad2: return 0x0054
            case .numpad3: return 0x0055
            case .numpad4: return 0x0056
            case .numpad5: return 0x0057
            case .numpad6: return 0x0058
            case .numpad7: return 0x0059
            case .numpad8: return 0x005b
            case .numpad9: return 0x005c
            case .numpadAdd: return 0x0045
            case .numpadBackspace: return nil // No Mac keycode
            case .numpadClear: return nil // No Mac keycode
            case .numpadClearEntry: return nil // No Mac keycode
            case .numpadComma: return 0x005f
            case .numpadDecimal: return 0x0041
            case .numpadDivide: return 0x004b
            case .numpadEnter: return 0x004c
            case .numpadEqual: return 0x0051
            case .numpadMemoryAdd: return nil // No Mac keycode
            case .numpadMemoryClear: return nil // No Mac keycode
            case .numpadMemoryRecall: return nil // No Mac keycode
            case .numpadMemoryStore: return nil // No Mac keycode
            case .numpadMemorySubtract: return nil // No Mac keycode
            case .numpadMultiply: return 0x0043
            case .numpadParenLeft: return nil // No Mac keycode
            case .numpadParenRight: return nil // No Mac keycode
            case .numpadSubtract: return 0x004e
            case .numpadSeparator: return nil // No Mac keycode
            case .numpadUp: return nil // No Mac keycode
            case .numpadDown: return nil // No Mac keycode
            case .numpadRight: return nil // No Mac keycode
            case .numpadLeft: return nil // No Mac keycode
            case .numpadBegin: return nil // No Mac keycode
            case .numpadHome: return nil // No Mac keycode
            case .numpadEnd: return nil // No Mac keycode
            case .numpadInsert: return nil // No Mac keycode
            case .numpadDelete: return nil // No Mac keycode
            case .numpadPageUp: return nil // No Mac keycode
            case .numpadPageDown: return nil // No Mac keycode

            // Function Section
            case .escape: return 0x0035
            case .f1: return 0x007a
            case .f2: return 0x0078
            case .f3: return 0x0063
            case .f4: return 0x0076
            case .f5: return 0x0060
            case .f6: return 0x0061
            case .f7: return 0x0062
            case .f8: return 0x0064
            case .f9: return 0x0065
            case .f10: return 0x006d
            case .f11: return 0x0067
            case .f12: return 0x006f
            case .f13: return 0x0069
            case .f14: return 0x006b
            case .f15: return 0x0071
            case .f16: return 0x006a
            case .f17: return 0x0040
            case .f18: return 0x004f
            case .f19: return 0x0050
            case .f20: return 0x005a
            case .f21: return nil // No Mac keycode
            case .f22: return nil // No Mac keycode
            case .f23: return nil // No Mac keycode
            case .f24: return nil // No Mac keycode
            case .f25: return nil // No Mac keycode
            case .fn: return nil // No Mac keycode
            case .fnLock: return nil // No Mac keycode
            case .printScreen: return nil // No Mac keycode
            case .scrollLock: return nil // No Mac keycode
            case .pause: return nil // No Mac keycode

            // Media Keys
            case .browserBack: return nil // No Mac keycode
            case .browserFavorites: return nil // No Mac keycode
            case .browserForward: return nil // No Mac keycode
            case .browserHome: return nil // No Mac keycode
            case .browserRefresh: return nil // No Mac keycode
            case .browserSearch: return nil // No Mac keycode
            case .browserStop: return nil // No Mac keycode
            case .eject: return nil // No Mac keycode
            case .launchApp1: return nil // No Mac keycode
            case .launchApp2: return nil // No Mac keycode
            case .launchMail: return nil // No Mac keycode
            case .mediaPlayPause: return nil // No Mac keycode
            case .mediaSelect: return nil // No Mac keycode
            case .mediaStop: return nil // No Mac keycode
            case .mediaTrackNext: return nil // No Mac keycode
            case .mediaTrackPrevious: return nil // No Mac keycode
            case .power: return nil // No Mac keycode
            case .sleep: return nil // No Mac keycode
            case .audioVolumeDown: return 0x0049
            case .audioVolumeMute: return 0x004a
            case .audioVolumeUp: return 0x0048
            case .wakeUp: return nil // No Mac keycode

            // Legacy, Non-standard, and Special Keys
            case .copy: return nil // No Mac keycode
            case .cut: return nil // No Mac keycode
            case .paste: return nil // No Mac keycode
            }
        }
    }
}

extension Ghostty.Input.Key: AppEnum {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Key")

    // Only include keys that have Mac keycodes for App Intents
    static var allCases: [Ghostty.Input.Key] {
        return [
            // Letters (A-Z)
            .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m, .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z,
            
            // Numbers (0-9)
            .digit0, .digit1, .digit2, .digit3, .digit4, .digit5, .digit6, .digit7, .digit8, .digit9,
            
            // Common Control Keys
            .space, .enter, .tab, .backspace, .escape, .delete,
            
            // Arrow Keys
            .arrowUp, .arrowDown, .arrowLeft, .arrowRight,
            
            // Navigation Keys
            .home, .end, .pageUp, .pageDown, .insert,
            
            // Function Keys (F1-F20)
            .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12,
            .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20,
            
            // Modifier Keys
            .shiftLeft, .shiftRight, .controlLeft, .controlRight, .altLeft, .altRight,
            .metaLeft, .metaRight, .capsLock,
            
            // Punctuation & Symbols
            .minus, .equal, .backquote, .bracketLeft, .bracketRight, .backslash,
            .semicolon, .quote, .comma, .period, .slash,
            
            // Numpad
            .numLock, .numpad0, .numpad1, .numpad2, .numpad3, .numpad4, .numpad5,
            .numpad6, .numpad7, .numpad8, .numpad9, .numpadAdd, .numpadSubtract,
            .numpadMultiply, .numpadDivide, .numpadDecimal, .numpadEqual,
            .numpadEnter, .numpadComma,
            
            // Media Keys
            .audioVolumeUp, .audioVolumeDown, .audioVolumeMute,
            
            // International Keys
            .intlBackslash, .intlRo, .intlYen,
            
            // Other
            .contextMenu
        ]
    }

    static var caseDisplayRepresentations: [Ghostty.Input.Key : DisplayRepresentation] = [
        // Letters (A-Z)
        .a: "A", .b: "B", .c: "C", .d: "D", .e: "E", .f: "F", .g: "G", .h: "H", .i: "I", .j: "J",
        .k: "K", .l: "L", .m: "M", .n: "N", .o: "O", .p: "P", .q: "Q", .r: "R", .s: "S", .t: "T",
        .u: "U", .v: "V", .w: "W", .x: "X", .y: "Y", .z: "Z",
        
        // Numbers (0-9)
        .digit0: "0", .digit1: "1", .digit2: "2", .digit3: "3", .digit4: "4",
        .digit5: "5", .digit6: "6", .digit7: "7", .digit8: "8", .digit9: "9",
        
        // Common Control Keys
        .space: "Space",
        .enter: "Enter",
        .tab: "Tab",
        .backspace: "Backspace",
        .escape: "Escape",
        .delete: "Delete",
        
        // Arrow Keys
        .arrowUp: "Up Arrow",
        .arrowDown: "Down Arrow",
        .arrowLeft: "Left Arrow",
        .arrowRight: "Right Arrow",
        
        // Navigation Keys
        .home: "Home",
        .end: "End",
        .pageUp: "Page Up",
        .pageDown: "Page Down",
        .insert: "Insert",
        
        // Function Keys (F1-F20)
        .f1: "F1", .f2: "F2", .f3: "F3", .f4: "F4", .f5: "F5", .f6: "F6",
        .f7: "F7", .f8: "F8", .f9: "F9", .f10: "F10", .f11: "F11", .f12: "F12",
        .f13: "F13", .f14: "F14", .f15: "F15", .f16: "F16", .f17: "F17",
        .f18: "F18", .f19: "F19", .f20: "F20",
        
        // Modifier Keys
        .shiftLeft: "Left Shift",
        .shiftRight: "Right Shift",
        .controlLeft: "Left Control",
        .controlRight: "Right Control",
        .altLeft: "Left Alt",
        .altRight: "Right Alt",
        .metaLeft: "Left Command",
        .metaRight: "Right Command",
        .capsLock: "Caps Lock",
        
        // Punctuation & Symbols
        .minus: "Minus (-)",
        .equal: "Equal (=)",
        .backquote: "Backtick (`)",
        .bracketLeft: "Left Bracket ([)",
        .bracketRight: "Right Bracket (])",
        .backslash: "Backslash (\\)",
        .semicolon: "Semicolon (;)",
        .quote: "Quote (')",
        .comma: "Comma (,)",
        .period: "Period (.)",
        .slash: "Slash (/)",
        
        // Numpad
        .numLock: "Num Lock",
        .numpad0: "Numpad 0", .numpad1: "Numpad 1", .numpad2: "Numpad 2",
        .numpad3: "Numpad 3", .numpad4: "Numpad 4", .numpad5: "Numpad 5",
        .numpad6: "Numpad 6", .numpad7: "Numpad 7", .numpad8: "Numpad 8", .numpad9: "Numpad 9",
        .numpadAdd: "Numpad Add (+)",
        .numpadSubtract: "Numpad Subtract (-)",
        .numpadMultiply: "Numpad Multiply (×)",
        .numpadDivide: "Numpad Divide (÷)",
        .numpadDecimal: "Numpad Decimal",
        .numpadEqual: "Numpad Equal",
        .numpadEnter: "Numpad Enter",
        .numpadComma: "Numpad Comma",
        
        // Media Keys
        .audioVolumeUp: "Volume Up",
        .audioVolumeDown: "Volume Down",
        .audioVolumeMute: "Volume Mute",
        
        // International Keys
        .intlBackslash: "International Backslash",
        .intlRo: "International Ro",
        .intlYen: "International Yen",
        
        // Other
        .contextMenu: "Context Menu"
    ]
}
