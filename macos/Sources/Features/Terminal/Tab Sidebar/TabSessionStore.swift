import AppKit

/// Remembers the tabs of the last terminal window the user closed so that they come
/// back the next time Ghostty opens a window, like Warp. Quitting is covered by macOS
/// window restoration; this covers closing the last window (e.g. the red close button)
/// and opening Ghostty again from the Dock.
///
/// Tabs that are closed one by one are not remembered, and the remembered window is
/// forgotten as soon as any other terminal window opens.
@MainActor
enum TabSessionStore {
    static let defaultsKey = "TabSessionClosedWindow"

    struct Snapshot: Codable {
        let frame: CGRect
        let selectedIndex: Int?
        let tabs: [TerminalRestorableState]
    }

    private static var defaults: UserDefaults { .ghostty }

    private static var isEnabled: Bool {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return false }
        return appDelegate.ghostty.config.windowSaveState != "never"
    }

    /// Whether a closed window is remembered.
    static var hasClosedWindow: Bool {
        defaults.data(forKey: defaultsKey) != nil
    }

    /// Remembers the given window and its tabs if it is the last terminal window.
    static func windowWillClose(_ controller: TerminalController) {
        guard isEnabled, let window = controller.window else { return }

        let windows = window.tabGroup?.windows ?? [window]
        let controllers = windows.compactMap { $0.windowController as? TerminalController }
        let isLastWindow = TerminalController.all.allSatisfy { other in
            guard let otherWindow = other.window, isOpen(otherWindow) else { return true }
            return windows.contains(otherWindow)
        }
        guard isLastWindow else { return }

        let tabs = controllers
            .filter { !$0.surfaceTree.isEmpty }
            .map { TerminalRestorableState(from: $0) }
        guard !tabs.isEmpty else { return }

        let selected = controllers.firstIndex { $0.window?.isKeyWindow ?? false }
            ?? controllers.firstIndex { $0 === controller }
        let snapshot = Snapshot(frame: window.frame, selectedIndex: selected, tabs: tabs)

        do {
            defaults.set(try JSONEncoder().encode(snapshot), forKey: defaultsKey)
        } catch {
            AppDelegate.logger.warning("failed to remember closed window: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Whether a window is still open. Closed windows can linger in `NSApp.windows`
    /// (e.g. while undo keeps them alive) and background tabs are ordered out.
    private static func isOpen(_ window: NSWindow) -> Bool {
        if window.isVisible || window.isMiniaturized { return true }
        return window.tabbedWindows?.contains { $0.isVisible || $0.isMiniaturized } ?? false
    }

    /// Forgets the remembered window.
    static func discard() {
        defaults.removeObject(forKey: defaultsKey)
    }

    /// Recreates the remembered window with its tabs. Returns false if there is no
    /// remembered window or it couldn't be restored.
    static func restoreClosedWindow(_ ghostty: Ghostty.App) -> Bool {
        guard let data = defaults.data(forKey: defaultsKey) else { return false }
        discard()
        guard isEnabled else { return false }

        // Decoding creates the terminal surfaces in the saved working directories.
        let snapshot: Snapshot
        do {
            snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        } catch {
            AppDelegate.logger.warning("failed to restore closed window: \(error.localizedDescription, privacy: .public)")
            return false
        }

        let controllers = snapshot.tabs
            .filter { !$0.surfaceTree.isEmpty }
            .map { state in
                TerminalController(ghostty, with: .init(
                    frame: snapshot.frame,
                    surfaceTree: state.surfaceTree,
                    focusedSurface: state.focusedSurface.flatMap(UUID.init(uuidString:)),
                    tabIndex: nil,
                    tabColor: state.tabColor ?? .none,
                    titleOverride: state.titleOverride))
            }
        guard let first = controllers.first, let firstWindow = first.window else { return false }

        // Add each tab after the previous one to keep the original order.
        var previousWindow = firstWindow
        for controller in controllers.dropFirst() {
            guard let window = controller.window else { continue }
            previousWindow.addTabbedWindowSafely(window, ordered: .above)
            previousWindow = window
        }

        let selected = snapshot.selectedIndex.flatMap { controllers[safe: $0] } ?? first
        selected.window?.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .terminalTabSidebarNeedsReload, object: nil)
        return true
    }
}
