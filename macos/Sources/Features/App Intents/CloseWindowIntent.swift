import AppKit
import AppIntents
import GhosttyKit

struct CloseWindowIntent: AppIntent {
    static var title: LocalizedStringResource = "Close Terminal Window"
    static var description = IntentDescription("Close the window containing an existing terminal.")

    @Parameter(
        title: "Terminal",
        description: "The terminal whose window should be closed.",
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

        guard let controller = surfaceView.window?.windowController as? TerminalController else {
            return .result()
        }

        controller.closeWindowImmediately()
        return .result()
    }
}
