import Foundation
import Cocoa
import Darwin
import SwiftUI
import Combine
import GhosttyKit
import ObjectiveC

/// Resolves transaction identities without retaining a controller or window.
struct VerticalTabStableResolver {
    static func resolve<Value>(
        sessionIDs: [UUID],
        in values: [Value],
        sessionID: (Value) -> UUID
    ) -> [Value]? {
        var resolved: [Value] = []
        for expectedID in sessionIDs {
            let matches = values.filter { sessionID($0) == expectedID }
            guard matches.count == 1, let match = matches.first else { return nil }
            resolved.append(match)
        }
        return resolved
    }
}

/// Stable identities needed to execute either side of a pane move.
struct VerticalTabMoveTransactionDescriptor: Equatable {
    let sourceTabSessionID: UUID
    let sourceSurfaceID: UUID
    let destinationTabSessionID: UUID
    let placement: VerticalTabDropPolicy.Placement
    var movedTabSessionID: UUID?

    var redoSessionIDs: [UUID] {
        [sourceTabSessionID, destinationTabSessionID]
    }

    var undoSessionIDs: [UUID]? {
        guard let movedTabSessionID else { return nil }
        return [sourceTabSessionID, destinationTabSessionID, movedTabSessionID]
    }
}

/// Canonical per-surface state that can safely change controller ownership.
/// Observer subscriptions and delayed validation work are intentionally absent;
/// the receiving controller creates those again from this value state.
struct PaneSessionStateSnapshot {
    let context: PaneSessionContext
    let activity: TabActivity?
    let resumeDescriptor: AgentResumeDescriptor?
    let resumeContextID: String?
    let reducer: AgentContextSignalReducer?
    let typedHookContextID: String?
    let observedForegroundProcessID: Int?
    let detectedAgent: PaneDetectedAgentState?
    let screenSignature: Int?
    let screenStableTicks: Int?
    let quickInputState: AgentQuickInputPaneState?
}

struct PaneDetectedAgentState {
    let id: String
    let processGroupID: Int
    let agent: SupportedAgent
    let launchedAt: Date
}

/// Native tab membership and layout captured before a pane-to-tab transaction.
/// All membership is represented by stable tab session IDs so close-window undo
/// may recreate the controllers without invalidating this snapshot.
@MainActor
struct VerticalTabWindowGroupSnapshot {
    struct Restoration {
        let controller: TerminalController
        let group: NSWindowTabGroup?
        let memberControllers: [TerminalController]
        let selectedWindow: NSWindow?
    }

    let memberSessionIDs: [UUID]
    let index: Int
    let selectedSessionID: UUID
    let layoutState: VerticalTabWindowLayoutState

    init(controller: TerminalController) {
        let window = controller.window
        if let group = window?.tabGroup,
           group.windows.count > 1,
           let window,
           let index = group.windows.firstIndex(of: window) {
            let members = group.windows.compactMap {
                $0.windowController as? TerminalController
            }
            self.memberSessionIDs = members.map(\.tabSessionID)
            self.index = index
            self.selectedSessionID = (group.selectedWindow?.windowController as? TerminalController)?
                .tabSessionID ?? controller.tabSessionID
        } else {
            self.memberSessionIDs = []
            self.index = 0
            self.selectedSessionID = controller.tabSessionID
        }
        self.layoutState = controller.tabLayoutState
    }

    /// Preflight every controller, window, and original group before mutation.
    func resolveRestoration(
        of controller: TerminalController,
        in controllers: [TerminalController]
    ) -> Restoration? {
        let expectedControllerID: UUID
        if memberSessionIDs.isEmpty {
            expectedControllerID = selectedSessionID
        } else {
            guard memberSessionIDs.indices.contains(index) else { return nil }
            expectedControllerID = memberSessionIDs[index]
        }
        guard controller.tabSessionID == expectedControllerID,
              controller.window != nil else { return nil }

        guard !memberSessionIDs.isEmpty else {
            return .init(
                controller: controller,
                group: nil,
                memberControllers: [controller],
                selectedWindow: controller.window
            )
        }
        guard let members = VerticalTabStableResolver.resolve(
                  sessionIDs: memberSessionIDs,
                  in: controllers,
                  sessionID: \.tabSessionID
              ),
              let selected = members.first(where: {
                  $0.tabSessionID == selectedSessionID
              }),
              let selectedWindow = selected.window,
              let anchor = members.first(where: { $0 !== controller }),
              let group = anchor.window?.tabGroup else { return nil }
        for member in members where member !== controller {
            guard let window = member.window,
                  window.tabGroup === group,
                  group.windows.contains(window) else { return nil }
        }
        return .init(
            controller: controller,
            group: group,
            memberControllers: members,
            selectedWindow: selectedWindow
        )
    }

    /// Restores membership, exact ordering, selection, and the original shared
    /// (or standalone) window layout state.
    func restore(_ restoration: Restoration) -> Bool {
        guard let window = restoration.controller.window else { return false }
        if let group = restoration.group {
            if window.tabGroup !== group || !group.windows.contains(window) {
                window.tabGroup?.removeWindow(window)
                guard let anchor = restoration.memberControllers
                    .first(where: { $0 !== restoration.controller })?.window,
                      anchor.addTabbedWindowSafely(window, ordered: .above),
                      window.tabGroup === group,
                      group.windows.contains(window) else { return false }
            }
            guard group.windows.indices.contains(index) else { return false }
            if group.windows[index] !== window {
                group.removeWindow(window)
                group.insertWindow(window, at: index)
            }
            group.setGhosttyTerminalShellLayoutState(layoutState)
            for controller in restoration.memberControllers {
                controller.tabLayoutState = layoutState
            }
            guard let selectedWindow = restoration.selectedWindow,
                  group.windows.contains(selectedWindow) else { return false }
            group.selectedWindow = selectedWindow
            return window.tabGroup === group &&
                group.windows.indices.contains(index) &&
                group.windows[index] === window &&
                group.selectedWindow === selectedWindow
        }

        if let currentGroup = window.tabGroup, currentGroup.windows.count > 1 {
            currentGroup.removeWindow(window)
        }
        window.tabGroup?.setGhosttyTerminalShellLayoutState(layoutState)
        restoration.controller.tabLayoutState = layoutState
        guard let standaloneGroup = window.tabGroup else { return true }
        return standaloneGroup.windows.count == 1 &&
            standaloneGroup.windows.first === window
    }
}

/// A classic, tabbed terminal experience.
class TerminalController: BaseTerminalController, TabGroupCloseCoordinator.Controller {
    let tabLayout: Ghostty.Config.MacOSTabLayout

    override var supportsSidebar: Bool {
        tabLayout == .vertical
    }

    override var activitySessionID: UUID? { tabSessionID }

    var sidebarIsShowing: Bool { tabLayoutState.isSidebarVisible }
    var sidebarWidth: CGFloat { tabLayoutState.sidebarWidth }

    override var windowNibName: NSNib.Name? {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return "Terminal" }
        let config = appDelegate.ghostty.config
        guard config.windowDecorations else { return "Terminal" }
        guard tabLayout == .horizontal else { return "TerminalVerticalTabs" }

        return switch config.macosTitlebarStyle {
        case .native: "Terminal"
        case .hidden: "TerminalHiddenTitlebar"
        case .transparent: "TerminalTransparentTitlebar"
        case .tabs:
#if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                "TerminalTabsTitlebarTahoe"
            } else {
                "TerminalTabsTitlebarVentura"
            }
#else
            "TerminalTabsTitlebarVentura"
#endif
        }
    }

    /// This is set to true when we care about frame changes. This is a small optimization since
    /// this controller registers a listener for ALL frame change notifications and this lets us bail
    /// early if we don't care.
    private var tabListenForFrame: Bool = false

    /// This is the hash value of the last tabGroup.windows array. We use this to detect order
    /// changes in the list.
    private var tabWindowsHash: Int = 0

    /// The initial window presentation is deferred by one runloop turn in a few places so
    /// AppKit can settle tab/window state first. Close actions must cancel it to avoid
    /// re-showing a tab that was already closed.
    private var pendingInitialPresentation: DispatchWorkItem?

    /// Recently-used ordering must never mutate NSWindowTabGroup from inside
    /// AppKit's selectedWindow/becomeKey stack. Coalesce it onto the next
    /// runloop turn after selection has settled.
    private var pendingTabOrganizationWorkItem: DispatchWorkItem?

    /// This is set to false by init if the window managed by this controller should not be restorable.
    /// For example, terminals executing custom scripts are not restorable.
    private var restorable: Bool = true

    /// The configuration derived from the Ghostty config so we don't need to rely on references.
    private(set) var derivedConfig: DerivedConfig

    /// The notification cancellable for focused surface property changes.
    private var surfaceAppearanceCancellables: Set<AnyCancellable> = []

    let tabSessionID: UUID
    let tabCreatedAt: Date
    @Published private(set) var tabLastActivatedAt: Date

    /// The real AppKit tabs in this controller's tab group, in display order.
    @Published private(set) var tabControllers: [TerminalController] = []

    /// The selected tab controller identity.
    @Published private(set) var selectedTabID: ObjectIdentifier?

    /// The tab currently under the pointer. This is independent from selection.
    @Published private(set) var hoveredTabID: ObjectIdentifier?

    /// Actual background used by the focused terminal, including runtime color changes.
    @Published private(set) var terminalBackgroundColor: Color

    /// Background opacity used by terminal-adjacent app shell chrome.
    /// The terminal renderer applies this independently to preserve opaque glyphs.
    @Published private(set) var terminalBackgroundOpacity: Double

    /// The background color app shell chrome (sidebars, quick input, etc.)
    /// should paint with, with the effective opacity already applied.
    ///
    /// While the window is transparent (windowed mode with
    /// `background-opacity < 1`) this is the terminal background at the
    /// configured opacity so the chrome blends with the desktop exactly like
    /// the terminal surface. When the window is opaque (native fullscreen,
    /// or the user toggled opaque backgrounds), the terminal renderer's
    /// semi-transparent background composited over the opaque same-colored
    /// window background produces exactly the opaque background color. The
    /// chrome must paint that same opaque color: a second semi-transparent
    /// SwiftUI layer composited by Core Animation over the opaque window
    /// does not match the terminal's renderer-side (P3, linear blending)
    /// compositing and shows a visible color difference in fullscreen.
    ///
    /// See: https://github.com/jischeng/oh-my-ghostty/issues/15
    @Published private(set) var terminalChromeBackground: Color

    /// Opaque semantic separator derived from the current terminal background.
    @Published private(set) var sidebarDividerColor: Color

    /// Canonical pane session state. Tab title/icon and Inspector/Files all
    /// consume this map rather than independently inferring SSH from titles.
    private(set) var paneSessionContexts: [UUID: PaneSessionContext] = [:] {
        willSet {
            guard newValue.count != paneSessionContexts.count || newValue.contains(where: { id, context in
                paneSessionContexts[id].map { !context.hasSameLocation(as: $0) } ?? true
            }) else { return }
            objectWillChange.send()
        }
    }
    @Published private(set) var agentActivities: [UUID: TabActivity] = [:]
    @Published private(set) var agentResumeDescriptors: [UUID: AgentResumeDescriptor] = [:]
    let quickInputModel = AgentQuickInputModel()
    private var quickInputEventMonitor: Any?
    private var quickInputSecureInputCancellable: AnyCancellable?
    private var quickInputLastTerminalSurfaceID: UUID?
    private var quickInputResizeDeferralWorkItem: DispatchWorkItem?
    private weak var quickInputResizeDeferralWindow: NSWindow?
    private var quickInputResizeDeferralActive = false
    private var agentResumeContextIDs: [UUID: String] = [:]
    private var paneSessionObservers: [UUID: Set<AnyCancellable>] = [:]
    private var agentReducers: [UUID: AgentContextSignalReducer] = [:]
    private var typedAgentHookContextIDs: [UUID: String] = [:]
    private var agentValidationWorkItems: [UUID: DispatchWorkItem] = [:]

    private var agentProcessPollCancellable: AnyCancellable?
    private var observedForegroundProcessIDs: [UUID: Int] = [:]
    private var observedSSHReconnectProcessIDs: [UUID: Int] = [:]
    private var detectedSSHReconnectProcessIDs: [UUID: Int] = [:]
    private var detectedAgentInstances: [UUID: PaneDetectedAgentState] = [:]
    private var conversationDiscoveryPending = Set<UUID>()
    private var agentScreenSignatures: [UUID: Int] = [:]
    private var agentScreenStableTicks: [UUID: Int] = [:]

    var focusedPaneSessionContext: PaneSessionContext? {
        paneSessionContext(for: focusedSurface ?? surfaceTree.first)
    }

    /// Generic workspace metadata resolved from the canonical focused session.
    var workspaceDescriptor: WorkspaceDescriptor? {
        focusedPaneSessionContext?.workspace
    }

    func agentActivity(for surface: Ghostty.SurfaceView?) -> TabActivity? {
        guard let surface else { return nil }
        return agentActivities[surface.id]
    }

    func agentResumeDescriptor(
        for surface: Ghostty.SurfaceView?
    ) -> AgentResumeDescriptor? {
        guard let surface else { return nil }
        return agentResumeDescriptors[surface.id]
    }

    /// Adopts a host-validated descriptor for a Surface created by an explicit
    /// Agent History resume action, before the resumed Agent emits its hook.
    func adoptAgentResumeDescriptor(
        _ descriptor: AgentResumeDescriptor,
        for surface: Ghostty.SurfaceView
    ) {
        guard descriptor.isValid, surfaceTree.contains(surface) else { return }
        agentResumeDescriptors[surface.id] = descriptor
        surface.agentResumeDescriptor = descriptor
        enableRestorationForAgentSession()
        invalidateRestorableState()
    }

    func focusedAgentActivity() -> TabActivity? {
        agentActivity(for: focusedSurface ?? surfaceTree.first)
    }

    func preferredAgentActivity() -> TabActivity? {
        let focusedID = focusedSurface?.id
        return AgentActivitySelection.preferred(surfaceTree.compactMap { surface in
            guard let activity = agentActivities[surface.id] else { return nil }
            return AgentActivityCandidate(
                activity: activity,
                isFocused: surface.id == focusedID
            )
        })
    }

    func toggleQuickInput() {
        if quickInputModel.isPresented {
            dismissQuickInput()
            return
        }
        guard let surface = focusedSurface ?? surfaceTree.first else { return }
        presentQuickInput(for: surface, requestFocus: true)
    }

    private func presentQuickInput(
        for surface: Ghostty.SurfaceView,
        requestFocus: Bool
    ) {
        beginQuickInputResizeDeferral()
        quickInputLastTerminalSurfaceID = surface.id
        quickInputModel.present(for: surface.id, requestFocus: requestFocus)
        if requestFocus { _ = surface.resignFirstResponder() }
    }

    func sendQuickInputDraft() {
        guard let surfaceID = quickInputModel.targetSurfaceID else { return }
        if quickInputModel.isEditingQueuedItem {
            guard quickInputModel.confirmQueuedItemEdit(moveToEnd: false) else {
                return
            }
            restoreTerminalFocus(surfaceID: surfaceID)
            return
        }
        let text = quickInputModel.draft
        guard submitQuickInputText(text, to: surfaceID, restoreFocus: true) else {
            return
        }
        beginQuickInputResizeDeferral()
        quickInputModel.dismiss(preservingDraft: false)
    }

    func queueQuickInputDraft() {
        guard let surfaceID = quickInputModel.targetSurfaceID else { return }
        if quickInputModel.isEditingQueuedItem {
            guard quickInputModel.confirmQueuedItemEdit(moveToEnd: true) else {
                return
            }
            restoreTerminalFocus(surfaceID: surfaceID)
            return
        }
        beginQuickInputResizeDeferral()
        guard quickInputModel.enqueueDraft() != nil else { return }
        quickInputModel.dismiss()
        if agentActivities[surfaceID]?.state == .done {
            dispatchNextQuickInput(for: surfaceID)
        }
        restoreTerminalFocus(surfaceID: surfaceID)
    }

    func dismissQuickInput() {
        let surfaceID = quickInputModel.targetSurfaceID
        beginQuickInputResizeDeferral()
        quickInputModel.dismiss()
        restoreTerminalFocus(surfaceID: surfaceID)
    }

    private func beginQuickInputResizeDeferral() {
        guard let window else { return }
        quickInputResizeDeferralWorkItem?.cancel()
        if !quickInputResizeDeferralActive {
            quickInputResizeDeferralActive = true
            quickInputResizeDeferralWindow = window
            TerminalSurfaceResizeInteraction.begin(in: window)
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.endQuickInputResizeDeferral()
        }
        quickInputResizeDeferralWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + AgentQuickInputMotion.terminalResizeDeferralDuration,
            execute: workItem
        )
    }

    private func endQuickInputResizeDeferral() {
        quickInputResizeDeferralWorkItem?.cancel()
        quickInputResizeDeferralWorkItem = nil
        guard quickInputResizeDeferralActive else { return }
        let window = quickInputResizeDeferralWindow
        quickInputResizeDeferralWindow = nil
        quickInputResizeDeferralActive = false
        TerminalSurfaceResizeInteraction.end(in: window)
    }

    func sendQueuedQuickInput(_ itemID: UUID, from surfaceID: UUID) {
        guard let item = quickInputModel.state(for: surfaceID)?.queue
            .first(where: { $0.id == itemID }),
              submitQuickInputText(item.text, to: surfaceID, restoreFocus: false) else {
            return
        }
        beginQuickInputResizeDeferral()
        quickInputModel.removeQueuedItem(itemID, for: surfaceID)
    }

    func editQueuedQuickInput(_ itemID: UUID, from surfaceID: UUID) {
        beginQuickInputResizeDeferral()
        quickInputModel.editQueuedItem(itemID, for: surfaceID)
    }

    func removeQueuedQuickInput(_ itemID: UUID, from surfaceID: UUID) {
        beginQuickInputResizeDeferral()
        quickInputModel.removeQueuedItem(itemID, for: surfaceID)
    }

    private func handleQuickInputKeyEvent(_ event: NSEvent) -> NSEvent? {
        let eventController = event.window?.windowController as? TerminalController
        guard eventController === self ||
                (event.window == nil && NSApp.keyWindow?.windowController === self) else {
            return event
        }

        let shortcut = OMGKeyboardShortcut(
            storageValue: OhMyGhosttySettings.shared.quickInputShortcut
        ) ?? .defaultQuickInput
        if shortcut.matches(event) {
            toggleQuickInput()
            return nil
        }

        guard quickInputModel.isPresented,
              let direction = AgentQuickInputFocusDirection.resolve(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags
              ) else {
            return event
        }

        if window?.firstResponder is ComposerTextView {
            switch direction {
            case .up:
                restoreTerminalFocus(
                    surfaceID: quickInputLastTerminalSurfaceID ??
                        quickInputModel.targetSurfaceID
                )
            case .left, .right:
                focusSplitFromQuickInput(direction: direction)
            case .down:
                break
            }
            return nil
        }

        guard direction == .down,
              let surface = focusedSurface ?? surfaceTree.first,
              !hasSplitFocusTarget(from: surface, direction: .down) else {
            return event
        }
        quickInputLastTerminalSurfaceID = surface.id
        quickInputModel.requestFocus()
        _ = surface.resignFirstResponder()
        return nil
    }

    private func hasSplitFocusTarget(
        from surface: Ghostty.SurfaceView,
        direction: Ghostty.SplitFocusDirection
    ) -> Bool {
        guard let node = surfaceTree.root?.node(view: surface) else { return false }
        return surfaceTree.focusTarget(
            for: direction.toSplitTreeFocusDirection(),
            from: node
        ) != nil
    }

    private func focusSplitFromQuickInput(
        direction: AgentQuickInputFocusDirection
    ) {
        guard let anchorID = quickInputLastTerminalSurfaceID ??
                quickInputModel.targetSurfaceID,
              let anchor = surfaceTree.first(where: { $0.id == anchorID }),
              hasSplitFocusTarget(
                from: anchor,
                direction: direction.splitDirection
              ) else {
            return
        }
        NotificationCenter.default.post(
            name: Ghostty.Notification.ghosttyFocusSplit,
            object: anchor,
            userInfo: [
                Ghostty.Notification.SplitDirectionKey: direction.splitDirection as Any,
            ]
        )
        quickInputLastTerminalSurfaceID = focusedSurface?.id ?? anchorID
    }

    @discardableResult
    private func submitQuickInputText(
        _ text: String,
        to surfaceID: UUID,
        restoreFocus: Bool
    ) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            quickInputModel.setStatusMessage("Enter a message first.")
            return false
        }
        guard text.utf8.count <= PluginProtocolContract.maximumFrameLength else {
            quickInputModel.setStatusMessage("Message exceeds the 1 MiB limit.")
            return false
        }
        guard !SecureInput.shared.enabled else {
            quickInputModel.setStatusMessage("Paused while Secure Input is enabled.")
            return false
        }
        guard let surface = surfaceTree.first(where: { $0.id == surfaceID }),
              let terminal = surface.surfaceModel else {
            quickInputModel.setStatusMessage("The target terminal is no longer available.")
            quickInputModel.removeState(for: surfaceID)
            return false
        }

        terminal.sendText(text)
        terminal.sendKeyEvent(.init(key: .enter))
        acknowledgeTerminalAgentState(for: surface)
        quickInputModel.setStatusMessage(nil)
        if restoreFocus {
            restoreTerminalFocus(surfaceID: surfaceID)
        }
        return true
    }

    private func restoreTerminalFocus(surfaceID: UUID?) {
        guard let surfaceID,
              let surface = surfaceTree.first(where: { $0.id == surfaceID }) else {
            return
        }
        DispatchQueue.main.async { [weak self, weak surface] in
            guard let self, let surface, self.window?.isKeyWindow == true else { return }
            self.window?.makeFirstResponder(surface)
        }
    }

    private func dispatchNextQuickInput(for surfaceID: UUID) {
        guard agentActivities[surfaceID]?.state == .done,
              let item = quickInputModel.state(for: surfaceID)?.queue.first,
              submitQuickInputText(item.text, to: surfaceID, restoreFocus: false) else {
            return
        }
        beginQuickInputResizeDeferral()
        _ = quickInputModel.dequeue(for: surfaceID)
    }

    private func dispatchCompletedQuickInputQueues() {
        for (surfaceID, activity) in agentActivities where activity.state == .done {
            dispatchNextQuickInput(for: surfaceID)
        }
    }

    func resolveImagePastePath(
        for localFile: URL,
        surfaceID: UUID,
        reportFailure: Bool = false,
        completion: @escaping (String) -> Void
    ) {
        let localPath = Ghostty.Shell.escape(localFile.path)
        guard let context = paneSessionContexts[surfaceID],
              case .sshReady(let ssh, _) = context.state else {
            completion(localPath)
            return
        }

        Task { @MainActor [weak self] in
            do {
                let remotePath = try await SSHImagePasteTransfer.upload(
                    localFile: localFile,
                    to: ssh
                )
                completion(remotePath)
            } catch {
                if reportFailure {
                    self?.quickInputModel.setStatusMessage(
                        "Could not upload image to \(ssh.alias); pasted the local path."
                    )
                }
                completion(localPath)
            }
        }
    }

    func paneSessionContext(
        for surface: Ghostty.SurfaceView?
    ) -> PaneSessionContext? {
        guard let surface else { return nil }
        return paneSessionContexts[surface.id] ?? .init(
            workingDirectory: surface.pwd,
            terminalTitle: surface.title
        )
    }
    private weak var observedVerticalTabGroup: NSWindowTabGroup?
    private var verticalTabWindowsObservation: NSKeyValueObservation?
    private var verticalTabSelectionObservation: NSKeyValueObservation?

    init(_ ghostty: Ghostty.App,
         withBaseConfig base: Ghostty.SurfaceConfiguration? = nil,
         withSurfaceTree tree: SplitTree<Ghostty.SurfaceView>? = nil,
         parent: NSWindow? = nil,
         tabLayout: Ghostty.Config.MacOSTabLayout? = nil,
         tabSessionID: UUID? = nil,
         tabCreatedAt: Date? = nil
    ) {
        // The window we manage is not restorable if we've specified a command
        // to execute. We do this because the restored window is meaningless at the
        // time of writing this: it'd just restore to a shell in the same directory
        // as the script. We may want to revisit this behavior when we have scrollback
        // restoration.
        self.restorable = (base?.command ?? "") == ""

        // Setup our initial derived config based on the current app config
        self.derivedConfig = DerivedConfig(ghostty.config)
        let initialBackgroundColor = ghostty.config.backgroundColor
        self.terminalBackgroundColor = initialBackgroundColor
        self.terminalBackgroundOpacity = ghostty.config.backgroundOpacity
        self.terminalChromeBackground = Self.chromeBackground(
            color: initialBackgroundColor,
            opacity: ghostty.config.backgroundOpacity,
            windowIsOpaque: false
        )
        self.sidebarDividerColor = ghostty.config.splitDividerColor(
            for: initialBackgroundColor
        )
        self.tabLayout = tabLayout ?? OhMyGhosttySettings.shared.tabLayout
        self.tabSessionID = tabSessionID ?? UUID()
        let now = Date()
        self.tabCreatedAt = tabCreatedAt ?? now
        self.tabLastActivatedAt = now

        let sessionBase = tree == nil
            ? Self.injectingSessionID(self.tabSessionID, into: base)
            : base
        let initialLayoutState = VerticalTabWindowLayoutState(
            isSidebarVisible: self.tabLayout == .vertical &&
                OhMyGhosttySettings.shared.sidebarVisible,
            isInspectorVisible: false
        )

        super.init(
            ghostty,
            baseConfig: sessionBase,
            surfaceTree: tree,
            tabLayoutState: initialLayoutState
        )
        (NSApp.delegate as? AppDelegate)?.inspectorRegistry.openTab(self.tabSessionID)

        // Setup our notifications for behaviors
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(onToggleFullscreen),
            name: Ghostty.Notification.ghosttyToggleFullscreen,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onMoveTab),
            name: .ghosttyMoveTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onOhMyGhosttySettingsChanged),
            name: OhMyGhosttySettings.didChangeNotification,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onAgentIntegrationChanged),
            name: AgentHookInstaller.didChangeNotification,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onGotoTab),
            name: Ghostty.Notification.ghosttyGotoTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onCloseTab),
            name: .ghosttyCloseTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onCloseOtherTabs),
            name: .ghosttyCloseOtherTabs,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onCloseTabsOnTheRight),
            name: .ghosttyCloseTabsOnTheRight,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onResetWindowSize),
            name: .ghosttyResetWindowSize,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(ghosttyConfigDidChange(_:)),
            name: .ghosttyConfigDidChange,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(onFrameDidChange),
            name: NSView.frameDidChangeNotification,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onCloseWindow),
            name: .ghosttyCloseWindow,
            object: nil
        )
        quickInputEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown]
        ) { [weak self] event in
            self?.handleQuickInputKeyEvent(event) ?? event
        }
        quickInputSecureInputCancellable = SecureInput.shared.$enabled
            .dropFirst()
            .filter { !$0 }
            .sink { [weak self] _ in
                self?.dispatchCompletedQuickInputQueues()
            }
        synchronizePaneSessionContexts()
        startAgentProcessPolling()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    deinit {
        verticalTabWindowsObservation?.invalidate()
        verticalTabSelectionObservation?.invalidate()
        agentProcessPollCancellable?.cancel()
        pendingTabOrganizationWorkItem?.cancel()
        quickInputSecureInputCancellable?.cancel()
        endQuickInputResizeDeferral()
        if let quickInputEventMonitor {
            NSEvent.removeMonitor(quickInputEventMonitor)
        }

        // Remove all of our notificationcenter subscriptions
        let center = NotificationCenter.default
        center.removeObserver(self)
    }

    private func cancelPendingInitialPresentation() {
        pendingInitialPresentation?.cancel()
        pendingInitialPresentation = nil
    }

    private func scheduleInitialPresentation(_ block: @escaping () -> Void) {
        cancelPendingInitialPresentation()

        var scheduledWorkItem: DispatchWorkItem?
        scheduledWorkItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            defer { self.pendingInitialPresentation = nil }
            guard pendingInitialPresentation?.isCancelled == false else { return }
            block()
        }

        let workItem = scheduledWorkItem!
        pendingInitialPresentation = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    static func injectingSessionID(
        _ sessionID: UUID,
        into base: Ghostty.SurfaceConfiguration?
    ) -> Ghostty.SurfaceConfiguration {
        var configuration = base ?? Ghostty.SurfaceConfiguration()
        configuration.environmentVariables["OH_MY_GHOSTTY_SESSION"] = sessionID.uuidString
        configuration.environmentVariables["OH_MY_GHOSTTY_CHANNEL"] =
            OMGApplicationEnvironment.channel()
        return configuration
    }

    func capturePaneSessionState(
        for surfaceID: UUID
    ) -> PaneSessionStateSnapshot? {
        guard let context = paneSessionContexts[surfaceID] else { return nil }
        return .init(
            context: context,
            activity: agentActivities[surfaceID],
            resumeDescriptor: agentResumeDescriptors[surfaceID],
            resumeContextID: agentResumeContextIDs[surfaceID],
            reducer: agentReducers[surfaceID],
            typedHookContextID: typedAgentHookContextIDs[surfaceID],
            observedForegroundProcessID: observedForegroundProcessIDs[surfaceID],
            detectedAgent: detectedAgentInstances[surfaceID],
            screenSignature: agentScreenSignatures[surfaceID],
            screenStableTicks: agentScreenStableTicks[surfaceID],
            quickInputState: quickInputModel.state(for: surfaceID)
        )
    }

    /// Installs canonical values after the surface has changed owner. Existing
    /// target observers remain local to this controller; validation work is
    /// cancelled and recreated from the transferred reducer state.
    func restorePaneSessionState(
        _ snapshot: PaneSessionStateSnapshot,
        for surfaceID: UUID
    ) {
        guard surfaceTree.contains(where: { $0.id == surfaceID }) else { return }
        agentValidationWorkItems.removeValue(forKey: surfaceID)?.cancel()
        paneSessionContexts[surfaceID] = snapshot.context
        if let activity = snapshot.activity {
            agentActivities[surfaceID] = activity
        } else {
            agentActivities.removeValue(forKey: surfaceID)
        }
        if let descriptor = snapshot.resumeDescriptor {
            agentResumeDescriptors[surfaceID] = descriptor
        } else {
            agentResumeDescriptors.removeValue(forKey: surfaceID)
        }
        surfaceTree.first(where: { $0.id == surfaceID })?
            .agentResumeDescriptor = snapshot.resumeDescriptor
        agentResumeContextIDs[surfaceID] = snapshot.resumeContextID
        agentReducers[surfaceID] = snapshot.reducer
        typedAgentHookContextIDs[surfaceID] = snapshot.typedHookContextID
        observedForegroundProcessIDs[surfaceID] = snapshot.observedForegroundProcessID
        detectedAgentInstances[surfaceID] = snapshot.detectedAgent
        agentScreenSignatures[surfaceID] = snapshot.screenSignature
        agentScreenStableTicks[surfaceID] = snapshot.screenStableTicks
        quickInputModel.restore(snapshot.quickInputState, for: surfaceID)
        if snapshot.reducer?.requiresForegroundValidation == true {
            scheduleAgentValidation(for: surfaceID)
        }
        if let detected = snapshot.detectedAgent,
           let descriptor = snapshot.resumeDescriptor,
           descriptor.scope == .local,
           descriptor.conversationID == nil,
           descriptor.agent == detected.agent {
            scheduleConversationDiscovery(
                agent: detected.agent,
                surfaceID: surfaceID,
                processGroupID: detected.processGroupID,
                launchedAt: detected.launchedAt
            )
        }
        objectWillChange.send()
        refreshPresentedTerminalTitle()
    }

    private func synchronizePaneSessionContexts() {
        let previousContexts = paneSessionContexts
        let surfaces = surfaceTree.map { $0 }
        let activeIDs = Set(surfaces.map(\.id))
        paneSessionObservers = paneSessionObservers.filter { activeIDs.contains($0.key) }
        paneSessionContexts = paneSessionContexts.filter { activeIDs.contains($0.key) }
        agentActivities = agentActivities.filter { activeIDs.contains($0.key) }
        agentResumeDescriptors = agentResumeDescriptors.filter {
            activeIDs.contains($0.key)
        }
        agentResumeContextIDs = agentResumeContextIDs.filter {
            activeIDs.contains($0.key)
        }
        agentReducers = agentReducers.filter { activeIDs.contains($0.key) }
        typedAgentHookContextIDs = typedAgentHookContextIDs.filter {
            activeIDs.contains($0.key)
        }
        observedForegroundProcessIDs = observedForegroundProcessIDs.filter {
            activeIDs.contains($0.key)
        }
        observedSSHReconnectProcessIDs = observedSSHReconnectProcessIDs.filter {
            activeIDs.contains($0.key)
        }
        detectedSSHReconnectProcessIDs = detectedSSHReconnectProcessIDs.filter {
            activeIDs.contains($0.key)
        }
        detectedAgentInstances = detectedAgentInstances.filter {
            activeIDs.contains($0.key)
        }
        conversationDiscoveryPending.formIntersection(activeIDs)
        agentScreenSignatures = agentScreenSignatures.filter {
            activeIDs.contains($0.key)
        }
        agentScreenStableTicks = agentScreenStableTicks.filter {
            activeIDs.contains($0.key)
        }
        for surfaceID in quickInputModel.paneStates.keys
        where !activeIDs.contains(surfaceID) {
            quickInputModel.removeState(for: surfaceID)
        }
        for (surfaceID, workItem) in agentValidationWorkItems
        where !activeIDs.contains(surfaceID) {
            workItem.cancel()
        }
        agentValidationWorkItems = agentValidationWorkItems.filter {
            activeIDs.contains($0.key)
        }

        for surface in surfaces where paneSessionObservers[surface.id] == nil {
            paneSessionContexts[surface.id] = .init(
                workingDirectory: surface.pwd,
                terminalTitle: surface.title
            )
            if let descriptor = surface.agentResumeDescriptor,
               descriptor.isValid {
                agentResumeDescriptors[surface.id] = descriptor
            }
            var observers: Set<AnyCancellable> = []

            Publishers.CombineLatest(surface.$pwd, surface.$title)
                .dropFirst()
                .sink { [weak self, weak surface] pwd, title in
                    guard let self, let surface else { return }
                    var context = paneSessionContexts[surface.id] ?? .init(
                        workingDirectory: pwd,
                        terminalTitle: title
                    )
                    context.updateLocalMetadata(
                        workingDirectory: pwd,
                        terminalTitle: title
                    )
                    updatePaneSessionContext(context, for: surface.id)
                    updateAgentTitleActivity(title, for: surface.id)
                }
                .store(in: &observers)

            surface.$contextSignal
                .compactMap { $0 }
                .sink { [weak self, weak surface] signal in
                    guard let self, let surface else { return }
                    var context = paneSessionContexts[surface.id] ?? .init(
                        workingDirectory: surface.pwd,
                        terminalTitle: surface.title
                    )
                    let wasSSHSession = context.isSSHSession
                    let sshReplay: SSHReplayDescriptor? = if signal.action == .start,
                       signal.id.hasPrefix("omg-ssh-") {
                        SSHReplayStore.load(connectionID: signal.id)
                    } else {
                        nil
                    }
                    context.apply(
                        signal,
                        currentWorkingDirectory: surface.pwd,
                        currentTerminalTitle: surface.title,
                        sshReplay: sshReplay
                    )
                    if let session = AgentContextSignalReducer.sessionSignal(from: signal),
                       session.scope == .remote,
                       let workingDirectory = session.workingDirectory {
                        context.applyInferredRemoteWorkingDirectory(workingDirectory)
                    }
                    let didEndSSHSession = wasSSHSession && !context.isSSHSession
                    updatePaneSessionContext(context, for: surface.id)
                    updateSSHResumeDescriptor(context, for: surface.id)
                    registerTypedAgentHookSignal(signal, for: surface.id)
                    updateAgentActivity(signal, for: surface.id)
                    if didEndSSHSession {
                        clearRemoteAgentState(for: surface.id)
                    }
                }
                .store(in: &observers)

            paneSessionObservers[surface.id] = observers
        }
        if paneSessionContexts != previousContexts {
            NotificationCenter.default.post(
                name: .terminalPaneSessionContextsDidChange,
                object: self
            )
        }
    }

    private func startAgentProcessPolling() {
        agentProcessPollCancellable = Timer.publish(
            every: 1,
            on: .main,
            in: .common
        ).autoconnect().sink { [weak self] _ in
            self?.pollSSHReconnectProcesses()
            self?.pollLocalAgentProcesses()
        }
    }

    private func pollSSHReconnectProcesses() {
        for surface in surfaceTree {
            let surfaceID = surface.id
            let processGroupID = surface.surfaceModel?.foregroundPID
            guard var context = paneSessionContexts[surfaceID] else { continue }

            if let detected = detectedSSHReconnectProcessIDs[surfaceID] {
                if processGroupID == detected,
                   Self.processGroupExists(detected),
                   case .sshReady(let ssh, _) = context.state,
                   ssh.connectionID == "omg-ssh-detected-\(detected)" {
                    continue
                }
                context.endDetectedSSHReconnect(processGroupID: detected)
                updatePaneSessionContext(context, for: surfaceID)
                detectedSSHReconnectProcessIDs.removeValue(forKey: surfaceID)
                observedSSHReconnectProcessIDs.removeValue(forKey: surfaceID)
                continue
            }

            guard case .local = context.state,
                  let alias = context.disconnectedSSH?.alias,
                  let processGroupID else {
                observedSSHReconnectProcessIDs.removeValue(forKey: surfaceID)
                continue
            }
            guard observedSSHReconnectProcessIDs[surfaceID] != processGroupID else {
                continue
            }
            observedSSHReconnectProcessIDs[surfaceID] = processGroupID
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let commands = Self.processGroupCommandLines(processGroupID)
                let isReconnect = commands.map {
                    PaneSessionContext.isSSHReconnectCommand($0, alias: alias)
                } ?? false
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          isReconnect,
                          observedSSHReconnectProcessIDs[surfaceID] == processGroupID,
                          let currentSurface = surfaceTree.first(where: { $0.id == surfaceID }),
                          currentSurface.surfaceModel?.foregroundPID == processGroupID,
                          var current = paneSessionContexts[surfaceID],
                          case .local = current.state else { return }
                    current.applyDetectedSSHReconnect(processGroupID: processGroupID)
                    updatePaneSessionContext(current, for: surfaceID)
                    detectedSSHReconnectProcessIDs[surfaceID] = processGroupID
                }
            }
        }
    }

    private func pollLocalAgentProcesses() {
        let detectsAgents = AgentStatusPlugin.isEnabled
        guard detectsAgents || SSHPlugin.isEnabled else { return }
        for surface in surfaceTree {
            guard var context = paneSessionContexts[surface.id] else { continue }
            guard let processGroupID = surface.surfaceModel?.foregroundPID else {
                continue
            }

            if let inferredProcessGroupID = context.inferredSSHProcessGroupID {
                guard inferredProcessGroupID != processGroupID else { continue }
                if context.finishForegroundSSH(
                    processGroupID: inferredProcessGroupID,
                    currentWorkingDirectory: surface.pwd,
                    currentTerminalTitle: surface.title
                ) {
                    updatePaneSessionContext(context, for: surface.id)
                    updateSSHResumeDescriptor(context, for: surface.id)
                    clearRemoteAgentState(for: surface.id)
                    observedForegroundProcessIDs.removeValue(forKey: surface.id)
                }
            }

            guard case .local = context.state else {
                clearDetectedAgent(for: surface.id, force: true)
                observedForegroundProcessIDs.removeValue(forKey: surface.id)
                continue
            }
            if let detected = detectedAgentInstances[surface.id] {
                if !detectsAgents ||
                    (detected.agent.definition.hook.kind == .none &&
                        !AgentHookInstaller().isInstalled(detected.agent)) {
                    clearDetectedAgent(for: surface.id, force: true)
                    observedForegroundProcessIDs.removeValue(forKey: surface.id)
                } else if detected.processGroupID != processGroupID,
                          !Self.processGroupExists(detected.processGroupID) {
                    clearDetectedAgent(for: surface.id, force: true)
                } else {
                    updateScreenFallback(for: surface, detected: detected)
                }
            }
            guard observedForegroundProcessIDs[surface.id] != processGroupID else {
                continue
            }
            observedForegroundProcessIDs[surface.id] = processGroupID
            let surfaceID = surface.id
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let commands = Self.processGroupCommandLines(processGroupID)
                let agent = detectsAgents ? commands.flatMap {
                    LocalAgentProcessDetector.detect(in: $0)
                } : nil
                let exactSSH = SSHProcessArguments.observe(groupID: processGroupID)
                let ssh = exactSSH?.observation ?? commands.map {
                    ForegroundSSHProcessDetector.observe(in: $0)
                } ?? .none
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          observedForegroundProcessIDs[surfaceID] == processGroupID,
                          let context = paneSessionContexts[surfaceID],
                          case .local = context.state else { return }
                    applyObservedForegroundProcess(
                        agent: agent,
                        ssh: ssh,
                        processGroupID: processGroupID,
                        surfaceID: surfaceID,
                        sshReplay: exactSSH?.replay
                    )
                }
            }
        }
    }

    private func applyObservedForegroundProcess(
        agent: SupportedAgent?,
        ssh: ForegroundSSHProcessObservation,
        processGroupID: Int,
        surfaceID: UUID,
        sshReplay: SSHReplayDescriptor? = nil
    ) {
        switch ssh {
        case .interactive(let alias, let transferTarget):
            clearDetectedAgent(for: surfaceID, force: true)
            guard let surface = surfaceTree.first(where: { $0.id == surfaceID }) else {
                return
            }
            var context = paneSessionContexts[surfaceID] ?? .init(
                workingDirectory: surface.pwd,
                terminalTitle: surface.title
            )
            let remoteWorkingDirectory: String? = if let descriptor =
                agentResumeDescriptors[surfaceID],
               descriptor.scope == .remote,
               agentReducers[surfaceID]?.hasRemoteActivity == true {
                descriptor.workingDirectory
            } else {
                nil
            }
            context.observeForegroundSSH(
                alias: alias,
                transferTarget: transferTarget,
                processGroupID: processGroupID,
                currentWorkingDirectory: surface.pwd,
                currentTerminalTitle: surface.title,
                remoteWorkingDirectory: remoteWorkingDirectory,
                replay: sshReplay
            )
            updatePaneSessionContext(context, for: surfaceID)
            updateSSHResumeDescriptor(context, for: surfaceID)

        case .ambiguous:
            // An OpenSSH process exists but its argv does not prove an
            // interactive pane. Preserve remote hook state conservatively,
            // but do not expose a guessed host/workspace.
            clearDetectedAgent(for: surfaceID, force: true)

        case .none:
            clearRemoteAgentState(for: surfaceID)
            applyDetectedAgent(
                agent,
                processGroupID: processGroupID,
                surfaceID: surfaceID
            )
        }
    }

    private func applyDetectedAgent(
        _ agent: SupportedAgent?,
        processGroupID: Int,
        surfaceID: UUID
    ) {
        guard let agent else { return }
        if agent.definition.hook.kind == .none,
           !AgentHookInstaller().isInstalled(agent) {
            clearDetectedAgent(for: surfaceID, force: true)
            return
        }
        let id = "omg-agent-\(agent.rawValue)-\(processGroupID)"
        let launchedAt = detectedAgentInstances[surfaceID]?.processGroupID == processGroupID
            ? detectedAgentInstances[surfaceID]?.launchedAt ?? Date()
            : Date()
        detectedAgentInstances[surfaceID] = .init(
            id: id,
            processGroupID: processGroupID,
            agent: agent,
            launchedAt: launchedAt
        )
        scheduleConversationDiscovery(
            agent: agent,
            surfaceID: surfaceID,
            processGroupID: processGroupID,
            launchedAt: launchedAt
        )
        guard agentActivities[surfaceID] == nil else { return }
        updateAgentActivity(.init(
            action: .start,
            id: id,
            metadata: "type=app;omg_agent=\(agent.rawValue);" +
                "omg_scope=local;omg_liveness=pgid;omg_state=idle"
        ), for: surfaceID)
    }

    private func updateScreenFallback(
        for surface: Ghostty.SurfaceView,
        detected: PaneDetectedAgentState
    ) {
        let definition = detected.agent.definition
        guard definition.hook.kind == .none else { return }
        let screen = surface.cachedScreenContents.get()
        let signature = screen.hashValue
        let previous = agentScreenSignatures[surface.id]
        agentScreenSignatures[surface.id] = signature
        guard let previous else { return }

        let classified = AgentScreenStatusDetector.detect(
            definition: definition,
            screen: screen
        )
        let nextState: TabActivityState
        if let classified, classified != .idle {
            nextState = classified
            agentScreenStableTicks[surface.id] = 0
        } else if signature != previous {
            nextState = .working
            agentScreenStableTicks[surface.id] = 0
        } else {
            let ticks = (agentScreenStableTicks[surface.id] ?? 0) + 1
            agentScreenStableTicks[surface.id] = ticks
            guard ticks >= 2,
                  agentActivities[surface.id]?.state == .working else { return }
            nextState = .done
        }
        guard agentActivities[surface.id]?.state != nextState else { return }
        let attention = nextState == .needsAttention
            ? ";omg_attention=permission"
            : ""
        updateAgentActivity(.init(
            action: .start,
            id: detected.id,
            metadata: "type=app;omg_agent=\(detected.agent.rawValue);" +
                "omg_scope=local;omg_liveness=pgid;" +
                "omg_state=\(nextState.rawValue)\(attention)"
        ), for: surface.id)
    }

    private func scheduleConversationDiscovery(
        agent: SupportedAgent,
        surfaceID: UUID,
        processGroupID: Int,
        launchedAt: Date,
        attempt: Int = 0
    ) {
        guard agentResumeDescriptors[surfaceID]?.conversationID == nil,
              let workingDirectory = paneSessionContexts[surfaceID]?.workingDirectory,
              conversationDiscoveryPending.insert(surfaceID).inserted else {
            return
        }
        let delays: [TimeInterval] = [2, 3, 5, 8, 13]
        guard attempt < delays.count else {
            conversationDiscoveryPending.remove(surfaceID)
            return
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + delays[attempt]
        ) { [weak self] in
            let conversationID = AgentConversationStore.discover(
                agent: agent,
                workingDirectory: workingDirectory,
                launchedAfter: launchedAt
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                conversationDiscoveryPending.remove(surfaceID)
                guard detectedAgentInstances[surfaceID]?.processGroupID == processGroupID,
                      var descriptor = agentResumeDescriptors[surfaceID],
                      descriptor.agent == agent,
                      descriptor.scope == .local,
                      descriptor.conversationID == nil else { return }
                guard let conversationID else {
                    scheduleConversationDiscovery(
                        agent: agent,
                        surfaceID: surfaceID,
                        processGroupID: processGroupID,
                        launchedAt: launchedAt,
                        attempt: attempt + 1
                    )
                    return
                }
                descriptor.conversationID = conversationID
                agentResumeDescriptors[surfaceID] = descriptor
                surfaceTree.first(where: { $0.id == surfaceID })?
                    .agentResumeDescriptor = descriptor
                invalidateRestorableState()
            }
        }
    }

    private func clearDetectedAgent(for surfaceID: UUID, force: Bool) {
        guard let detected = detectedAgentInstances[surfaceID],
              force || !Self.processGroupExists(detected.processGroupID) else {
            return
        }
        detectedAgentInstances.removeValue(forKey: surfaceID)
        if typedAgentHookContextIDs[surfaceID] == detected.id {
            typedAgentHookContextIDs.removeValue(forKey: surfaceID)
        }
        agentScreenSignatures.removeValue(forKey: surfaceID)
        agentScreenStableTicks.removeValue(forKey: surfaceID)
        updateAgentActivity(.init(
            action: .end,
            id: detected.id,
            metadata: "type=app"
        ), for: surfaceID)
    }

    nonisolated private static func processGroupCommandLines(
        _ processGroupID: Int
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = [
            "-o", "command=",
            "-g", String(processGroupID),
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            defer {
                if process.isRunning {
                    process.terminate()
                    process.waitUntilExit()
                }
            }
            let handle = output.fileHandleForReading
            var captured = Data()
            while let chunk = try handle.read(upToCount: 8 * 1024),
                  !chunk.isEmpty {
                let remaining = max(0, 64 * 1024 - captured.count)
                if remaining > 0 { captured.append(chunk.prefix(remaining)) }
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: captured, encoding: .utf8)
        } catch {
            return nil
        }
    }

    func updateAgentTitleActivity(
        _ title: String,
        for surfaceID: UUID
    ) {
        guard let descriptor = agentResumeDescriptors[surfaceID],
              let contextID = agentResumeContextIDs[surfaceID],
              let state = AgentTitleStatusReconciler.nextState(
                  status: descriptor.agent.definition.titleStatus,
                  title: title,
                  current: agentActivities[surfaceID]?.state,
                  typedHookOwnsContext: typedAgentHookContextIDs[surfaceID] == contextID
              ) else { return }
        updateAgentActivity(.init(
            action: .start,
            id: contextID,
            metadata: "type=app;omg_agent=\(descriptor.agent.rawValue);" +
                "omg_scope=\(descriptor.scope.rawValue);omg_state=\(state.rawValue)"
        ), for: surfaceID)
    }

    private func registerTypedAgentHookSignal(
        _ signal: Ghostty.ContextSignal,
        for surfaceID: UUID
    ) {
        guard signal.id.hasPrefix("omg-agent-") else { return }
        switch signal.action {
        case .start:
            guard AgentContextSignalReducer.sessionSignal(from: signal) != nil else {
                return
            }
            typedAgentHookContextIDs[surfaceID] = signal.id
        case .end:
            guard typedAgentHookContextIDs[surfaceID] == signal.id else { return }
            typedAgentHookContextIDs.removeValue(forKey: surfaceID)
        }
    }

    private func updateAgentActivity(
        _ signal: Ghostty.ContextSignal,
        for surfaceID: UUID
    ) {
        guard AgentStatusPlugin.isEnabled else {
            agentReducers.removeValue(forKey: surfaceID)
            typedAgentHookContextIDs.removeValue(forKey: surfaceID)
            agentValidationWorkItems.removeValue(forKey: surfaceID)?.cancel()
            clearAgentResumeDescriptor(for: surfaceID)
            if agentActivities.removeValue(forKey: surfaceID) != nil {
                objectWillChange.send()
            }
            return
        }
        updateAgentResumeDescriptor(signal, for: surfaceID)
        var reducer = agentReducers[surfaceID] ?? AgentContextSignalReducer()
        let hadRemoteActivity = reducer.hasRemoteActivity
        let update = reducer.consume(signal) ?? reducer.consumeRemotePrompt(signal)
        agentReducers[surfaceID] = reducer
        if !hadRemoteActivity,
           reducer.hasRemoteActivity,
           let context = paneSessionContexts[surfaceID],
           case .local = context.state {
            // A plain SSH Agent signal can arrive before the next one-second
            // foreground sample. Force exactly one fresh lookup without
            // turning unchanged-PID polling into repeated `ps` work.
            observedForegroundProcessIDs.removeValue(forKey: surfaceID)
        }
        guard let update else { return }
        applyAgentActivityUpdate(update, for: surfaceID)
        scheduleAgentValidation(for: surfaceID)
    }

    private func clearRemoteAgentState(for surfaceID: UUID) {
        var clearedRemoteActivity = false
        if var reducer = agentReducers[surfaceID] {
            clearedRemoteActivity = reducer.hasRemoteActivity
            let update = reducer.clearRemoteActivities()
            agentReducers[surfaceID] = reducer
            if let update {
                applyAgentActivityUpdate(update, for: surfaceID)
            }
        }
        if clearedRemoteActivity {
            typedAgentHookContextIDs.removeValue(forKey: surfaceID)
        }
        if agentResumeDescriptors[surfaceID]?.scope == .remote {
            clearAgentResumeDescriptor(for: surfaceID)
        }
    }

    private func updateSSHResumeDescriptor(
        _ context: PaneSessionContext,
        for surfaceID: UUID
    ) {
        guard let surface = surfaceTree.first(where: { $0.id == surfaceID }) else { return }
        // The remote cwd is only known once the first remote prompt reports
        // it; during .sshConnecting `context.workingDirectory` is still the
        // local pre-SSH directory and must not be replayed remotely.
        let remoteWorkingDirectory: String? = switch context.state {
        case .sshReady(_, let workingDirectory):
            workingDirectory
        case .local, .sshConnecting:
            nil
        }
        let next: SSHResumeDescriptor? = switch context.state {
        case .local:
            nil
        case .sshConnecting(let ssh), .sshReady(let ssh, _):
            if let replay = ssh.replay ?? SSHReplayStore.load(connectionID: ssh.connectionID) {
                .init(
                    sshReplay: replay,
                    remoteWorkingDirectory: remoteWorkingDirectory,
                    localWorkingDirectory: context.local.workingDirectory
                )
            } else {
                nil
            }
        }
        guard surface.sshResumeDescriptor != next else { return }
        surface.sshResumeDescriptor = next
        invalidateRestorableState()
    }

    private func updateAgentResumeDescriptor(
        _ signal: Ghostty.ContextSignal,
        for surfaceID: UUID
    ) {
        if signal.action == .end {
            guard agentResumeContextIDs[surfaceID] == signal.id else { return }
            clearAgentResumeDescriptor(for: surfaceID)
            return
        }
        if signal.id.hasPrefix("omg-ssh-"),
           signal.metadata.contains("type=remote"),
           signal.metadata.contains("cwd="),
           agentResumeDescriptors[surfaceID]?.scope == .remote {
            clearAgentResumeDescriptor(for: surfaceID)
            return
        }
        guard let session = AgentContextSignalReducer.sessionSignal(from: signal) else {
            return
        }
        let existing = agentResumeDescriptors[surfaceID]
        let previous: AgentResumeDescriptor?
        if existing?.agent == session.agent,
           existing?.scope == session.scope {
            previous = existing
        } else {
            previous = nil
        }
        let conversationID = session.conversationID ?? previous?.conversationID
        // Prefer the session's own project directory (reported via `omg_cwd`)
        // over the pane's shell working directory: conversations are
        // directory-scoped for agents such as Pi, and `pi resume` can start
        // a conversation that belongs to a directory other than the shell's
        // current one. Restoring in the shell directory would make the agent
        // create a brand-new conversation instead of resuming this one.
        let workingDirectory = session.workingDirectory
            ?? paneSessionContexts[surfaceID]?.workingDirectory
        let sshReplay: SSHReplayDescriptor? = if session.scope == .remote,
           let context = paneSessionContexts[surfaceID] {
            switch context.state {
            case .local:
                nil
            case .sshConnecting(let ssh), .sshReady(let ssh, _):
                ssh.replay ?? SSHReplayStore.load(connectionID: ssh.connectionID)
            }
        } else {
            nil
        }
        let descriptor = AgentResumeDescriptor(
            agent: session.agent,
            conversationID: conversationID,
            scope: session.scope,
            workingDirectory: workingDirectory,
            sshReplay: sshReplay ?? previous?.sshReplay
        )
        guard descriptor.isValid else { return }
        agentResumeContextIDs[surfaceID] = session.contextID
        guard agentResumeDescriptors[surfaceID] != descriptor else { return }
        agentResumeDescriptors[surfaceID] = descriptor
        surfaceTree.first(where: { $0.id == surfaceID })?
            .agentResumeDescriptor = descriptor
        if descriptor.scope == .local,
           descriptor.conversationID == nil,
           let detected = detectedAgentInstances[surfaceID],
           detected.agent == descriptor.agent {
            scheduleConversationDiscovery(
                agent: detected.agent,
                surfaceID: surfaceID,
                processGroupID: detected.processGroupID,
                launchedAt: detected.launchedAt
            )
        }
        enableRestorationForAgentSession()
        invalidateRestorableState()
    }

    private func enableRestorationForAgentSession() {
        guard !restorable else { return }
        restorable = true
        guard let window else { return }
        window.isRestorable = true
        window.restorationClass = TerminalWindowRestoration.self
        window.identifier = .init(String(describing: TerminalWindowRestoration.self))
    }

    private func clearAgentResumeDescriptor(for surfaceID: UUID) {
        agentResumeContextIDs.removeValue(forKey: surfaceID)
        conversationDiscoveryPending.remove(surfaceID)
        guard agentResumeDescriptors.removeValue(forKey: surfaceID) != nil else {
            return
        }
        surfaceTree.first(where: { $0.id == surfaceID })?
            .agentResumeDescriptor = nil
        invalidateRestorableState()
    }

    func acknowledgeTerminalAgentStateFromUserInput(
        on surface: Ghostty.SurfaceView
    ) {
        guard focusedSurface === surface else { return }
        acknowledgeTerminalAgentState(for: surface)
    }

    private func acknowledgeTerminalAgentState(
        for surface: Ghostty.SurfaceView?
    ) {
        guard let surface,
              var reducer = agentReducers[surface.id],
              let update = reducer.acknowledgeTerminalState() else { return }
        agentReducers[surface.id] = reducer
        applyAgentActivityUpdate(update, for: surface.id)
    }

    private func applyAgentActivityUpdate(
        _ update: AgentActivityUpdate,
        for surfaceID: UUID
    ) {
        let previousActivity = agentActivities[surfaceID]
        let previousState = previousActivity?.state
        var next = agentActivities
        switch update {
        case .set(let activity):
            next[surfaceID] = activity
        case .clear:
            next.removeValue(forKey: surfaceID)
        }
        guard next != agentActivities else { return }
        agentActivities = next
        if AgentQuickInputPresentationPolicy.shouldPresentForAgentStart(
            previous: previousActivity,
            next: next[surfaceID],
            enabled: OhMyGhosttySettings.shared.openQuickInputOnAgentStart,
            isAlreadyPresented: quickInputModel.isPresented,
            isTargetFocused: (focusedSurface ?? surfaceTree.first)?.id == surfaceID
        ), let surface = surfaceTree.first(where: { $0.id == surfaceID }) {
            presentQuickInput(for: surface, requestFocus: false)
        }
        if AgentQuickInputPresentationPolicy.shouldPresentForAgentCompletion(
            previous: previousState,
            next: next[surfaceID]?.state,
            enabled: OhMyGhosttySettings.shared.openQuickInputOnAgentComplete,
            isAlreadyPresented: quickInputModel.isPresented,
            isTargetFocused: (focusedSurface ?? surfaceTree.first)?.id == surfaceID
        ), let surface = surfaceTree.first(where: { $0.id == surfaceID }) {
            presentQuickInput(for: surface, requestFocus: false)
        }
        if AgentQuickInputDispatchPolicy.shouldDispatch(
            previous: previousState,
            next: next[surfaceID]?.state
        ) {
            dispatchNextQuickInput(for: surfaceID)
        }
    }

    private func scheduleAgentValidation(for surfaceID: UUID) {
        agentValidationWorkItems.removeValue(forKey: surfaceID)?.cancel()
        guard agentReducers[surfaceID]?.requiresForegroundValidation == true else {
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  let surface = surfaceTree.first(where: { $0.id == surfaceID }),
                  var reducer = agentReducers[surfaceID] else { return }
            let livenessIsAlive = reducer.validationIdentity.map {
                switch $0 {
                case .process(let processID): Self.processExists(processID)
                case .processGroup(let processGroupID):
                    Self.processGroupExists(processGroupID)
                }
            }
            let update = reducer.reconcileLocalForegroundProcess(
                surface.surfaceModel?.foregroundPID,
                livenessIsAlive: livenessIsAlive
            )
            agentReducers[surfaceID] = reducer
            if let update {
                applyAgentActivityUpdate(update, for: surfaceID)
                if update == .clear {
                    clearAgentResumeDescriptor(for: surfaceID)
                } else if case .set(let activity) = update,
                          activity.state == .error {
                    clearAgentResumeDescriptor(for: surfaceID)
                }
            }
            scheduleAgentValidation(for: surfaceID)
        }
        agentValidationWorkItems[surfaceID] = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 1,
            execute: workItem
        )
    }

    private static func processExists(_ processID: Int) -> Bool {
        guard processID > 0,
              let value = Int32(exactly: processID) else { return false }
        if kill(value, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func processGroupExists(_ processGroupID: Int) -> Bool {
        guard processGroupID > 0,
              let value = Int32(exactly: processGroupID) else { return false }
        if kill(-value, 0) == 0 { return true }
        return errno == EPERM
    }

    private func updatePaneSessionContext(
        _ context: PaneSessionContext,
        for surfaceID: UUID
    ) {
        guard paneSessionContexts[surfaceID] != context else { return }
        let locationChanged = paneSessionContexts[surfaceID].map {
            !context.hasSameLocation(as: $0)
        } ?? true
        var next = paneSessionContexts
        next[surfaceID] = context
        paneSessionContexts = next
        if locationChanged {
            NotificationCenter.default.post(
                name: .terminalPaneSessionContextsDidChange,
                object: self
            )
        }
        if (focusedSurface ?? surfaceTree.first)?.id == surfaceID {
            refreshPresentedTerminalTitle()
        }
    }

    // MARK: Base Controller Overrides

    override func presentedTerminalTitle(
        for surface: Ghostty.SurfaceView,
        terminalTitle: String
    ) -> String {
        paneSessionContext(for: surface)?.presentationTitle ?? terminalTitle
    }

    func tabConfiguration(
        inherited config: Ghostty.SurfaceConfiguration?,
        from source: Ghostty.SurfaceView
    ) -> Ghostty.SurfaceConfiguration? {
        guard let session = paneSessionContext(for: source) else { return config }
        return Self.tabConfiguration(
            inherited: config,
            session: session,
            fallbackWorkingDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

    static func tabConfiguration(
        inherited config: Ghostty.SurfaceConfiguration?,
        session: PaneSessionContext,
        fallbackWorkingDirectory: String
    ) -> Ghostty.SurfaceConfiguration? {
        // A nil inherited directory means tab inheritance is disabled. Leave it
        // nil so Ghostty applies the configured home/custom/default directory.
        guard var result = config, result.workingDirectory != nil else {
            return config
        }
        guard case .local = session.state else {
            // The inherited pwd belongs to the remote host and may not exist
            // locally. Start a normal local tab from the pre-SSH snapshot.
            result.workingDirectory = session.local.workingDirectory
                ?? fallbackWorkingDirectory
            return result
        }
        return config
    }

    @discardableResult
    override func newSplit(
        at oldView: Ghostty.SurfaceView,
        direction: SplitTree<Ghostty.SurfaceView>.NewDirection,
        baseConfig config: Ghostty.SurfaceConfiguration? = nil
    ) -> Ghostty.SurfaceView? {
        super.newSplit(
            at: oldView,
            direction: direction,
            baseConfig: splitConfiguration(
                inherited: config,
                from: oldView
            )
        )
    }

    func splitConfiguration(
        inherited config: Ghostty.SurfaceConfiguration?,
        from source: Ghostty.SurfaceView
    ) -> Ghostty.SurfaceConfiguration? {
        guard let session = paneSessionContext(for: source) else { return config }
        let replay: SSHReplayDescriptor? = switch session.state {
        case .local:
            nil
        case .sshConnecting(let ssh), .sshReady(let ssh, _):
            ssh.replay ?? SSHReplayStore.load(connectionID: ssh.connectionID)
        }
        let split = Self.splitConfiguration(
            inherited: config,
            session: session,
            replay: replay,
            executablePath: Bundle.main.executableURL?.path
        )
        return Self.injectingSessionID(tabSessionID, into: split)
    }

    static func splitConfiguration(
        inherited config: Ghostty.SurfaceConfiguration?,
        session: PaneSessionContext,
        replay: SSHReplayDescriptor?,
        executablePath: String?,
        fallbackWorkingDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> Ghostty.SurfaceConfiguration? {
        let remoteWorkingDirectory: String?
        let activeReplay: SSHReplayDescriptor?
        switch session.state {
        case .local:
            return config
        case .sshConnecting(let ssh):
            remoteWorkingDirectory = nil
            activeReplay = replay ?? ssh.replay
        case .sshReady(let ssh, let workingDirectory):
            remoteWorkingDirectory = workingDirectory
            activeReplay = replay ?? ssh.replay
        }

        var result = config ?? Ghostty.SurfaceConfiguration()
        result.workingDirectory = session.local.workingDirectory
            ?? fallbackWorkingDirectory
        result.command = nil
        guard let executablePath,
              let command = activeReplay?.command(
                executablePath: executablePath,
                remoteWorkingDirectory: remoteWorkingDirectory
              ) else {
            return result
        }
        result.command = replaySurvivalCommand(
            command,
            survivalShell: Self.survivalShell
        )
        return result
    }

    static func replaySurvivalCommand(
        _ command: String,
        survivalShell: String
    ) -> String {
        // macOS wraps SurfaceConfiguration.command as `exec -l <command>`.
        // Put the sequence inside its own shell so that replacing the outer
        // bash process does not discard the post-SSH survival command. Start
        // the replacement as a login shell, matching a normal Ghostty pane;
        // otherwise login-only fish/zsh setup (including prompts) is skipped.
        let script = "\(command); exec -l \(Ghostty.Shell.quote(survivalShell))"
        return "/bin/sh -c \(Ghostty.Shell.quote(script))"
    }

    /// Convenience overload that uses the user's login shell as the survival shell.
    static func replaySurvivalCommand(_ command: String) -> String {
        replaySurvivalCommand(command, survivalShell: survivalShell)
    }

    /// The user's login shell, used to keep an SSH split pane alive after the
    /// remote connection ends.
    private static var survivalShell: String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return "/bin/zsh"
    }

    override func surfaceTreeDidChange(from: SplitTree<Ghostty.SurfaceView>, to: SplitTree<Ghostty.SurfaceView>) {
        super.surfaceTreeDidChange(from: from, to: to)

        // Whenever our surface tree changes in any way (new split, close split, etc.)
        // we want to invalidate our state.
        invalidateRestorableState()
        synchronizePaneSessionContexts()

        // Update our zoom state
        if let window = window as? TerminalWindow {
            window.surfaceIsZoomed = to.zoomed != nil
        }

        // If our surface tree is now nil then we close our window.
        if to.isEmpty {
            self.window?.close()
        }
    }

    override func replaceSurfaceTree(
        _ newTree: SplitTree<Ghostty.SurfaceView>,
        moveFocusTo newView: Ghostty.SurfaceView? = nil,
        moveFocusFrom oldView: Ghostty.SurfaceView? = nil,
        undoAction: String? = nil
    ) {
        // We have a special case if our tree is empty to close our tab immediately.
        // This makes it so that undo is handled properly.
        if newTree.isEmpty {
            closeTabImmediately()
            return
        }

        super.replaceSurfaceTree(
            newTree,
            moveFocusTo: newView,
            moveFocusFrom: oldView,
            undoAction: undoAction)
    }

    // MARK: Vertical Tabs

    func selectVerticalTab(_ controller: TerminalController) {
        guard let targetWindow = controller.window,
              NSApp.windows.contains(where: { $0 === targetWindow }) else { return }
        // The row's controller identifies the target. UI projections and the
        // source's group can lag behind native reorder/restore notifications.
        let tabGroup = targetWindow.tabGroup
        tabGroup?.selectedWindow = targetWindow
        controller.markTabActivated()
        // Key status alone does not guarantee native tab/front ordering.
        targetWindow.makeKeyAndOrderFront(nil)
        Self.refreshTabs(in: tabGroup)
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
    }

    func markTabActivated() {
        tabLastActivatedAt = Date()
        guard tabLayoutState.orderingMode == .recentlyUsed,
              window?.tabGroup?.selectedWindow === window else { return }
        pendingTabOrganizationWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            defer { pendingTabOrganizationWorkItem = nil }
            guard tabLayoutState.orderingMode == .recentlyUsed,
                  window?.tabGroup?.selectedWindow === window else { return }
            reconcileTabOrganization()
        }
        pendingTabOrganizationWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    @discardableResult
    func reorderTab(_ controller: TerminalController, toInsertionIndex insertionIndex: Int) -> Bool {
        guard let tabGroup = window?.tabGroup,
              let movedWindow = controller.window else { return false }
        let windows = tabGroup.windows
        guard let sourceIndex = windows.firstIndex(of: movedWindow) else { return false }

        var reordered = windows
        reordered.remove(at: sourceIndex)
        let destination = VerticalTabDropPolicy.destinationIndex(
            sourceIndex: sourceIndex,
            insertionIndex: insertionIndex,
            tabCount: windows.count
        )
        reordered.insert(movedWindow, at: destination)
        guard reordered != windows else { return false }

        tabLayoutState.setOrderingMode(.manual)
        applyCanonicalTabOrder(reordered, in: tabGroup)
        return true
    }

    func setTabGroupingMode(_ mode: GhosttyTabGroupingMode) {
        guard mode != tabLayoutState.groupingMode else { return }
        reconcileTabOrganization(grouping: mode, ordering: tabLayoutState.orderingMode)
        tabLayoutState.setGroupingMode(mode)
    }

    func setTabOrderingMode(_ mode: GhosttyTabOrderingMode) {
        guard mode != tabLayoutState.orderingMode else { return }
        reconcileTabOrganization(grouping: tabLayoutState.groupingMode, ordering: mode)
        tabLayoutState.setOrderingMode(mode)
    }

    func beginManualTabDrag() {
        if tabLayoutState.orderingMode != .manual {
            tabLayoutState.setOrderingMode(.manual)
        }
    }

    func reconcileTabOrganization(
        grouping: GhosttyTabGroupingMode? = nil,
        ordering: GhosttyTabOrderingMode? = nil
    ) {
        guard let tabGroup = window?.tabGroup else { return }
        let controllers = tabGroup.windows.compactMap {
            $0.windowController as? TerminalController
        }
        let groups = GhosttyTabOrganizationModel().groups(
            tabs: controllers,
            grouping: grouping ?? tabLayoutState.groupingMode,
            ordering: ordering ?? tabLayoutState.orderingMode
        )
        let windows = groups.flatMap(\.tabs).compactMap(\.controller.window)
        guard windows.count == tabGroup.windows.count else { return }
        applyCanonicalTabOrder(windows, in: tabGroup)
    }

    private func applyCanonicalTabOrder(_ windows: [NSWindow], in tabGroup: NSWindowTabGroup) {
        guard windows != tabGroup.windows else { return }
        let selectedWindow = tabGroup.selectedWindow

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            for (index, candidate) in windows.enumerated() {
                guard tabGroup.windows.indices.contains(index),
                      tabGroup.windows[index] !== candidate else { continue }
                tabGroup.removeWindow(candidate)
                tabGroup.insertWindow(candidate, at: index)
            }
        }

        if let selectedWindow, tabGroup.windows.contains(selectedWindow) {
            tabGroup.selectedWindow = selectedWindow
        }
        for candidate in tabGroup.windows {
            candidate.invalidateRestorableState()
        }
        Self.refreshTabs(in: tabGroup)
    }

    func newVerticalTab() {
        _ = Self.newTab(ghostty, from: window)
    }

    /// Detach a dragged pane into its own tab at a stable sidebar destination.
    ///
    /// The remove, attach, reorder, and undo registration are one transaction;
    /// the lower-level split and new-tab operations must not register competing
    /// undo actions of their own.
    @discardableResult
    func moveSurfaceToNewTab(
        _ surface: Ghostty.SurfaceView,
        relativeTo destinationController: TerminalController,
        placement: VerticalTabDropPolicy.Placement,
        registerUndo: Bool = true
    ) -> Bool {
        guard let destinationWindow = destinationController.window,
              let sourceController = BaseTerminalController.controller(owning: surface)
                as? TerminalController,
              let sourceWindow = sourceController.window else { return false }

        var descriptor = VerticalTabMoveTransactionDescriptor(
            sourceTabSessionID: sourceController.tabSessionID,
            sourceSurfaceID: surface.id,
            destinationTabSessionID: destinationController.tabSessionID,
            placement: placement,
            movedTabSessionID: nil
        )

        if !sourceController.surfaceTree.isSplit {
            let alreadyGrouped: Bool = if let sourceGroup = sourceWindow.tabGroup,
                let destinationGroup = destinationWindow.tabGroup {
                sourceGroup === destinationGroup
            } else {
                false
            }
            guard sourceWindow !== destinationWindow, !alreadyGrouped else { return false }

            let sourceSnapshot = VerticalTabWindowGroupSnapshot(
                controller: sourceController
            )
            let destinationSnapshot = VerticalTabWindowGroupSnapshot(
                controller: destinationController
            )
            guard destinationWindow.addTabbedWindowSafely(
                sourceWindow,
                ordered: .above
            ) else {
                _ = Self.restoreSinglePaneMove(
                    descriptor: descriptor,
                    sourceSnapshot: sourceSnapshot,
                    destinationSnapshot: destinationSnapshot
                )
                return false
            }

            guard let destinationGroup = destinationWindow.tabGroup,
                  sourceWindow.tabGroup === destinationGroup,
                  destinationGroup.windows.contains(sourceWindow),
                  let insertionIndex = verticalTabInsertionIndex(
                      relativeTo: destinationController,
                      placement: placement,
                      in: destinationGroup
                  ),
                  let plan = VerticalTabMoveTransactionPlan(
                      sourceIndexAfterAttach: destinationGroup.windows.firstIndex(of: sourceWindow),
                      insertionIndex: insertionIndex,
                      tabCount: destinationGroup.windows.count
                  ) else {
                _ = Self.restoreSinglePaneMove(
                    descriptor: descriptor,
                    sourceSnapshot: sourceSnapshot,
                    destinationSnapshot: destinationSnapshot
                )
                return false
            }

            _ = destinationController.reorderTab(
                sourceController,
                toInsertionIndex: plan.insertionIndex
            )
            guard plan.validates(
                actualIndex: destinationGroup.windows.firstIndex(of: sourceWindow),
                tabCount: destinationGroup.windows.count
            ) else {
                _ = Self.restoreSinglePaneMove(
                    descriptor: descriptor,
                    sourceSnapshot: sourceSnapshot,
                    destinationSnapshot: destinationSnapshot
                )
                return false
            }

            Self.refreshTabs(in: destinationGroup)
            destinationController.selectVerticalTab(sourceController)
            guard destinationGroup.selectedWindow === sourceWindow else {
                _ = Self.restoreSinglePaneMove(
                    descriptor: descriptor,
                    sourceSnapshot: sourceSnapshot,
                    destinationSnapshot: destinationSnapshot
                )
                return false
            }

            if registerUndo {
                registerSinglePaneMoveUndo(
                    descriptor: descriptor,
                    sourceSnapshot: sourceSnapshot,
                    destinationSnapshot: destinationSnapshot
                )
            }
            return true
        }

        guard let sourceNode = sourceController.surfaceTree.root?.node(view: surface),
              let sessionSnapshot = sourceController.capturePaneSessionState(
                  for: surface.id
              ) else { return false }
        if let fullscreenStyle = destinationController.fullscreenStyle,
           fullscreenStyle.isFullscreen && !fullscreenStyle.supportsTabs {
            return false
        }

        let oldTree = sourceController.surfaceTree
        let oldFocusedSurfaceID = sourceController.focusedSurface?.id
        let destinationSnapshot = VerticalTabWindowGroupSnapshot(
            controller: destinationController
        )
        sourceController.removeSurfaceNode(
            sourceNode,
            undoAction: nil,
            registerUndo: false
        )

        let newTree = SplitTree<Ghostty.SurfaceView>(view: surface)
        guard let newController = Self.newTab(
            ghostty,
            from: destinationWindow,
            withSurfaceTree: newTree,
            registerUndo: false
        ) else {
            Self.restoreSurfaceTree(
                oldTree,
                focusedSurfaceID: oldFocusedSurfaceID,
                to: sourceController
            )
            sourceController.restorePaneSessionState(sessionSnapshot, for: surface.id)
            return false
        }
        newController.restorePaneSessionState(sessionSnapshot, for: surface.id)
        descriptor.movedTabSessionID = newController.tabSessionID

        guard let destinationGroup = destinationWindow.tabGroup,
              let newWindow = newController.window,
              newWindow.tabGroup === destinationGroup,
              destinationGroup.windows.contains(newWindow),
              let insertionIndex = verticalTabInsertionIndex(
                  relativeTo: destinationController,
                  placement: placement,
                  in: destinationGroup
              ),
              let plan = VerticalTabMoveTransactionPlan(
                  sourceIndexAfterAttach: destinationGroup.windows.firstIndex(of: newWindow),
                  insertionIndex: insertionIndex,
                  tabCount: destinationGroup.windows.count
              ) else {
            Self.discardMovedPaneTab(newController)
            Self.restoreSurfaceTree(
                oldTree,
                focusedSurfaceID: oldFocusedSurfaceID,
                to: sourceController
            )
            sourceController.restorePaneSessionState(sessionSnapshot, for: surface.id)
            _ = Self.restoreWindowSnapshot(
                destinationSnapshot,
                controllerID: destinationController.tabSessionID
            )
            return false
        }

        _ = destinationController.reorderTab(
            newController,
            toInsertionIndex: plan.insertionIndex
        )
        Self.refreshTabs(in: destinationGroup)
        destinationController.selectVerticalTab(newController)
        guard plan.validates(
            actualIndex: destinationGroup.windows.firstIndex(of: newWindow),
            tabCount: destinationGroup.windows.count
        ), destinationGroup.selectedWindow === newWindow else {
            Self.discardMovedPaneTab(newController)
            Self.restoreSurfaceTree(
                oldTree,
                focusedSurfaceID: oldFocusedSurfaceID,
                to: sourceController
            )
            sourceController.restorePaneSessionState(sessionSnapshot, for: surface.id)
            _ = Self.restoreWindowSnapshot(
                destinationSnapshot,
                controllerID: destinationController.tabSessionID
            )
            return false
        }

        if registerUndo {
            registerSplitPaneMoveUndo(
                descriptor: descriptor,
                oldTree: oldTree,
                oldFocusedSurfaceID: oldFocusedSurfaceID,
                initialSessionSnapshot: sessionSnapshot,
                destinationSnapshot: destinationSnapshot
            )
        }
        return true
    }

    private func verticalTabInsertionIndex(
        relativeTo destinationController: TerminalController,
        placement: VerticalTabDropPolicy.Placement,
        in tabGroup: NSWindowTabGroup
    ) -> Int? {
        if placement == .end { return tabGroup.windows.count }
        guard let destinationWindow = destinationController.window,
              let destinationIndex = tabGroup.windows.firstIndex(of: destinationWindow) else {
            return nil
        }
        return VerticalTabDropPolicy.insertionIndex(
            destinationIndex: destinationIndex,
            placement: placement
        )
    }

    private static func resolvedControllers(
        sessionIDs: [UUID]
    ) -> [TerminalController]? {
        VerticalTabStableResolver.resolve(
            sessionIDs: sessionIDs,
            in: TerminalController.all,
            sessionID: \.tabSessionID
        )
    }

    private static func restoreWindowSnapshot(
        _ snapshot: VerticalTabWindowGroupSnapshot,
        controllerID: UUID
    ) -> Bool {
        let controllers = TerminalController.all
        guard let controller = controllers.first(where: {
            $0.tabSessionID == controllerID
        }),
              let restoration = snapshot.resolveRestoration(
                  of: controller,
                  in: controllers
              ),
              snapshot.restore(restoration) else { return false }
        refreshTabs(in: restoration.group)
        controller.setupTabObservation()
        return true
    }

    private static func restoreSinglePaneMove(
        descriptor: VerticalTabMoveTransactionDescriptor,
        sourceSnapshot: VerticalTabWindowGroupSnapshot,
        destinationSnapshot: VerticalTabWindowGroupSnapshot
    ) -> Bool {
        let controllers = TerminalController.all
        guard let resolved = VerticalTabStableResolver.resolve(
            sessionIDs: descriptor.redoSessionIDs,
            in: controllers,
            sessionID: \.tabSessionID
        ), resolved.count == 2 else { return false }
        let source = resolved[0]
        let destination = resolved[1]
        guard source.surfaceTree.contains(where: {
            $0.id == descriptor.sourceSurfaceID
        }),
              let sourceRestoration = sourceSnapshot.resolveRestoration(
                  of: source,
                  in: controllers
              ),
              let destinationRestoration = destinationSnapshot.resolveRestoration(
                  of: destination,
                  in: controllers
              ) else { return false }

        guard sourceSnapshot.restore(sourceRestoration),
              destinationSnapshot.restore(destinationRestoration) else { return false }
        refreshTabs(in: sourceRestoration.group)
        refreshTabs(in: destinationRestoration.group)
        source.setupTabObservation()
        destination.setupTabObservation()
        return true
    }

    private func registerSinglePaneMoveUndo(
        descriptor: VerticalTabMoveTransactionDescriptor,
        sourceSnapshot: VerticalTabWindowGroupSnapshot,
        destinationSnapshot: VerticalTabWindowGroupSnapshot
    ) {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        let undoManager = appDelegate.undoManager
        let expiration = undoExpiration
        undoManager.setActionName("Move Split")
        undoManager.registerUndo(
            withTarget: ghostty,
            expiresAfter: expiration
        ) { ghostty in
            guard Self.restoreSinglePaneMove(
                descriptor: descriptor,
                sourceSnapshot: sourceSnapshot,
                destinationSnapshot: destinationSnapshot
            ) else { return }
            Self.registerPaneMoveRedo(
                descriptor: descriptor,
                ghostty: ghostty,
                undoManager: undoManager,
                expiration: expiration
            )
        }
    }

    private func registerSplitPaneMoveUndo(
        descriptor: VerticalTabMoveTransactionDescriptor,
        oldTree: SplitTree<Ghostty.SurfaceView>,
        oldFocusedSurfaceID: UUID?,
        initialSessionSnapshot: PaneSessionStateSnapshot,
        destinationSnapshot: VerticalTabWindowGroupSnapshot
    ) {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let undoIDs = descriptor.undoSessionIDs else { return }
        let undoManager = appDelegate.undoManager
        undoManager.setActionName("Move Split")
        let expiration = undoExpiration
        undoManager.registerUndo(
            withTarget: ghostty,
            expiresAfter: expiration
        ) { ghostty in
            let controllers = TerminalController.all
            guard let resolved = VerticalTabStableResolver.resolve(
                sessionIDs: undoIDs,
                in: controllers,
                sessionID: \.tabSessionID
            ), resolved.count == 3 else { return }
            let source = resolved[0]
            let destination = resolved[1]
            let moved = resolved[2]
            guard let movedSurface = moved.surfaceTree.first(where: {
                $0.id == descriptor.sourceSurfaceID
            }),
                  !source.surfaceTree.contains(where: {
                      $0.id == descriptor.sourceSurfaceID
                  }),
                  let restoredTree = Self.replacingSurface(
                      descriptor.sourceSurfaceID,
                      with: movedSurface,
                      in: oldTree
                  ),
                  let destinationRestoration = destinationSnapshot.resolveRestoration(
                      of: destination,
                      in: controllers
                  ) else { return }

            let transferredState = moved.capturePaneSessionState(
                for: descriptor.sourceSurfaceID
            ) ?? initialSessionSnapshot
            Self.discardMovedPaneTab(moved)
            Self.restoreSurfaceTree(
                restoredTree,
                focusedSurfaceID: oldFocusedSurfaceID,
                to: source
            )
            source.restorePaneSessionState(
                transferredState,
                for: descriptor.sourceSurfaceID
            )
            guard destinationSnapshot.restore(destinationRestoration) else { return }
            Self.refreshTabs(in: destinationRestoration.group)
            Self.registerPaneMoveRedo(
                descriptor: descriptor,
                ghostty: ghostty,
                undoManager: undoManager,
                expiration: expiration
            )
        }
    }

    private static func registerPaneMoveRedo(
        descriptor: VerticalTabMoveTransactionDescriptor,
        ghostty: Ghostty.App,
        undoManager: ExpiringUndoManager,
        expiration: Duration
    ) {
        undoManager.registerUndo(
            withTarget: ghostty,
            expiresAfter: expiration
        ) { _ in
            guard let resolved = resolvedControllers(
                sessionIDs: descriptor.redoSessionIDs
            ), resolved.count == 2 else { return }
            let source = resolved[0]
            let destination = resolved[1]
            guard let surface = source.surfaceTree.first(where: {
                $0.id == descriptor.sourceSurfaceID
            }) else { return }
            _ = source.moveSurfaceToNewTab(
                surface,
                relativeTo: destination,
                placement: descriptor.placement
            )
        }
    }

    private static func replacingSurface(
        _ surfaceID: UUID,
        with surface: Ghostty.SurfaceView,
        in tree: SplitTree<Ghostty.SurfaceView>
    ) -> SplitTree<Ghostty.SurfaceView>? {
        guard let node = tree.find(id: surfaceID) else { return nil }
        if tree.contains(surface) { return tree }
        return try? tree.replacing(node: node, with: .leaf(view: surface))
    }

    private static func discardMovedPaneTab(_ controller: TerminalController) {
        controller.cancelPendingInitialPresentation()
        controller.surfaceTree = .init()
        controller.window?.close()
    }

    private static func restoreSurfaceTree(
        _ tree: SplitTree<Ghostty.SurfaceView>,
        focusedSurfaceID: UUID?,
        to controller: TerminalController
    ) {
        controller.surfaceTree = tree
        controller.focusedSurface = focusedSurfaceID.flatMap { focusedID in
            tree.first(where: { $0.id == focusedID })
        }
        if let focusedSurface = controller.focusedSurface {
            DispatchQueue.main.async {
                Ghostty.moveFocus(to: focusedSurface)
            }
        }
    }

    func setVerticalTabHovered(_ controller: TerminalController, hovered: Bool) {
        let id = ObjectIdentifier(controller)
        if hovered {
            hoveredTabID = id
        } else if hoveredTabID == id {
            hoveredTabID = nil
        }
    }

    func clearVerticalTabHover() {
        hoveredTabID = nil
    }

    func updateSidebarWidth(_ proposedWidth: CGFloat, persist: Bool) {
        let contentWidth = window?.contentLayoutRect.width ?? VerticalTabSidebarMetrics.maximumWidth * 2
        tabLayoutState.updateSidebarWidth(
            proposedWidth,
            availableWidth: contentWidth,
            persist: persist
        )
    }

    func updateInspectorWidth(_ proposedWidth: CGFloat, persist: Bool) {
        let contentWidth = window?.contentLayoutRect.width ?? RightInspectorMetrics.maximumWidth * 2
        tabLayoutState.updateInspectorWidth(
            proposedWidth,
            availableWidth: contentWidth,
            persist: persist
        )
    }

    func updateQuickInputHeight(_ proposedHeight: CGFloat, persist: Bool) {
        let contentHeight = window?.contentLayoutRect.height ??
            AgentQuickInputMetrics.maximumHeight * 2
        quickInputModel.updateDockHeight(
            proposedHeight,
            availableHeight: contentHeight,
            persist: persist
        )
    }

    func setInspectorVisible(_ visible: Bool) {
        tabLayoutState.setInspectorVisible(visible)
    }

    func toggleInspectorPane() {
        tabLayoutState.toggleInspector()
    }

    func closeVerticalTab(_ controller: TerminalController) {
        guard tabControllers.contains(where: { $0 === controller }) else { return }
        selectVerticalTab(controller)
        DispatchQueue.main.async {
            controller.closeTab(nil)
        }
    }

    func setSidebarVisible(_ visible: Bool) {
        guard supportsSidebar else { return }
        tabLayoutState.setSidebarVisible(visible)
    }

    override func toggleSidebar(_ sender: Any?) {
        guard supportsSidebar else { return }
        tabLayoutState.toggleSidebar()
    }

    func refreshTabState() {
        setupTabObservation()
    }

    private func setupTabObservation() {
        let currentGroup = window?.tabGroup
        if observedVerticalTabGroup === currentGroup {
            refreshTabs()
            return
        }

        verticalTabWindowsObservation?.invalidate()
        verticalTabSelectionObservation?.invalidate()
        observedVerticalTabGroup = currentGroup

        guard let currentGroup else {
            refreshTabs()
            return
        }

        verticalTabWindowsObservation = currentGroup.observe(
            \.windows,
            options: [.new]
        ) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshTabs() }
        }
        verticalTabSelectionObservation = currentGroup.observe(
            \.selectedWindow,
            options: [.new]
        ) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshTabs() }
        }
        refreshTabs()
    }

    private func refreshTabs() {
        guard let window else {
            if !tabControllers.isEmpty { tabControllers = [] }
            if selectedTabID != nil { selectedTabID = nil }
            return
        }

        let tabGroup = window.tabGroup
        let windows = tabGroup?.windows ?? [window]
        let controllers = windows.compactMap {
            $0.windowController as? TerminalController
        }
        let sameControllers = tabControllers.count == controllers.count &&
            zip(tabControllers, controllers).allSatisfy { $0 === $1 }
        if !sameControllers {
            tabControllers = controllers
            if tabGroup?.selectedWindow === window,
               tabLayoutState.orderingMode != .manual {
                DispatchQueue.main.async { [weak self] in
                    self?.reconcileTabOrganization()
                }
            }
        }

        let sharedState = tabGroup?.ghosttyTerminalShellLayoutState ?? tabLayoutState
        for controller in controllers where controller.tabLayoutState !== sharedState {
            controller.tabLayoutState = sharedState
        }

        let selectedWindow = tabGroup?.selectedWindow ?? window
        let selectedID = (selectedWindow.windowController as? TerminalController)
            .map(ObjectIdentifier.init)
        if selectedTabID != selectedID {
            selectedTabID = selectedID
        }
    }

    private static func refreshTabs(in tabGroup: NSWindowTabGroup?) {
        guard let tabGroup else { return }
        for case let controller as TerminalController in tabGroup.windows.compactMap(\.windowController) {
            controller.setupTabObservation()
        }
    }

    // MARK: Terminal Creation

    /// Returns all the available terminal controllers present in the app currently.
    static var all: [TerminalController] {
        return NSApplication.shared.windows.compactMap {
            $0.windowController as? TerminalController
        }
    }

    // Keep track of the last point that our window was launched at so that new
    // windows "cascade" over each other and don't just launch directly on top
    // of each other.
    private static var lastCascadePoint = NSPoint(x: 0, y: 0)

    private static func applyCascade(to window: NSWindow, hasFixedPos: Bool) {
        if hasFixedPos { return }

        if all.count > 1 {
            lastCascadePoint = window.cascadeTopLeft(from: lastCascadePoint)
        } else {
            // We assume the window frame is already correct at this point,
            // so we pass .zero to let cascade use the current frame position.
            lastCascadePoint = window.cascadeTopLeft(from: .zero)
        }
    }

    // The preferred parent terminal controller.
    static var preferredParent: TerminalController? {
        all.first {
            $0.window?.isMainWindow ?? false
        } ?? lastMain ?? all.last
    }

    // The last controller to be main. We use this when paired with "preferredParent"
    // to find the preferred window to attach new tabs, perform actions, etc. We
    // always prefer the main window but if there isn't any (because we're triggered
    // by something like an App Intent) then we prefer the most previous main.
    static private(set) weak var lastMain: TerminalController?

    /// The "new window" action.
    static func newWindow(
        _ ghostty: Ghostty.App,
        withBaseConfig baseConfig: Ghostty.SurfaceConfiguration? = nil,
        withParent explicitParent: NSWindow? = nil
    ) -> TerminalController {
        let c = TerminalController.init(ghostty, withBaseConfig: baseConfig)

        // Get our parent. Our parent is the one explicitly given to us,
        // otherwise the focused terminal, otherwise an arbitrary one.
        let parent: NSWindow? = explicitParent ?? preferredParent?.window
        if let parentController = parent?.windowController as? TerminalController {
            c.isBackgroundOpaque = parentController.isBackgroundOpaque
        }

        if let parent, parent.styleMask.contains(.fullScreen) {
            // If our previous window was fullscreen then we want our new window to
            // be fullscreen. This behavior actually doesn't match the native tabbing
            // behavior of macOS apps where new windows create tabs when in native
            // fullscreen but this is how we've always done it. This matches iTerm2
            // behavior.
            c.toggleFullscreen(mode: .native)
        } else if let fullscreenMode = ghostty.config.windowFullscreen {
            switch fullscreenMode {
            case .native:
                // Native has to be done immediately so that our stylemask contains
                // fullscreen for the logic later in this method.
                c.toggleFullscreen(mode: .native)

            case .nonNative, .nonNativeVisibleMenu, .nonNativePaddedNotch:
                // If we're non-native then we have to do it on a later loop
                // so that the content view is setup.
                DispatchQueue.main.async {
                    c.toggleFullscreen(mode: fullscreenMode)
                }
            }
        }

        // We're dispatching this async because otherwise the lastCascadePoint doesn't
        // take effect. Our best theory is there is some next-event-loop-tick logic
        // that Cocoa is doing that we need to be after.
        c.scheduleInitialPresentation {
            c.showWindow(self)

            // Only cascade if we aren't fullscreen.
            if let window = c.window {
                if !window.styleMask.contains(.fullScreen) {
                    let hasFixedPos = c.derivedConfig.windowPositionX != nil && c.derivedConfig.windowPositionY != nil
                    Self.applyCascade(to: window, hasFixedPos: hasFixedPos)
                }
            }

            // All new_window actions force our app to be active, so that the new
            // window is focused and visible.
            NSApp.activate(ignoringOtherApps: true)
        }

        // Setup our undo
        if let undoManager = c.undoManager {
            undoManager.setActionName("New Window")
            undoManager.registerUndo(
                withTarget: c,
                expiresAfter: c.undoExpiration
            ) { target in
                // Close the window when undoing
                undoManager.disableUndoRegistration {
                    target.closeWindow(nil)
                }

                // Register redo action
                undoManager.registerUndo(
                    withTarget: ghostty,
                    expiresAfter: target.undoExpiration
                ) { ghostty in
                    _ = TerminalController.newWindow(
                        ghostty,
                        withBaseConfig: baseConfig,
                        withParent: explicitParent)
                }
            }
        }

        return c
    }

    /// Create a new window with an existing split tree.
    /// The window will be sized to match the tree's current view bounds if available.
    /// - Parameters:
    ///   - ghostty: The Ghostty app instance.
    ///   - tree: The split tree to use for the new window.
    ///   - position: Optional screen position (top-left corner) for the new window.
    ///               If nil, the window will cascade from the last cascade point.
    static func newWindow(
        _ ghostty: Ghostty.App,
        tree: SplitTree<Ghostty.SurfaceView>,
        position: NSPoint? = nil,
        confirmUndo: Bool = true,
        inheritBackgroundOpacity: Bool? = nil
    ) -> TerminalController {
        // Calculate the target frame based on the tree's view bounds
        // before moving into the new window
        let treeSize: CGSize? = tree.root?.viewBounds()

        let c = TerminalController.init(ghostty, withSurfaceTree: tree)
        if let inheritBackgroundOpacity {
            c.isBackgroundOpaque = inheritBackgroundOpacity
        }

        c.scheduleInitialPresentation {
            c.showWindow(self)
            if let window = c.window {
                // If we have a tree size, resize the window's content to match
                if let treeSize, treeSize.width > 0, treeSize.height > 0 {
                    window.setContentSize(treeSize)
                    window.constrainToScreen()
                }

                if !window.styleMask.contains(.fullScreen) {
                    if let position {
                        window.setFrameTopLeftPoint(position)
                        window.constrainToScreen()
                    } else {
                        let hasFixedPos = c.derivedConfig.windowPositionX != nil && c.derivedConfig.windowPositionY != nil
                        Self.applyCascade(to: window, hasFixedPos: hasFixedPos)
                    }
                }
            }
        }

        // Setup our undo
        if let undoManager = c.undoManager {
            undoManager.setActionName("New Window")
            undoManager.registerUndo(
                withTarget: c,
                expiresAfter: c.undoExpiration
            ) { target in
                undoManager.disableUndoRegistration {
                    if confirmUndo {
                        target.closeWindow(nil)
                    } else {
                        target.closeWindowImmediately()
                    }
                }

                undoManager.registerUndo(
                    withTarget: ghostty,
                    expiresAfter: target.undoExpiration
                ) { ghostty in
                    _ = TerminalController.newWindow(
                        ghostty,
                        tree: tree,
                        inheritBackgroundOpacity: inheritBackgroundOpacity
                    )
                }
            }
        }

        return c
    }

    static func newTab(
        _ ghostty: Ghostty.App,
        from parent: NSWindow? = nil,
        withBaseConfig baseConfig: Ghostty.SurfaceConfiguration? = nil,
        withSurfaceTree surfaceTree: SplitTree<Ghostty.SurfaceView>? = nil,
        registerUndo: Bool = true
    ) -> TerminalController? {
        // Making sure that we're dealing with a TerminalController. If not,
        // then we just create a new window.
        guard let parent,
              let parentController = parent.windowController as? TerminalController else {
            // A caller-owned tree must remain with its caller when there is no
            // valid tab parent; falling back to newWindow would register an
            // independent undo and break the pane-move transaction.
            guard surfaceTree == nil else { return nil }
            return newWindow(ghostty, withBaseConfig: baseConfig, withParent: parent)
        }

        // If our parent is in non-native fullscreen, then new tabs do not work.
        // See: https://github.com/mitchellh/ghostty/issues/392
        if let fullscreenStyle = parentController.fullscreenStyle,
           fullscreenStyle.isFullscreen && !fullscreenStyle.supportsTabs {
            let alert = NSAlert()
            alert.messageText = "Cannot Create New Tab"
            alert.informativeText = "New tabs are unsupported while in non-native fullscreen. Exit fullscreen and try again."
            alert.addButton(withTitle: "OK")
            alert.alertStyle = .warning
            alert.beginSheetModal(for: parent)
            return nil
        }

        // Menu and vertical-tab actions arrive without a base configuration.
        // Resolve the tab inheritance from the focused Surface here so those
        // paths receive the same SSH-safe local-directory handling as a core
        // new_tab notification.
        let resolvedBaseConfig: Ghostty.SurfaceConfiguration? = if let baseConfig {
            baseConfig
        } else if let source = parentController.focusedSurface,
                  let surface = source.surface {
            parentController.tabConfiguration(
                inherited: .init(from: ghostty_surface_inherited_config(
                    surface,
                    GHOSTTY_SURFACE_CONTEXT_TAB
                )),
                from: source
            )
        } else {
            nil
        }

        // Create a new window and add it to the parent
        let controller = TerminalController.init(
            ghostty,
            withBaseConfig: resolvedBaseConfig,
            withSurfaceTree: surfaceTree,
            tabLayout: parentController.tabLayout
        )
        controller.isBackgroundOpaque = parentController.isBackgroundOpaque
        controller.tabLayoutState = parentController.tabLayoutState
        guard let window = controller.window else { return nil }

        // If the parent is miniaturized, then macOS exhibits really strange behaviors
        // so we have to bring it back out.
        if parent.isMiniaturized { parent.deminiaturize(self) }

        // If our parent tab group already has this window, macOS added it and
        // we need to remove it so we can set the correct order in the next line.
        // If we don't do this, macOS gets really confused and the tabbedWindows
        // state becomes incorrect.
        //
        // At the time of writing this code, the only known case this happens
        // is when the "+" button is clicked in the tab bar.
        if let tg = parent.tabGroup,
           tg.windows.firstIndex(of: window) != nil {
            tg.removeWindow(window)
        }

        // If we don't allow tabs then we create a new window instead.
        if window.tabbingMode != .disallowed {
            // Add the window to the tab group and show it.
            let addedToTabGroup: Bool
            switch ghostty.config.windowNewTabPosition {
            case "end":
                // If we already have a tab group and we want the new tab to open at the end,
                // then we use the last window in the tab group as the parent.
                if let last = parent.tabGroup?.windows.last {
                    addedToTabGroup = last.addTabbedWindowSafely(
                        window,
                        ordered: .above
                    )
                } else {
                    addedToTabGroup = parent.addTabbedWindowSafely(
                        window,
                        ordered: .above
                    )
                }

            case "current": fallthrough
            default:
                addedToTabGroup = parent.addTabbedWindowSafely(
                    window,
                    ordered: .above
                )
            }

            guard addedToTabGroup,
                  let tabGroup = parent.tabGroup,
                  window.tabGroup === tabGroup,
                  tabGroup.windows.contains(window) else {
                // Detach any caller-owned surface before closing the failed tab.
                // The caller can then restore its original split tree safely.
                controller.surfaceTree = .init()
                window.close()
                return nil
            }
            Self.refreshTabs(in: tabGroup)
        }

        // We're dispatching this async because otherwise the lastCascadePoint doesn't
        // take effect. Our best theory is there is some next-event-loop-tick logic
        // that Cocoa is doing that we need to be after.
        controller.scheduleInitialPresentation {
            // Only cascade if we aren't fullscreen and are alone in the tab group.
            if !window.styleMask.contains(.fullScreen) &&
                window.tabGroup?.windows.count ?? 1 == 1 {
                let hasFixedPos = controller.derivedConfig.windowPositionX != nil && controller.derivedConfig.windowPositionY != nil
                Self.applyCascade(to: window, hasFixedPos: hasFixedPos)
            }

            // showWindow makes regular windows key and ordered front. AppKit can
            // throw while selecting a tab if its fullscreen stack is inconsistent,
            // so this must cross the Objective-C exception bridge.
            controller.showWindowSafely(self)

            // We also activate our app so that it becomes front. This may be
            // necessary for the dock menu.
            NSApp.activate(ignoringOtherApps: true)
        }

        // It takes an event loop cycle until the macOS tabGroup state becomes
        // consistent which causes our tab labeling to be off when the "+" button
        // is used in the tab bar. This fixes that. If we can find a more robust
        // solution we should do that.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            controller.relabelTabs()
            Self.refreshTabs(in: window.tabGroup)
        }

        // Setup our undo
        if registerUndo, let undoManager = parentController.undoManager {
            undoManager.setActionName("New Tab")
            undoManager.registerUndo(
                withTarget: controller,
                expiresAfter: controller.undoExpiration
            ) { target in
                // Close the tab when undoing
                undoManager.disableUndoRegistration {
                    target.closeTab(nil)
                }

                // Register redo action
                undoManager.registerUndo(
                    withTarget: ghostty,
                    expiresAfter: target.undoExpiration
                ) { ghostty in
                    _ = TerminalController.newTab(
                        ghostty,
                        from: parent,
                        withBaseConfig: resolvedBaseConfig,
                        withSurfaceTree: surfaceTree,
                        registerUndo: registerUndo)
                }
            }
        }

        return controller
    }

    // MARK: - Methods

    @objc private func ghosttyConfigDidChange(_ notification: Notification) {
        // Get our managed configuration object out
        guard let config = notification.userInfo?[
            Notification.Name.GhosttyConfigChangeKey
        ] as? Ghostty.Config else { return }

        // If this is an app-level config update then we update some things.
        if notification.object == nil {
            // Update our derived config
            self.derivedConfig = DerivedConfig(config)

            // If we have no surfaces in our window (is that possible?) then we update
            // our window appearance based on the root config. If we have surfaces, we
            // don't call this because focused surface changes will trigger appearance updates.
            if surfaceTree.isEmpty {
                syncAppearance(.init(config))
            }

            return
        }
        /// Surface-level config will be updated in
        /// ``Ghostty/Ghostty/SurfaceView/derivedConfig`` then
        /// ``TerminalController/focusedSurfaceDidChange(to:)``
    }

    /// Update the accessory view of each tab according to the keyboard
    /// shortcut that activates it (if any). This is called when the key window
    /// changes, when a window is closed, and when tabs are reordered
    /// with the mouse.
    func relabelTabs() {
        // We only listen for frame changes if we have more than 1 window,
        // otherwise the accessory view doesn't matter.
        tabListenForFrame = window?.tabbedWindows?.count ?? 0 > 1

        if let windows = window?.tabbedWindows as? [TerminalWindow] {
            for (tab, window) in zip(1..., windows) {
                // We need to clear any windows beyond this because they have had
                // a keyEquivalent set previously.
                guard tab <= 9 else {
                    window.keyEquivalent = ""
                    continue
                }

                if let shortcut = tabShortcutLabel(for: tab) {
                    window.keyEquivalent = shortcut
                } else {
                    window.keyEquivalent = ""
                }
            }
        }
    }

    func tabShortcutLabel(for index: Int) -> String? {
        guard (1...9).contains(index),
              let shortcut = ghostty.config.keyboardShortcut(for: "goto_tab:\(index)") else {
            return nil
        }
        return "\(shortcut)"
    }

    @objc private func onFrameDidChange(_ notification: NSNotification) {
        // This is a huge hack to set the proper shortcut for tab selection
        // on tab reordering using the mouse. There is no event, delegate, etc.
        // as far as I can tell for when a tab is manually reordered with the
        // mouse in a macOS-native tab group, so the way we detect it is setting
        // the accessoryView "postsFrameChangedNotification" to true, listening
        // for the view frame to change, comparing the windows list, and
        // relabeling the tabs.
        guard tabListenForFrame else { return }
        guard let v = self.window?.tabbedWindows?.hashValue else { return }
        guard tabWindowsHash != v else { return }
        tabWindowsHash = v
        self.relabelTabs()
    }

    override func syncAppearance() {
        // When our focus changes, we update our window appearance based on the
        // currently focused surface.
        guard let focusedSurface else { return }
        syncAppearance(focusedSurface.derivedConfig)
    }

    private func syncAppearance(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        // Let our window handle its own appearance
        guard let window = window as? TerminalWindow else { return }
        let backgroundColor = focusedSurface?.backgroundColor ?? surfaceConfig.backgroundColor
        let backgroundOpacity = surfaceConfig.backgroundOpacity
        // Mirrors the opaque-window condition in `TerminalWindow.syncAppearance`:
        // native fullscreen forces an opaque window, as does the user's
        // opaque-background toggle (`toggle_background_opacity`).
        let windowIsOpaque = window.styleMask.contains(.fullScreen) || isBackgroundOpaque
        let chromeBackground = Self.chromeBackground(
            color: backgroundColor,
            opacity: backgroundOpacity,
            windowIsOpaque: windowIsOpaque
        )
        let dividerColor = ghostty.config.splitDividerColor(for: backgroundColor)
        if terminalBackgroundColor != backgroundColor ||
            terminalBackgroundOpacity != backgroundOpacity ||
            terminalChromeBackground != chromeBackground ||
            sidebarDividerColor != dividerColor {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.terminalBackgroundColor != backgroundColor {
                    self.terminalBackgroundColor = backgroundColor
                }
                if self.terminalBackgroundOpacity != backgroundOpacity {
                    self.terminalBackgroundOpacity = backgroundOpacity
                }
                if self.terminalChromeBackground != chromeBackground {
                    self.terminalChromeBackground = chromeBackground
                }
                if self.sidebarDividerColor != dividerColor {
                    self.sidebarDividerColor = dividerColor
                }
            }
        }

        // Sync our zoom state for splits
        window.surfaceIsZoomed = surfaceTree.zoomed != nil

        // Set the font for the window and tab titles.
        if let titleFontName = surfaceConfig.windowTitleFontFamily {
            window.titlebarFont = NSFont(name: titleFontName, size: NSFont.systemFontSize)
        } else {
            window.titlebarFont = nil
        }

        // Call this last in case it uses any of the properties above.
        window.syncAppearance(surfaceConfig)
        terminalViewContainer?.ghosttyConfigDidChange(ghostty.config, preferredBackgroundColor: window.preferredBackgroundColor)
    }

    /// The background color app shell chrome should paint with.
    ///
    /// When the window is transparent, the chrome uses the terminal
    /// background at the configured opacity so it blends with whatever is
    /// behind the window, matching the terminal surface. When the window is
    /// opaque (fullscreen / opaque toggle), the terminal surface's alpha
    /// composited over the opaque same-colored window background yields the
    /// opaque background color, so the chrome must paint that same opaque
    /// color instead of relying on Core Animation to composite a second
    /// semi-transparent layer (which produces a visible mismatch).
    static func chromeBackground(color: Color, opacity: Double, windowIsOpaque: Bool) -> Color {
        if windowIsOpaque || opacity >= 1 {
            return color.opacity(1)
        }
        return color.opacity(max(0, min(1, opacity)))
    }

    /// Adjusts the given frame for the configured window position.
    func adjustForWindowPosition(frame: NSRect, on screen: NSScreen) -> NSRect {
        guard let x = derivedConfig.windowPositionX else { return frame }
        guard let y = derivedConfig.windowPositionY else { return frame }

        // Convert top-left coordinates to bottom-left origin using our utility extension
        let origin = screen.origin(
            fromTopLeftOffsetX: CGFloat(x),
            offsetY: CGFloat(y),
            windowSize: frame.size)

        // Clamp the origin to ensure the window stays fully visible on screen
        var safeOrigin = origin
        let vf = screen.visibleFrame
        safeOrigin.x = min(max(safeOrigin.x, vf.minX), vf.maxX - frame.width)
        safeOrigin.y = min(max(safeOrigin.y, vf.minY), vf.maxY - frame.height)

        // Return our new origin
        var result = frame
        result.origin = safeOrigin
        return result
    }

    /// This is called anytime a node in the surface tree is being removed.
    override func closeSurface(
        _ node: SplitTree<Ghostty.SurfaceView>.Node,
        withConfirmation: Bool = true
    ) {
        let leafIDs = node.leaves().map(\.id)
        guard EditorWorkspaceStore.shared.prepareToClose(surfaceIDs: leafIDs, window: window, retry: { [weak self] in
            self?.closeSurface(node, withConfirmation: withConfirmation)
        }) else { return }

        // If this isn't the root then we're dealing with a split closure.
        if surfaceTree.root != node {
            guard surfaceTree.contains(node) else { return }
            if !withConfirmation {
                EditorWorkspaceStore.shared.remove(surfaceIDs: leafIDs)
                removeSurfaceNode(node, registerUndo: false)
                return
            }
            confirmClose(
                messageText: "Close Terminal?",
                informativeText: "The terminal still has a running process. If you close the terminal the process will be killed."
            ) { [weak self] in
                guard let self else { return }
                EditorWorkspaceStore.shared.remove(surfaceIDs: leafIDs)
                self.removeSurfaceNode(node, registerUndo: false)
            }
            return
        }

        // More than 1 window means we have tabs and we're closing a tab
        if window?.tabGroup?.windows.count ?? 0 > 1 {
            if withConfirmation {
                closeTab(nil)
            } else {
                closeTabImmediately()
            }
            return
        }

        // 1 window, closing the window
        if withConfirmation {
            closeWindow(nil)
        } else {
            closeWindowImmediately()
        }
    }

    func closeTabImmediately(registerRedo: Bool = true) {
        guard let window = window else { return }
        guard EditorWorkspaceStore.shared.prepareToClose(tabIDs: [tabSessionID], window: window, retry: { [weak self] in
            self?.closeTabImmediately(registerRedo: registerRedo)
        }) else { return }
        guard let tabGroup = window.tabGroup,
                tabGroup.windows.count > 1 else {
            closeWindowImmediately()
            return
        }

        cancelPendingInitialPresentation()

        // Undo
        if let undoManager, let undoState {
            // Register undo action to restore the tab
            undoManager.setActionName("Close Tab")
            undoManager.registerUndo(
                withTarget: ghostty,
                expiresAfter: undoExpiration
            ) { ghostty in
                let newController = TerminalController(ghostty, with: undoState)

                if registerRedo {
                    undoManager.registerUndo(
                        withTarget: newController,
                        expiresAfter: newController.undoExpiration
                    ) { target in
                        target.closeTabImmediately()
                    }
                }
            }
        }

        window.close()
    }

    private func closeOtherTabsImmediately() {
        guard let window = window else { return }
        guard let tabGroup = window.tabGroup else { return }
        guard tabGroup.windows.count > 1 else { return }

        // Start an undo grouping
        if let undoManager {
            undoManager.beginUndoGrouping()
        }
        defer {
            undoManager?.endUndoGrouping()
        }

        // Iterate through all tabs except the current one.
        for window in tabGroup.windows where window != self.window {
            // We ignore any non-terminal tabs. They don't currently exist and we can't
            // properly undo them anyways so I'd rather ignore them and get a bug report
            // later if and when we introduce non-terminal tabs.
            if let controller = window.windowController as? TerminalController {
                // We must not register a redo, because it messes with our own redo
                // that we register later.
                controller.closeTabImmediately(registerRedo: false)
            }
        }

        if let undoManager {
            undoManager.setActionName("Close Other Tabs")

            // We need to register an undo that refocuses this window. Otherwise, the
            // undo operation above for each tab will steal focus.
            undoManager.registerUndo(
                withTarget: self,
                expiresAfter: undoExpiration
            ) { target in
                DispatchQueue.main.async {
                    target.window?.makeKeyAndOrderFront(nil)
                }

                // Register redo action
                undoManager.registerUndo(
                    withTarget: target,
                    expiresAfter: target.undoExpiration
                ) { target in
                    target.closeOtherTabsImmediately()
                }
            }
        }
    }

    private func closeTabsOnTheRightImmediately() {
        guard let window = window else { return }
        guard let tabGroup = window.tabGroup else { return }
        guard let currentIndex = tabGroup.windows.firstIndex(of: window) else { return }

        let tabsToClose = tabGroup.windows.enumerated().filter { $0.offset > currentIndex }
        guard !tabsToClose.isEmpty else { return }

        undoManager?.beginUndoGrouping()
        defer {
            undoManager?.endUndoGrouping()
        }

        for (_, candidate) in tabsToClose {
            if let controller = candidate.windowController as? TerminalController {
                controller.closeTabImmediately(registerRedo: false)
            }
        }

        if let undoManager {
            undoManager.setActionName("Close Tabs to the Right")

            undoManager.registerUndo(
                withTarget: self,
                expiresAfter: undoExpiration
            ) { target in
                DispatchQueue.main.async {
                    target.window?.makeKeyAndOrderFront(nil)
                }

                undoManager.registerUndo(
                    withTarget: target,
                    expiresAfter: target.undoExpiration
                ) { target in
                    target.closeTabsOnTheRightImmediately()
                }
            }
        }
    }

    /// Closes the current window (including any other tabs) immediately and without
    /// confirmation. This will setup proper undo state so the action can be undone.
    func closeWindowImmediately() {
        guard let window = window else { return }
        let editorTabIDs = (window.tabGroup?.windows ?? [window]).compactMap {
            ($0.windowController as? TerminalController)?.tabSessionID
        }
        guard EditorWorkspaceStore.shared.prepareToClose(tabIDs: editorTabIDs, window: window, retry: { [weak self] in
            self?.closeWindowImmediately()
        }) else { return }

        cancelPendingInitialPresentation()

        registerUndoForCloseWindow()

        if let tabGroup = window.tabGroup, tabGroup.windows.count > 1 {
            tabGroup.windows.forEach { window in
                // Clear out the surfacetree to ensure there is no undo state.
                // This prevents unnecessary undos registered since AppKit may
                // process them on later ticks so we can't just disable undo registration.
                if let controller = window.windowController as? TerminalController {
                    controller.cancelPendingInitialPresentation()
                    controller.surfaceTree = .init()
                }

                window.close()
            }
        } else {
            window.close()
        }
    }

    /// Registers undo for closing window(s), handling both single windows and tab groups.
    private func registerUndoForCloseWindow() {
        guard let undoManager, undoManager.isUndoRegistrationEnabled else { return }
        guard let window else { return }

        // If we don't have a tab group or we don't have multiple tabs, then
        // do a normal single window close.
        guard let tabGroup = window.tabGroup,
              tabGroup.windows.count > 1 else {
            // No tabs, just save this window's state
            if let undoState {
                // Register undo action to restore the window
                undoManager.setActionName("Close Window")
                undoManager.registerUndo(
                    withTarget: ghostty,
                    expiresAfter: undoExpiration) { ghostty in
                        // Restore the undo state
                        let newController = TerminalController(ghostty, with: undoState)

                        // Register redo action
                        undoManager.registerUndo(
                            withTarget: newController,
                            expiresAfter: newController.undoExpiration) { target in
                                target.closeWindowImmediately()
                            }
                    }
            }

            return
        }

        // Multiple windows in tab group - collect all undo states in sorted order
        // by tab ordering. Also track which window was key.
        let undoStates = tabGroup.windows
            .compactMap { tabWindow -> UndoState? in
                guard let controller = tabWindow.windowController as? TerminalController,
                      var undoState = controller.undoState else { return nil }
                // Clear the tab group reference since it is unneeded. It should be
                // garbage collected but we want to be extra sure we don't try to
                // restore into it because we're going to recreate it.
                undoState.tabGroup = nil
                return undoState
            }
            .sorted { (lhs, rhs) in
                switch (lhs.tabIndex, rhs.tabIndex) {
                case let (l?, r?): return l < r
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return true
                }
            }

        // Find the index of the key window in our sorted states. This is a bit verbose
        // but we only need this for this style of undo so we don't want to add it to
        // UndoState.
        let keyWindowIndex: Int?
        if let keyWindow = tabGroup.windows.first(where: { $0.isKeyWindow }),
            let keyController = keyWindow.windowController as? TerminalController,
            let keyUndoState = keyController.undoState {
            keyWindowIndex = undoStates.firstIndex {
                $0.tabIndex == keyUndoState.tabIndex }
        } else {
            keyWindowIndex = nil
        }

        // Register undo action to restore all windows
        guard !undoStates.isEmpty else { return }

        undoManager.setActionName("Close Window")
        undoManager.registerUndo(
            withTarget: ghostty,
            expiresAfter: undoExpiration
        ) { ghostty in
            // Restore all windows in the tab group
            let controllers = undoStates.map { undoState in
                TerminalController(ghostty, with: undoState)
            }

            // The first controller becomes the parent window for all tabs.
            // If we don't have a first controller (shouldn't be possible?)
            // then we can't restore tabs.
            guard let firstController = controllers.first else { return }

            // Add all subsequent controllers as tabs to the first window
            for controller in controllers.dropFirst() {
                controller.showWindow(nil)
                if let firstWindow = firstController.window,
                   let newWindow = controller.window {
                    firstWindow.addTabbedWindowSafely(newWindow, ordered: .above)
                }
            }

            // Make the appropriate window key. If we had a key window, restore it.
            // Otherwise, make the last window key.
            if let keyWindowIndex, keyWindowIndex < controllers.count {
                controllers[keyWindowIndex].window?.makeKeyAndOrderFront(nil)
            } else {
                controllers.last?.window?.makeKeyAndOrderFront(nil)
            }

            // Register redo action on the first controller
            undoManager.registerUndo(
                withTarget: firstController,
                expiresAfter: firstController.undoExpiration
            ) { target in
                target.closeWindowImmediately()
            }
        }
    }

    /// Close all windows, asking for confirmation if necessary.
    static func closeAllWindows() {
        // The window we use for confirmations. Try to find the first window that
        // needs quit confirmation. This lets us attach the confirmation to something
        // that is running.
        guard let confirmWindow = all
            .first(where: { $0.surfaceTree.contains(where: { $0.needsConfirmQuit }) })?
            .surfaceTree.first(where: { $0.needsConfirmQuit })?
            .window
        else {
            closeAllWindowsImmediately()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Close All Windows?"
        alert.informativeText = "All terminal sessions will be terminated."
        alert.addButton(withTitle: "Close All Windows")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: confirmWindow, completionHandler: { response in
            if response == .alertFirstButtonReturn {
                // This is important so that we avoid losing focus when Stage
                // Manager is used (#8336)
                alert.window.orderOut(nil)
                closeAllWindowsImmediately()
            }
        })
    }

    static private func closeAllWindowsImmediately() {
        let undoManager = (NSApp.delegate as? AppDelegate)?.undoManager
        undoManager?.beginUndoGrouping()
        all.forEach { $0.closeWindowImmediately() }
        undoManager?.setActionName("Close All Windows")
        undoManager?.endUndoGrouping()
    }

    // MARK: Undo/Redo

    /// The state that we require to recreate a TerminalController from an undo.
    struct UndoState {
        let frame: NSRect
        let surfaceTree: SplitTree<Ghostty.SurfaceView>
        let focusedSurface: UUID?
        let tabIndex: Int?
        weak var tabGroup: NSWindowTabGroup?
        let tabColor: TerminalTabColor
        let tabSessionID: UUID
        let tabCreatedAt: Date
        let paneSessionStates: [UUID: PaneSessionStateSnapshot]
    }

    convenience init(_ ghostty: Ghostty.App, with undoState: UndoState) {
        self.init(
            ghostty,
            withSurfaceTree: undoState.surfaceTree,
            tabSessionID: undoState.tabSessionID,
            tabCreatedAt: undoState.tabCreatedAt
        )
        for (surfaceID, snapshot) in undoState.paneSessionStates {
            restorePaneSessionState(snapshot, for: surfaceID)
        }

        // Show the window and restore its frame
        showWindow(nil)
        if let window {
            window.setFrame(undoState.frame, display: true)
            if let terminalWindow = window as? TerminalWindow {
                terminalWindow.tabColor = undoState.tabColor
            }

            // If we have a tab group and index, restore the tab to its original position
            if let tabGroup = undoState.tabGroup,
               let tabIndex = undoState.tabIndex {
                if tabIndex < tabGroup.windows.count {
                    // Find the window that is currently at that index
                    let currentWindow = tabGroup.windows[tabIndex]
                    currentWindow.addTabbedWindowSafely(window, ordered: .below)
                } else {
                    tabGroup.windows.last?.addTabbedWindowSafely(window, ordered: .above)
                }

                // Make it the key window
                window.makeKeyAndOrderFront(nil)
            }

            // Restore focus to the previously focused surface
            if let focusedUUID = undoState.focusedSurface,
               let focusTarget = surfaceTree.first(where: { $0.id == focusedUUID }) {
                DispatchQueue.main.async {
                    Ghostty.moveFocus(to: focusTarget, from: nil)
                }
            } else if let focusedSurface = surfaceTree.first {
                // No prior focused surface or we can't find it, let's focus
                // the first.
                self.focusedSurface = focusedSurface
                DispatchQueue.main.async {
                    Ghostty.moveFocus(to: focusedSurface, from: nil)
                }
            }
        }
    }

    /// The current undo state for this controller
    var undoState: UndoState? {
        guard let window else { return nil }
        guard !surfaceTree.isEmpty else { return nil }
        return .init(
            frame: window.frame,
            surfaceTree: surfaceTree,
            focusedSurface: focusedSurface?.id,
            tabIndex: window.tabGroup?.windows.firstIndex(of: window),
            tabGroup: window.tabGroup,
            tabColor: (window as? TerminalWindow)?.tabColor ?? .none,
            tabSessionID: tabSessionID,
            tabCreatedAt: tabCreatedAt,
            paneSessionStates: Dictionary(
                uniqueKeysWithValues: surfaceTree.compactMap { surface in
                    capturePaneSessionState(for: surface.id).map {
                        (surface.id, $0)
                    }
                }
            )
        )
    }

    // MARK: - NSWindowController

    override func windowWillLoad() {
        // We do NOT want to cascade because we handle this manually from the manager.
        shouldCascadeWindows = false
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        guard let window else { return }

        // I copy this because we may change the source in the future but also because
        // I regularly audit our codebase for "ghostty.config" access because generally
        // you shouldn't use it. Its safe in this case because for a new window we should
        // use whatever the latest app-level config is.
        let config = ghostty.config

        // Setting all three of these is required for restoration to work.
        window.isRestorable = restorable
        if restorable {
            window.restorationClass = TerminalWindowRestoration.self
            window.identifier = .init(String(describing: TerminalWindowRestoration.self))
        }

        // If we have only a single surface (no splits) and there is a default size then
        // we should resize to that default size.
        if case let .leaf(view) = surfaceTree.root {
            // If this is our first surface then our focused surface will be nil
            // so we force the focused surface to the leaf.
            focusedSurface = view
        }

        // Initialize our content view to the SwiftUI root
        let container = TerminalViewContainer {
            TerminalView(ghostty: ghostty, viewModel: self, delegate: self)
        }

        // Set the initial content size on the container so that
        // intrinsicContentSize returns the correct value immediately,
        // without waiting for @FocusedValue to propagate through the
        // SwiftUI focus chain.
        container.initialContentSize = focusedSurface?.initialSize

        window.contentView = container

        // If we have a default size, we want to apply it.
        if let defaultSize {
            defaultSize.apply(to: window)

            if case .contentIntrinsicSize = defaultSize {
                if let screen = window.screen ?? NSScreen.main {
                    let frame = self.adjustForWindowPosition(frame: window.frame, on: screen)
                    window.setFrameOrigin(frame.origin)
                }
            }
        }

        // In various situations, macOS automatically tabs new windows. Ghostty handles
        // its own tabbing so we DONT want this behavior. This detects this scenario and undoes
        // it.
        //
        // Example scenarios where this happens:
        //   - When the system user tabbing preference is "always"
        //   - When the "+" button in the tab bar is clicked
        //
        // We don't run this logic in fullscreen because in fullscreen this will end up
        // removing the window and putting it into its own dedicated fullscreen, which is not
        // the expected or desired behavior of anyone I've found.
        //
        // We also only run this when the system tabbing preference is "always",
        // which is the only scenario AppKit will have auto-tabbed a fresh window
        // at this point: the tab bar "+" button goes through newWindowForTab
        // which we route through our own tab logic. This check matters because
        // accessing `window.tabGroup` materializes the window's tab group
        // machinery, which takes ~15-20ms and is otherwise not needed during
        // window creation.
        if NSWindow.userTabbingPreference == .always,
           !window.styleMask.contains(.fullScreen) {
            // If we have more than 1 window in our tab group we know we're a new window.
            // Since Ghostty manages tabbing manually this will never be more than one
            // at this point in the AppKit lifecycle (we add to the group after this).
            if let tabGroup = window.tabGroup, tabGroup.windows.count > 1 {
                window.tabGroup?.removeWindow(window)
            }
        }

        (window as? VerticalTabsTerminalWindow)?.installSidebarToggle(controller: self)
        if let appDelegate = NSApp.delegate as? AppDelegate {
            (window as? TerminalWindow)?.installInspectorToggle(
                controller: self,
                registry: appDelegate.inspectorRegistry
            )
        }

        // Apply any additional appearance-related properties to the new window. We
        // apply this based on the root config but change it later based on surface
        // config (see focused surface change callback).
        syncAppearance(.init(config))
        setupTabObservation()
    }

    /// Setup correct window frame before showing the window
    override func showWindow(_ sender: Any?) {
        guard let terminalWindow = window as? TerminalWindow else { return }

        // Set the initial window position. This must happen after the window
        // is fully set up (content view, toolbar, default size) so that
        // decorations added by subclass awakeFromNib (e.g. toolbar for tabs
        // style) don't change the frame after the position is restored.
        let originChanged = terminalWindow.setInitialWindowPosition(
            x: derivedConfig.windowPositionX,
            y: derivedConfig.windowPositionY,
        )
        let restored = LastWindowPosition.shared.restore(
            terminalWindow,
            origin: !originChanged,
            size: defaultSize == nil,
        )

        // If nothing is changed for the frame,
        // we should center the window
        if !originChanged, !restored {
            // This doesn't work in `windowDidLoad` somehow
            terminalWindow.center()
        }

        super.showWindow(sender)

        syncAppearance()
    }

    // Shows the "+" button in the tab bar, responds to that click.
    override func newWindowForTab(_ sender: Any?) {
        // Trigger the ghostty core event logic for a new tab.
        guard let surface = self.focusedSurface?.surface else { return }
        ghostty.newTab(surface: surface)
    }

    // MARK: NSWindowDelegate

    // TabGroupCloseCoordinator.Controller
    lazy private(set) var tabGroupCloseCoordinator = TabGroupCloseCoordinator()

    override func windowShouldClose(_ sender: NSWindow) -> Bool {
        tabGroupCloseCoordinator.windowShouldClose(sender) { [weak self] scope in
            guard let self else { return }
            switch scope {
            case .tab: closeTab(nil)
            case .window:
                guard self.window?.isFirstWindowInTabGroup ?? false else { return }
                closeWindow(nil)
            }
        }

        // We will always explicitly close the window using the above
        return false
    }

    override func windowWillClose(_ notification: Notification) {
        super.windowWillClose(notification)
        EditorWorkspaceStore.shared.remove(tabID: tabSessionID)
        (NSApp.delegate as? AppDelegate)?.releaseInspectorState(tabID: tabSessionID)
        (NSApp.delegate as? AppDelegate)?.tabActivities.removeSession(tabSessionID)
        cancelPendingInitialPresentation()
        self.relabelTabs()

        // If we remove a window, we reset the cascade point to the key window so that
        // the next window cascade's from that one.
        if let focusedWindow = NSApplication.shared.keyWindow {
            // If we are NOT the focused window, then we are a tabbed window. If we
            // are closing a tabbed window, we want to set the cascade point to be
            // the next cascade point from this window.
            if focusedWindow != window {
                // The cascadeTopLeft call below should NOT move the window. Starting with
                // macOS 15, we found that specifically when used with the new window snapping
                // features of macOS 15, this WOULD move the frame. So we keep track of the
                // old frame and restore it if necessary. Issue:
                // https://github.com/ghostty-org/ghostty/issues/2565
                let oldFrame = focusedWindow.frame

                Self.lastCascadePoint = focusedWindow.cascadeTopLeft(from: .zero)

                if focusedWindow.frame != oldFrame {
                    focusedWindow.setFrame(oldFrame, display: true)
                }

                return
            }

            // If we are the focused window, then we set the last cascade point to
            // our own frame so that it shows up in the same spot.
            let frame = focusedWindow.frame
            Self.lastCascadePoint = NSPoint(x: frame.minX, y: frame.maxY)
        }
    }

    override func windowDidBecomeKey(_ notification: Notification) {
        super.windowDidBecomeKey(notification)
        markTabActivated()
        setupTabObservation()
        Self.refreshTabs(in: window?.tabGroup)
        self.relabelTabs()
        terminalViewContainer?.updateGlassTintOverlay(isKeyWindow: true)
    }

    override func windowDidResignKey(_ notification: Notification) {
        super.windowDidResignKey(notification)
        terminalViewContainer?.updateGlassTintOverlay(isKeyWindow: false)
    }

    override func windowDidMove(_ notification: Notification) {
        super.windowDidMove(notification)

        // Whenever we move save our last position for the next start.
        LastWindowPosition.shared.save(window)
    }

    override func windowDidResize(_ notification: Notification) {
        super.windowDidResize(notification)

        // Whenever we resize save our last position and size for the next start.
        LastWindowPosition.shared.save(window)
    }

    func windowDidBecomeMain(_ notification: Notification) {
        // Whenever we get focused, use that as our last window position for
        // restart. This differs from Terminal.app but matches iTerm2 behavior
        // and I think its sensible.
        LastWindowPosition.shared.save(window)

        // Remember our last main
        Self.lastMain = self
    }

    // Called when the window will be encoded. We handle the data encoding here in the
    // window controller.
    func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
        let data = TerminalRestorableState(from: self)
        data.encode(with: state)
    }

    // MARK: First Responder

    @IBAction func newWindow(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.newWindow(surface: surface)
    }

    @IBAction func newTab(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.newTab(surface: surface)
    }

    @IBAction func closeTab(_ sender: Any?) {
        guard let window = window else { return }
        guard window.tabGroup?.windows.count ?? 0 > 1 else {
            closeWindow(sender)
            return
        }

        guard surfaceTree.contains(where: { $0.needsConfirmQuit }) else {
            closeTabImmediately()
            return
        }

        confirmClose(
            messageText: "Close Tab?",
            informativeText: "The terminal still has a running process. If you close the tab the process will be killed."
        ) {
            self.closeTabImmediately()
        }
    }

    @IBAction func closeOtherTabs(_ sender: Any?) {
        guard let window = window else { return }
        guard let tabGroup = window.tabGroup else { return }

        // If we only have one window then we have no other tabs to close
        guard tabGroup.windows.count > 1 else { return }

        // Check if we have to confirm close.
        guard tabGroup.windows.contains(where: { window in
            // Ignore ourself
            if window == self.window { return false }

            // Ignore non-terminals
            guard let controller = window.windowController as? TerminalController else {
                return false
            }

            // Check if any surfaces require confirmation
            return controller.surfaceTree.contains(where: { $0.needsConfirmQuit })
        }) else {
            self.closeOtherTabsImmediately()
            return
        }

        confirmClose(
            messageText: "Close Other Tabs?",
            informativeText: "At least one other tab still has a running process. If you close the tab the process will be killed."
        ) {
            self.closeOtherTabsImmediately()
        }
    }

    @IBAction func closeTabsOnTheRight(_ sender: Any?) {
        guard let window = window else { return }
        guard let tabGroup = window.tabGroup else { return }
        guard let currentIndex = tabGroup.windows.firstIndex(of: window) else { return }

        let tabsToClose = tabGroup.windows.enumerated().filter { $0.offset > currentIndex }
        guard !tabsToClose.isEmpty else { return }

        let needsConfirm = tabsToClose.contains { (_, candidate) in
            guard let controller = candidate.windowController as? TerminalController else {
                return false
            }

            return controller.surfaceTree.contains(where: { $0.needsConfirmQuit })
        }

        if !needsConfirm {
            self.closeTabsOnTheRightImmediately()
            return
        }

        confirmClose(
            messageText: "Close Tabs on the Right?",
            informativeText: "At least one tab to the right still has a running process. If you close the tab the process will be killed."
        ) {
            self.closeTabsOnTheRightImmediately()
        }
    }

    @IBAction func returnToDefaultSize(_ sender: Any?) {
        guard let window, let defaultSize else { return }
        defaultSize.apply(to: window)
    }

    @IBAction override func closeWindow(_ sender: Any?) {
        guard let window = window else { return }

        // We need to check all the windows in our tab group for confirmation
        // if we're closing the window. If we don't have a tabgroup for any
        // reason we check ourselves.
        let windows: [NSWindow] = window.tabGroup?.windows ?? [window]
        guard let confirmController = windows
            .compactMap({ $0.windowController as? TerminalController })
            .first(where: { $0.surfaceTree.contains(where: { $0.needsConfirmQuit }) })
        else {
            closeWindowImmediately()
            return
        }

        // We call confirmClose on the proper controller so the alert is
        // attached to the window that needs confirmation.
        confirmController.confirmClose(
            messageText: "Close Window?",
            informativeText: "All terminal sessions in this window will be terminated.",
        ) {
            self.closeWindowImmediately()
        }
    }

    @IBAction func toggleGhosttyFullScreen(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.toggleFullscreen(surface: surface)
    }

    @IBAction func toggleTerminalInspector(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.toggleTerminalInspector(surface: surface)
    }

    // MARK: - TerminalViewDelegate

    override func focusedSurfaceDidChange(to: Ghostty.SurfaceView?) {
        super.focusedSurfaceDidChange(to: to)

        // We always cancel our event listener
        surfaceAppearanceCancellables.removeAll()

        guard let focusedSurface else { return }
        syncAppearance(focusedSurface.derivedConfig)

        // We also want to get notified of certain changes to update our appearance.
        focusedSurface.$derivedConfig
            .dropFirst()
            .sink { [weak self, weak focusedSurface] _ in self?.syncAppearanceOnPropertyChange(focusedSurface) }
            .store(in: &surfaceAppearanceCancellables)
        focusedSurface.$backgroundColor
            .dropFirst()
            .sink { [weak self, weak focusedSurface] _ in self?.syncAppearanceOnPropertyChange(focusedSurface) }
            .store(in: &surfaceAppearanceCancellables)
    }

    private func syncAppearanceOnPropertyChange(_ surface: Ghostty.SurfaceView?) {
        guard let surface else { return }
        DispatchQueue.main.async { [weak self, weak surface] in
            guard let surface else { return }
            guard let self else { return }
            guard self.focusedSurface == surface else { return }
            self.syncAppearance(surface.derivedConfig)
        }
    }

    // MARK: - Notifications

    @objc private func onAgentIntegrationChanged(_ notification: SwiftUI.Notification) {
        guard let rawAgent = notification.userInfo?[
            AgentHookInstaller.changedAgentUserInfoKey
        ] as? String,
        let agent = SupportedAgent(rawValue: rawAgent) else { return }
        let installer = AgentHookInstaller()
        let staleSurfaceIDs = detectedAgentInstances.compactMap { surfaceID, detected in
            detected.agent == agent && !installer.isInstalled(agent)
                ? surfaceID : nil
        }
        for surfaceID in staleSurfaceIDs {
            clearDetectedAgent(for: surfaceID, force: true)
        }
        observedForegroundProcessIDs = [:]
        pollLocalAgentProcesses()
    }

    @objc private func onOhMyGhosttySettingsChanged(_ notification: SwiftUI.Notification) {
        let settings = OhMyGhosttySettings.shared
        let changedKey = notification.userInfo?[
            OhMyGhosttySettings.changedKeyUserInfoKey
        ] as? String
        if changedKey == nil || changedKey == "agents.statusHooks" {
            if !settings.agentStatusHooksEnabled {
                agentActivities = [:]
                agentReducers = [:]
                typedAgentHookContextIDs = [:]
                agentResumeDescriptors = [:]
                agentResumeContextIDs = [:]
                observedForegroundProcessIDs = [:]
                detectedAgentInstances = [:]
                conversationDiscoveryPending = []
                agentScreenSignatures = [:]
                agentScreenStableTicks = [:]
                agentValidationWorkItems.values.forEach { $0.cancel() }
                agentValidationWorkItems = [:]
            }
        }
        if changedKey == nil || changedKey == "keyboard.quickInputHeight" {
            quickInputModel.applyConfiguredDockHeight(
                CGFloat(settings.quickInputHeight),
                availableHeight: window?.contentLayoutRect.height ?? 720
            )
        }
        guard supportsSidebar,
              window?.tabGroup?.selectedWindow === window else { return }
        if changedKey == nil ||
            changedKey == "tabs.sidebarVisible" ||
            changedKey == "tabs.sidebarWidth" {
            tabLayoutState.applySidebarPreferences(
                visible: settings.sidebarVisible,
                width: CGFloat(settings.defaultSidebarWidth),
                availableWidth: window?.contentLayoutRect.width ?? 960
            )
        }
        if tabLayoutState.groupingMode != settings.groupingMode ||
            tabLayoutState.orderingMode != settings.orderingMode {
            reconcileTabOrganization(
                grouping: settings.groupingMode,
                ordering: settings.orderingMode
            )
            tabLayoutState.applyPreferences(
                grouping: settings.groupingMode,
                ordering: settings.orderingMode
            )
        }
    }

    @objc private func onMoveTab(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }
        guard let window = self.window else { return }

        // Get the move action
        guard let action = notification.userInfo?[Notification.Name.GhosttyMoveTabKey] as? Ghostty.Action.MoveTab else { return }
        guard action.amount != 0 else { return }

        // Determine our current selected index
        guard let windowController = window.windowController else { return }
        guard let tabGroup = windowController.window?.tabGroup else { return }
        guard let selectedWindow = tabGroup.selectedWindow else { return }
        let tabbedWindows = tabGroup.windows
        guard tabbedWindows.count > 0 else { return }
        guard let selectedIndex = tabbedWindows.firstIndex(where: { $0 == selectedWindow }) else { return }

        // Determine the final index we want to insert our tab
        let finalIndex: Int
        if action.amount < 0 {
            finalIndex = selectedIndex - min(selectedIndex, -action.amount)
        } else {
            let remaining: Int = tabbedWindows.count - 1 - selectedIndex
            finalIndex = selectedIndex + min(remaining, action.amount)
        }

        // If our index is the same we do nothing
        guard finalIndex != selectedIndex else { return }

        if supportsSidebar {
            let insertionIndex = finalIndex > selectedIndex ? finalIndex + 1 : finalIndex
            _ = reorderTab(self, toInsertionIndex: insertionIndex)
            return
        }

        // Get our target window
        let targetWindow = tabbedWindows[finalIndex]

        // Moving tabs on macOS 26 RC causes very nasty visual glitches in the titlebar tabs.
        // I believe this is due to messed up constraints for our hacky tab bar. I'd like to
        // find a better workaround. For now, this improves things dramatically.
        //
        // Reproduction: titlebar tabs, create two tabs, "move tab left"
        if #available(macOS 26, *) {
            if window is TitlebarTabsTahoeTerminalWindow {
                tabGroup.removeWindow(selectedWindow)
                targetWindow.addTabbedWindowSafely(selectedWindow, ordered: action.amount < 0 ? .below : .above)
                DispatchQueue.main.async {
                    selectedWindow.makeKey()
                }

                return
            }
        }

        // Begin a group of window operations to minimize visual updates
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0

        // Remove and re-add the window in the correct position
        tabGroup.removeWindow(selectedWindow)
        targetWindow.addTabbedWindowSafely(selectedWindow, ordered: action.amount < 0 ? .below : .above)

        // Ensure our window remains selected
        selectedWindow.makeKey()

        NSAnimationContext.endGrouping()
    }

    @objc private func onGotoTab(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }
        guard let window = self.window else { return }

        // Get the tab index from the notification
        guard let tabEnumAny = notification.userInfo?[Ghostty.Notification.GotoTabKey] else { return }
        guard let tabEnum = tabEnumAny as? ghostty_action_goto_tab_e else { return }
        let tabIndex: Int32 = tabEnum.rawValue

        guard let windowController = window.windowController else { return }
        guard let tabGroup = windowController.window?.tabGroup else { return }
        let tabbedWindows = tabGroup.windows

        // This will be the index we want to actual go to
        let finalIndex: Int

        // An index that is invalid is used to signal some special values.
        if tabIndex <= 0 {
            guard let selectedWindow = tabGroup.selectedWindow else { return }
            guard let selectedIndex = tabbedWindows.firstIndex(where: { $0 == selectedWindow }) else { return }

            if tabIndex == GHOSTTY_GOTO_TAB_PREVIOUS.rawValue {
                if selectedIndex == 0 {
                    finalIndex = tabbedWindows.count - 1
                } else {
                    finalIndex = selectedIndex - 1
                }
            } else if tabIndex == GHOSTTY_GOTO_TAB_NEXT.rawValue {
                if selectedIndex == tabbedWindows.count - 1 {
                    finalIndex = 0
                } else {
                    finalIndex = selectedIndex + 1
                }
            } else if tabIndex == GHOSTTY_GOTO_TAB_LAST.rawValue {
                finalIndex = tabbedWindows.count - 1
            } else {
                return
            }
        } else {
            // The configured value is 1-indexed.
            guard tabIndex >= 1 else { return }

            // If our index is outside our boundary then we use the max
            finalIndex = min(Int(tabIndex - 1), tabbedWindows.count - 1)
        }

        guard finalIndex >= 0 else { return }
        let targetWindow = tabbedWindows[finalIndex]
        tabGroup.selectedWindow = targetWindow
        (targetWindow.windowController as? TerminalController)?.markTabActivated()
        targetWindow.makeKeyAndOrderFront(nil)
        Self.refreshTabs(in: tabGroup)
    }

    @discardableResult
    static func selectTab(digit: Int, in window: NSWindow?) -> Bool {
        guard let tabGroup = window?.tabGroup else { return false }
        let tabbedWindows = tabGroup.windows
        guard tabbedWindows.count > 1 else { return false }
        let targetIndex = digit == 9 ? (tabbedWindows.count - 1) : (digit - 1)
        guard targetIndex >= 0, targetIndex < tabbedWindows.count else { return false }
        let targetWindow = tabbedWindows[targetIndex]
        tabGroup.selectedWindow = targetWindow
        (targetWindow.windowController as? TerminalController)?.markTabActivated()
        targetWindow.makeKeyAndOrderFront(nil)
        Self.refreshTabs(in: tabGroup)
        return true
    }

    @objc private func onCloseTab(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        closeTab(self)
    }

    @objc private func onCloseOtherTabs(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        closeOtherTabs(self)
    }

    @objc private func onCloseTabsOnTheRight(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        closeTabsOnTheRight(self)
    }

    @objc private func onCloseWindow(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        closeWindow(self)
    }

    @objc private func onResetWindowSize(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        returnToDefaultSize(nil)
    }

    @objc private func onToggleFullscreen(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }

        // Get the fullscreen mode we want to toggle
        let fullscreenMode: FullscreenMode
        if let any = notification.userInfo?[Ghostty.Notification.FullscreenModeKey],
           let mode = any as? FullscreenMode {
            fullscreenMode = mode
        } else {
            Ghostty.logger.warning("no fullscreen mode specified or invalid mode, doing nothing")
            return
        }

        toggleFullscreen(mode: fullscreenMode)
    }

    struct DerivedConfig {
        let backgroundColor: Color
        let macosWindowButtons: Ghostty.MacOSWindowButtons
        let macosTitlebarStyle: Ghostty.Config.MacOSTitlebarStyle
        let maximize: Bool
        let windowPositionX: Int16?
        let windowPositionY: Int16?

        init() {
            self.backgroundColor = Color(NSColor.windowBackgroundColor)
            self.macosWindowButtons = .visible
            self.macosTitlebarStyle = .default
            self.maximize = false
            self.windowPositionX = nil
            self.windowPositionY = nil
        }

        init(_ config: Ghostty.Config) {
            self.backgroundColor = config.backgroundColor
            self.macosWindowButtons = config.macosWindowButtons
            self.macosTitlebarStyle = config.macosTitlebarStyle
            self.maximize = config.maximize
            self.windowPositionX = config.windowPositionX
            self.windowPositionY = config.windowPositionY
        }
    }
}

private nonisolated(unsafe) var verticalTabLayoutStateAssociationKey: UInt8 = 0

extension NSWindowTabGroup {
    @MainActor
    func setGhosttyTerminalShellLayoutState(
        _ state: VerticalTabWindowLayoutState
    ) {
        objc_setAssociatedObject(
            self,
            &verticalTabLayoutStateAssociationKey,
            state,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    @MainActor
    var ghosttyTerminalShellLayoutState: VerticalTabWindowLayoutState {
        if let state = objc_getAssociatedObject(
            self,
            &verticalTabLayoutStateAssociationKey
        ) as? VerticalTabWindowLayoutState {
            return state
        }

        let state = windows
            .compactMap { $0.windowController as? TerminalController }
            .first?
            .tabLayoutState ?? VerticalTabWindowLayoutState(
                isSidebarVisible: OhMyGhosttySettings.shared.tabLayout == .vertical &&
                    OhMyGhosttySettings.shared.sidebarVisible,
                isInspectorVisible: false
            )
        setGhosttyTerminalShellLayoutState(state)
        return state
    }

    /// Compatibility name for vertical-tab call sites and tests.
    @MainActor
    var ghosttyVerticalTabLayoutState: VerticalTabWindowLayoutState {
        ghosttyTerminalShellLayoutState
    }
}

// MARK: NSMenuItemValidation

extension TerminalController {
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(closeTabsOnTheRight):
            guard let window, let tabGroup = window.tabGroup else { return false }
            guard let currentIndex = tabGroup.windows.firstIndex(of: window) else { return false }
            return tabGroup.windows.indices.contains { $0 > currentIndex }

        case #selector(returnToDefaultSize):
            guard let window else { return false }

            // Native fullscreen windows can't revert to default size.
            if window.styleMask.contains(.fullScreen) {
                return false
            }

            // If we're fullscreen at all then we can't change size
            if fullscreenStyle?.isFullscreen ?? false {
                return false
            }

            // If our window is already the default size or we don't have a
            // default size, then disable.
            return defaultSize?.isChanged(for: window) ?? false

        default:
            return super.validateMenuItem(item)
        }
    }
}

// MARK: Default Size

extension TerminalController {
    /// The possible default sizes for a terminal. The size can't purely be known as a
    /// window frame because if we set `window-width/height` then it is based
    /// on content size.
    enum DefaultSize {
        /// A frame, set with `window.setFrame`
        case frame(NSRect)

        /// A content size, set with `window.setContentSize`
        case contentIntrinsicSize

        func isChanged(for window: NSWindow) -> Bool {
            switch self {
            case .frame(let rect):
                return window.frame != rect
            case .contentIntrinsicSize:
                guard let view = window.contentView else {
                    return false
                }

                return view.frame.size != view.intrinsicContentSize
            }
        }

        func apply(to window: NSWindow) {
            switch self {
            case .frame(let rect):
                window.setFrame(rect, display: true)
            case .contentIntrinsicSize:
                guard let size = window.contentView?.intrinsicContentSize else {
                    return
                }

                window.setContentSize(size)
                window.constrainToScreen()
            }
        }
    }

    private var defaultSize: DefaultSize? {
        if derivedConfig.maximize, let screen = window?.screen ?? NSScreen.main {
            // Maximize takes priority, we take up the full screen we're on.
            return .frame(screen.visibleFrame)
        } else if focusedSurface?.initialSize != nil {
            // Initial size as requested by the configuration (e.g. `window-width`)
            // takes next priority.
            return .contentIntrinsicSize
        } else {
            return nil
        }
    }
}
