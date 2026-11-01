import AppKit
import Combine
import SwiftUI

struct NativeTabSidebarConfiguration {
    let controller: TerminalController
    let layoutState: VerticalTabWindowLayoutState
    let statusStore: TabActivityStore
    let backgroundColor: NSColor
    var backgroundOpacity: Double = 1
    var iconProvider = AnyGhosttyTabIconProvider(CompositeGhosttyTabIconProvider(overrides: []))
}

/// The window container retains this view; the group retains it weakly.
/// Its controller survives moving between native tab windows.
final class NativeTabSidebarHostingView: NSView {
    let sidebar: NativeTabSidebarController

    init(configuration: NativeTabSidebarConfiguration) {
        sidebar = NativeTabSidebarController(configuration: configuration)
        super.init(frame: .zero)
        let content = sidebar.view
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ configuration: NativeTabSidebarConfiguration) { sidebar.configure(configuration) }
}

final class NativeTabSidebarController: NSViewController {
    private(set) var configuration: NativeTabSidebarConfiguration
    private(set) var list: NativeTabOutlineController!
    private let workspaceButton = TerminalWorkspaceHeaderButton()
    private let optionsButton = NativeOptionsControl()
    private let organization = GhosttyTabOrganizationModel()
    private var subscriptions = Set<AnyCancellable>()
    private var metadataSubscriptions = Set<AnyCancellable>()
    private var tabIDs: [ObjectIdentifier] = []
    private var scheduled = false
    private var workspaceWidth: NSLayoutConstraint?
    private let themeObserver = OMGNativeThemeObserver()
    private(set) var refreshCount = 0

    init(configuration: NativeTabSidebarConfiguration) {
        self.configuration = configuration
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.clipsToBounds = true
        root.setAccessibilityIdentifier("native.tab.sidebar")
        let header = NSStackView(views: [workspaceButton, NSView(), optionsButton])
        header.orientation = .horizontal
        header.distribution = .fill
        header.spacing = 4
        header.translatesAutoresizingMaskIntoConstraints = false
        optionsButton.configure(title: "", symbol: "ellipsis", help: "Organize Tabs",
                                enabled: true, style: .plain, identifier: "tabs.organize")
        list = NativeTabOutlineController(outlineConfiguration())
        addChild(list)
        let content = list.view
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        root.addSubview(content)
        let width = workspaceButton.widthAnchor.constraint(equalToConstant: 160)
        width.priority = .defaultHigh
        workspaceWidth = width
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 32),
            optionsButton.widthAnchor.constraint(equalToConstant: 24),
            optionsButton.heightAnchor.constraint(equalToConstant: 24),
            workspaceButton.heightAnchor.constraint(equalToConstant: 28),
            width,
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
        ])
        view = root
        themeObserver.onChange = { [weak self] _ in self?.scheduleRefresh() }
        bind()
        refresh(force: true)
    }

    func configure(_ next: NativeTabSidebarConfiguration) {
        let rebind = configuration.controller !== next.controller || configuration.layoutState !== next.layoutState ||
            configuration.statusStore !== next.statusStore
        if configuration.controller !== next.controller {
            optionsButton.dismiss()
            configuration.controller.workspacePopover.close()
        }
        configuration = next
        guard isViewLoaded else { return }
        if rebind { bind() }
        refresh(force: true)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        workspaceWidth?.constant = workspaceButton.fittingSize(proposedWidth: max(50, view.bounds.width - 52)).width
    }

    private var tabs: [TerminalController] {
        let current = configuration.layoutState.tabSnapshot.controllers
        return current.isEmpty ? [configuration.controller] : current
    }

    private func bind() {
        subscriptions.removeAll()
        metadataSubscriptions.removeAll()
        tabIDs = []
        let config = configuration
        let changes: [AnyPublisher<Void, Never>] = [
            config.layoutState.objectWillChange.eraseToAnyPublisher(),
            config.layoutState.tabPresentation.objectWillChange.eraseToAnyPublisher(),
            config.statusStore.objectWillChange.eraseToAnyPublisher(),
            config.controller.objectWillChange.eraseToAnyPublisher(),
            config.controller.workspaceCoordinator.store.objectWillChange.eraseToAnyPublisher(),
            config.controller.workspaceCoordinator.objectWillChange.eraseToAnyPublisher(),
            OhMyGhosttySettings.shared.objectWillChange.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(changes).sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        themeObserver.sourceWindow = config.controller.window
    }

    private func observeMetadata() {
        let ids = tabs.map(ObjectIdentifier.init)
        guard ids != tabIDs else { return }
        tabIDs = ids
        metadataSubscriptions.removeAll()
        for tab in tabs {
            tab.objectWillChange.sink { [weak self] _ in
                if self?.configuration.layoutState.groupingMode == .project { self?.scheduleRefresh() }
            }.store(in: &metadataSubscriptions)
            tab.$tabLastActivatedAt.dropFirst().sink { [weak self] _ in
                if self?.configuration.layoutState.orderingMode == .recentlyUsed { self?.scheduleRefresh() }
            }.store(in: &metadataSubscriptions)
            tab.$surfaceTree.dropFirst().sink { [weak self] _ in
                self?.tabIDs = []
                self?.scheduleRefresh()
            }.store(in: &metadataSubscriptions)
            for surface in tab.surfaceTree {
                surface.$pwd.dropFirst().sink { [weak self] _ in
                    if self?.configuration.layoutState.groupingMode == .project { self?.scheduleRefresh() }
                }.store(in: &metadataSubscriptions)
            }
        }
    }

    private func scheduleRefresh() {
        guard !scheduled, isActivePresentation else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.refresh()
        }
    }

    private var isActivePresentation: Bool {
        let controller = configuration.controller
        guard !TerminalWorkspacePresentation.isChanging, !controller.workspacePresentationIsParked,
              !controller.workspaceTabAttachmentIsPending, let window = controller.window else { return false }
        if controller.workspaceCoordinator.hasNonNativeFullscreen(in: controller.windowSessionID),
           !window.isVisible { return false }
        guard (window.tabGroup?.selectedWindow ?? window) === window else { return false }
        let selectedID = configuration.layoutState.tabSnapshot.selectedID
        return selectedID == nil || selectedID == ObjectIdentifier(controller)
    }

    private func refresh(force: Bool = false) {
        guard isViewLoaded else { return }
        guard force || isActivePresentation else { return }
        refreshCount += 1
        observeMetadata()
        let config = configuration
        view.layer?.backgroundColor = config.backgroundColor.withAlphaComponent(config.backgroundOpacity).cgColor
        workspaceButton.configure(.resolve(controller: config.controller, activities: config.statusStore),
                                  controller: config.controller) { [weak controller = config.controller] in
            controller?.workspaceSwitcherIsPresented.toggle()
        }
        optionsButton.entries = [.action("GROUP", enabled: false) {}] + GhosttyTabGroupingMode.allCases.map { mode in
            .action(mode.title, checked: config.layoutState.groupingMode == mode) { [weak controller = config.controller] in
                controller?.setTabGroupingMode(mode)
            }
        } + [.separator, .action("ORDER", enabled: false) {}] + GhosttyTabOrderingMode.allCases.map { mode in
            .action(mode.title, checked: config.layoutState.orderingMode == mode) { [weak controller = config.controller] in
                controller?.setTabOrderingMode(mode)
            }
        }
        list.update(outlineConfiguration())
        view.needsLayout = true
    }

    private func outlineConfiguration() -> NativeTabOutlineConfiguration {
        let config = configuration
        return NativeTabOutlineConfiguration(
            groups: organization.groups(tabs: tabs, grouping: config.layoutState.groupingMode, ordering: config.layoutState.orderingMode),
            selectedID: config.layoutState.pendingSelectedTabID ?? config.layoutState.tabSnapshot.selectedID,
            layoutState: config.layoutState, controller: config.controller,
            rowHeight: OhMyGhosttySettings.shared.tabRowDensity.rowHeight,
            presentation: { [weak self] in self?.presentation(for: $0) }
        )
    }

    private func presentation(for tab: GhosttyOrganizedTab) -> GhosttyTabPresentation? {
        TerminalTabPresentationResolver.resolve(tab.controller, index: tab.actualIndex,
            selected: tab.id == configuration.layoutState.tabSnapshot.selectedID,
            activities: configuration.statusStore, icons: configuration.iconProvider)
    }
}
