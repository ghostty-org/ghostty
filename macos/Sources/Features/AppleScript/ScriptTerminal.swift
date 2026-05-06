import AppKit

/// AppleScript-facing wrapper around a live Ghostty terminal surface.
///
/// This class is intentionally ObjC-visible because Cocoa scripting resolves
/// AppleScript objects through Objective-C runtime names/selectors, not Swift
/// protocol conformance.
///
/// Mapping from `Ghostty.sdef`:
/// - `class terminal` -> this class (`@objc(GhosttyAppleScriptTerminal)`).
/// - `property id` -> `@objc(id)` getter below.
/// - `property title` -> `@objc(title)` getter below.
/// - `property working directory` -> `@objc(workingDirectory)` getter below.
/// - `property pid` -> `@objc(pid)` getter below.
/// - `property tty` -> `@objc(tty)` getter below.
///
/// We keep only a weak reference to the underlying `SurfaceView` so this
/// wrapper never extends the terminal's lifetime.
@MainActor
@objc(GhosttyScriptTerminal)
final class ScriptTerminal: NSObject {
    /// Weak reference to the underlying surface. Package-visible so that
    /// other AppleScript command handlers (e.g. `ScriptSplitCommand`) can
    /// access the live surface without exposing it to ObjC/AppleScript.
    weak var surfaceView: Ghostty.SurfaceView?

    init(surfaceView: Ghostty.SurfaceView) {
        self.surfaceView = surfaceView
    }

    /// Exposed as the AppleScript `id` property.
    ///
    /// This is a stable UUID string for the life of a surface and is also used
    /// by `NSUniqueIDSpecifier` to re-identify a terminal object in scripts.
    @objc(id)
    var stableID: String {
        guard NSApp.isAppleScriptEnabled else { return "" }
        return surfaceView?.id.uuidString ?? ""
    }

    /// Exposed as the AppleScript `title` property.
    @objc(title)
    var title: String {
        guard NSApp.isAppleScriptEnabled else { return "" }
        return surfaceView?.title ?? ""
    }

    /// Exposed as the AppleScript `working directory` property.
    ///
    /// The `sdef` uses a spaced name, but Cocoa scripting maps that to the
    /// camel-cased selector name `workingDirectory`.
    @objc(workingDirectory)
    var workingDirectory: String {
        guard NSApp.isAppleScriptEnabled else { return "" }
        return surfaceView?.pwd ?? ""
    }

    /// Exposed as the AppleScript `pid` property.
    @objc(pid)
    var pid: Int {
        guard NSApp.isAppleScriptEnabled else { return 0 }
        return surfaceView?.surfaceModel?.foregroundPID ?? 0
    }

    /// Exposed as the AppleScript `tty` property.
    @objc(tty)
    var tty: String {
        guard NSApp.isAppleScriptEnabled else { return "" }
        return surfaceView?.surfaceModel?.ttyName ?? ""
    }

    /// Used by command handling (`perform action ... on <terminal>`).
    func perform(action: String) -> Bool {
        guard NSApp.isAppleScriptEnabled else { return false }
        guard let surfaceModel = surfaceView?.surfaceModel else { return false }
        return surfaceModel.perform(action: action)
    }

    /// Handler for `split <terminal> direction <dir>`.
    @objc(handleSplitCommand:)
    func handleSplit(_ command: NSScriptCommand) -> Any? {
        guard NSApp.validateScript(command: command) else { return nil }

        guard let surfaceView else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Terminal surface is no longer available."
            return nil
        }

        guard let directionCode = command.evaluatedArguments?["direction"] as? UInt32 else {
            command.scriptErrorNumber = errAEParamMissed
            command.scriptErrorString = "Missing or unknown split direction."
            return nil
        }

        guard let direction = ScriptSplitDirection(code: directionCode)?.splitDirection else {
            command.scriptErrorNumber = errAEParamMissed
            command.scriptErrorString = "Missing or unknown split direction."
            return nil
        }

        let baseConfig: Ghostty.SurfaceConfiguration?
        if let scriptRecord = command.evaluatedArguments?["configuration"] as? NSDictionary {
            do {
                baseConfig = try Ghostty.SurfaceConfiguration(scriptRecord: scriptRecord)
            } catch {
                command.scriptErrorNumber = errAECoercionFail
                command.scriptErrorString = error.localizedDescription
                return nil
            }
        } else {
            baseConfig = nil
        }

        guard let controller = surfaceView.window?.windowController as? BaseTerminalController else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Terminal is not in a splittable window."
            return nil
        }

        guard let newView = controller.newSplit(
            at: surfaceView,
            direction: direction,
            baseConfig: baseConfig
        ) else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Failed to create split."
            return nil
        }

        return ScriptTerminal(surfaceView: newView)
    }

    /// Handler for `focus <terminal>`.
    @objc(handleFocusCommand:)
    func handleFocus(_ command: NSScriptCommand) -> Any? {
        guard NSApp.validateScript(command: command) else { return nil }

        guard let surfaceView else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Terminal surface is no longer available."
            return nil
        }

        guard let controller = surfaceView.window?.windowController as? BaseTerminalController else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Terminal is not in a window."
            return nil
        }

        controller.focusSurface(surfaceView)
        return nil
    }

    /// Handler for `close <terminal>`.
    @objc(handleCloseCommand:)
    func handleClose(_ command: NSScriptCommand) -> Any? {
        guard NSApp.validateScript(command: command) else { return nil }

        guard let surfaceView else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Terminal surface is no longer available."
            return nil
        }

        guard let controller = surfaceView.window?.windowController as? BaseTerminalController else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Terminal is not in a window."
            return nil
        }

        controller.closeSurface(surfaceView, withConfirmation: false)
        return nil
    }

    /// Provides Cocoa scripting with a canonical "path" back to this object.
    ///
    /// Without an object specifier, returned terminal objects can't be reliably
    /// referenced in follow-up script statements because AppleScript cannot
    /// express where the object came from (`application.terminals[id]`).
    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        guard let appClassDescription = NSApplication.shared.classDescription as? NSScriptClassDescription else {
            return nil
        }

        return NSUniqueIDSpecifier(
            containerClassDescription: appClassDescription,
            containerSpecifier: nil,
            key: "terminals",
            uniqueID: stableID
        )
    }
}

/// Converts four-character codes from the `split direction` enumeration in `Ghostty.sdef`
/// to `SplitTree.NewDirection` values.
enum ScriptSplitDirection {
    case right
    case left
    case down
    case up

    init?(code: UInt32) {
        switch code {
        case "GSrt".fourCharCode: self = .right
        case "GSlf".fourCharCode: self = .left
        case "GSdn".fourCharCode: self = .down
        case "GSup".fourCharCode: self = .up
        default: return nil
        }
    }

    var splitDirection: SplitTree<Ghostty.SurfaceView>.NewDirection {
        switch self {
        case .right: .right
        case .left: .left
        case .down: .down
        case .up: .up
        }
    }
}
