import AppKit
import AppIntents

/// App intent that invokes a command palette entry.
@available(macOS 14.0, *)
struct CommandPaletteIntent: AppIntent {
    static var title: LocalizedStringResource = "Invoke Command Palette Action"

    @Parameter(
        title: "Terminal",
        description: "The terminal to base available commands from."
    )
    var terminal: TerminalEntity

    @Parameter(
        title: "Command",
        description: "The command to invoke.",
        optionsProvider: CommandQuery()
    )
    var command: CommandEntity

    @available(macOS 26.0, *)
    static var supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        guard await requestIntentPermission() else {
            throw GhosttyIntentError.permissionDenied
        }
        
        guard let surface = terminal.surfaceModel else {
            throw GhosttyIntentError.surfaceNotFound
        }

        let performed = surface.perform(action: command.action)
        return .result(value: performed)
    }
}
