import AppKit

/// AppleScript-facing wrapper around a single tab in a scripting window.
///
/// `ScriptWindow.tabs` vends these objects so AppleScript can traverse
/// `window -> tab` without knowing anything about AppKit controllers.
@MainActor
@objc(GhosttyScriptTab)
final class ScriptTab: NSObject {
    /// Stable identifier used by AppleScript `tab id "..."` references.
    private let stableID: String

    /// Weak back-reference to the scripting window that owns this tab wrapper.
    ///
    /// We only need this for dynamic properties (`index`, `selected`) and for
    /// building an object specifier path.
    private weak var window: ScriptWindow?

    /// Live terminal controller for this tab.
    ///
    /// This can become `nil` if the tab closes while a script is running.
    private weak var controller: BaseTerminalController?

    /// Called by `ScriptWindow.tabs` / `ScriptWindow.selectedTab`.
    ///
    /// The ID is computed once so object specifiers built from this instance keep
    /// a consistent tab identity.
    init(window: ScriptWindow, controller: BaseTerminalController) {
        self.stableID = Self.stableID(controller: controller)
        self.window = window
        self.controller = controller
    }

    /// Exposed as the AppleScript `id` property.
    @objc(id)
    var idValue: String {
        guard NSApp.isAppleScriptEnabled else { return "" }
        return stableID
    }

    /// Exposed as the AppleScript `title` property.
    ///
    /// Returns the title of the tab's window.
    @objc(title)
    var title: String {
        guard NSApp.isAppleScriptEnabled else { return "" }
        return controller?.window?.title ?? ""
    }

    /// Exposed as the AppleScript `index` property.
    ///
    /// Cocoa scripting expects this to be 1-based for user-facing collections.
    @objc(index)
    var index: Int {
        guard NSApp.isAppleScriptEnabled else { return 0 }
        guard let controller else { return 0 }
        return window?.tabIndex(for: controller) ?? 0
    }

    /// Exposed as the AppleScript `selected` property.
    ///
    /// Powers script conditions such as `if selected of tab 1 then ...`.
    @objc(selected)
    var selected: Bool {
        guard NSApp.isAppleScriptEnabled else { return false }
        guard let controller else { return false }
        return window?.tabIsSelected(controller) ?? false
    }

    /// Exposed as the AppleScript `color` property.
    ///
    /// The value is a `tab color` enumeration constant defined in `Ghostty.sdef`.
    /// Cocoa scripting passes enumerator FourCharCodes as `UInt32` via KVC.
    @objc(color)
    var color: UInt32 {
        get {
            guard NSApp.isAppleScriptEnabled else { return TerminalTabColor.none.appleScriptCode }
            return ((controller?.window as? TerminalWindow)?.tabColor ?? .none).appleScriptCode
        }
        set {
            guard NSApp.isAppleScriptEnabled else { return }
            guard let terminalWindow = controller?.window as? TerminalWindow else { return }
            terminalWindow.tabColor = TerminalTabColor(appleScriptCode: newValue)
        }
    }

    /// Exposed as the AppleScript `focused terminal` property.
    ///
    /// Uses the currently focused surface for this tab.
    @objc(focusedTerminal)
    var focusedTerminal: ScriptTerminal? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        guard let controller else { return nil }
        guard let surface = controller.focusedSurface,
              controller.surfaceTree.contains(surface)
        else { return nil }

        return ScriptTerminal(surfaceView: surface)
    }

    /// Best-effort native window containing this tab.
    var parentWindow: NSWindow? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        return controller?.window
    }

    /// Live controller backing this tab wrapper.
    var parentController: BaseTerminalController? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        return controller
    }

    /// Exposed as the AppleScript `terminals` element on a tab.
    ///
    /// Returns all terminal surfaces (split panes) within this tab.
    @objc(terminals)
    var terminals: [ScriptTerminal] {
        guard NSApp.isAppleScriptEnabled else { return [] }
        guard let controller else { return [] }
        return (controller.surfaceTree.root?.leaves() ?? [])
            .map(ScriptTerminal.init)
    }

    /// Enables unique-ID lookup for `terminals` references on a tab.
    @objc(valueInTerminalsWithUniqueID:)
    func valueInTerminals(uniqueID: String) -> ScriptTerminal? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        guard let controller else { return nil }
        return (controller.surfaceTree.root?.leaves() ?? [])
            .first(where: { $0.id.uuidString == uniqueID })
            .map(ScriptTerminal.init)
    }

    /// Handler for `select tab <tab>`.
    @objc(handleSelectTabCommand:)
    func handleSelectTab(_ command: NSScriptCommand) -> Any? {
        guard NSApp.validateScript(command: command) else { return nil }

        guard let tabContainerWindow = parentWindow else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Tab is no longer available."
            return nil
        }

        tabContainerWindow.makeKeyAndOrderFront(nil)
        return nil
    }

    /// Handler for `close tab <tab>`.
    @objc(handleCloseTabCommand:)
    func handleCloseTab(_ command: NSScriptCommand) -> Any? {
        guard NSApp.validateScript(command: command) else { return nil }

        guard let tabController = parentController else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Tab is no longer available."
            return nil
        }

        if let managedTerminalController = tabController as? TerminalController {
            managedTerminalController.closeTabImmediately(registerRedo: false)
            return nil
        }

        guard let tabContainerWindow = parentWindow else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Tab container window is no longer available."
            return nil
        }

        tabContainerWindow.close()
        return nil
    }

    /// Provides Cocoa scripting with a canonical "path" back to this object.
    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        guard let window else { return nil }
        guard let windowClassDescription = window.classDescription as? NSScriptClassDescription else {
            return nil
        }
        guard let windowSpecifier = window.objectSpecifier else { return nil }

        // This tells Cocoa how to re-find this tab later:
        // application -> scriptWindows[id] -> tabs[id].
        return NSUniqueIDSpecifier(
            containerClassDescription: windowClassDescription,
            containerSpecifier: windowSpecifier,
            key: "tabs",
            uniqueID: stableID
        )
    }
}

extension ScriptTab {
    /// Stable ID for one tab controller.
    ///
    /// Tab identity belongs to `ScriptTab`, so both tab creation and tab ID
    /// lookups in `ScriptWindow` call this helper.
    static func stableID(controller: BaseTerminalController) -> String {
        "tab-\(ObjectIdentifier(controller).hexString)"
    }
}

/// Maps `TerminalTabColor` to and from the `tab color` enumeration in `Ghostty.sdef`.
/// See `Ghostty.sdef` for how the codes are derived.
private extension TerminalTabColor {
    var appleScriptCode: UInt32 {
        switch self {
        case .none:     "none".fourCharCode
        case .blue:     "08FF".fourCharCode
        case .purple:   "C3DF".fourCharCode
        case .pink:     "F35F".fourCharCode
        case .red:      "F34F".fourCharCode
        case .orange:   "F82F".fourCharCode
        case .yellow:   "FC0F".fourCharCode
        case .green:    "3C5F".fourCharCode
        case .teal:     "0CBF".fourCharCode
        case .graphite: "889F".fourCharCode
        }
    }

    init(appleScriptCode: UInt32) {
        self = Self.allCases.first(where: { $0.appleScriptCode == appleScriptCode }) ?? .none
    }
}
