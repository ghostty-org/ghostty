import AppKit

/// AppKit restores each terminal window separately. Keep tab selection by
/// stable session identity, not array index or window creation order.
@MainActor
final class TerminalTabSelectionRestoration {
    static let shared = TerminalTabSelectionRestoration()
    static let codingKey = "omg.selected-terminal-tabs.v1"

    struct Group: Codable, Equatable {
        let members: [UUID]
        let selected: UUID
    }

    struct Snapshot: Codable, Equatable {
        let groups: [Group]
        let foreground: UUID?

        /// Apply only to the reconstructed group, never to an unrelated window
        /// that happens to occupy the old tab's index.
        func selection(for members: Set<UUID>) -> UUID? {
            groups.first { Set($0.members) == members && members.contains($0.selected) }?.selected
        }
    }

    private var pending: Snapshot?
    private var quittingSnapshot: Snapshot?
    private var restored = Set<UUID>()
    private var monitor: Any?
    private var generation = UUID()
    private var launchFinished = false
    private let captureSnapshot: @MainActor () -> Snapshot
    private let finishRestoring: @MainActor () -> Void

    init(
        captureSnapshot: @escaping @MainActor () -> Snapshot = {
            TerminalTabSelectionRestoration.capture(TerminalController.all, foreground: NSApp.mainWindow)
        },
        finishRestoring: @escaping @MainActor () -> Void = {
            TerminalWorkspaceCoordinator.shared.finishRestoring()
        }
    ) {
        self.captureSnapshot = captureSnapshot
        self.finishRestoring = finishRestoring
    }

    static func capture(_ controllers: [TerminalController], foreground: NSWindow?) -> Snapshot {
        var visited = Set<UUID>()
        var groups: [Group] = []
        for controller in controllers {
            guard let window = controller.window, window.isRestorable,
                  !visited.contains(controller.tabSessionID) else { continue }
            let windows = controller.workspaceTabWindows
            let members = windows.filter(\.isRestorable).compactMap {
                ($0.windowController as? TerminalController)?.tabSessionID
            }
            let state = controller.workspaceCoordinator.store.snapshot
            let record = state.windows?[controller.windowSessionID]
            let storedSelection = controller.workspaceCoordinator.store
                .group(window: controller.windowSessionID, workspace: controller.workspaceID)?.selected
            let nativeSelection: UUID? = if record?.currentWorkspace == controller.workspaceID,
                                    let selected = window.tabGroup?.selectedWindow,
                                    windows.contains(selected) {
                (selected.windowController as? TerminalController)?.tabSessionID
            } else {
                nil
            }
            let selected = nativeSelection ?? storedSelection
            guard let selected, members.contains(selected) else { continue }
            visited.formUnion(members)
            groups.append(.init(members: members, selected: selected))
        }
        let foregroundID: UUID?
        if let foreground, let controller = foreground.windowController as? TerminalController,
           controller.workspaceTabWindows.contains(foreground) {
            foregroundID = controller.tabSessionID
        } else {
            foregroundID = ((foreground?.tabGroup?.selectedWindow ?? foreground)?.windowController
                as? TerminalController)?.tabSessionID
        }
        return .init(groups: groups, foreground: foregroundID)
    }

    func prepareToQuit() {
        // Confirmation dialogs/window teardown can change AppKit's main tab.
        if quittingSnapshot == nil {
            quittingSnapshot = captureSnapshot()
        }
        NSApp.invalidateRestorableState()
    }

    func cancelQuit() {
        quittingSnapshot = nil
    }

    func encode(into coder: NSCoder) {
        let snapshot = quittingSnapshot ?? captureSnapshot()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        coder.encode(data as NSData, forKey: Self.codingKey)
    }

    func decode(from coder: NSCoder) {
        guard coder.containsValue(forKey: Self.codingKey),
              let data = coder.decodeObject(of: NSData.self, forKey: Self.codingKey) as Data?,
              data.count <= 128 * 1_024,
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        pending = snapshot
        if launchFinished { beginSelectionRestore() }
    }

    func registerRestored(_ controller: TerminalController) {
        restored.insert(controller.tabSessionID)
    }

    /// Called once after application launch, not during each window's restore
    /// callback. Late SwiftUI attachment and AppKit tab grouping get a bounded
    /// retry; actual user input cancels it rather than stealing focus back.
    func finishLaunching() {
        launchFinished = true
        beginSelectionRestore()
        if pending == nil { TerminalWorkspaceCoordinator.shared.finishRestoring() }
    }

    private func beginSelectionRestore() {
        guard pending != nil, monitor == nil else { return }
        let token = generation
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.cancel()
            return event
        }
        DispatchQueue.main.async { [weak self] in self?.apply(token: token, attempt: 0) }
    }

    private func cancel() {
        generation = UUID()
        pending = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        finishRestoring()
    }

    private func apply(token: UUID, attempt: Int) {
        guard generation == token, let pending else { return }
        let controllers = TerminalController.all.filter { restored.contains($0.tabSessionID) }
        var unresolved: [Group] = []
        for group in pending.groups {
            guard let selected = controllers.first(where: { $0.tabSessionID == group.selected }),
                  let window = selected.window else {
                unresolved.append(group)
                continue
            }
            let actual = Set(selected.workspaceTabWindows.filter(\.isRestorable).compactMap {
                ($0.windowController as? TerminalController)?.tabSessionID
            })
            guard pending.selection(for: actual) == group.selected else {
                unresolved.append(group)
                continue
            }
            guard !selected.workspaceCoordinator.store.snapshot.isParked(selected.tabSessionID) else { continue }
            if let nativeGroup = window.tabGroup, nativeGroup.windows.contains(window),
               nativeGroup.selectedWindow !== window {
                nativeGroup.selectedWindow = window
            }
            if let surface = selected.focusedSurface, surface.window === window {
                window.makeFirstResponder(surface)
            }
        }
        // Apply foreground last so parked workspace records cannot steal the
        // retained group's physical selection after the active workspace.
        if let id = pending.foreground,
           let controller = controllers.first(where: { $0.tabSessionID == id }),
           !controller.workspaceCoordinator.store.snapshot.isParked(id),
           let window = controller.window,
           controller.workspaceTabWindows.contains(window) {
            if let nativeGroup = window.tabGroup, nativeGroup.windows.contains(window),
               nativeGroup.selectedWindow !== window {
                nativeGroup.selectedWindow = window
            }
            window.makeKeyAndOrderFront(nil)
        }
        guard !unresolved.isEmpty, attempt < 40 else { cancel(); return }
        self.pending = .init(groups: unresolved, foreground: pending.foreground)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            self?.apply(token: token, attempt: attempt + 1)
        }
    }
}
