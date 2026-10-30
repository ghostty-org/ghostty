import AppKit
import Combine
import GhosttyKit
import SwiftUI

struct TerminalWorkspace: Codable, Equatable, Identifiable {
    static let defaultID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    var id: UUID
    var name: String
    var symbol: String
    var color: String

    static let symbols = [
        "house", "briefcase", "person.crop.circle", "terminal", "folder", "hammer",
        "sparkles", "star", "heart", "book", "graduationcap", "globe",
        "airplane", "leaf", "cup.and.saucer", "gamecontroller", "music.note", "camera",
        "paintbrush", "lightbulb", "bolt", "server.rack", "cloud", "shippingbox",
        "ladybug", "cpu", "network", "externaldrive", "lock.shield", "wrench.and.screwdriver", "flask", "chart.bar",
        "doc.text", "pencil.and.outline", "film", "headphones", "mountain.2", "sun.max", "moon", "pawprint",
    ]
    static let colors = ["accent", "sage", "green", "mint", "teal", "blue", "indigo", "purple", "rose", "red", "orange", "amber", "gray"]
    static let initial = TerminalWorkspace(id: defaultID, name: "Personal", symbol: "house", color: "accent")

    var tint: Color {
        switch color {
        case "accent": Color.accentColor
        case "green": Color.green
        case "mint": Color.mint
        case "teal": Color.teal
        case "indigo": Color.indigo
        case "red": Color.red
        case "orange": Color.orange
        case "blue": Color(red: 0.57, green: 0.68, blue: 0.79)
        case "purple": Color(red: 0.69, green: 0.63, blue: 0.81)
        case "amber": Color(red: 0.80, green: 0.67, blue: 0.46)
        case "rose": Color(red: 0.79, green: 0.59, blue: 0.63)
        case "gray": Color(red: 0.65, green: 0.68, blue: 0.72)
        default: Color(red: 0.60, green: 0.71, blue: 0.64)
        }
    }
}

/// Workspace metadata is independent of terminal output and process restoration.
/// Stable tab IDs join this catalog to AppKit's existing session archives.
@MainActor
final class TerminalWorkspaceStore: ObservableObject {
    static let shared = OMGApplicationEnvironment.isRunningTests
        ? TerminalWorkspaceStore(fileURL: nil) : TerminalWorkspaceStore()

    typealias Presentation = TerminalWorkspaceState.Presentation
    typealias Group = TerminalWorkspaceState.Group
    typealias Window = TerminalWorkspaceState.Window
    typealias Snapshot = TerminalWorkspaceState

    /// The session writer takes over persistence after startup. One envelope
    /// then owns both catalog and session state; catalog.json is migration-only.
    var checkpointRequested: (() -> Void)?
    let presentationChanges = PassthroughSubject<(UUID, Presentation), Never>()

    func commit(_ value: Snapshot) {
        guard snapshot != value else { return }
        let removed = Set(snapshot.workspaces.map(\.id)).subtracting(value.workspaces.map(\.id))
        for id in removed { quickInputPresentations.removeValue(forKey: id) }
        snapshot = value
        persist()
    }

    func transaction(_ change: (inout Snapshot) -> Void) {
        var next = snapshot
        change(&next)
        commit(next)
    }

    func restore(_ value: Snapshot) {
        quickInputPresentations.removeAll()
        snapshot = value
    }

    func reportSaveError(_ message: String?) { saveError = message }

    private var quickInputPresentations: [UUID: QuickInputGlobalPresentation] = [:]

    func presentation(for id: UUID) -> Presentation {
        snapshot.presentations?[id] ?? Presentation(
            sidebarVisible: OhMyGhosttySettings.shared.sidebarVisible,
            sidebarWidth: OhMyGhosttySettings.shared.defaultSidebarWidth,
            inspectorVisible: false,
            inspectorWidth: Double(RightInspectorMetrics.defaultWidth),
            quickInputHeight: OhMyGhosttySettings.shared.quickInputHeight
        )
    }

    func updatePresentation(for id: UUID, _ update: (inout Presentation) -> Void) {
        var value = presentation(for: id)
        update(&value)
        guard snapshot.presentations?[id] != value else { return }
        if snapshot.presentations == nil { snapshot.presentations = [:] }
        snapshot.presentations?[id] = value
        presentationChanges.send((id, value))
        persist()
    }

    func quickInputPresentation(for id: UUID) -> QuickInputGlobalPresentation {
        if let existing = quickInputPresentations[id] { return existing }
        let value = presentation(for: id)
        let result = QuickInputGlobalPresentation()
        result.setPresented(value.quickInputVisible)
        if value.quickInputPinned { result.togglePinned() }
        result.setHeight(value.quickInputHeight)
        result.onChange = { [weak self, weak result] in
            guard let result else { return }
            self?.updatePresentation(for: id) {
                $0.quickInputVisible = result.isPresented
                $0.quickInputPinned = result.isPinned
                $0.quickInputHeight = result.height
            }
        }
        quickInputPresentations[id] = result
        return result
    }

    func group(window: UUID, workspace: UUID) -> Group? {
        snapshot.windows?[window]?.groups[workspace]
    }

    func rememberGroup(window: UUID, workspace: UUID, group: Group) {
        var record = snapshot.windows?[window] ?? Window(currentWorkspace: workspace)
        guard record.groups[workspace] != group else { return }
        var normalized = group
        normalized.tabs = group.tabs.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        if !normalized.tabs.contains(normalized.selected ?? UUID()) { normalized.selected = normalized.tabs.first }
        record.groups[workspace] = normalized
        transaction { state in
            for tab in normalized.tabs {
                if let old = state.owner(of: tab), old.window != window || old.workspace != workspace { state.remove(tab) }
                state.membership[tab] = workspace
            }
            if state.windows == nil { state.windows = [:] }
            state.windows?[window] = record
            state.updateLegacyPresentation()
        }
    }

    func selectWorkspace(_ workspace: UUID, in window: UUID, frame: CGRect?, fullscreen: Bool?) {
        var record = snapshot.windows?[window] ?? Window(currentWorkspace: workspace)
        if record.currentWorkspace != workspace {
            record.previousWorkspace = record.currentWorkspace
            record.currentWorkspace = workspace
        }
        record.frame = frame ?? record.frame
        record.fullscreen = fullscreen ?? record.fullscreen
        setWindow(window, record)
    }

    func removeTab(_ tab: UUID, window: UUID, workspace: UUID) {
        guard group(window: window, workspace: workspace)?.tabs.contains(tab) == true else { return }
        transaction { $0.remove(tab) }
    }

    private func setWindow(_ id: UUID, _ value: Window) {
        guard snapshot.windows?[id] != value else { return }
        if snapshot.windows == nil { snapshot.windows = [:] }
        snapshot.windows?[id] = value
        snapshot.updateLegacyPresentation()
        persist()
    }

    @Published private(set) var snapshot: Snapshot
    @Published private(set) var saveError: String?
    private let fileURL: URL?
    private let queue = DispatchQueue(label: "com.jischeng.omg.workspaces.persistence", qos: .utility)
    private var revision = 0

    init(fileURL: URL? = OMGApplicationEnvironment.applicationSupportURL()
        .appendingPathComponent("workspaces/catalog.json")) {
        self.fileURL = fileURL
        var loaded = Snapshot()
        if let fileURL, let data = try? Data(contentsOf: fileURL), data.count <= 4 * 1_024 * 1_024,
           let decoded = try? JSONDecoder().decode(Snapshot.self, from: data),
           Self.isValid(decoded) {
            loaded = decoded
        }
        // Migrate only the original, uncustomized workspace appearance.
        if let index = loaded.workspaces.firstIndex(where: {
            $0.id == TerminalWorkspace.defaultID && $0.name == "Personal" &&
                $0.symbol == "house" && $0.color == "sage"
        }) {
            loaded.workspaces[index].color = "accent"
        }
        snapshot = loaded
    }

    static func isValid(_ value: Snapshot) -> Bool {
        let ids = Set(value.workspaces.map(\.id))
        return value.version == 1 && !ids.isEmpty && ids.count == value.workspaces.count &&
            value.workspaces.count <= 100 && value.workspaces.allSatisfy {
                !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 40 &&
                    TerminalWorkspace.symbols.contains($0.symbol) && TerminalWorkspace.colors.contains($0.color)
            } && value.membership.values.allSatisfy { ids.contains($0) }
    }

    var workspaces: [TerminalWorkspace] { snapshot.workspaces }
    var defaultID: UUID { workspaces.first?.id ?? TerminalWorkspace.defaultID }

    func workspace(_ id: UUID) -> TerminalWorkspace {
        workspaces.first { $0.id == id } ?? workspaces[0]
    }

    func workspaceID(for tab: UUID, inheriting parent: UUID? = nil) -> UUID {
        let id = snapshot.membership[tab] ?? parent ?? defaultID
        return workspaces.contains { $0.id == id } ? id : defaultID
    }

    @discardableResult
    func create(name: String, symbol: String, color: String) -> UUID? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40, workspaces.count < 100,
              TerminalWorkspace.symbols.contains(symbol), TerminalWorkspace.colors.contains(color) else { return nil }
        let id = UUID()
        snapshot.workspaces.append(.init(id: id, name: name, symbol: symbol, color: color))
        persist()
        return id
    }

    /// Removing a label retains sessions and merges each window's group into
    /// a remaining workspace. At least one workspace must be retained.
    @discardableResult
    func delete(id: UUID) -> Bool {
        guard workspaces.count > 1, workspaces.contains(where: { $0.id == id }) else { return false }
        transaction { _ = $0.deleteWorkspace(id) }
        quickInputPresentations.removeValue(forKey: id)
        return true
    }

    func update(id: UUID, name: String, symbol: String, color: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = workspaces.firstIndex(where: { $0.id == id }), !name.isEmpty, name.count <= 40,
              TerminalWorkspace.symbols.contains(symbol), TerminalWorkspace.colors.contains(color) else { return }
        snapshot.workspaces[index] = .init(id: id, name: name, symbol: symbol, color: color)
        persist()
    }

    func assign(tab: UUID, to workspace: UUID) {
        guard workspaces.contains(where: { $0.id == workspace }), snapshot.membership[tab] != workspace else { return }
        snapshot.membership[tab] = workspace
        persist()
    }

    func rememberPresentation(hidden: Set<UUID>, selected: [UUID: UUID], groups: [UUID: [UUID]] = [:]) {
        guard snapshot.hiddenTabs != hidden || snapshot.selectedTabs != selected || snapshot.parkedGroups != groups else { return }
        snapshot.hiddenTabs = hidden
        snapshot.selectedTabs = selected
        snapshot.parkedGroups = groups
        persist()
    }

    static func defaultShortcut(slot: Int) -> String {
        OMGKeyboardShortcut(key: slot == 0 ? "w" : "\(slot)", modifiers: [.control, .command]).storageValue
    }

    func shortcut(slot: Int) -> String {
        snapshot.shortcuts[String(slot)] ?? Self.defaultShortcut(slot: slot)
    }

    func setShortcut(slot: Int, value: String) {
        guard (0...9).contains(slot), let shortcut = OMGKeyboardShortcut(storageValue: value),
              shortcut.modifiers.contains(.command) else { return }
        snapshot.shortcuts[String(slot)] = shortcut.storageValue
        persist()
    }

    func shortcutConflict(slot: Int) -> String? {
        guard let shortcut = OMGKeyboardShortcut(storageValue: shortcut(slot: slot)) else { return nil }
        for other in 0...9 where other != slot {
            if self.shortcut(slot: other) == shortcut.storageValue {
                return other == 0 ? WorkspaceL10n.text("Workspace switcher", "工作区切换器") :
                    WorkspaceL10n.text("Workspace \(other)", "工作区 \(other)")
            }
        }
        let settings = OhMyGhosttySettings.shared
        if shortcut.storageValue == settings.quickInputShortcut { return "Quick Input" }
        for panel in 1...4 where shortcut.storageValue == settings.inspectorPanelShortcut(slot: panel) {
            return WorkspaceL10n.text("Inspector panel \(panel)", "右侧面板 \(panel)")
        }
        if let title = shortcut.conflictingMenuItemTitle() { return title }
        if let config = (NSApp.delegate as? AppDelegate)?.ghostty.config.config,
           let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: shortcut.modifiers,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: shortcut.key, charactersIgnoringModifiers: shortcut.key,
            isARepeat: false, keyCode: Self.keyCodes[shortcut.key] ?? 0
           ) {
            var key = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
            let bound = shortcut.key.withCString { text in
                key.text = text
                return ghostty_config_key_is_binding(config, key)
            }
            if bound { return WorkspaceL10n.text("Ghostty key binding", "Ghostty 快捷键") }
        }
        return nil
    }

    private static let keyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
        "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50,
    ]

    func flush() { queue.sync {} }

    private func persist() {
        if let checkpointRequested { checkpointRequested(); return }
        guard let fileURL else { return }
        let value = snapshot
        revision += 1
        let revision = revision
        queue.async { [weak self] in
            let errorMessage: String?
            do {
                let directory = fileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                let data = try JSONEncoder().encode(value)
                try data.write(to: fileURL, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            DispatchQueue.main.async {
                guard let self, self.revision == revision else { return }
                self.saveError = errorMessage
            }
        }
    }
}

@MainActor
enum WorkspaceL10n {
    static func text(_ english: String, _ chinese: String) -> String {
        SettingsStrings(language: OhMyGhosttySettings.shared.language).t(english, chinese)
    }
}
