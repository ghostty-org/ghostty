import AppKit
import Carbon

class KeyboardLayout {
    /// Return a string ID of the current keyboard input source.
    static var id: String? {
        if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let sourceIdPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            let sourceId = unsafeBitCast(sourceIdPointer, to: CFString.self)
            return sourceId as String
        }

        return nil
    }

    /// Translate a physical keycode for use as a menu key equivalent.
    ///
    /// AppKit retranslates against the current input source without changing its dead key state.
    ///
    /// - Important: Must be called on the main thread because underlying Text Input Sources APIs are not thread-safe.
    @MainActor static func character(
        for keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> Character? {
        guard
            let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: keyCode),
            let result = event.characters(byApplyingModifiers: modifiers),
            result.count == 1
        else { return nil }

        return result.first
    }
}
