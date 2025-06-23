import AppKit
import AppIntents
import GhosttyKit

/// App intent that allows creating a new terminal window or tab.
///
/// This requires macOS 15 or greater because we use features of macOS 15 here.
@available(macOS 15.0, *)
struct NewTerminalIntent: AppIntent {
    static var title: LocalizedStringResource = "New Terminal"
    static var description = IntentDescription("Create a new terminal.")

    @Parameter(
        title: "Location",
        description: "The location that the terminal should be created.",
        default: .window
    )
    var location: NewTerminalLocation

    @Parameter(
        title: "Command",
        description: "Command to execute within your configured shell.",
    )
    var command: String?

    @Parameter(
        title: "Working Directory",
        description: "The working directory to open in the terminal.",
        supportedContentTypes: [.folder]
    )
    var workingDirectory: IntentFile?

    @Parameter(
        title: "Environment Variables",
        description: "Environment variables in `KEY=VALUE` format.",
        default: []
    )
    var env: [String]

    @Parameter(
        title: "Parent Terminal",
        description: "The terminal to inherit the base configuration from."
    )
    var parent: TerminalEntity?

    @available(macOS 26.0, *)
    static var supportedModes: IntentModes = .foreground(.immediate)

    @available(macOS, obsoleted: 26.0, message: "Replaced by supportedModes")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<TerminalEntity?> {
        guard await requestIntentPermission() else {
            throw GhosttyIntentError.permissionDenied
        }
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            throw GhosttyIntentError.appUnavailable
        }
        let ghostty = appDelegate.ghostty

        var config = Ghostty.SurfaceConfiguration()

        // We don't run command as "command" and instead use "initialInput" so
        // that we can get all the login scripts to setup things like PATH.
        if let command {
            config.initialInput = "\(command); exit\n"
        }

        // If we were given a working directory then open that directory
        if let url = workingDirectory?.fileURL {
            let dir = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
            config.workingDirectory = dir.path(percentEncoded: false)
        }

        // Parse environment variables from KEY=VALUE format
        for envVar in env {
            if let separatorIndex = envVar.firstIndex(of: "=") {
                let key = String(envVar[..<separatorIndex])
                let value = String(envVar[envVar.index(after: separatorIndex)...])
                config.environmentVariables[key] = value
            }
        }

        // Determine if we have a parent and get it
        let parent: Ghostty.SurfaceView?
        if let parentParam = self.parent {
            guard let view = parentParam.surfaceView else {
                throw GhosttyIntentError.surfaceNotFound
            }

            parent = view
        } else if let preferred = TerminalController.preferredParent {
            parent = preferred.focusedSurface ?? preferred.surfaceTree.root?.leftmostLeaf()
        } else {
            parent = nil
        }

        switch location {
        case .window:
            let newController = TerminalController.newWindow(
                ghostty,
                withBaseConfig: config,
                withParent: parent?.window)
            if let view = newController.surfaceTree.root?.leftmostLeaf() {
                return .result(value: TerminalEntity(view))
            }

        case .tab:
            let newController = TerminalController.newTab(
                ghostty,
                from: parent?.window,
                withBaseConfig: config)
            if let view = newController?.surfaceTree.root?.leftmostLeaf() {
                return .result(value: TerminalEntity(view))
            }

        case .splitLeft, .splitRight, .splitUp, .splitDown:
            guard let parent,
                  let controller = parent.window?.windowController as? BaseTerminalController else {
                throw GhosttyIntentError.surfaceNotFound
            }

            if let view = controller.newSplit(
                at: parent,
                direction: location.splitDirection!
            ) {
                return .result(value: TerminalEntity(view))
            }
        }

        return .result(value: .none)
    }
}

// MARK: NewTerminalLocation

enum NewTerminalLocation: String {
    case tab
    case window
    case splitLeft = "split:left"
    case splitRight = "split:right"
    case splitUp = "split:up"
    case splitDown = "split:down"
    
    var splitDirection: SplitTree<Ghostty.SurfaceView>.NewDirection? {
        switch self {
        case .splitLeft: return .left
        case .splitRight: return .right
        case .splitUp: return .up
        case .splitDown: return .down
        default: return nil
        }
    }
}

extension NewTerminalLocation: AppEnum {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Terminal Location")

    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .tab: .init(title: "Tab"),
        .window: .init(title: "Window"),
        .splitLeft: .init(title: "Split Left"),
        .splitRight: .init(title: "Split Right"),
        .splitUp: .init(title: "Split Up"),
        .splitDown: .init(title: "Split Down"),
    ]
}
