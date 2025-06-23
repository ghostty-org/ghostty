import AppKit
import AppIntents

/// App intent to input text in a terminal.
struct InputTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Input Text to Terminal"

    @Parameter(
        title: "Text",
        description: "The text to input to the terminal. The text will be inputted as if it was pasted.",
        inputOptions: String.IntentInputOptions(
            capitalizationType: .none,
            multiline: true,
            autocorrect: false,
            smartQuotes: false,
            smartDashes: false
        )
    )
    var text: String

    @Parameter(
        title: "Terminal",
        description: "The terminal to scope this action to."
    )
    var terminal: TerminalEntity

    @available(macOS 26.0, *)
    static var supportedModes: IntentModes = [.background, .foreground]

    @MainActor
    func perform() async throws -> some IntentResult {
        guard await requestIntentPermission() else {
            throw GhosttyIntentError.permissionDenied
        }
        
        guard let surface = terminal.surfaceModel else {
            throw GhosttyIntentError.surfaceNotFound
        }

        surface.sendText(text)
        return .result()
    }
}

/// App intent to trigger a keyboard event.
struct KeyEventIntent: AppIntent {
    static var title: LocalizedStringResource = "Send Keyboard Event to Terminal"
    static var description = IntentDescription("Simulate a keyboard event. This will not handle text encoding; use the 'Input Text' action for that.")

    @Parameter(
        title: "Key",
        description: "The key to send to the terminal.",
        default: .enter
    )
    var key: Ghostty.Input.Key

    @Parameter(
        title: "Modifier(s)",
        description: "The modifiers to send with the key event.",
        default: []
    )
    var mods: [KeyEventMods]

    @Parameter(
        title: "Event Type",
        description: "A key press or release.",
        default: .press
    )
    var action: Ghostty.Input.Action

    @Parameter(
        title: "Terminal",
        description: "The terminal to scope this action to."
    )
    var terminal: TerminalEntity

    @available(macOS 26.0, *)
    static var supportedModes: IntentModes = [.background, .foreground]

    @MainActor
    func perform() async throws -> some IntentResult {
        guard await requestIntentPermission() else {
            throw GhosttyIntentError.permissionDenied
        }
        
        guard let surface = terminal.surfaceModel else {
            throw GhosttyIntentError.surfaceNotFound
        }

        // Convert KeyEventMods array to Ghostty.Input.Mods
        let ghosttyMods = mods.reduce(Ghostty.Input.Mods()) { result, mod in
            result.union(mod.ghosttyMod)
        }
        
        let keyEvent = Ghostty.Input.KeyEvent(
            key: key,
            action: action,
            mods: ghosttyMods
        )
        surface.sendKeyEvent(keyEvent)

        return .result()
    }
}

// MARK: MouseButtonIntent

/// App intent to trigger a mouse button event.
struct MouseButtonIntent: AppIntent {
    static var title: LocalizedStringResource = "Send Mouse Button Event to Terminal"

    @Parameter(
        title: "Button",
        description: "The mouse button to press or release.",
        default: .left
    )
    var button: Ghostty.Input.MouseButton

    @Parameter(
        title: "Action",
        description: "Whether to press or release the button.",
        default: .press
    )
    var action: Ghostty.Input.MouseState

    @Parameter(
        title: "Modifier(s)",
        description: "The modifiers to send with the mouse event.",
        default: []
    )
    var mods: [KeyEventMods]

    @Parameter(
        title: "Terminal",
        description: "The terminal to scope this action to."
    )
    var terminal: TerminalEntity

    @available(macOS 26.0, *)
    static var supportedModes: IntentModes = [.background, .foreground]

    @MainActor
    func perform() async throws -> some IntentResult {
        guard await requestIntentPermission() else {
            throw GhosttyIntentError.permissionDenied
        }
        
        guard let surface = terminal.surfaceModel else {
            throw GhosttyIntentError.surfaceNotFound
        }

        // Convert KeyEventMods array to Ghostty.Input.Mods
        let ghosttyMods = mods.reduce(Ghostty.Input.Mods()) { result, mod in
            result.union(mod.ghosttyMod)
        }
        
        let mouseEvent = Ghostty.Input.MouseButtonEvent(
            action: action,
            button: button,
            mods: ghosttyMods
        )
        surface.sendMouseButton(mouseEvent)

        return .result()
    }
}

/// App intent to send a mouse position event.
struct MousePosIntent: AppIntent {
    static var title: LocalizedStringResource = "Send Mouse Position Event to Terminal"
    static var description = IntentDescription("Send a mouse position event to the terminal. This reports the cursor position for mouse tracking.")

    @Parameter(
        title: "X Position",
        description: "The horizontal position of the mouse cursor in pixels.",
        default: 0
    )
    var x: Double

    @Parameter(
        title: "Y Position", 
        description: "The vertical position of the mouse cursor in pixels.",
        default: 0
    )
    var y: Double

    @Parameter(
        title: "Modifier(s)",
        description: "The modifiers to send with the mouse position event.",
        default: []
    )
    var mods: [KeyEventMods]

    @Parameter(
        title: "Terminal",
        description: "The terminal to scope this action to."
    )
    var terminal: TerminalEntity

    @available(macOS 26.0, *)
    static var supportedModes: IntentModes = [.background, .foreground]

    @MainActor
    func perform() async throws -> some IntentResult {
        guard await requestIntentPermission() else {
            throw GhosttyIntentError.permissionDenied
        }
        
        guard let surface = terminal.surfaceModel else {
            throw GhosttyIntentError.surfaceNotFound
        }

        // Convert KeyEventMods array to Ghostty.Input.Mods
        let ghosttyMods = mods.reduce(Ghostty.Input.Mods()) { result, mod in
            result.union(mod.ghosttyMod)
        }
        
        let mousePosEvent = Ghostty.Input.MousePosEvent(
            x: x,
            y: y,
            mods: ghosttyMods
        )
        surface.sendMousePos(mousePosEvent)

        return .result()
    }
}

/// App intent to send a mouse scroll event.
struct MouseScrollIntent: AppIntent {
    static var title: LocalizedStringResource = "Send Mouse Scroll Event to Terminal"
    static var description = IntentDescription("Send a mouse scroll event to the terminal with configurable precision and momentum.")

    @Parameter(
        title: "X Scroll Delta",
        description: "The horizontal scroll amount.",
        default: 0
    )
    var x: Double

    @Parameter(
        title: "Y Scroll Delta",
        description: "The vertical scroll amount.",
        default: 0
    )
    var y: Double

    @Parameter(
        title: "High Precision",
        description: "Whether this is a high-precision scroll event (e.g., from trackpad).",
        default: false
    )
    var precision: Bool

    @Parameter(
        title: "Momentum Phase",
        description: "The momentum phase for inertial scrolling.",
        default: Ghostty.Input.Momentum.none
    )
    var momentum: Ghostty.Input.Momentum

    @Parameter(
        title: "Terminal",
        description: "The terminal to scope this action to."
    )
    var terminal: TerminalEntity

    @available(macOS 26.0, *)
    static var supportedModes: IntentModes = [.background, .foreground]

    @MainActor
    func perform() async throws -> some IntentResult {
        guard await requestIntentPermission() else {
            throw GhosttyIntentError.permissionDenied
        }
        
        guard let surface = terminal.surfaceModel else {
            throw GhosttyIntentError.surfaceNotFound
        }

        let scrollEvent = Ghostty.Input.MouseScrollEvent(
            x: x,
            y: y,
            mods: .init(precision: precision, momentum: momentum)
        )
        surface.sendMouseScroll(scrollEvent)

        return .result()
    }
}

// MARK: Mods

enum KeyEventMods: String, AppEnum, CaseIterable {
    case shift
    case control
    case option
    case command
    
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Modifier Key")
    
    static var caseDisplayRepresentations: [KeyEventMods : DisplayRepresentation] = [
        .shift: "Shift",
        .control: "Control",
        .option: "Option",
        .command: "Command"
    ]
    
    var ghosttyMod: Ghostty.Input.Mods {
        switch self {
        case .shift: .shift
        case .control: .ctrl
        case .option: .alt
        case .command: .super
        }
    }
}
