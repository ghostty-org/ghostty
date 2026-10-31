import AppKit
import Combine
import SwiftUI

/// Native window accessories; never owns or recreates a terminal session.
@MainActor
final class TerminalTabChromeController {
    private weak var controller: TerminalController?
    private weak var window: TerminalWindow?
    private let leading = NSTitlebarAccessoryViewController()
    private let workspace = TerminalWorkspaceHeaderButton()
    private let sidebar = NativeActionControl()
    private let newTab = NativeActionControl()
    private let icon = NativeTabIconView()
    private let status = NSImageView()
    private var subscriptions = Set<AnyCancellable>()
    private var surfaceSubscriptions = Set<AnyCancellable>()
    private var scheduled = false
    private var stopped = false
    private weak var observedLayout: VerticalTabWindowLayoutState?
    private var layoutSubscription: AnyCancellable?
    private var layoutMode: Ghostty.Config.MacOSTabLayout?
    private weak var observedGroup: NSWindowTabGroup?
    private var groupObservations: [NSKeyValueObservation] = []
    private(set) var refreshCount = 0
    private(set) var visibilityChangeCount = 0

    init(controller: TerminalController, window: TerminalWindow) {
        self.controller = controller
        self.window = window
        window.titlebarSeparatorStyle = .none
        let stack = NSStackView(views: [workspace, sidebar, newTab])
        stack.orientation = .horizontal
        stack.distribution = .gravityAreas
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = true
        stack.setFrameSize(.init(width: 150, height: 28))
        leading.layoutAttribute = .left
        leading.view = NativeTabChromeAccessory(stack: stack)
        for button in [sidebar, newTab] {
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        sidebar.configure(title: "", symbol: "sidebar.left", help: "Show/Hide Tabs", enabled: true,
                          style: .plain, identifier: "tabs.toggle")
        sidebar.onPress = { [weak controller] in controller?.toggleSidebar(nil) }
        newTab.configure(title: "", symbol: "plus", help: "New Tab", enabled: true,
                         style: .plain, identifier: "tabs.new")
        newTab.onPress = { [weak controller] in controller?.newVerticalTab() }
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 26).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 24).isActive = true
        status.translatesAutoresizingMaskIntoConstraints = false
        status.widthAnchor.constraint(equalToConstant: 12).isActive = true
        status.heightAnchor.constraint(equalToConstant: 12).isActive = true
        status.imageScaling = .scaleProportionallyDown
        status.isHidden = true
        if let accessory = window.tab.accessoryView as? NSStackView {
            accessory.insertArrangedSubview(icon, at: 0)
            accessory.insertArrangedSubview(status, at: 1)
        }
        controller.objectWillChange.sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
        controller.workspaceCoordinator.store.objectWillChange.sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
        controller.workspaceCoordinator.objectWillChange.sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
        OhMyGhosttySettings.shared.objectWillChange.sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
        if let activities = (NSApp.delegate as? AppDelegate)?.tabActivities {
            activities.objectWillChange.sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
        }
        controller.$surfaceTree.sink { [weak self] tree in
            guard let self else { return }
            self.surfaceSubscriptions.removeAll()
            for surface in tree {
                Publishers.CombineLatest(surface.$title, surface.$pwd).dropFirst()
                    .sink { [weak self] _ in self?.schedule() }.store(in: &self.surfaceSubscriptions)
            }
            self.schedule()
        }.store(in: &subscriptions)
        window.publisher(for: \.title).dropFirst().sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
        window.publisher(for: \.styleMask).dropFirst().sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification, object: window)
            .sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSWindow.didResizeNotification, object: window)
            .sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .ghosttyConfigDidChange)
            .sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: window)
            .sink { [weak self] _ in self?.stop() }.store(in: &subscriptions)
        refresh()
    }

    func schedule() {
        guard !stopped, !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.refresh()
        }
    }

    func refresh() {
        guard !stopped, let controller, !controller.workspacePresentationIsParked,
              controller.isAvailableForWorkspace, let window else { return }
        refreshCount += 1
        // A newly created tab has not joined its destination yet. Reading
        // tabGroup here builds a throwaway native group and its titlebar.
        guard !controller.workspaceTabAttachmentIsPending else { return }
        // Borderless fullscreen has no titlebar; even reading its accessory list
        // raises an AppKit exception. Restore chrome after the style returns.
        guard window.styleMask.contains(.titled) else {
            if controller.horizontalWorkspaceInTitlebar { controller.horizontalWorkspaceInTitlebar = false }
            icon.isHidden = true
            status.isHidden = true
            return
        }
        if observedLayout !== controller.tabLayoutState {
            observedLayout = controller.tabLayoutState
            layoutSubscription = controller.tabLayoutState.objectWillChange.sink { [weak self] _ in self?.schedule() }
        }
        let group = window.tabGroup
        if observedGroup !== group {
            groupObservations.removeAll()
            observedGroup = group
            if let group {
                groupObservations = [
                    group.observe(\.selectedWindow, options: []) { [weak self] _, _ in self?.schedule() },
                    group.observe(\.windows, options: []) { [weak self] _, _ in self?.schedule() },
                    group.observe(\.isTabBarVisible, options: []) { [weak self] _, _ in self?.schedule() },
                ]
            }
        }
        let horizontal = controller.tabLayout == .horizontal
        let usesLeading = horizontal || !(window is VerticalTabsTerminalWindow)
        let installed = window.titlebarAccessoryViewControllers.contains(leading)
        if usesLeading && window.styleMask.contains(.titled) {
            if !installed { window.addTitlebarAccessoryViewController(leading) }
        } else if let index = window.titlebarAccessoryViewControllers.firstIndex(of: leading) {
            window.removeTitlebarAccessoryViewController(at: index)
        }
        let hasWorkspace = horizontal && window.titlebarAccessoryViewControllers.contains(leading)
        if controller.horizontalWorkspaceInTitlebar != hasWorkspace { controller.horizontalWorkspaceInTitlebar = hasWorkspace }
        workspace.isHidden = !horizontal
        sidebar.isHidden = horizontal
        newTab.isHidden = horizontal
        icon.isHidden = !horizontal
        if horizontal {
            workspace.configure(.resolve(controller: controller, activities: (NSApp.delegate as? AppDelegate)?.tabActivities),
                                controller: controller) { [weak controller] in controller?.workspaceSwitcherIsPresented.toggle() }
        }
        let available = max(56, min(160, window.frame.width - 160))
        let desiredWidth = horizontal ? workspace.fittingSize(proposedWidth: available).width : 56
        (leading.view as? NativeTabChromeAccessory)?.setWidth(desiredWidth)
        if layoutMode != controller.tabLayout {
            layoutMode = controller.tabLayout
            if let verticalWindow = window as? VerticalTabsTerminalWindow {
                if horizontal { verticalWindow.removeSidebarToggle() } else { verticalWindow.installSidebarToggle(controller: controller) }
            }
            window.titleVisibility = .hidden
            if let app = NSApp.delegate as? AppDelegate {
                window.installInspectorToggle(controller: controller, registry: app.inspectorRegistry)
            }
        }
        // A multi-tab group cannot hide its bar through toggleTabBar. Collapse
        // the native accessory instead, keeping AppKit's group bookkeeping intact.
        window.setNativeTabStripHidden(!horizontal)
        if (group?.selectedWindow ?? window) === window,
           window.isVisible, !controller.workspacePresentationIsParked,
           window.tabbingMode != .disallowed,
           !controller.workspaceCoordinator.isChanging,
           !(controller.fullscreenStyle?.isFullscreen == true && controller.fullscreenStyle?.supportsTabs == false),
           !controller.workspaceCoordinator.native.transitioningWindows.contains(controller.windowSessionID) {
            let visible = group?.isTabBarVisible == true
            if horizontal && !visible {
                visibilityChangeCount += 1
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    context.allowsImplicitAnimation = false
                    window.toggleTabBar(nil)
                }
            }
        }
        guard horizontal else { return }
        let selected = (group?.selectedWindow ?? window) === window
        let index = (group?.windows.firstIndex(of: window) ?? 0) + 1
        guard let value = TerminalTabPresentationResolver.resolve(controller, index: index, selected: selected,
            activities: (NSApp.delegate as? AppDelegate)?.tabActivities) else { return }
        icon.previewEdge = horizontal ? .maxY : .maxX
        icon.configure(controller: controller, icon: value.icon, selected: selected, activity: value.activity)
        let symbol: String?
        switch value.activity?.state {
        case .needsAttention:
            symbol = value.activity?.attentionKind == .permission ? "lock.shield.fill" : "exclamationmark.circle.fill"
            status.contentTintColor = .systemOrange
        case .error: symbol = "xmark.circle.fill"; status.contentTintColor = .systemRed
        case .done: symbol = "checkmark.circle.fill"; status.contentTintColor = .systemGreen
        default: symbol = nil
        }
        status.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        status.isHidden = !horizontal || symbol == nil
        if horizontal {
            let title = value.remoteBreadcrumb?.title ?? value.title
            if window.tab.title != title { window.tab.title = title }
            let attributed = NSAttributedString(string: title, attributes: [
                .font: window.titlebarFont ?? NSFont.systemFont(ofSize: 11),
                .foregroundColor: OMGNativeTheme.resolve(for: window).foreground,
            ])
            if window.tab.attributedTitle?.isEqual(to: attributed) != true { window.tab.attributedTitle = attributed }
            var help = title
            if let activity = value.activity {
                let state = switch activity.state {
                case .idle: WorkspaceL10n.text("Idle", "空闲")
                case .working: WorkspaceL10n.text("Working", "工作中")
                case .done: WorkspaceL10n.text("Done", "已完成")
                case .needsAttention: WorkspaceL10n.text("Needs attention", "等待处理")
                case .error: WorkspaceL10n.text("Error", "错误")
                }
                help += "\n\(activity.label ?? activity.source) · \(state)"
            }
            status.toolTip = help
            status.setAccessibilityLabel(help)
            if window.tab.toolTip != help { window.tab.toolTip = help }
        }
    }

    private func stop() {
        stopped = true
        subscriptions.removeAll()
        surfaceSubscriptions.removeAll()
        layoutSubscription = nil
        groupObservations.removeAll()
    }
}

/// AppKit temporarily gives accessories a zero frame while attaching/removing them.
/// Keep the controls' own layout valid independently of that transient frame.
private final class NativeTabChromeAccessory: NSView {
    private let stack: NSStackView
    private var desiredWidth: CGFloat = 150
    init(stack: NSStackView) {
        self.stack = stack
        super.init(frame: .init(x: 0, y: 0, width: 150, height: 28))
        addSubview(stack)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { .init(width: desiredWidth, height: 28) }
    func setWidth(_ width: CGFloat) {
        guard desiredWidth != width || frame.size != NSSize(width: width, height: 28) else { return }
        if desiredWidth != width {
            desiredWidth = width
            invalidateIntrinsicContentSize()
        }
        if frame.width != width || frame.height != 28 { setFrameSize(.init(width: width, height: 28)) }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        stack.frame = .init(x: 0, y: bounds.midY - 14, width: desiredWidth, height: 28)
    }
}

extension TerminalWindow {
    func installOMGTabChrome(controller: TerminalController) {
        if let omgTabChrome { omgTabChrome.refresh() } else {
            omgTabChrome = TerminalTabChromeController(controller: controller, window: self)
        }
    }
}
