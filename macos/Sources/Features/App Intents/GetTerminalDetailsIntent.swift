import AppKit
import AppIntents

/// App intent that retrieves details about a specific terminal.
struct GetTerminalDetailsIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Details of Terminal"

    @Parameter(
        title: "Detail",
        description: "The detail to extract about a terminal."
    )
    var detail: TerminalDetail

    @Parameter(
        title: "Terminal",
        description: "The terminal to extract information about."
    )
    var terminal: TerminalEntity

    @available(macOS 26.0, *)
    static var supportedModes: IntentModes = .background

    static var parameterSummary: some ParameterSummary {
        Summary("Get \(\.$detail) from \(\.$terminal)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String?> {
        guard await requestIntentPermission() else {
            throw GhosttyIntentError.permissionDenied
        }
        
        switch detail {
        case .title: return .result(value: terminal.title)
        case .workingDirectory: return .result(value: terminal.workingDirectory)
        case .allContents:
            guard let view = terminal.surfaceView else { throw GhosttyIntentError.surfaceNotFound }
            return .result(value: view.cachedScreenContents.get())
        case .selectedText:
            guard let view = terminal.surfaceView else { throw GhosttyIntentError.surfaceNotFound }
            return .result(value: view.accessibilitySelectedText())
        case .visibleText:
            guard let view = terminal.surfaceView else { throw GhosttyIntentError.surfaceNotFound }
            return .result(value: view.cachedVisibleContents.get())
        }
    }
}

// MARK: TerminalDetail

enum TerminalDetail: String {
    case title
    case workingDirectory
    case allContents
    case selectedText
    case visibleText
}

extension TerminalDetail: AppEnum {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Terminal Detail")

    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .title: .init(title: "Title"),
        .workingDirectory: .init(title: "Working Directory"),
        .allContents: .init(title: "Full Contents"),
        .selectedText: .init(title: "Selected Text"),
        .visibleText: .init(title: "Visible Text"),
    ]
}
