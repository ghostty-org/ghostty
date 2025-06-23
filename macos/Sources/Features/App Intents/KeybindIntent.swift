import AppKit
import AppIntents

struct KeybindIntent: AppIntent {
    static var title: LocalizedStringResource = "Invoke a Keybind Action"

    @Parameter(
        title: "Terminal",
        description: "The terminal to invoke the action on."
    )
    var terminal: TerminalEntity

    @Parameter(
        title: "Action",
        description: "The keybind action to invoke. This can be any valid keybind action you could put in a configuration file."
    )
    var action: String

    @available(macOS 26.0, *)
    static var supportedModes: IntentModes = [.background, .foreground]

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        guard await requestIntentPermission() else {
            throw GhosttyIntentError.permissionDenied
        }
        
        guard let surface = terminal.surfaceModel else {
            throw GhosttyIntentError.surfaceNotFound
        }

        let performed = surface.perform(action: action)
        return .result(value: performed)
    }
}
