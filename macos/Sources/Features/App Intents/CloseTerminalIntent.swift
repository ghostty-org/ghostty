import AppKit
import AppIntents
import GhosttyKit

struct CloseTerminalIntent: AppIntent {
    static var title: LocalizedStringResource = "Close Terminal"
    static var description = IntentDescription("Close an existing terminal.")

    @Parameter(
        title: "Terminal",
        description: "The terminal to close.",
    )
    var terminal: TerminalEntity

#if compiler(>=6.2)
    @available(macOS 26.0, *)
    static var supportedModes: IntentModes = .background
#endif

    @MainActor
    func perform() async throws -> some IntentResult {
        guard await requestIntentPermission() else {
            throw GhosttyIntentError.permissionDenied
        }
        
        guard let surfaceView = terminal.surfaceView else {
            throw GhosttyIntentError.surfaceNotFound
        }

        guard let controller = surfaceView.window?.windowController as? BaseTerminalController else {
            return .result()
        }

        controller.closeSurface(surfaceView, withConfirmation: false)
        return .result()
    }
}
