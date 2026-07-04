import AppKit
import Carbon

/// Handler for the `send key` AppleScript command defined in `Ghostty.sdef`.
///
/// Cocoa scripting instantiates this class because the command's `<cocoa>` element
/// specifies `class="GhosttyScriptKeyEventCommand"`. The runtime calls
/// `performDefaultImplementation()` to execute the command.
@MainActor
@objc(GhosttyScriptKeyEventCommand)
final class ScriptKeyEventCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard NSApp.validateScript(command: self) else { return nil }

        guard let keyName = directParameter as? String else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = "Missing key name."
            return nil
        }

        guard let terminal = evaluatedArguments?["terminal"] as? ScriptTerminal else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = "Missing terminal target."
            return nil
        }

        guard let surfaceView = terminal.surfaceView else {
            scriptErrorNumber = errAEEventFailed
            scriptErrorString = "Terminal surface is no longer available."
            return nil
        }

        guard let surface = surfaceView.surfaceModel else {
            scriptErrorNumber = errAEEventFailed
            scriptErrorString = "Terminal surface model is not available."
            return nil
        }

        guard let key = Ghostty.Input.Key(rawValue: keyName) else {
            scriptErrorNumber = errAECoercionFail
            scriptErrorString = "Unknown key name: \(keyName)"
            return nil
        }

        let action: Ghostty.Input.Action
        if let actionCode = evaluatedArguments?["action"] as? UInt32 {
            switch actionCode {
            case "GIpr".fourCharCode: action = .press
            case "GIrl".fourCharCode: action = .release
            default: action = .press
            }
        } else {
            action = .press
        }

        let mods: Ghostty.Input.Mods
        if let modsString = evaluatedArguments?["modifiers"] as? String {
            guard let parsed = Ghostty.Input.Mods(scriptModifiers: modsString) else {
                scriptErrorNumber = errAECoercionFail
                scriptErrorString = "Unknown modifier in: \(modsString)"
                return nil
            }
            mods = parsed
        } else {
            mods = []
        }

        // derive text and unshifted codepoint via `UCKeyTranslate`
        let (text, unshiftedCodepoint) = ScriptKeyEventTranslator.translate(key: key, mods: mods)

        let keyEvent = Ghostty.Input.KeyEvent(
            key: key,
            action: action,
            text: text,
            mods: mods,
            unshiftedCodepoint: unshiftedCodepoint
        )

        surface.sendKeyEvent(keyEvent)

        return nil
    }
}

/// extracted translation logic to map a Ghostty key to its generated text and unshifted codepoint,
/// primarily so it can be unit-tested without instantiating an `NSScriptCommand`.
struct ScriptKeyEventTranslator {
    static func translate(key: Ghostty.Input.Key, mods: Ghostty.Input.Mods) -> (text: String?, unshiftedCodepoint: UInt32) {
        let text: String?
        let unshiftedCodepoint: UInt32

        if let keyCode = key.keyCode {
            let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
            let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            let layoutPtr = unsafeBitCast(layoutData, to: CFData.self)
            let keyboardLayout = unsafeBitCast(CFDataGetBytePtr(layoutPtr), to: UnsafePointer<UCKeyboardLayout>.self)

            var deadKeyState: UInt32 = 0
            var unicodeLength = 0
            var unicodeBuffer = [UniChar](repeating: 0, count: 4)

            let shiftedModifiers = mods.contains(.shift) ? UInt32(shiftKey >> 8) : 0
            let kbdType = UInt32(LMGetKbdType())

            // source terminal already resolved any dead keys; bypass dead-key state entirely.
            let noDeadKeys = OptionBits(kUCKeyTranslateNoDeadKeysBit)

            UCKeyTranslate(
                keyboardLayout, UInt16(keyCode),
                UInt16(kUCKeyActionDown), shiftedModifiers,
                kbdType, noDeadKeys,
                &deadKeyState, 4, &unicodeLength, &unicodeBuffer)
            text = unicodeLength > 0 ? String(utf16CodeUnits: unicodeBuffer, count: unicodeLength) : nil

            deadKeyState = 0
            UCKeyTranslate(
                keyboardLayout, UInt16(keyCode),
                UInt16(kUCKeyActionDown), 0,
                kbdType, noDeadKeys,
                &deadKeyState, 4, &unicodeLength, &unicodeBuffer)
            let unshiftedChar = unicodeLength > 0 ? String(utf16CodeUnits: unicodeBuffer, count: unicodeLength) : nil

            unshiftedCodepoint = unshiftedChar?.unicodeScalars.first?.value ?? 0
        } else {
            text = nil
            unshiftedCodepoint = 0
        }

        return (text, unshiftedCodepoint)
    }
}
