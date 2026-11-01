import Combine
import Foundation

enum OMGApplicationEnvironment {
    /// XCTest can load after AppDelegate's early singleton initialization.
    /// Launch environment is available before the test bundle classes exist.
    static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["OMG_TESTING"] == "1" || NSClassFromString("XCTestCase") != nil ||
            environment["XCTestConfigurationFilePath"] != nil ||
            environment["XCTestBundlePath"] != nil ||
            environment["XCTestSessionIdentifier"] != nil
    }

    static var isWorkspaceDevelopment: Bool {
        Bundle.main.bundleIdentifier == "com.jischeng.omg.debug.workspace"
    }

    static var isPTYDevelopment: Bool {
        Bundle.main.bundleIdentifier == "com.jischeng.omg.debug.pty"
    }

    static var isDevelopment: Bool {
        Bundle.main.bundleIdentifier == "com.jischeng.omg.debug" || isWorkspaceDevelopment || isPTYDevelopment
    }

    static func channel(development: Bool = isDevelopment) -> String {
        guard development else { return "release" }
        if isPTYDevelopment { return "debug-pty" }
        return isWorkspaceDevelopment ? "debug-workspace" : "debug"
    }

    static func quitWithoutConfirmationDefault(
        development: Bool = isDevelopment
    ) -> Bool {
        development
    }

    static func settingsFileURL(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        development: Bool = isDevelopment
    ) -> URL {
        let name = if !development { "oh-my-ghostty" } else if isPTYDevelopment {
            "oh-my-ghostty-dev-pty"
        } else if isWorkspaceDevelopment {
            "oh-my-ghostty-dev-workspace"
        } else { "oh-my-ghostty-dev" }
        return homeURL.appendingPathComponent(".config/\(name)/settings.json")
    }

    static func applicationSupportURL(
        baseURL: URL? = nil,
        development: Bool = isDevelopment
    ) -> URL {
        let base = baseURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let name = if !development { "OMG" } else if isPTYDevelopment {
            "OMG Dev PTY"
        } else if isWorkspaceDevelopment {
            "OMG Dev Workspace"
        } else { "OMG Dev" }
        return base.appendingPathComponent(name, isDirectory: true)
    }
}

enum OMGStartupMode: String, CaseIterable, Identifiable, Sendable {
    case newTerminal
    case restoreTabs
    case restoreSessions

    var id: String { rawValue }
    var restoresTabs: Bool { self != .newTerminal }
    var restoresSessions: Bool { self == .restoreSessions }
}

enum TerminalResizeRenderingMode: String, CaseIterable, Identifiable, Sendable {
    case duringDrag
    case onRelease

    var id: String { rawValue }
}

struct OhMyGhosttySettingDescriptor: Codable, Identifiable, Sendable {
    enum ValueType: String, Codable, Sendable {
        case boolean
        case enumeration
        case number
        case string
    }

    let id: String
    let type: ValueType
    let defaultValue: String
    let allowedValues: [String]?
    let minimum: Double?
    let maximum: Double?
    let description: String
    let requiresNewWindow: Bool
    let category: String
}

enum OhMyGhosttyAppearanceSource: String, Codable, Sendable {
    case ohMyGhosttyOverride
    case ghosttyConfig
    case builtInDefault

    var title: String {
        switch self {
        case .ohMyGhosttyOverride: "OMG"
        case .ghosttyConfig: "Ghostty config"
        case .builtInDefault: "Built-in default"
        }
    }
}

struct ResolvedSetting<Value> {
    let effectiveValue: Value
    let source: OhMyGhosttyAppearanceSource
    let overrideValue: Value?
    let inheritedValue: Value?
    let defaultValue: Value
}

enum OhMyGhosttyWindowTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum OhMyGhosttyBackgroundBlur: String, CaseIterable, Identifiable {
    case disabled
    case enabled
    case macosGlassRegular
    case macosGlassClear

    var id: String { rawValue }
    var title: String {
        switch self {
        case .disabled: "Off"
        case .enabled: "Blur"
        case .macosGlassRegular: "macOS Glass — Regular"
        case .macosGlassClear: "macOS Glass — Clear"
        }
    }

    var ghosttyValue: String {
        switch self {
        case .disabled: "false"
        case .enabled: "true"
        case .macosGlassRegular: "macos-glass-regular"
        case .macosGlassClear: "macos-glass-clear"
        }
    }
}

enum OhMyGhosttyCursorStyle: String, CaseIterable, Identifiable {
    case block
    case bar
    case underline
    case blockHollow = "block_hollow"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .block: "Block"
        case .bar: "Bar"
        case .underline: "Underline"
        case .blockHollow: "Hollow Block"
        }
    }
}

struct EffectiveAppearance {
    let windowTheme: ResolvedSetting<String>
    let theme: ResolvedSetting<String>
    let fontFamily: ResolvedSetting<String>
    let fontSize: ResolvedSetting<Double>
    let backgroundOpacity: ResolvedSetting<Double>
    let backgroundBlur: ResolvedSetting<String>
    let cursorStyle: ResolvedSetting<String>
}

enum GhosttyThemeCatalog {
    static func availableThemes(
        resourceURL: URL? = Bundle.main.resourceURL,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String] {
        let roots = [
            resourceURL?.appendingPathComponent("ghostty/themes"),
            homeURL.appendingPathComponent(".config/ghostty/themes"),
        ].compactMap { $0 }
        var names = Set<String>()
        for root in roots {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries where
                (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                names.insert(entry.lastPathComponent)
            }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

enum OhMyGhosttyTabPathDisplay: String, CaseIterable, Identifiable {
    case fullPath
    case folderName

    var id: String { rawValue }
    var title: String {
        switch self {
        case .fullPath: "Full Path"
        case .folderName: "Current Folder"
        }
    }
}

enum OhMyGhosttyTabRowDensity: String, CaseIterable, Identifiable {
    case compact
    case comfortable

    var id: String { rawValue }
    var title: String {
        switch self {
        case .compact: "Compact"
        case .comfortable: "Comfortable"
        }
    }

    var rowHeight: CGFloat {
        switch self {
        case .compact: 28
        case .comfortable: 32
        }
    }
}

@MainActor
final class OhMyGhosttySettings: ObservableObject {
    static let shared = OhMyGhosttySettings()
    static let didChangeNotification = Notification.Name("com.oh-my-ghostty.settingsDidChange")
    static let changedKeyUserInfoKey = "changedKey"
    static let appearanceDidChangeNotification = Notification.Name(
        "com.oh-my-ghostty.appearanceDidChange"
    )

    static var fileURL: URL {
        OMGApplicationEnvironment.settingsFileURL()
    }

    static var ghosttyAppearanceOverlayURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("appearance.ghostty")
    }

    /// Reads a persisted value straight from the settings JSON, actor-free.
    nonisolated static func persistedValue(forKey key: String) -> Any? {
        guard let data = try? Data(contentsOf: OMGApplicationEnvironment.settingsFileURL()),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object[key]
    }

    static let descriptors: [OhMyGhosttySettingDescriptor] = [
        .init(
            id: "tabs.layout", type: .enumeration, defaultValue: "ghostty-config",
            allowedValues: ["horizontal", "vertical"], minimum: nil, maximum: nil,
            description: "Tab presentation for the current window host and the default for new windows.",
            requiresNewWindow: true, category: "tabs"),
        .init(
            id: "tabs.sidebarWidth", type: .number, defaultValue: "240",
            allowedValues: nil, minimum: 176, maximum: 480,
            description: "Default width of the Vertical Tabs sidebar in points.",
            requiresNewWindow: false, category: "tabs"),
        .init(
            id: "tabs.grouping", type: .enumeration, defaultValue: "none",
            allowedValues: GhosttyTabGroupingMode.allCases.map(\.rawValue), minimum: nil, maximum: nil,
            description: "Derived grouping applied to Vertical Tabs.",
            requiresNewWindow: false, category: "tabs"),
        .init(
            id: "tabs.ordering", type: .enumeration, defaultValue: "manual",
            allowedValues: GhosttyTabOrderingMode.allCases.map(\.rawValue), minimum: nil, maximum: nil,
            description: "Canonical tab ordering policy.",
            requiresNewWindow: false, category: "tabs"),
        .init(
            id: "tabs.pathDisplay", type: .enumeration, defaultValue: "folderName",
            allowedValues: OhMyGhosttyTabPathDisplay.allCases.map(\.rawValue),
            minimum: nil, maximum: nil,
            description: "Display the full working path or only the current folder in Vertical Tabs.",
            requiresNewWindow: false, category: "tabs"),
        .init(
            id: "tabs.showShortcutLabels", type: .boolean, defaultValue: "true",
            allowedValues: nil, minimum: nil, maximum: nil,
            description: "Show configured position shortcuts for the first nine tabs.",
            requiresNewWindow: false, category: "tabs"),
        .init(
            id: "tabs.rememberSidebarWidth", type: .boolean, defaultValue: "true",
            allowedValues: nil, minimum: nil, maximum: nil,
            description: "Use the last committed sidebar width as the next window default.",
            requiresNewWindow: false, category: "tabs"),
        .init(
            id: "tabs.sidebarVisible", type: .boolean, defaultValue: "true",
            allowedValues: nil, minimum: nil, maximum: nil,
            description: "Show the Vertical Tabs sidebar by default.",
            requiresNewWindow: false, category: "tabs"),
        .init(
            id: "git.autoFetchInterval", type: .number, defaultValue: "5",
            allowedValues: nil, minimum: 0, maximum: 1440,
            description: "Interval in minutes for automatic Git fetch. 0 disables auto-fetch.",
            requiresNewWindow: false, category: "general"),
        .init(
            id: "appearance.windowTheme", type: .enumeration, defaultValue: "ghostty-config",
            allowedValues: OhMyGhosttyWindowTheme.allCases.map(\.rawValue), minimum: nil, maximum: nil,
            description: "Optional window appearance override.",
            requiresNewWindow: false, category: "appearance"),
        .init(
            id: "appearance.lightTheme", type: .string, defaultValue: "ghostty-config",
            allowedValues: nil, minimum: nil, maximum: nil,
            description: "Optional Ghostty theme used in Light appearance.",
            requiresNewWindow: false, category: "appearance"),
        .init(
            id: "appearance.darkTheme", type: .string, defaultValue: "ghostty-config",
            allowedValues: nil, minimum: nil, maximum: nil,
            description: "Optional Ghostty theme used in Dark appearance.",
            requiresNewWindow: false, category: "appearance"),
        .init(
            id: "appearance.fontFamily", type: .string, defaultValue: "ghostty-config",
            allowedValues: nil, minimum: nil, maximum: nil,
            description: "Optional terminal font family override.",
            requiresNewWindow: false, category: "appearance"),
        .init(
            id: "appearance.fontSize", type: .number, defaultValue: "ghostty-config",
            allowedValues: nil, minimum: 6, maximum: 72,
            description: "Optional terminal font size override in points.",
            requiresNewWindow: false, category: "appearance"),
        .init(
            id: "appearance.backgroundOpacity", type: .number, defaultValue: "ghostty-config",
            allowedValues: nil, minimum: 0.05, maximum: 1,
            description: "Optional terminal and app-shell background opacity override.",
            requiresNewWindow: false, category: "appearance"),
        .init(
            id: "appearance.backgroundBlur", type: .enumeration, defaultValue: "ghostty-config",
            allowedValues: OhMyGhosttyBackgroundBlur.allCases.map(\.rawValue), minimum: nil, maximum: nil,
            description: "Optional Ghostty background blur override.",
            requiresNewWindow: false, category: "appearance"),
        .init(
            id: "appearance.cursorStyle", type: .enumeration, defaultValue: "ghostty-config",
            allowedValues: OhMyGhosttyCursorStyle.allCases.map(\.rawValue), minimum: nil, maximum: nil,
            description: "Optional terminal cursor style override.",
            requiresNewWindow: false, category: "appearance"),
        .init(
            id: "appearance.tabRowDensity", type: .enumeration, defaultValue: "compact",
            allowedValues: OhMyGhosttyTabRowDensity.allCases.map(\.rawValue), minimum: nil, maximum: nil,
            description: "Vertical tab row density.",
            requiresNewWindow: false, category: "appearance"),
        .init(
            id: "appearance.tabIconSize", type: .number, defaultValue: "16",
            allowedValues: nil, minimum: 12, maximum: 20,
            description: "Vertical tab icon size in points.",
            requiresNewWindow: false, category: "appearance"),
        .init(
            id: "notifications.taskComplete", type: .boolean, defaultValue: "true",
            allowedValues: nil, minimum: nil, maximum: nil,
            description: "Allow completion events to request a notification.",
            requiresNewWindow: false, category: "plugins"),
        .init(
            id: "notifications.attention", type: .boolean, defaultValue: "true",
            allowedValues: nil, minimum: nil, maximum: nil,
            description: "Allow attention events to request a notification.",
            requiresNewWindow: false, category: "plugins"),
        .init(
            id: "notifications.sound", type: .boolean, defaultValue: "false",
            allowedValues: nil, minimum: nil, maximum: nil,
            description: "Play a sound for enabled agent notifications.",
            requiresNewWindow: false, category: "plugins"),
        .init(
            id: "agents.statusHooks", type: .boolean, defaultValue: "true",
            allowedValues: nil, minimum: nil, maximum: nil,
            description: "Accept normalized activity events from agent adapters.",
            requiresNewWindow: false, category: "plugins"),
        .init(
            id: "agents.openQuickInputOnStart", type: .boolean, defaultValue: "false",
            allowedValues: nil, minimum: nil, maximum: nil,
            description: "Open Quick Input when an agent starts without changing keyboard focus.",
            requiresNewWindow: false, category: "keyboard"),
        .init(
            id: "agents.openQuickInputOnComplete", type: .boolean, defaultValue: "false",
            allowedValues: nil, minimum: nil, maximum: nil,
            description: "Open Quick Input when an agent completes without changing keyboard focus.",
            requiresNewWindow: false, category: "keyboard"),
        .init(
            id: "keyboard.quickInput", type: .string,
            defaultValue: OMGKeyboardShortcut.defaultQuickInput.storageValue,
            allowedValues: nil, minimum: nil, maximum: nil,
            description: "Shortcut that toggles the Agent Quick Input composer.",
            requiresNewWindow: false, category: "keyboard"),
        .init(
            id: "keyboard.inspectorPanel1", type: .string,
            defaultValue: OMGKeyboardShortcut.defaultInspectorPanel(slot: 1).storageValue,
            allowedValues: nil, minimum: nil, maximum: nil,
            description: "Shortcut to switch to or hide right sidebar panel 1.",
            requiresNewWindow: false, category: "keyboard"),
        .init(
            id: "keyboard.inspectorPanel2", type: .string,
            defaultValue: OMGKeyboardShortcut.defaultInspectorPanel(slot: 2).storageValue,
            allowedValues: nil, minimum: nil, maximum: nil,
            description: "Shortcut to switch to or hide right sidebar panel 2.",
            requiresNewWindow: false, category: "keyboard"),
        .init(
            id: "keyboard.inspectorPanel3", type: .string,
            defaultValue: OMGKeyboardShortcut.defaultInspectorPanel(slot: 3).storageValue,
            allowedValues: nil, minimum: nil, maximum: nil,
            description: "Shortcut to switch to or hide right sidebar panel 3.",
            requiresNewWindow: false, category: "keyboard"),
        .init(
            id: "keyboard.inspectorPanel4", type: .string,
            defaultValue: OMGKeyboardShortcut.defaultInspectorPanel(slot: 4).storageValue,
            allowedValues: nil, minimum: nil, maximum: nil,
            description: "Shortcut to switch to or hide right sidebar panel 4.",
            requiresNewWindow: false, category: "keyboard"),
        .init(
            id: "keyboard.quickInputImportShortcut", type: .string, defaultValue: "auto",
            allowedValues: nil, minimum: nil, maximum: nil,
            description: "Agent draft import: auto selects the external-editor shortcut; empty disables; other values override it. Comma separates chords.",
            requiresNewWindow: true, category: "keyboard"),
        .init(
            id: "keyboard.quickInputHeight", type: .number, defaultValue: "252",
            allowedValues: nil, minimum: 140, maximum: 480,
            description: "Last committed Agent Quick Input dock height in points.",
            requiresNewWindow: false, category: "keyboard"),
        .init(
            id: "keyboard.quickInputHistoryScope", type: .enumeration,
            defaultValue: QuickInputHistoryScope.tab.rawValue,
            allowedValues: QuickInputHistoryScope.allCases.map(\.rawValue), minimum: nil, maximum: nil,
            description: "Visible Quick Input history: current pane, current tab, or all windows.",
            requiresNewWindow: false, category: "keyboard"),
        .init(
            id: "keyboard.quickInputHistoryInsertionMode", type: .enumeration,
            defaultValue: QuickInputHistoryInsertionMode.append.rawValue,
            allowedValues: QuickInputHistoryInsertionMode.allCases.map(\.rawValue), minimum: nil, maximum: nil,
            description: "Append a selected history message to the draft or replace the draft.",
            requiresNewWindow: false, category: "keyboard"),
        .init(
            id: "keyboard.quickInputHistoryRetentionDays", type: .number, defaultValue: "7",
            allowedValues: nil, minimum: 1, maximum: 365,
            description: "Quick Input history expiration in days, including in-memory history.",
            requiresNewWindow: false, category: "keyboard"),
        .init(
            id: "keyboard.quickInputHistoryKeepAfterQuit", type: .boolean, defaultValue: "true",
            allowedValues: nil, minimum: nil, maximum: nil,
            description: "Keep Quick Input history on disk after quitting. Disabling deletes the saved copy.",
            requiresNewWindow: false, category: "keyboard"),
        .init(
            id: "terminal.resizeRendering", type: .enumeration,
            defaultValue: TerminalResizeRenderingMode.onRelease.rawValue,
            allowedValues: TerminalResizeRenderingMode.allCases.map(\.rawValue),
            minimum: nil, maximum: nil,
            description: "Choose whether terminal content reflows during a resize or once on release.",
            requiresNewWindow: false, category: "terminal"),
        .init(
            id: "editor.fileOpenDestination", type: .enumeration,
            defaultValue: EditorOpenDestination.currentPane.rawValue,
            allowedValues: EditorOpenDestination.allCases.map(\.rawValue),
            minimum: nil, maximum: nil,
            description: "Default destination for opening files in the editor, including Command-click.",
            requiresNewWindow: false, category: "editor"),
        .init(
            id: "editor.directoryOpenDestination", type: .enumeration,
            defaultValue: EditorOpenDestination.currentPane.rawValue,
            allowedValues: EditorOpenDestination.allCases.map(\.rawValue),
            minimum: nil, maximum: nil,
            description: "Default destination for directories opened with Command-click.",
            requiresNewWindow: false, category: "editor"),
        .init(
            id: "editor.keymapPreset", type: .enumeration,
            defaultValue: EditorKeymapPreset.idea.rawValue,
            allowedValues: EditorKeymapPreset.allCases.map(\.rawValue),
            minimum: nil, maximum: nil,
            description: "Keyboard shortcut preset used by the native editor.",
            requiresNewWindow: false, category: "editor"),
        .init(
            id: "editor.backgroundMode", type: .enumeration,
            defaultValue: EditorBackgroundMode.followTerminal.rawValue,
            allowedValues: EditorBackgroundMode.allCases.map(\.rawValue),
            minimum: nil, maximum: nil,
            description: "Choose whether the editor follows the terminal background or uses the system editor background.",
            requiresNewWindow: false, category: "editor"),
        .init(
            id: "editor.syntaxTheme", type: .enumeration,
            defaultValue: EditorSyntaxTheme.followTerminal.rawValue,
            allowedValues: EditorSyntaxTheme.allCases.map(\.rawValue),
            minimum: nil, maximum: nil,
            description: "Syntax highlighting style theme for the native editor.",
            requiresNewWindow: false, category: "editor"),
        .init(
            id: "editor.themeName", type: .string, defaultValue: "",
            allowedValues: nil, minimum: nil, maximum: nil,
            description: "Optional independent Ghostty catalog theme for editor colors.",
            requiresNewWindow: false, category: "editor"),
        .init(
            id: "editor.autoClosePairs", type: .boolean, defaultValue: "true",
            allowedValues: nil, minimum: nil, maximum: nil,
            description: "Insert matching quotes and brackets and position the caret inside.",
            requiresNewWindow: false, category: "editor"),
        .init(
            id: "editor.opacity", type: .number, defaultValue: "1",
            allowedValues: nil, minimum: 0.05, maximum: 1,
            description: "Background opacity when the editor uses an independent theme.",
            requiresNewWindow: false, category: "editor"),
        .init(
            id: "editor.blur", type: .enumeration, defaultValue: "disabled",
            allowedValues: OhMyGhosttyBackgroundBlur.allCases.map(\.rawValue), minimum: nil, maximum: nil,
            description: "Background effect when the editor uses an independent theme.",
            requiresNewWindow: false, category: "editor"),
        .init(
            id: "editor.fontFamily", type: .enumeration,
            defaultValue: EditorFontFamily.jetbrainsMono.rawValue,
            allowedValues: EditorFontFamily.allCases.map(\.rawValue),
            minimum: nil, maximum: nil,
            description: "Font family used by the native editor.",
            requiresNewWindow: false, category: "editor"),
        .init(
            id: "editor.fontSize", type: .number, defaultValue: "13",
            allowedValues: nil, minimum: 8, maximum: 36,
            description: "Native editor font size in points.",
            requiresNewWindow: false, category: "editor"),
        .init(
            id: "editor.tabWidth", type: .number, defaultValue: "4",
            allowedValues: nil, minimum: 1, maximum: 12,
            description: "Number of spaces represented by one editor tab stop.",
            requiresNewWindow: false, category: "editor"),
        .init(
            id: "editor.wordWrap", type: .boolean, defaultValue: "false",
            allowedValues: nil, minimum: nil, maximum: nil,
            description: "Wrap long editor lines at the visible content width.",
            requiresNewWindow: false, category: "editor"),
        .init(
            id: "general.language", type: .enumeration, defaultValue: "system",
            allowedValues: OhMyGhosttyLanguage.allCases.map(\.rawValue), minimum: nil, maximum: nil,
            description: "Settings display language. system follows the macOS preferred language.",
            requiresNewWindow: false, category: "general"),
        .init(
            id: "general.quitWithoutConfirmation", type: .boolean,
            defaultValue: String(
                OMGApplicationEnvironment.quitWithoutConfirmationDefault()
            ),
            allowedValues: nil, minimum: nil, maximum: nil,
            description: "Quit immediately without confirming running terminal processes.",
            requiresNewWindow: false, category: "general"),
        .init(
            id: "agents.historyLimit", type: .number, defaultValue: "10000",
            allowedValues: nil, minimum: 100, maximum: 50000,
            description: "Maximum number of historical agent sessions to index and display.",
            requiresNewWindow: false, category: "general"),
        .init(
            id: "sessions.localRuntimeEnabled", type: .boolean, defaultValue: "true",
            allowedValues: nil, minimum: nil, maximum: nil,
            description: "Launch new local terminals in the durable local session runtime.",
            requiresNewWindow: true, category: "general"),
        .init(
            id: "sessions.runtimeDetachedHours", type: .number, defaultValue: "72",
            allowedValues: nil, minimum: 0, maximum: 8760,
            description: "Maximum detached local and SSH session lifetime in hours; zero explicitly keeps it indefinitely.",
            requiresNewWindow: true, category: "general"),
        .init(
            id: "sessions.runtimeExpiration", type: .string, defaultValue: "",
            allowedValues: nil, minimum: nil, maximum: nil,
            description: "Optional ISO-8601 deadline for detached sessions; empty disables the absolute deadline.",
            requiresNewWindow: true, category: "general"),
        .init(
            id: "sessions.runtimeCloseOnAgentDone", type: .boolean, defaultValue: "false",
            allowedValues: nil, minimum: nil, maximum: nil,
            description: "Beta, disabled by default. Close detached sessions after verified Agent completion and durable recovery metadata; unsupported Agents remain running like ordinary processes.",
            requiresNewWindow: true, category: "general"),
        .init(
            id: "sessions.runtimeDoneGraceSeconds", type: .number, defaultValue: "60",
            allowedValues: nil, minimum: 1, maximum: 86400,
            description: "Grace period before closing a completed detached Agent session.",
            requiresNewWindow: true, category: "general"),
        .init(
            id: "sessions.startupMode", type: .enumeration,
            defaultValue: OMGStartupMode.restoreSessions.rawValue,
            allowedValues: OMGStartupMode.allCases.map(\.rawValue),
            minimum: nil, maximum: nil,
            description: "Choose a fresh terminal, layout-only tabs, or full session restoration on next launch.",
            requiresNewWindow: false, category: "general"),
    ] + CoreSetting.all.map {
        .init(id: $0.id, type: .enumeration, defaultValue: "",
              allowedValues: [""] + $0.values, minimum: nil, maximum: nil,
              description: $0.helpEnglish, requiresNewWindow: $0.requiresNewTerminal,
              category: $0.group.tab.rawValue)
    }

    @Published private(set) var coreOverrides: [String: String] = [:]

    /// Empty/nil removes only the OMG override, never the inherited Ghostty value.
    @discardableResult
    func setCoreOverride(_ key: String, value: String?) -> Bool {
        guard let descriptor = CoreSetting.find(key) else { return false }
        let value = value.flatMap { $0.isEmpty ? nil : $0 }
        if let value, !descriptor.values.contains(value) { return false }
        coreOverrides[key] = value
        persistOptional(descriptor.id, value)
        return true
    }

    @Published var tabLayout: Ghostty.Config.MacOSTabLayout = .vertical {
        didSet { persist("tabs.layout", tabLayout.rawValue) }
    }
    @Published var defaultSidebarWidth: Double = 240 {
        didSet {
            let clamped = min(max(defaultSidebarWidth, 176), 480)
            if defaultSidebarWidth != clamped {
                defaultSidebarWidth = clamped
            } else {
                persist("tabs.sidebarWidth", clamped)
            }
        }
    }
    @Published var groupingMode: GhosttyTabGroupingMode = .none {
        didSet { persist("tabs.grouping", groupingMode.rawValue) }
    }
    @Published var orderingMode: GhosttyTabOrderingMode = .manual {
        didSet { persist("tabs.ordering", orderingMode.rawValue) }
    }
    @Published var tabPathDisplay: OhMyGhosttyTabPathDisplay = .folderName {
        didSet { persist("tabs.pathDisplay", tabPathDisplay.rawValue) }
    }
    @Published var showShortcutLabels = true {
        didSet { persist("tabs.showShortcutLabels", showShortcutLabels) }
    }
    @Published var rememberSidebarWidth = true {
        didSet { persist("tabs.rememberSidebarWidth", rememberSidebarWidth) }
    }
    @Published var sidebarVisible = true {
        didSet { persist("tabs.sidebarVisible", sidebarVisible) }
    }
    @Published var windowThemeOverride: OhMyGhosttyWindowTheme? {
        didSet { persistOptional("appearance.windowTheme", windowThemeOverride?.rawValue) }
    }
    @Published var lightThemeOverride: String? {
        didSet {
            persistOptional("appearance.lightTheme", Self.normalized(lightThemeOverride))
        }
    }
    @Published var darkThemeOverride: String? {
        didSet {
            persistOptional("appearance.darkTheme", Self.normalized(darkThemeOverride))
        }
    }
    @Published var fontFamilyOverride: String? {
        didSet {
            persistOptional("appearance.fontFamily", Self.normalized(fontFamilyOverride))
        }
    }
    @Published var fontSizeOverride: Double? {
        didSet {
            let clamped = fontSizeOverride.map { min(max($0, 6), 72) }
            if fontSizeOverride != clamped {
                fontSizeOverride = clamped
            } else {
                persistOptional("appearance.fontSize", clamped)
            }
        }
    }
    @Published var backgroundOpacityOverride: Double? {
        didSet {
            let clamped = backgroundOpacityOverride.map { min(max($0, 0.05), 1) }
            if backgroundOpacityOverride != clamped {
                backgroundOpacityOverride = clamped
            } else {
                persistOptional("appearance.backgroundOpacity", clamped)
            }
        }
    }
    @Published var backgroundBlurOverride: OhMyGhosttyBackgroundBlur? {
        didSet { persistOptional("appearance.backgroundBlur", backgroundBlurOverride?.rawValue) }
    }
    @Published var cursorStyleOverride: OhMyGhosttyCursorStyle? {
        didSet { persistOptional("appearance.cursorStyle", cursorStyleOverride?.rawValue) }
    }
    @Published var tabRowDensity: OhMyGhosttyTabRowDensity = .compact {
        didSet { persist("appearance.tabRowDensity", tabRowDensity.rawValue) }
    }
    @Published var tabIconSize: Double = 16 {
        didSet {
            let clamped = min(max(tabIconSize, 12), 20)
            if tabIconSize != clamped {
                tabIconSize = clamped
            } else {
                persist("appearance.tabIconSize", clamped)
            }
        }
    }
    @Published var notifyTaskComplete = true {
        didSet { persist("notifications.taskComplete", notifyTaskComplete) }
    }
    @Published var notifyAttention = true {
        didSet { persist("notifications.attention", notifyAttention) }
    }
    @Published var notificationSound = false {
        didSet { persist("notifications.sound", notificationSound) }
    }
    @Published var agentStatusHooksEnabled = true {
        didSet { persist("agents.statusHooks", agentStatusHooksEnabled) }
    }
    @Published var openQuickInputOnAgentStart = false {
        didSet {
            persist("agents.openQuickInputOnStart", openQuickInputOnAgentStart)
        }
    }
    @Published var openQuickInputOnAgentComplete = false {
        didSet {
            persist("agents.openQuickInputOnComplete", openQuickInputOnAgentComplete)
        }
    }
    @Published var quickInputShortcut = OMGKeyboardShortcut.defaultQuickInput.storageValue {
        didSet {
            let normalized = OMGKeyboardShortcut(storageValue: quickInputShortcut)?.storageValue
                ?? OMGKeyboardShortcut.defaultQuickInput.storageValue
            if quickInputShortcut != normalized {
                quickInputShortcut = normalized
            } else {
                persist("keyboard.quickInput", normalized)
            }
        }
    }
    @Published var inspectorPanel1Shortcut = OMGKeyboardShortcut.defaultInspectorPanel(slot: 1).storageValue {
        didSet {
            let normalized = OMGKeyboardShortcut(storageValue: inspectorPanel1Shortcut)?.storageValue
                ?? OMGKeyboardShortcut.defaultInspectorPanel(slot: 1).storageValue
            if inspectorPanel1Shortcut != normalized {
                inspectorPanel1Shortcut = normalized
            } else {
                persist("keyboard.inspectorPanel1", normalized)
            }
        }
    }
    @Published var inspectorPanel2Shortcut = OMGKeyboardShortcut.defaultInspectorPanel(slot: 2).storageValue {
        didSet {
            let normalized = OMGKeyboardShortcut(storageValue: inspectorPanel2Shortcut)?.storageValue
                ?? OMGKeyboardShortcut.defaultInspectorPanel(slot: 2).storageValue
            if inspectorPanel2Shortcut != normalized {
                inspectorPanel2Shortcut = normalized
            } else {
                persist("keyboard.inspectorPanel2", normalized)
            }
        }
    }
    @Published var inspectorPanel3Shortcut = OMGKeyboardShortcut.defaultInspectorPanel(slot: 3).storageValue {
        didSet {
            let normalized = OMGKeyboardShortcut(storageValue: inspectorPanel3Shortcut)?.storageValue
                ?? OMGKeyboardShortcut.defaultInspectorPanel(slot: 3).storageValue
            if inspectorPanel3Shortcut != normalized {
                inspectorPanel3Shortcut = normalized
            } else {
                persist("keyboard.inspectorPanel3", normalized)
            }
        }
    }
    @Published var inspectorPanel4Shortcut = OMGKeyboardShortcut.defaultInspectorPanel(slot: 4).storageValue {
        didSet {
            let normalized = OMGKeyboardShortcut(storageValue: inspectorPanel4Shortcut)?.storageValue
                ?? OMGKeyboardShortcut.defaultInspectorPanel(slot: 4).storageValue
            if inspectorPanel4Shortcut != normalized {
                inspectorPanel4Shortcut = normalized
            } else {
                persist("keyboard.inspectorPanel4", normalized)
            }
        }
    }

    func inspectorPanelShortcut(slot: Int) -> String {
        switch slot {
        case 1: inspectorPanel1Shortcut
        case 2: inspectorPanel2Shortcut
        case 3: inspectorPanel3Shortcut
        case 4: inspectorPanel4Shortcut
        default: OMGKeyboardShortcut.defaultInspectorPanel(slot: slot).storageValue
        }
    }

    func setInspectorPanelShortcut(slot: Int, value: String) {
        switch slot {
        case 1: inspectorPanel1Shortcut = value
        case 2: inspectorPanel2Shortcut = value
        case 3: inspectorPanel3Shortcut = value
        case 4: inspectorPanel4Shortcut = value
        default: break
        }
    }
    @Published var quickInputImportShortcut = "auto" {
        didSet { persist("keyboard.quickInputImportShortcut", quickInputImportShortcut) }
    }
    @Published var quickInputHeight = Double(AgentQuickInputMetrics.defaultHeight) {
        didSet {
            let clamped = min(max(quickInputHeight, 140), 480)
            if quickInputHeight != clamped {
                quickInputHeight = clamped
            } else {
                persist("keyboard.quickInputHeight", clamped)
            }
        }
    }
    @Published var quickInputHistoryScope: QuickInputHistoryScope = .tab {
        didSet { persist("keyboard.quickInputHistoryScope", quickInputHistoryScope.rawValue) }
    }
    @Published var quickInputHistoryInsertionMode: QuickInputHistoryInsertionMode = .append {
        didSet { persist("keyboard.quickInputHistoryInsertionMode", quickInputHistoryInsertionMode.rawValue) }
    }
    @Published var quickInputHistoryRetentionDays: Double = 7 {
        didSet {
            let value = quickInputHistoryRetentionDays.isFinite
                ? min(max(quickInputHistoryRetentionDays.rounded(), 1), 365) : 7
            if quickInputHistoryRetentionDays != value {
                quickInputHistoryRetentionDays = value
            } else {
                persist("keyboard.quickInputHistoryRetentionDays", value)
            }
        }
    }
    @Published var quickInputHistoryKeepAfterQuit = true {
        didSet { persist("keyboard.quickInputHistoryKeepAfterQuit", quickInputHistoryKeepAfterQuit) }
    }
    @Published var terminalResizeRendering: TerminalResizeRenderingMode = .onRelease {
        didSet { persist("terminal.resizeRendering", terminalResizeRendering.rawValue) }
    }
    @Published var editorFileOpenDestination: EditorOpenDestination = .currentPane {
        didSet { persist("editor.fileOpenDestination", editorFileOpenDestination.rawValue) }
    }
    @Published var editorDirectoryOpenDestination: EditorOpenDestination = .currentPane {
        didSet { persist("editor.directoryOpenDestination", editorDirectoryOpenDestination.rawValue) }
    }
    @Published var editorKeymapPreset: EditorKeymapPreset = .idea {
        didSet { persist("editor.keymapPreset", editorKeymapPreset.rawValue) }
    }
    @Published var editorBackgroundMode: EditorBackgroundMode = .followTerminal {
        didSet { persist("editor.backgroundMode", editorBackgroundMode.rawValue) }
    }
    @Published var editorSyntaxTheme: EditorSyntaxTheme = .followTerminal {
        didSet { persist("editor.syntaxTheme", editorSyntaxTheme.rawValue) }
    }
    @Published var editorThemeName: String? {
        didSet { persistOptional("editor.themeName", Self.normalized(editorThemeName)) }
    }
    @Published var editorAutoClosePairs = true {
        didSet { persist("editor.autoClosePairs", editorAutoClosePairs) }
    }
    @Published var editorOpacity: Double = 1 {
        didSet { persist("editor.opacity", min(max(editorOpacity, 0.05), 1)) }
    }
    @Published var editorBlur: OhMyGhosttyBackgroundBlur = .disabled {
        didSet { persist("editor.blur", editorBlur.rawValue) }
    }
    @Published var editorFontFamily: EditorFontFamily = .jetbrainsMono {
        didSet { persist("editor.fontFamily", editorFontFamily.rawValue) }
    }
    @Published var editorFontSize: Double = 13 {
        didSet {
            let clamped = min(max(editorFontSize, 8), 36)
            if editorFontSize != clamped {
                editorFontSize = clamped
            } else {
                persist("editor.fontSize", clamped)
            }
        }
    }
    @Published var editorTabWidth: Double = 4 {
        didSet {
            let clamped = min(max(editorTabWidth.rounded(), 1), 12)
            if editorTabWidth != clamped {
                editorTabWidth = clamped
            } else {
                persist("editor.tabWidth", clamped)
            }
        }
    }
    @Published var editorWordWrap = false {
        didSet { persist("editor.wordWrap", editorWordWrap) }
    }
    /// Last Git History scope selection ("currentBranch" or "allBranches").
    /// Restored on launch; a deleted branch falls back to the current branch.
    var gitHistoryScope: String? {
        didSet { persistOptional("git.historyScope", gitHistoryScope) }
    }
    /// Git auto-fetch interval in minutes.
    /// 0 means disabled. Typical values: 1, 2, 5, 10, 15, 30, 60.
    @Published var gitAutoFetchInterval: Int = 5 {
        didSet {
            let clamped = max(0, min(gitAutoFetchInterval, 1440))
            if gitAutoFetchInterval != clamped {
                gitAutoFetchInterval = clamped
            } else {
                persist("git.autoFetchInterval", clamped)
            }
        }
    }
    @Published var gitCommitAIPrompt = "" {
        didSet { persist("git.commitAI.prompt", gitCommitAIPrompt) }
    }
    @Published var gitCommitAIRoutes: [GitCommitAIRoute] = [] {
        didSet { persist("git.commitAI.routes", GitCommitAIRoute.encode(gitCommitAIRoutes)) }
    }
    @Published var agentHistoryLimit: Double = 10_000 {
        didSet {
            let clamped = min(max(agentHistoryLimit, 100), 50_000)
            if agentHistoryLimit != clamped {
                agentHistoryLimit = clamped
            } else {
                persist("agents.historyLimit", clamped)
            }
        }
    }
    @Published var localRuntimeEnabled = true {
        didSet { persist("sessions.localRuntimeEnabled", localRuntimeEnabled) }
    }
    @Published var runtimeDetachedHours: Double = 72 {
        didSet { persist("sessions.runtimeDetachedHours", min(max(runtimeDetachedHours, 0), 8760)) }
    }
    @Published var runtimeExpiration = "" {
        didSet { persist("sessions.runtimeExpiration", runtimeExpiration) }
    }
    @Published var runtimeCloseOnAgentDone = false {
        didSet { persist("sessions.runtimeCloseOnAgentDone", runtimeCloseOnAgentDone) }
    }
    @Published var runtimeDoneGraceSeconds: Double = 60 {
        didSet { persist("sessions.runtimeDoneGraceSeconds", min(max(runtimeDoneGraceSeconds, 1), 86400)) }
    }
    var runtimePolicy: SessionRuntimePolicy {
        .init(detachedTTLSeconds: Int(min(max(runtimeDetachedHours, 0), 8760) * 3600),
              expiresAt: ISO8601DateFormatter().date(from: runtimeExpiration).map { Int($0.timeIntervalSince1970) },
              closeOnAgentDone: runtimeCloseOnAgentDone,
              agentDoneGraceSeconds: Int(min(max(runtimeDoneGraceSeconds, 1), 86400)))
    }
    @Published var startupMode: OMGStartupMode = .restoreSessions {
        didSet { persist("sessions.startupMode", startupMode.rawValue) }
    }
    @Published var quitWithoutConfirmation =
        OMGApplicationEnvironment.quitWithoutConfirmationDefault() {
        didSet {
            persist("general.quitWithoutConfirmation", quitWithoutConfirmation)
        }
    }
    @Published var language: OhMyGhosttyLanguage = .system {
        didSet { persist("general.language", language.rawValue) }
    }
    @Published private(set) var lastError: String?

    private var chosen: [String: Any] = [:]
    private var ghosttyTabLayout: Ghostty.Config.MacOSTabLayout = .vertical
    private var isApplying = false
    private let fileURL: URL
    private let appearanceOverlayURL: URL
    private var appearanceNotificationWorkItem: DispatchWorkItem?

    init(fileURL: URL? = nil) {
        if fileURL == nil { Self.seedDevelopmentSettingsIfNeeded() }
        let fileURL = fileURL ?? Self.fileURL
        self.fileURL = fileURL
        self.appearanceOverlayURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("appearance.ghostty")
        reloadFromDisk()
    }

    static func seedDevelopmentSettingsIfNeeded(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        development: Bool = OMGApplicationEnvironment.isDevelopment
    ) {
        guard development else { return }
        let destination = OMGApplicationEnvironment.settingsFileURL(
            homeURL: homeURL,
            development: true
        )
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        let source = OMGApplicationEnvironment.settingsFileURL(
            homeURL: homeURL,
            development: false
        )
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            // Loading defaults remains safe when the optional seed cannot be copied.
        }
    }

    func configureGhosttyFallback(tabLayout: Ghostty.Config.MacOSTabLayout) {
        ghosttyTabLayout = tabLayout
        guard chosen["tabs.layout"] == nil else { return }
        applyWithoutPersisting {
            self.tabLayout = tabLayout
        }
    }

    func reloadFromDisk() {
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let data = try Data(contentsOf: fileURL)
                let object = try JSONSerialization.jsonObject(with: data)
                guard let dictionary = object as? [String: Any] else {
                    throw SettingsError.invalidRoot
                }
                chosen = dictionary
            } else {
                chosen = [:]
            }
            let migratedPathDisplay = migratePathDisplayDefault()
            let migratedResizeRendering = migrateResizeRenderingSetting()
            let migratedStartupMode = migrateStartupModeSetting()
            applyChosenValues()
            if migratedPathDisplay || migratedResizeRendering || migratedStartupMode { save() }
            lastError = nil
            writeAppearanceOverlay()
            notifyRuntime()
            notifyAppearanceRuntime()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func migratePathDisplayDefault() -> Bool {
        let marker = "_migrations.tabsPathDisplayFolderName"
        guard chosen[marker] == nil else { return false }
        chosen["tabs.pathDisplay"] = OhMyGhosttyTabPathDisplay.folderName.rawValue
        chosen[marker] = 1
        return true
    }

    private func migrateResizeRenderingSetting() -> Bool {
        let legacyKey = "terminal.smoothResize"
        guard chosen["terminal.resizeRendering"] == nil,
              let enabled = chosen.removeValue(forKey: legacyKey) as? Bool else {
            return false
        }
        chosen["terminal.resizeRendering"] = enabled
            ? TerminalResizeRenderingMode.duringDrag.rawValue
            : TerminalResizeRenderingMode.onRelease.rawValue
        return true
    }

    private func migrateStartupModeSetting() -> Bool {
        let legacy = chosen.removeValue(forKey: "sessions.restoreOnLaunch") as? Bool
        guard let legacy else { return false }
        if chosen["sessions.startupMode"] == nil {
            chosen["sessions.startupMode"] = (legacy
                ? OMGStartupMode.restoreSessions : .newTerminal).rawValue
        }
        return true
    }

    func ensureFileExists() {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        save()
    }

    func resetTabs() {
        let keys = chosen.keys.filter { $0.hasPrefix("tabs.") }
        for key in keys { chosen.removeValue(forKey: key) }
        applyChosenValues()
        save()
        notifyRuntime()
    }

    func resetAppearance() {
        let keys = chosen.keys.filter {
            $0.hasPrefix("appearance.") &&
                $0 != "appearance.tabRowDensity" &&
                $0 != "appearance.tabIconSize"
        }
        for key in keys { chosen.removeValue(forKey: key) }
        applyChosenValues()
        save()
        notifyRuntime()
        notifyAppearanceRuntime()
    }

    /// Ensures the generated Ghostty overlay exists before Ghostty starts.
    /// The overlay is app-owned and never mutates the user's Ghostty config.
    func prepareAppearanceOverlay() {
        writeAppearanceOverlay()
    }

    func effectiveAppearance(using config: Ghostty.Config) -> EffectiveAppearance {
        let inheritedWindowTheme = config.windowTheme ?? "auto"
        let inheritedBlur = Self.describe(config.backgroundBlur)
        let overrideTheme = resolvedThemeOverride
        return .init(
            windowTheme: resolve(
                override: windowThemeOverride?.rawValue,
                inherited: inheritedWindowTheme,
                defaultValue: "auto"
            ),
            theme: resolve(
                override: overrideTheme,
                inherited: "Ghostty configuration",
                defaultValue: "Built-in Ghostty theme"
            ),
            fontFamily: resolve(
                override: Self.normalized(fontFamilyOverride),
                inherited: "Ghostty configuration",
                defaultValue: "System monospace"
            ),
            fontSize: resolve(
                override: fontSizeOverride,
                inherited: config.fontSize,
                defaultValue: 13
            ),
            backgroundOpacity: resolve(
                override: backgroundOpacityOverride,
                inherited: config.backgroundOpacity,
                defaultValue: 1
            ),
            backgroundBlur: resolve(
                override: backgroundBlurOverride?.title,
                inherited: inheritedBlur,
                defaultValue: "Off"
            ),
            cursorStyle: resolve(
                override: cursorStyleOverride?.rawValue,
                inherited: config.cursorStyle,
                defaultValue: "block"
            )
        )
    }

    func schemaData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Self.descriptors)
    }

    var editorSettings: EditorSettings {
        EditorSettings(
            keymapPreset: editorKeymapPreset,
            backgroundMode: editorBackgroundMode,
            syntaxTheme: editorSyntaxTheme,
            fontFamily: editorFontFamily,
            fontSize: editorFontSize,
            tabWidth: Int(editorTabWidth),
            wordWrap: editorWordWrap,
            opacity: editorOpacity,
            blur: editorBlur,
            themeName: editorThemeName,
            autoClosePairs: editorAutoClosePairs,
            fileOpenDestination: editorFileOpenDestination,
            directoryOpenDestination: editorDirectoryOpenDestination
        )
    }

    private func applyChosenValues() {
        applyWithoutPersisting {
            coreOverrides = Dictionary(uniqueKeysWithValues: CoreSetting.all.compactMap { descriptor in
                guard let value = chosen[descriptor.id] as? String, descriptor.values.contains(value) else { return nil }
                return (descriptor.key, value)
            })
            tabLayout = enumValue("tabs.layout", fallback: ghosttyTabLayout)
            defaultSidebarWidth = numberValue("tabs.sidebarWidth", fallback: 240, range: 176...480)
            groupingMode = enumValue("tabs.grouping", fallback: .none)
            orderingMode = enumValue("tabs.ordering", fallback: .manual)
            tabPathDisplay = enumValue("tabs.pathDisplay", fallback: .folderName)
            showShortcutLabels = boolValue("tabs.showShortcutLabels", fallback: true)
            rememberSidebarWidth = boolValue("tabs.rememberSidebarWidth", fallback: true)
            sidebarVisible = boolValue("tabs.sidebarVisible", fallback: true)
            windowThemeOverride = optionalEnumValue("appearance.windowTheme")
            lightThemeOverride = optionalStringValue("appearance.lightTheme")
            darkThemeOverride = optionalStringValue("appearance.darkTheme")
            fontFamilyOverride = optionalStringValue("appearance.fontFamily")
            fontSizeOverride = optionalNumberValue("appearance.fontSize", range: 6...72)
            backgroundOpacityOverride = optionalNumberValue(
                "appearance.backgroundOpacity",
                range: 0.05...1
            )
            backgroundBlurOverride = optionalEnumValue("appearance.backgroundBlur")
            cursorStyleOverride = optionalEnumValue("appearance.cursorStyle")
            tabRowDensity = enumValue("appearance.tabRowDensity", fallback: .compact)
            tabIconSize = numberValue("appearance.tabIconSize", fallback: 16, range: 12...20)
            notifyTaskComplete = boolValue("notifications.taskComplete", fallback: true)
            notifyAttention = boolValue("notifications.attention", fallback: true)
            notificationSound = boolValue("notifications.sound", fallback: false)
            agentStatusHooksEnabled = boolValue("agents.statusHooks", fallback: true)
            openQuickInputOnAgentStart = boolValue(
                "agents.openQuickInputOnStart",
                fallback: false
            )
            openQuickInputOnAgentComplete = boolValue(
                "agents.openQuickInputOnComplete",
                fallback: false
            )
            quickInputShortcut = validatedShortcutValue(
                "keyboard.quickInput",
                fallback: OMGKeyboardShortcut.defaultQuickInput.storageValue
            )
            inspectorPanel1Shortcut = validatedShortcutValue(
                "keyboard.inspectorPanel1",
                fallback: OMGKeyboardShortcut.defaultInspectorPanel(slot: 1).storageValue
            )
            inspectorPanel2Shortcut = validatedShortcutValue(
                "keyboard.inspectorPanel2",
                fallback: OMGKeyboardShortcut.defaultInspectorPanel(slot: 2).storageValue
            )
            inspectorPanel3Shortcut = validatedShortcutValue(
                "keyboard.inspectorPanel3",
                fallback: OMGKeyboardShortcut.defaultInspectorPanel(slot: 3).storageValue
            )
            inspectorPanel4Shortcut = validatedShortcutValue(
                "keyboard.inspectorPanel4",
                fallback: OMGKeyboardShortcut.defaultInspectorPanel(slot: 4).storageValue
            )
            quickInputImportShortcut = optionalStringValue("keyboard.quickInputImportShortcut") ?? "auto"
            quickInputHeight = numberValue(
                "keyboard.quickInputHeight",
                fallback: Double(AgentQuickInputMetrics.defaultHeight),
                range: 140...480
            )
            quickInputHistoryScope = enumValue("keyboard.quickInputHistoryScope", fallback: .tab)
            quickInputHistoryInsertionMode = enumValue("keyboard.quickInputHistoryInsertionMode", fallback: .append)
            quickInputHistoryRetentionDays = numberValue(
                "keyboard.quickInputHistoryRetentionDays", fallback: 7, range: 1...365
            ).rounded()
            quickInputHistoryKeepAfterQuit = boolValue("keyboard.quickInputHistoryKeepAfterQuit", fallback: true)
            terminalResizeRendering = enumValue(
                "terminal.resizeRendering",
                fallback: .onRelease
            )
            editorFileOpenDestination = enumValue("editor.fileOpenDestination", fallback: .currentPane)
            editorDirectoryOpenDestination = enumValue("editor.directoryOpenDestination", fallback: .currentPane)
            editorKeymapPreset = enumValue("editor.keymapPreset", fallback: .idea)
            editorBackgroundMode = enumValue("editor.backgroundMode", fallback: .followTerminal)
            editorSyntaxTheme = enumValue("editor.syntaxTheme", fallback: .followTerminal)
            editorThemeName = optionalStringValue("editor.themeName")
            editorAutoClosePairs = boolValue("editor.autoClosePairs", fallback: true)
            editorOpacity = numberValue("editor.opacity", fallback: 1, range: 0.05...1)
            editorBlur = enumValue("editor.blur", fallback: .disabled)
            editorFontFamily = enumValue("editor.fontFamily", fallback: .jetbrainsMono)
            editorFontSize = numberValue("editor.fontSize", fallback: 13, range: 8...36)
            editorTabWidth = numberValue("editor.tabWidth", fallback: 4, range: 1...12).rounded()
            editorWordWrap = boolValue("editor.wordWrap", fallback: false)
            gitCommitAIPrompt = chosen["git.commitAI.prompt"] as? String ?? ""
            gitCommitAIRoutes = GitCommitAIRoute.decode(chosen["git.commitAI.routes"])
            gitHistoryScope = optionalStringValue("git.historyScope")
            gitAutoFetchInterval = Int(numberValue("git.autoFetchInterval", fallback: 5, range: 0...1440).rounded())
            agentHistoryLimit = numberValue(
                "agents.historyLimit",
                fallback: 10_000,
                range: 100...50_000
            )
            localRuntimeEnabled = boolValue("sessions.localRuntimeEnabled", fallback: true)
            startupMode = enumValue("sessions.startupMode", fallback: .restoreSessions)
            runtimeDetachedHours = min(max(chosen["sessions.runtimeDetachedHours"] as? Double ?? 72, 0), 8760)
            runtimeExpiration = chosen["sessions.runtimeExpiration"] as? String ?? ""
            runtimeCloseOnAgentDone = chosen["sessions.runtimeCloseOnAgentDone"] as? Bool ?? false
            runtimeDoneGraceSeconds = min(max(chosen["sessions.runtimeDoneGraceSeconds"] as? Double ?? 60, 1), 86400)
            quitWithoutConfirmation = boolValue(
                "general.quitWithoutConfirmation",
                fallback: OMGApplicationEnvironment.quitWithoutConfirmationDefault()
            )
            language = enumValue("general.language", fallback: .system)
        }
    }

    private func enumValue<Value: RawRepresentable>(
        _ key: String,
        fallback: Value
    ) -> Value where Value.RawValue == String {
        guard let raw = chosen[key] as? String, let value = Value(rawValue: raw) else {
            return fallback
        }
        return value
    }

    private func optionalEnumValue<Value: RawRepresentable>(_ key: String) -> Value?
    where Value.RawValue == String {
        guard let raw = chosen[key] as? String else { return nil }
        return Value(rawValue: raw)
    }

    private func optionalStringValue(_ key: String) -> String? {
        guard let raw = chosen[key] as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func validatedShortcutValue(_ key: String, fallback: String) -> String {
        guard let raw = chosen[key] as? String,
              let shortcut = OMGKeyboardShortcut(storageValue: raw) else {
            return fallback
        }
        return shortcut.storageValue
    }

    private func optionalNumberValue(
        _ key: String,
        range: ClosedRange<Double>
    ) -> Double? {
        guard let value = (chosen[key] as? NSNumber)?.doubleValue else { return nil }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private func boolValue(_ key: String, fallback: Bool) -> Bool {
        chosen[key] as? Bool ?? fallback
    }

    private func numberValue(_ key: String, fallback: Double, range: ClosedRange<Double>) -> Double {
        let value = (chosen[key] as? NSNumber)?.doubleValue ?? fallback
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private func applyWithoutPersisting(_ body: () -> Void) {
        isApplying = true
        body()
        isApplying = false
    }

    private func persist(_ key: String, _ value: Any) {
        guard !isApplying else { return }
        chosen[key] = value
        save()
        notifyRuntime(changedKey: key)
        if key.hasPrefix("appearance.") { notifyAppearanceRuntime() }
    }

    private func persistOptional(_ key: String, _ value: Any?) {
        guard !isApplying else { return }
        if let value {
            chosen[key] = value
        } else {
            chosen.removeValue(forKey: key)
        }
        save()
        notifyRuntime(changedKey: key)
        notifyAppearanceRuntime()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(
                withJSONObject: chosen,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: fileURL, options: .atomic)
            writeAppearanceOverlay()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func notifyRuntime(changedKey: String? = nil) {
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: self,
            userInfo: changedKey.map { [Self.changedKeyUserInfoKey: $0] }
        )
    }

    private func notifyAppearanceRuntime() {
        appearanceNotificationWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(
                name: Self.appearanceDidChangeNotification,
                object: self
            )
        }
        appearanceNotificationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    private var resolvedThemeOverride: String? {
        switch (Self.normalized(lightThemeOverride), Self.normalized(darkThemeOverride)) {
        case let (light?, dark?) where light == dark:
            light
        case let (light?, dark?):
            "light:\(light),dark:\(dark)"
        case let (theme?, nil), let (nil, theme?):
            theme
        case (nil, nil):
            nil
        }
    }

    private func writeAppearanceOverlay() {
        do {
            try FileManager.default.createDirectory(
                at: appearanceOverlayURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var lines: [String] = [
                "# Generated by OMG. Edit settings.json, not this file.",
            ]
            if let windowThemeOverride {
                lines.append("window-theme = \(windowThemeOverride.rawValue)")
            }
            if let theme = resolvedThemeOverride {
                lines.append("theme = \(Self.safeConfigValue(theme))")
            }
            if let fontFamilyOverride = Self.normalized(fontFamilyOverride) {
                lines.append("font-family =")
                lines.append("font-family = \(Self.safeConfigValue(fontFamilyOverride))")
            }
            if let fontSizeOverride {
                lines.append("font-size = \(fontSizeOverride)")
            }
            if let backgroundOpacityOverride {
                lines.append("background-opacity = \(backgroundOpacityOverride)")
            }
            if let backgroundBlurOverride {
                lines.append("background-blur = \(backgroundBlurOverride.ghosttyValue)")
            }
            if let cursorStyleOverride {
                lines.append("cursor-style = \(cursorStyleOverride.rawValue)")
            }
            for descriptor in CoreSetting.all {
                if let value = coreOverrides[descriptor.key], descriptor.values.contains(value) {
                    lines.append("\(descriptor.key) = \(value)")
                }
            }
            let content = lines.joined(separator: "\n") + "\n"
            try content.write(to: appearanceOverlayURL, atomically: true, encoding: .utf8)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func resolve<Value>(
        override: Value?,
        inherited: Value?,
        defaultValue: Value
    ) -> ResolvedSetting<Value> {
        if let override {
            return .init(
                effectiveValue: override,
                source: .ohMyGhosttyOverride,
                overrideValue: override,
                inheritedValue: inherited,
                defaultValue: defaultValue
            )
        }
        if let inherited {
            return .init(
                effectiveValue: inherited,
                source: .ghosttyConfig,
                overrideValue: nil,
                inheritedValue: inherited,
                defaultValue: defaultValue
            )
        }
        return .init(
            effectiveValue: defaultValue,
            source: .builtInDefault,
            overrideValue: nil,
            inheritedValue: nil,
            defaultValue: defaultValue
        )
    }

    private static func normalized(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized?.isEmpty == false ? normalized : nil
    }

    private static func safeConfigValue(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func describe(_ blur: Ghostty.Config.BackgroundBlur) -> String {
        switch blur {
        case .disabled: "Off"
        case .radius(let radius): "Radius \(radius)"
        case .macosGlassRegular: "macOS Glass — Regular"
        case .macosGlassClear: "macOS Glass — Clear"
        }
    }

    private enum SettingsError: LocalizedError {
        case invalidRoot

        var errorDescription: String? {
            "The settings file must contain one JSON object."
        }
    }
}
