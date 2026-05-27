import Cocoa

protocol TerminalRestorable: Codable {
    static var selfKey: String { get }
    static var versionKey: String { get }
    static var version: Int { get }
    /// Minimum version that can be decoded safely
    static var minimumVersion: Int { get }
    init(copy other: Self)

    /// Returns a base configuration to use when restoring terminal surfaces.
    /// Override this to provide custom environment variables or other configuration.
    var baseConfig: Ghostty.SurfaceConfiguration? { get }
}

extension TerminalRestorable {
    static var minimumVersion: Int { version }
}

extension TerminalRestorable {
    static var selfKey: String { "state" }
    static var versionKey: String { "version" }

    private var debugDescription: String {
        withUnsafePointer(to: self) { ptr in
            "<\(ptr)>[version: \(Self.version)]"
        }
    }

    /// Default implementation returns nil (no custom base config).
    var baseConfig: Ghostty.SurfaceConfiguration? { nil }

    init?(coder aDecoder: NSCoder) {
        // If the version doesn't match then we can't decode. In the future we can perform
        // version upgrading or something but for now we only have one version so we
        // don't bother.
        let current = aDecoder.decodeInteger(forKey: Self.versionKey)
        guard current >= Self.minimumVersion else {
            AppDelegate.logger.error("error restoring terminal: version not supported: expected=\(Self.minimumVersion, privacy: .public), got=\(current, privacy: .public)")
            return nil
        }

        guard let v = aDecoder.decodeObject(of: CodableBridge<Self>.self, forKey: Self.selfKey) else {
            AppDelegate.logger.error("error restoring terminal: decode failed")
            return nil
        }

        self.init(copy: v.value)
    }

    func encode(with coder: NSCoder) {
        coder.encode(Self.version, forKey: Self.versionKey)
        coder.encode(CodableBridge(self), forKey: Self.selfKey)

        AppDelegate.logger.debug("saved terminal state: \(debugDescription, privacy: .public)")
    }
}


/// The state stored for terminal window restoration.
final class TerminalRestorableState: TerminalRestorable {
    static var version: Int { 8 }
    static var minimumVersion: Int { 5 }

    var focusedSurface: String? {
        internalState.focusedSurface
    }
    var surfaceTree: SplitTree<Ghostty.SurfaceView> {
        internalState.surfaceTree
    }
    var effectiveFullscreenMode: FullscreenMode? {
        internalState.effectiveFullscreenMode
    }
    var tabColor: TerminalTabColor? {
        internalState.tabColor
    }
    var titleOverride: String? {
        internalState.titleOverride
    }

    /// Internal State we use to perform unit tests
    ///
    /// Since we can't really change the type of `TerminalRestorableState`
    /// due to `CodableBridge<TerminalRestorableState>` supporting secure coding,
    /// we use an internal type to perform migration and tests
    private let internalState: InternalState<Ghostty.SurfaceView>

    init(from controller: TerminalController) {
        internalState = .init(from: controller)
    }

    required init(copy other: TerminalRestorableState) {
        self.internalState = other.internalState
    }

    /// This is just wrapper around internalState
    ///
    /// - Important: If you intend to add more things, go to `InternalState`.
    init(from decoder: any Decoder) throws {
        self.internalState = try InternalState<Ghostty.SurfaceView>(from: decoder)
    }

    /// This is just wrapper around internalState
    ///
    /// - Important: If you intend to add more things, go to `InternalState`.
    func encode(to encoder: any Encoder) throws {
        try internalState.encode(to: encoder)
    }
}

enum TerminalRestoreError: Error {
    case delegateInvalid
    case identifierUnknown
    case stateDecodeFailed
    case windowDidNotLoad
}

/// The NSWindowRestoration implementation that is called when a terminal window needs to be restored.
/// The encoding of a terminal window is handled elsewhere (usually NSWindowDelegate).
class TerminalWindowRestoration: NSObject, NSWindowRestoration {
    static func restoreWindow(
        withIdentifier identifier: NSUserInterfaceItemIdentifier,
        state: NSCoder,
        completionHandler: @escaping (NSWindow?, Error?) -> Void
    ) {
        // Verify the identifier is what we expect
        guard identifier == .init(String(describing: Self.self)) else {
            completionHandler(nil, TerminalRestoreError.identifierUnknown)
            return
        }

        // The app delegate is definitely setup by now. If it isn't our AppDelegate
        // then something is royally fucked up but protect against it anyhow.
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else {
            completionHandler(nil, TerminalRestoreError.delegateInvalid)
            return
        }

        // CSSH launches are one-shot command-line requests. AppKit may try to
        // restore the previous terminal windows before the app delegate creates
        // the cluster window, but those restored windows are unrelated.
        if appDelegate.isCSSHLaunch {
            AppDelegate.logger.debug("skip restoration: +cssh launch")
            completionHandler(nil, nil)
            return
        }

        // If our configuration is "never" then we never restore the state
        // no matter what. Note its safe to use "ghostty.config" directly here
        // because window restoration is only ever invoked on app start so we
        // don't have to deal with config reloads.
        if appDelegate.ghostty.config.windowSaveState == "never" {
            AppDelegate.logger.warning("skip restoration: window-save-state=never")
            completionHandler(nil, nil)
            return
        }

        // Decode the state. If we can't decode the state, then we can't restore.
        guard let state = TerminalRestorableState(coder: state) else {
            completionHandler(nil, TerminalRestoreError.stateDecodeFailed)
            return
        }

        // The window creation has to go through our terminalManager so that it
        // can be found for events from libghostty. This uses the low-level
        // createWindow so that AppKit can place the window wherever it should
        // be.
        let c = TerminalController.init(
            appDelegate.ghostty,
            withSurfaceTree: state.surfaceTree)
        guard let window = c.window else {
            completionHandler(nil, TerminalRestoreError.windowDidNotLoad)
            return
        }

        // Restore our tab color and avoid unnecessary `invalidateRestorableState` calls
        if let tabColor = state.tabColor {
            (window as? TerminalWindow)?.tabColor = tabColor
        }

        // Restore the tab title override
        c.titleOverride = state.titleOverride

        // Setup our restored state on the controller
        // Find the focused surface in surfaceTree
        if let focusedStr = state.focusedSurface {
            var foundView: Ghostty.SurfaceView?
            for view in c.surfaceTree where view.id.uuidString == focusedStr {
                foundView = view
                break
            }

            if let view = foundView {
                c.focusedSurface = view
                c.focusedSurfaceDidChange(to: view)
                restoreFocus(to: view, inWindow: window)
            }
        }

        completionHandler(window, nil)
        guard let mode = state.effectiveFullscreenMode, mode != .native else {
            // We let AppKit handle native fullscreen
            return
        }
        // Give the window to AppKit first, then adjust its frame and style
        // to minimise any visible frame changes.
        c.toggleFullscreen(mode: mode)
    }

    /// This restores the focus state of the surfaceview within the given window. When restoring,
    /// the view isn't immediately attached to the window since we have to wait for SwiftUI to
    /// catch up. Therefore, we sit in an async loop waiting for the attachment to happen.
    private static func restoreFocus(to: Ghostty.SurfaceView, inWindow: NSWindow, attempts: Int = 0) {
        // For the first attempt, we schedule it immediately. Subsequent events wait a bit
        // so we don't just spin the CPU at 100%. Give up after some period of time.
        let after: DispatchTime
        if attempts == 0 {
            after = .now()
        } else if attempts > 40 {
            // 2 seconds, give up
            return
        } else {
            after = .now() + .milliseconds(50)
        }

        DispatchQueue.main.asyncAfter(deadline: after) {
            // If the view is not attached to a window yet then we repeat.
            guard let viewWindow = to.window else {
                restoreFocus(to: to, inWindow: inWindow, attempts: attempts + 1)
                return
            }

            // If the view is attached to some other window, we give up
            guard viewWindow == inWindow else { return }

            inWindow.makeFirstResponder(to)

            // If the window is main, then we also make sure it comes forward. This
            // prevents a bug found in #1177 where sometimes on restore the windows
            // would be behind other applications.
            if viewWindow.isMainWindow {
                viewWindow.orderFront(nil)
            }
        }
    }
}

enum TerminalSessionStore {
    private static let manifestFileName = "session.json"
    private static let version = 1

    private struct Manifest: Codable {
        let version: Int
        let tabGroups: [TabGroup]

        init(tabGroups: [TabGroup]) {
            self.version = TerminalSessionStore.version
            self.tabGroups = tabGroups
        }
    }

    private struct TabGroup: Codable {
        let selectedIndex: Int?
        let tabs: [TerminalRestorableState]
    }

    static func saveCurrentSession() {
        guard let manifestURL = manifestURL() else { return }

        let tabGroups = currentTabGroups().map { controllers in
            TabGroup(
                selectedIndex: selectedIndex(in: controllers),
                tabs: controllers.map { TerminalRestorableState(from: $0) })
        }
        guard !tabGroups.isEmpty else {
            removeManifest(at: manifestURL)
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: manifestURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Manifest(tabGroups: tabGroups))
            try data.write(to: manifestURL, options: [.atomic])
        } catch {
            AppDelegate.logger.warning("failed to save terminal session: \(error)")
        }
    }

    @discardableResult
    static func restoreSession(_ ghostty: Ghostty.App) -> Bool {
        guard let manifestURL = manifestURL() else { return false }
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return false }

        do {
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            guard manifest.version == version else {
                AppDelegate.logger.warning("skip terminal session restore: unsupported version \(manifest.version)")
                return false
            }

            var restored = false
            for group in manifest.tabGroups {
                restored = restore(group, ghostty: ghostty) || restored
            }

            return restored
        } catch {
            AppDelegate.logger.warning("failed to restore terminal session: \(error)")
            return false
        }
    }

    private static func configuredDirectory() -> URL? {
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return nil }
        guard let path = appDelegate.ghostty.config.sessionHistoryDir?.path else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    private static func manifestURL() -> URL? {
        configuredDirectory()?.appendingPathComponent(manifestFileName, isDirectory: false)
    }

    private static func removeManifest(at url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            if (error as? CocoaError)?.code == .fileNoSuchFile { return }
            AppDelegate.logger.warning("failed to remove terminal session manifest: \(error)")
        }
    }

    private static func currentTabGroups() -> [[TerminalController]] {
        var result: [[TerminalController]] = []
        var seenTabGroups = Set<ObjectIdentifier>()

        for controller in TerminalController.all {
            guard let window = controller.window else { continue }
            guard window.isVisible else { continue }
            guard !controller.surfaceTree.isEmpty else { continue }

            if let tabGroup = window.tabGroup, tabGroup.windows.count > 1 {
                let tabGroupID = ObjectIdentifier(tabGroup)
                guard seenTabGroups.insert(tabGroupID).inserted else { continue }

                let controllers = tabGroup.windows.compactMap {
                    $0.windowController as? TerminalController
                }.filter {
                    $0.window?.isVisible == true && !$0.surfaceTree.isEmpty
                }

                if !controllers.isEmpty {
                    result.append(controllers)
                }
            } else {
                result.append([controller])
            }
        }

        return result
    }

    private static func selectedIndex(in controllers: [TerminalController]) -> Int? {
        controllers.firstIndex { controller in
            guard let window = controller.window else { return false }
            return window.isKeyWindow || window.tabGroup?.selectedWindow == window
        }
    }

    private static func restore(_ group: TabGroup, ghostty: Ghostty.App) -> Bool {
        let controllers = group.tabs.map { state in
            let controller = TerminalController(
                ghostty,
                withSurfaceTree: state.surfaceTree)
            apply(state, to: controller)
            return controller
        }
        guard let firstController = controllers.first else { return false }

        firstController.showWindow(nil)
        for controller in controllers.dropFirst() {
            controller.showWindow(nil)
            if let firstWindow = firstController.window,
               let newWindow = controller.window {
                firstWindow.addTabbedWindowSafely(newWindow, ordered: .above)
            }
        }

        let selectedController: TerminalController
        if let selectedIndex = group.selectedIndex,
           controllers.indices.contains(selectedIndex) {
            selectedController = controllers[selectedIndex]
        } else {
            selectedController = firstController
        }
        selectedController.window?.makeKeyAndOrderFront(nil)

        for (controller, state) in zip(controllers, group.tabs) {
            if let mode = state.effectiveFullscreenMode, mode != .native {
                controller.toggleFullscreen(mode: mode)
            }
        }

        return true
    }

    private static func apply(_ state: TerminalRestorableState, to controller: TerminalController) {
        guard let window = controller.window else { return }

        if let tabColor = state.tabColor {
            (window as? TerminalWindow)?.tabColor = tabColor
        }
        controller.titleOverride = state.titleOverride

        let focusedView = state.focusedSurface.flatMap { focusedStr in
            controller.surfaceTree.first { $0.id.uuidString == focusedStr }
        } ?? controller.surfaceTree.first

        if let focusedView {
            controller.focusedSurface = focusedView
            controller.focusedSurfaceDidChange(to: focusedView)
            restoreFocus(to: focusedView, inWindow: window)
        }
    }

    private static func restoreFocus(
        to surfaceView: Ghostty.SurfaceView,
        inWindow window: NSWindow,
        attempts: Int = 0
    ) {
        let after: DispatchTime
        if attempts == 0 {
            after = .now()
        } else if attempts > 40 {
            return
        } else {
            after = .now() + .milliseconds(50)
        }

        DispatchQueue.main.asyncAfter(deadline: after) {
            guard let viewWindow = surfaceView.window else {
                restoreFocus(to: surfaceView, inWindow: window, attempts: attempts + 1)
                return
            }

            guard viewWindow == window else { return }
            window.makeFirstResponder(surfaceView)
        }
    }
}
