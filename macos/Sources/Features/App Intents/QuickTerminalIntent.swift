import AppKit
import AppIntents

struct QuickTerminalIntent: AppIntent {
    static var title: LocalizedStringResource = "Open the Quick Terminal"
    static var description = IntentDescription("Open the Quick Terminal. If it is already open, then do nothing.")

#if compiler(>=6.2)
    @available(macOS 26.0, *)
    static var supportedModes: IntentModes = .background
#endif

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[TerminalEntity]> {
        guard await requestIntentPermission() else {
            throw GhosttyIntentError.permissionDenied
        }

        guard let delegate = NSApp.delegate as? AppDelegate else {
            throw GhosttyIntentError.appUnavailable
        }

        // Show through PopupManager exclusively.
        delegate.popupManager.show(PopupManager.quickProfileName)

        // Grab all our terminals from the popup controller.
        let terminals = delegate.popupManager.controllers[PopupManager.quickProfileName]?.surfaceTree.root?.leaves().map {
            TerminalEntity($0)
        } ?? []

        return .result(value: terminals)
    }
}
