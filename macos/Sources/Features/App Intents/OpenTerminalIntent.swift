import AppKit
import AppIntents

/// Opens a terminal selected from Spotlight or Siri.
#if compiler(>=6.3)
@available(macOS 27.0, *)
@AppIntent(schema: .system.open)
#endif
struct OpenTerminalIntent: OpenIntent {
    static var title: LocalizedStringResource = "Open Terminal"
    static var description = IntentDescription("Open an existing terminal.")

    @Parameter(
        title: "Terminal",
        description: "The terminal to open."
    )
    var target: TerminalEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        guard await requestIntentPermission() else {
            throw GhosttyIntentError.permissionDenied
        }

        guard let surfaceView = target.surfaceView else {
            throw GhosttyIntentError.surfaceNotFound
        }

        guard let controller = BaseTerminalController.controller(owning: surfaceView) else {
            throw GhosttyIntentError.appUnavailable
        }

        controller.focusSurface(surfaceView)
        return .result()
    }
}
