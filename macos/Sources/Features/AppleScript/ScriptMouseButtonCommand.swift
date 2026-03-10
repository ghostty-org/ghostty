import AppKit

/// Handler for the `send mouse button` AppleScript command defined in `Ghostty.sdef`.
///
/// Cocoa scripting instantiates this class because the command's `<cocoa>` element
/// specifies `class="GhosttyScriptMouseButtonCommand"`. The runtime calls
/// `performDefaultImplementation()` to execute the command.
@MainActor
@objc(GhosttyScriptMouseButtonCommand)
final class ScriptMouseButtonCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard NSApp.validateScript(command: self) else { return nil }

        guard let buttonCode = directParameter as? UInt32,
              let button = ScriptMouseButtonValue(code: buttonCode) else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = "Missing or unknown mouse button."
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

        let action: Ghostty.Input.MouseState
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

        let mouseEvent = Ghostty.Input.MouseButtonEvent(
            action: action,
            button: button.ghosttyButton,
            mods: mods
        )
        surface.sendMouseButton(mouseEvent)

        return nil
    }
}

/// Four-character codes matching the `mouse button` enumeration in `Ghostty.sdef`.
private enum ScriptMouseButtonValue {
    case left
    case right
    case middle

    init?(code: UInt32) {
        switch code {
        case "GMlf".fourCharCode: self = .left
        case "GMrt".fourCharCode: self = .right
        case "GMmd".fourCharCode: self = .middle
        default: return nil
        }
    }

    var ghosttyButton: Ghostty.Input.MouseButton {
        switch self {
        case .left: .left
        case .right: .right
        case .middle: .middle
        }
    }
}
