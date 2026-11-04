import AppKit

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

        let keyEvent: Ghostty.Input.KeyEvent
        do {
            keyEvent = try Self.parse(
                directParameter: directParameter,
                evaluatedArguments: evaluatedArguments,
                translationMods: surface.keyTranslationMods,
            )
        } catch ArgumentError.missingKey {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = "Missing key name."
            return nil
        } catch let ArgumentError.unknownKey(keyName) {
            scriptErrorNumber = errAECoercionFail
            scriptErrorString = "Unknown key name: \(keyName)"
            return nil
        } catch let ArgumentError.unknownModifiers(modsString) {
            scriptErrorNumber = errAECoercionFail
            scriptErrorString = "Unknown modifier in: \(modsString)"
            return nil
        } catch {
            scriptErrorNumber = errAEEventFailed
            scriptErrorString = "Invalid key event."
            return nil
        }

        surface.sendKeyEvent(keyEvent)

        return nil
    }
}

extension ScriptKeyEventCommand {
    enum ArgumentError: Error, Equatable {
        case missingKey
        case unknownKey(String)
        case unknownModifiers(String)
    }

    /// Parse the scripting arguments for `send key` into the key event to
    /// deliver to the surface.
    ///
    /// - Parameters:
    ///   - directParameter: The command's direct parameter (the key name).
    ///   - evaluatedArguments: The command's evaluated arguments.
    ///   - translationMods: Maps the event's modifiers to the subset that
    ///     participates in text translation for the target surface.
    static func parse(
        directParameter: Any?,
        evaluatedArguments: [String: Any]?,
        translationMods: (Ghostty.Input.Mods) -> Ghostty.Input.Mods = { $0 },
    ) throws -> Ghostty.Input.KeyEvent {
        guard let keyName = directParameter as? String else {
            throw ArgumentError.missingKey
        }

        guard let key = Ghostty.Input.Key(rawValue: keyName) else {
            throw ArgumentError.unknownKey(keyName)
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
                throw ArgumentError.unknownModifiers(modsString)
            }
            mods = parsed
        } else {
            mods = []
        }

        return Ghostty.Input.KeyEvent(
            synthesizing: key,
            action: action,
            mods: mods,
            translationMods: translationMods(mods),
        )
    }
}
