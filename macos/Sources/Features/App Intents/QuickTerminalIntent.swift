import AppKit
import AppIntents

struct QuickTerminalIntent: AppIntent {
    static var title: LocalizedStringResource = "Open the Quick Terminal"
    static var description = IntentDescription("Open the Quick Terminal. If it is already open, then do nothing.")

    @available(macOS 26.0, *)
    static var supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[TerminalEntity]> {
        guard await requestIntentPermission() else {
            throw GhosttyIntentError.permissionDenied
        }
        
        guard let delegate = NSApp.delegate as? AppDelegate else {
            throw GhosttyIntentError.appUnavailable
        }

        // This is safe to call even if it is already shown.
        let c = delegate.quickController
        c.animateIn()

        // Grab all our terminals
        let terminals = c.surfaceTree.root?.leaves().map {
            TerminalEntity($0)
        } ?? []

        return .result(value: terminals)
    }
}
