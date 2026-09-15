import Combine
import SwiftUI
import UniformTypeIdentifiers

struct VerticalTabSidebarMetrics {
    static let minimumWidth: CGFloat = 176
    static let defaultWidth: CGFloat = 240
    static let maximumWidth: CGFloat = 480

    @MainActor
    static var persistedWidth: CGFloat {
        let stored = CGFloat(OhMyGhosttySettings.shared.defaultSidebarWidth)
        return min(max(stored, minimumWidth), maximumWidth)
    }

    @MainActor
    static func persist(_ width: CGFloat) {
        guard OhMyGhosttySettings.shared.rememberSidebarWidth else { return }
        OhMyGhosttySettings.shared.defaultSidebarWidth = Double(
            min(max(width, minimumWidth), maximumWidth)
        )
    }
}

enum GhosttyTabGroupingMode: String, CaseIterable {
    case none
    case project
    case date

    var title: String {
        switch self {
        case .none: "No Grouping"
        case .project: "By Project"
        case .date: "By Date"
        }
    }
}

enum GhosttyTabOrderingMode: String, CaseIterable {
    case manual
    case created
    case recentlyUsed

    var title: String {
        switch self {
        case .manual: "Manual"
        case .created: "Created Time"
        case .recentlyUsed: "Recently Used"
        }
    }
}

@MainActor
final class VerticalTabWindowLayoutState: ObservableObject {
    @Published private(set) var isSidebarVisible: Bool
    @Published private(set) var sidebarWidth: CGFloat
    @Published private(set) var committedSidebarWidth: CGFloat
    @Published private(set) var groupingMode: GhosttyTabGroupingMode
    @Published private(set) var orderingMode: GhosttyTabOrderingMode
    @Published private(set) var collapsedGroupIDs: Set<String> = []
    @Published private(set) var isInspectorVisible = false
    @Published private(set) var inspectorWidth = RightInspectorMetrics.defaultWidth
    @Published private(set) var committedInspectorWidth = RightInspectorMetrics.defaultWidth
    @Published private(set) var selectedInspectorPaneID: String?

    private var pendingSidebarWidth: CGFloat?
    private var resizeWorkItem: DispatchWorkItem?
    private var sidebarPersistenceWorkItem: DispatchWorkItem?
    private var pendingInspectorWidth: CGFloat?
    private var inspectorResizeWorkItem: DispatchWorkItem?
    private(set) var appliedResizeCount = 0
    private(set) var appliedInspectorResizeCount = 0
    private let settings: OhMyGhosttySettings
    private let inspectorPresentation: InspectorPresentationStore

    init(
        isSidebarVisible: Bool,
        sidebarWidth: CGFloat? = nil,
        isInspectorVisible: Bool? = nil,
        settings: OhMyGhosttySettings? = nil,
        inspectorPresentation: InspectorPresentationStore? = nil
    ) {
        let settings = settings ?? OhMyGhosttySettings.shared
        let inspectorPresentation = inspectorPresentation ?? InspectorPresentationStore.shared
        self.settings = settings
        self.inspectorPresentation = inspectorPresentation
        let initialWidth = sidebarWidth ?? CGFloat(settings.defaultSidebarWidth)
        self.isSidebarVisible = isSidebarVisible
        self.sidebarWidth = initialWidth
        self.committedSidebarWidth = initialWidth
        self.groupingMode = settings.groupingMode
        self.orderingMode = settings.orderingMode
        self.isInspectorVisible = isInspectorVisible ?? inspectorPresentation.snapshot.isVisible
        let inspectorWidth = CGFloat(inspectorPresentation.snapshot.width)
        self.inspectorWidth = inspectorWidth
        self.committedInspectorWidth = inspectorWidth
        self.selectedInspectorPaneID = inspectorPresentation.snapshot.selectedPaneID
    }

    func setSidebarVisible(_ visible: Bool) {
        guard isSidebarVisible != visible else { return }
        isSidebarVisible = visible
    }

    func applySidebarPreferences(
        visible: Bool,
        width proposedWidth: CGFloat,
        availableWidth: CGFloat
    ) {
        setSidebarVisible(visible)
        let maximumWidth = min(
            VerticalTabSidebarMetrics.maximumWidth,
            max(VerticalTabSidebarMetrics.minimumWidth, availableWidth * 0.5)
        )
        let width = min(
            max(proposedWidth, VerticalTabSidebarMetrics.minimumWidth),
            maximumWidth
        )
        resizeWorkItem?.cancel()
        resizeWorkItem = nil
        sidebarPersistenceWorkItem?.cancel()
        sidebarPersistenceWorkItem = nil
        pendingSidebarWidth = nil
        applySidebarWidth(width)
        committedSidebarWidth = width
    }

    func toggleSidebar() {
        setSidebarVisible(!isSidebarVisible)
    }

    func setInspectorVisible(_ visible: Bool) {
        guard isInspectorVisible != visible else { return }
        isInspectorVisible = visible
        inspectorPresentation.setVisible(visible)
    }

    func toggleInspector() {
        setInspectorVisible(!isInspectorVisible)
    }

    func selectInspectorPane(_ paneID: String?) {
        guard selectedInspectorPaneID != paneID else { return }
        selectedInspectorPaneID = paneID
        inspectorPresentation.selectPane(paneID)
    }

    func setGroupingMode(_ mode: GhosttyTabGroupingMode) {
        guard groupingMode != mode else { return }
        groupingMode = mode
        settings.groupingMode = mode
    }

    func setOrderingMode(_ mode: GhosttyTabOrderingMode) {
        guard orderingMode != mode else { return }
        orderingMode = mode
        settings.orderingMode = mode
    }

    func applyPreferences(
        grouping: GhosttyTabGroupingMode,
        ordering: GhosttyTabOrderingMode
    ) {
        if groupingMode != grouping { groupingMode = grouping }
        if orderingMode != ordering { orderingMode = ordering }
    }

    func toggleGroup(_ id: String) {
        if collapsedGroupIDs.contains(id) {
            collapsedGroupIDs.remove(id)
        } else {
            collapsedGroupIDs.insert(id)
        }
    }

    func updateSidebarWidth(_ proposedWidth: CGFloat, availableWidth: CGFloat, persist: Bool) {
        let maximumWidth = min(
            VerticalTabSidebarMetrics.maximumWidth,
            max(VerticalTabSidebarMetrics.minimumWidth, availableWidth * 0.5)
        )
        let width = min(max(proposedWidth, VerticalTabSidebarMetrics.minimumWidth), maximumWidth)

        if persist {
            resizeWorkItem?.cancel()
            resizeWorkItem = nil
            pendingSidebarWidth = nil
            applySidebarWidth(width)
            if committedSidebarWidth != width {
                committedSidebarWidth = width
            }
            scheduleSidebarWidthPersistence(width)
            return
        }

        sidebarPersistenceWorkItem?.cancel()
        sidebarPersistenceWorkItem = nil
        pendingSidebarWidth = width
        guard resizeWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.resizeWorkItem = nil
            guard let width = self.pendingSidebarWidth else { return }
            self.pendingSidebarWidth = nil
            self.applySidebarWidth(width)
        }
        resizeWorkItem = workItem
        // Apply at the end of the current runloop turn rather than on a fixed
        // 16ms timer. A fixed delay adds a full frame of pointer lag and drifts
        // out of phase with the display, which reads as a hitch on the selected
        // tab while dragging. Frame-boundary scheduling coalesces all drag
        // events in the current turn into one apply with near-zero latency.
        DispatchQueue.main.async(execute: workItem)
    }

    private func scheduleSidebarWidthPersistence(_ width: CGFloat) {
        sidebarPersistenceWorkItem?.cancel()
        guard settings.rememberSidebarWidth else {
            sidebarPersistenceWorkItem = nil
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.sidebarPersistenceWorkItem = nil
            guard self.committedSidebarWidth == width else { return }
            self.settings.defaultSidebarWidth = Double(width)
        }
        sidebarPersistenceWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.2,
            execute: workItem
        )
    }

    func updateInspectorWidth(
        _ proposedWidth: CGFloat,
        availableWidth: CGFloat,
        persist: Bool
    ) {
        let maximumWidth = min(
            RightInspectorMetrics.maximumWidth,
            max(RightInspectorMetrics.minimumWidth, availableWidth * 0.5)
        )
        let width = min(max(proposedWidth, RightInspectorMetrics.minimumWidth), maximumWidth)

        if persist {
            inspectorResizeWorkItem?.cancel()
            inspectorResizeWorkItem = nil
            pendingInspectorWidth = nil
            applyInspectorWidth(width)
            committedInspectorWidth = width
            inspectorPresentation.setWidth(width)
            return
        }

        pendingInspectorWidth = width
        guard inspectorResizeWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.inspectorResizeWorkItem = nil
            guard let width = self.pendingInspectorWidth else { return }
            self.pendingInspectorWidth = nil
            self.applyInspectorWidth(width)
        }
        inspectorResizeWorkItem = workItem
        // Same rationale as the sidebar: frame-boundary scheduling avoids the
        // fixed-timer pointer lag while still coalescing per-turn.
        DispatchQueue.main.async(execute: workItem)
    }

    private func applySidebarWidth(_ width: CGFloat) {
        guard sidebarWidth != width else { return }
        sidebarWidth = width
        appliedResizeCount += 1
    }

    private func applyInspectorWidth(_ width: CGFloat) {
        guard inspectorWidth != width else { return }
        inspectorWidth = width
        appliedInspectorResizeCount += 1
    }
}

struct GhosttyTabStyle {
    static let rowHeight: CGFloat = 30
    static let cornerRadius: CGFloat = 5
    static let horizontalPadding: CGFloat = 8
    static let contentSpacing: CGFloat = 8
    static let shortcutFontSize = NSFont.smallSystemFontSize

    static func backgroundOpacity(selected: Bool, hovered: Bool) -> Double {
        if selected { return 0.14 }
        if hovered { return 0.07 }
        return 0
    }

    static func iconColor(selected: Bool, hovered: Bool) -> Color {
        if selected { return .accentColor }
        if hovered { return .primary }
        return .secondary
    }
}

enum GhosttyTabIcon {
    case systemSymbol(String)
    case asset(String)
    case image(NSImage)
}

struct GhosttyTabGroupIdentity {
    let id: String
    let title: String
    let icon: GhosttyTabIcon
}

struct GhosttyTabMetadata {
    let project: GhosttyTabGroupIdentity?
    let agent: GhosttyTabGroupIdentity?
    let workspace: GhosttyTabGroupIdentity?
    let customGroup: GhosttyTabGroupIdentity?
}

struct GhosttyTabMetadataContext {
    let tabID: UUID
    let title: String
    let workingDirectory: String?
}

protocol GhosttyTabMetadataProviding {
    func metadata(for context: GhosttyTabMetadataContext) -> GhosttyTabMetadata?
}

struct AnyGhosttyTabMetadataProvider: GhosttyTabMetadataProviding {
    private let resolve: (GhosttyTabMetadataContext) -> GhosttyTabMetadata?

    init<Provider: GhosttyTabMetadataProviding>(_ provider: Provider) {
        self.resolve = provider.metadata
    }

    func metadata(for context: GhosttyTabMetadataContext) -> GhosttyTabMetadata? {
        resolve(context)
    }
}

struct CompositeGhosttyTabMetadataProvider: GhosttyTabMetadataProviding {
    let providers: [AnyGhosttyTabMetadataProvider]

    func metadata(for context: GhosttyTabMetadataContext) -> GhosttyTabMetadata? {
        for provider in providers {
            if let metadata = provider.metadata(for: context) { return metadata }
        }
        return nil
    }
}

struct GhosttyTabIconContext {
    let tabID: UUID
    let title: String
    let activity: TabActivity?
    let defaultIcon: GhosttyTabIcon?

    init(
        tabID: UUID,
        title: String,
        activity: TabActivity?,
        defaultIcon: GhosttyTabIcon? = nil
    ) {
        self.tabID = tabID
        self.title = title
        self.activity = activity
        self.defaultIcon = defaultIcon
    }
}

protocol GhosttyTabIconProviding {
    func icon(for context: GhosttyTabIconContext) -> GhosttyTabIcon?
}

struct DefaultGhosttyTabIconProvider: GhosttyTabIconProviding {
    func icon(for context: GhosttyTabIconContext) -> GhosttyTabIcon? {
        if let icon = context.activity?.icon {
            return switch icon.kind {
            case .systemSymbol: .systemSymbol(icon.name)
            case .bundledAsset: .asset(icon.name)
            }
        }
        return context.defaultIcon ?? .systemSymbol("terminal")
    }
}

struct AnyGhosttyTabIconProvider: GhosttyTabIconProviding {
    private let resolve: (GhosttyTabIconContext) -> GhosttyTabIcon?

    init<Provider: GhosttyTabIconProviding>(_ provider: Provider) {
        self.resolve = provider.icon
    }

    func icon(for context: GhosttyTabIconContext) -> GhosttyTabIcon? {
        resolve(context)
    }
}

struct CompositeGhosttyTabIconProvider: GhosttyTabIconProviding {
    let overrides: [AnyGhosttyTabIconProvider]
    let fallback = DefaultGhosttyTabIconProvider()

    func icon(for context: GhosttyTabIconContext) -> GhosttyTabIcon? {
        for provider in overrides {
            if let icon = provider.icon(for: context) { return icon }
        }
        return fallback.icon(for: context)
    }
}

struct GhosttyTabPresentation {
    let title: String
    let remoteBreadcrumb: RemoteTabBreadcrumb?
    let shortcut: String?
    let icon: GhosttyTabIcon
    let activity: TabActivity?
    let selected: Bool
    let hovered: Bool
}

struct GhosttyOrganizedTab: Identifiable {
    let controller: TerminalController
    let actualIndex: Int
    var id: ObjectIdentifier { ObjectIdentifier(controller) }
}

struct GhosttyTabGroupPresentation: Identifiable {
    let id: String
    let title: String?
    let icon: GhosttyTabIcon?
    var tabs: [GhosttyOrganizedTab]
}

@MainActor
final class GhosttyTabOrganizationModel: ObservableObject {
    private var projectCache: [String: GhosttyTabGroupIdentity] = [:]
    private let metadataProvider: AnyGhosttyTabMetadataProvider

    init(
        metadataProvider: AnyGhosttyTabMetadataProvider = .init(
            CompositeGhosttyTabMetadataProvider(providers: [])
        )
    ) {
        self.metadataProvider = metadataProvider
    }

    func groups(
        tabs: [TerminalController],
        grouping: GhosttyTabGroupingMode,
        ordering: GhosttyTabOrderingMode,
        now: Date = Date()
    ) -> [GhosttyTabGroupPresentation] {
        var organized = tabs.enumerated().map {
            GhosttyOrganizedTab(controller: $0.element, actualIndex: $0.offset + 1)
        }
        switch ordering {
        case .manual:
            break
        case .created:
            organized.sort {
                if $0.controller.tabCreatedAt == $1.controller.tabCreatedAt {
                    return $0.actualIndex < $1.actualIndex
                }
                return $0.controller.tabCreatedAt < $1.controller.tabCreatedAt
            }
        case .recentlyUsed:
            organized.sort {
                if $0.controller.tabLastActivatedAt == $1.controller.tabLastActivatedAt {
                    return $0.actualIndex < $1.actualIndex
                }
                return $0.controller.tabLastActivatedAt > $1.controller.tabLastActivatedAt
            }
        }

        guard grouping != .none else {
            return [.init(id: "all", title: nil, icon: nil, tabs: organized)]
        }

        var groups: [GhosttyTabGroupPresentation] = []
        var indices: [String: Int] = [:]
        for tab in organized {
            let identity: (id: String, title: String, icon: GhosttyTabIcon)
            switch grouping {
            case .none:
                continue
            case .project:
                let project = projectIdentity(for: tab.controller)
                identity = (project.id, project.title, project.icon)
            case .date:
                identity = dateIdentity(for: tab.controller.tabCreatedAt, now: now)
            }

            if let index = indices[identity.id] {
                groups[index].tabs.append(tab)
            } else {
                indices[identity.id] = groups.count
                groups.append(.init(
                    id: identity.id,
                    title: identity.title,
                    icon: identity.icon,
                    tabs: [tab]
                ))
            }
        }
        return groups
    }

    private func projectIdentity(for controller: TerminalController) -> GhosttyTabGroupIdentity {
        let surface = controller.focusedSurface ?? controller.surfaceTree.first
        let path = surface?.pwd ?? ""
        let metadata = metadataProvider.metadata(for: .init(
            tabID: controller.tabSessionID,
            title: controller.titleOverride ?? surface?.title ?? "Terminal",
            workingDirectory: surface?.pwd
        ))
        if let project = metadata?.project { return project }
        if let cached = projectCache[path] { return cached }
        guard !path.isEmpty else {
            let identity = GhosttyTabGroupIdentity(
                id: "project:other",
                title: "Other",
                icon: .systemSymbol("folder")
            )
            projectCache[path] = identity
            return identity
        }

        var url = URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        while !url.path.isEmpty, url.path != "/" {
            if FileManager.default.fileExists(
                atPath: url.appendingPathComponent(".git").path
            ) {
                let identity = GhosttyTabGroupIdentity(
                    id: "project:\(url.path)",
                    title: url.lastPathComponent,
                    icon: .systemSymbol("folder")
                )
                projectCache[path] = identity
                return identity
            }
            url.deleteLastPathComponent()
        }

        let title = URL(fileURLWithPath: path).lastPathComponent
        let identity = GhosttyTabGroupIdentity(
            id: path.isEmpty ? "project:other" : "cwd:\(path)",
            title: title.isEmpty ? "Other" : title,
            icon: .systemSymbol("folder")
        )
        projectCache[path] = identity
        return identity
    }

    private func dateIdentity(
        for date: Date,
        now: Date
    ) -> (id: String, title: String, icon: GhosttyTabIcon) {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return ("date:today", "Today", .systemSymbol("calendar"))
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return ("date:yesterday", "Yesterday", .systemSymbol("calendar"))
        }
        return ("date:older", "Older", .systemSymbol("calendar"))
    }
}

enum VerticalTabDragLifecyclePolicy {
    static func shouldFinish(_ event: NSEvent) -> Bool {
        // NSEvent raises an Objective-C exception if a mouse event is asked
        // for keyCode. Keep the read inside the keyboard-only branch.
        switch event.type {
        case .leftMouseUp, .leftMouseDown: true
        case .keyDown: event.keyCode == 53
        default: false
        }
    }
}

/// Tracks the source-side end of a SwiftUI tab drag. DropDelegate callbacks are
/// destination-scoped, so a cancelled drag or a release outside the app may not
/// receive dropExited or performDrop and must be cleaned up from the mouse/key
/// lifecycle instead.
@MainActor
final class VerticalTabDragLifecycleMonitor: ObservableObject {
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var cleanup: (() -> Void)?
    private var generation = 0

    func begin(cleanup: @escaping () -> Void) {
        finish()
        self.cleanup = cleanup
        let generation = self.generation
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .keyDown]
        ) { [weak self] event in
            // A native drag loop may consume its final mouse-up. The next
            // press also retires stale state, without consuming that click.
            self?.receive(event, generation: generation)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseUp]
        ) { [weak self] event in
            self?.receive(event, generation: generation)
        }
    }

    private func receive(_ event: NSEvent, generation: Int) {
        guard VerticalTabDragLifecyclePolicy.shouldFinish(event) else { return }
        // Let the destination commit its drop before clearing the source ID.
        // An old queued completion must never clear a newly started drag.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation else { return }
            self.finish()
        }
    }

    func finish() {
        generation &+= 1
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        let cleanup = self.cleanup
        self.cleanup = nil
        cleanup?()
    }

    deinit {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    }
}

struct TerminalTabSidebarView: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var layoutState: VerticalTabWindowLayoutState
    @ObservedObject var statusStore: TabActivityStore
    @ObservedObject private var settings = OhMyGhosttySettings.shared
    let backgroundColor: Color
    let backgroundOpacity: Double
    let iconProvider: AnyGhosttyTabIconProvider

    @StateObject private var organizationModel = GhosttyTabOrganizationModel()
    @StateObject private var tabDragLifecycle = VerticalTabDragLifecycleMonitor()
    @State private var metadataRevision = 0
    @State private var draggedTabSessionID: UUID?
    @State private var dropTarget: VerticalTabDropTarget?
    @State private var tabDropActivity: VerticalTabDropActivity = .idle
    @State private var surfaceDropActivity: VerticalTabDropActivity = .idle

    init(
        controller: TerminalController,
        layoutState: VerticalTabWindowLayoutState,
        statusStore: TabActivityStore,
        backgroundColor: Color,
        backgroundOpacity: Double = 1,
        iconProvider: AnyGhosttyTabIconProvider = .init(
            CompositeGhosttyTabIconProvider(overrides: [])
        )
    ) {
        self.controller = controller
        self.layoutState = layoutState
        self.statusStore = statusStore
        self.backgroundColor = backgroundColor
        self.backgroundOpacity = backgroundOpacity
        self.iconProvider = iconProvider
    }

    private var tabs: [TerminalController] {
        controller.tabControllers.isEmpty
            ? [controller]
            : controller.tabControllers
    }

    var body: some View {
        let groups = organizedGroups
        VStack(spacing: 0) {
            header

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(groups) { group in
                        if let title = group.title, let icon = group.icon {
                            VerticalTabGroupHeader(
                                title: title,
                                icon: icon,
                                collapsed: groupIsCollapsed(group),
                                toggle: { layoutState.toggleGroup(group.id) }
                            )
                        }
                        if !groupIsCollapsed(group) {
                            ForEach(group.tabs) { organizedTab in
                                tabRow(
                                    organizedTab,
                                    groupID: group.id,
                                    groupSessionIDs: Set(group.tabs.map {
                                        $0.controller.tabSessionID
                                    })
                                )
                                .padding(.leading, group.title == nil ? 0 : 12)
                            }
                        }
                    }
                    // Keep the end target as a sibling of the rows. A drop target on
                    // the whole sidebar shadows the rows' plain-text tab targets,
                    // preventing tab reordering from receiving drag updates.
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: max(
                            OhMyGhosttySettings.shared.tabRowDensity.rowHeight,
                            24
                        ))
                        .contentShape(Rectangle())
                        .onDrop(
                            of: [.ghosttySurfaceId],
                            delegate: VerticalTabSurfaceDropDelegate(
                                controller: controller,
                                destination: controller,
                                groupID: nil,
                                placement: .end,
                                dropTarget: $dropTarget,
                                dropActivity: $surfaceDropActivity
                            )
                        )
                        .overlay {
                            VerticalTabInsertionIndicator(
                                target: dropTarget,
                                tabSessionID: nil
                            )
                        }
                }
                .padding(.horizontal, 8)
                .padding(.top, 2)
                .padding(.bottom, 8)
            }
        }
        .background(backgroundColor.opacity(backgroundOpacity))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
        .onDisappear { tabDragLifecycle.finish() }
        .onReceive(metadataChanges) { _ in
            metadataRevision &+= 1
        }
    }

    private var header: some View {
        HStack {
            Text("TABS")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            TabOrganizationMenu(controller: controller, layoutState: layoutState)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
    }

    private var organizedGroups: [GhosttyTabGroupPresentation] {
        _ = metadataRevision
        return organizationModel.groups(
            tabs: tabs,
            grouping: layoutState.groupingMode,
            ordering: layoutState.orderingMode
        )
    }

    private var metadataChanges: AnyPublisher<Void, Never> {
        let activation = tabs.map {
            $0.$tabLastActivatedAt.dropFirst().map { _ in () }.eraseToAnyPublisher()
        }
        let paths = tabs.compactMap { tab -> AnyPublisher<Void, Never>? in
            guard let surface = tab.focusedSurface ?? tab.surfaceTree.first else { return nil }
            return surface.$pwd.dropFirst().map { _ in () }.eraseToAnyPublisher()
        }
        return Publishers.MergeMany(activation + paths).eraseToAnyPublisher()
    }

    private func groupIsCollapsed(_ group: GhosttyTabGroupPresentation) -> Bool {
        let containsSelected = group.tabs.contains {
            ObjectIdentifier($0.controller) == controller.selectedTabID
        }
        return layoutState.collapsedGroupIDs.contains(group.id) && !containsSelected
    }

    @ViewBuilder
    private func tabRow(
        _ organizedTab: GhosttyOrganizedTab,
        groupID: String,
        groupSessionIDs: Set<UUID>
    ) -> some View {
        let tab = organizedTab.controller
        let tabID = ObjectIdentifier(tab)
        let selected = controller.selectedTabID == tabID
        let dragIsActive = tabDropActivity != .idle || surfaceDropActivity != .idle
        let hovered = !dragIsActive && controller.hoveredTabID == tabID
        if let surface = tab.focusedSurface ?? tab.surfaceTree.first {
            let activity = tab.focusedAgentActivity() ??
                statusStore.activity(for: tab.tabSessionID)
            VerticalTabRow(
                controller: tab,
                surface: surface,
                presentation: presentation(
                    for: tab,
                    surface: surface,
                    index: organizedTab.actualIndex,
                    selected: selected,
                    hovered: hovered,
                    activity: activity
                ),
                canClose: tabs.count > 1,
                select: { controller.selectVerticalTab(tab) },
                close: { controller.closeVerticalTab(tab) },
                hoverChanged: {
                    guard tabDropActivity == .idle,
                          surfaceDropActivity == .idle else { return }
                    controller.setVerticalTabHovered(tab, hovered: $0)
                }
            )
            .contentShape(Rectangle())
            .onDrag {
                controller.beginManualTabDrag()
                controller.clearVerticalTabHover()
                draggedTabSessionID = tab.tabSessionID
                tabDropActivity = .active
                tabDragLifecycle.begin { [weak controller] in
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        draggedTabSessionID = nil
                        dropTarget = nil
                        tabDropActivity = .idle
                    }
                    controller?.clearVerticalTabHover()
                }
                return NSItemProvider(object: tab.tabSessionID.uuidString as NSString)
            }
            // A SwiftUI view must expose one drop destination for this hit area.
            // Stacking separate pane and tab onDrop modifiers causes one payload
            // type to shadow the other, so route both through one delegate.
            .onDrop(
                of: [.ghosttySurfaceId, UTType.utf8PlainText],
                delegate: VerticalTabRowDropDelegate(
                    controller: controller,
                    destination: tab,
                    groupID: groupID,
                    allowedSessionIDs: groupSessionIDs,
                    draggedSessionID: $draggedTabSessionID,
                    dropTarget: $dropTarget,
                    tabDropActivity: $tabDropActivity,
                    surfaceDropActivity: $surfaceDropActivity
                )
            )
            .overlay {
                VerticalTabInsertionIndicator(
                    target: dropTarget,
                    tabSessionID: tab.tabSessionID
                )
            }
        }
    }

    private func presentation(
        for tab: TerminalController,
        surface: Ghostty.SurfaceView,
        index: Int,
        selected: Bool,
        hovered: Bool,
        activity: TabActivity?
    ) -> GhosttyTabPresentation {
        let session = tab.paneSessionContext(for: surface) ?? .init(
            workingDirectory: surface.pwd,
            terminalTitle: surface.title
        )
        let agent = activity.flatMap { SupportedAgent(rawValue: $0.source) }
        let baseTitle = tab.titleOverride ?? (agent == nil
            ? session.presentationTitle(pathDisplay: settings.tabPathDisplay)
            : session.agentPathTitle(pathDisplay: settings.tabPathDisplay))
        let resolvedTitle = agent?.normalizedTitle(baseTitle) ?? baseTitle
        let context = GhosttyTabIconContext(
            tabID: tab.tabSessionID,
            title: resolvedTitle,
            activity: activity,
            defaultIcon: session.workspace?.icon ?? .systemSymbol(
                session.tabIconSystemName
            )
        )
        return .init(
            title: resolvedTitle,
            remoteBreadcrumb: tab.titleOverride == nil
                ? session.remoteTabBreadcrumb
                : nil,
            shortcut: settings.showShortcutLabels ? tab.tabShortcutLabel(for: index) : nil,
            icon: iconProvider.icon(for: context) ?? .systemSymbol("terminal"),
            activity: activity,
            selected: selected,
            hovered: hovered
        )
    }
}

struct VerticalTabDropPolicy {
    enum Placement: Equatable {
        case before
        case after
        case end
    }

    static func allows(source: UUID?, in allowedSessionIDs: Set<UUID>) -> Bool {
        source.map(allowedSessionIDs.contains) ?? false
    }

    static func placement(y: CGFloat, rowHeight: CGFloat) -> Placement {
        y < max(rowHeight, 0) / 2 ? .before : .after
    }

    static func insertionIndex(
        destinationIndex: Int,
        placement: Placement
    ) -> Int {
        switch placement {
        case .before, .end: destinationIndex
        case .after: destinationIndex + 1
        }
    }

    static func destinationIndex(
        sourceIndex: Int,
        insertionIndex: Int,
        tabCount: Int
    ) -> Int {
        guard tabCount > 0 else { return 0 }
        var destination = min(max(insertionIndex, 0), tabCount)
        if sourceIndex < destination { destination -= 1 }
        return min(max(destination, 0), tabCount - 1)
    }
}

/// The index contract for the mutating portion of a pane-to-tab move.
///
/// AppKit may place an attached window anywhere in the destination group. The
/// transaction therefore computes the final index from the post-attach state
/// and only commits when that exact index is observed afterward.
struct VerticalTabMoveTransactionPlan: Equatable {
    let insertionIndex: Int
    let destinationIndex: Int
    let tabCount: Int

    init?(sourceIndexAfterAttach: Int?, insertionIndex: Int, tabCount: Int) {
        guard let sourceIndexAfterAttach,
              tabCount > 0,
              (0..<tabCount).contains(sourceIndexAfterAttach) else { return nil }

        self.insertionIndex = insertionIndex
        self.destinationIndex = VerticalTabDropPolicy.destinationIndex(
            sourceIndex: sourceIndexAfterAttach,
            insertionIndex: insertionIndex,
            tabCount: tabCount
        )
        self.tabCount = tabCount
    }

    func validates(actualIndex: Int?, tabCount actualTabCount: Int) -> Bool {
        actualTabCount == tabCount && actualIndex == destinationIndex
    }
}

enum VerticalTabDropActivity: Equatable {
    case idle
    case active
    case performed

    // SwiftUI tab drags can deliver dropUpdated without a preceding
    // dropEntered when moving between sibling row destinations. Idle must
    // therefore accept updates; only a completed drop rejects late callbacks.
    var acceptsUpdates: Bool { self != .performed }
}

struct VerticalTabDropTarget: Equatable {
    let tabSessionID: UUID?
    let groupID: String?
    let placement: VerticalTabDropPolicy.Placement
}

enum VerticalTabDropPayload: Equatable {
    case surface
    case tab

    static func resolve(hasSurface: Bool, hasTab: Bool) -> Self? {
        if hasSurface { return .surface }
        if hasTab { return .tab }
        return nil
    }
}

/// Routes both pane and tab payloads through a single SwiftUI drop destination.
/// Multiple onDrop modifiers on the same row compete for the same hit area and
/// can prevent the plain-text tab payload from ever reaching its delegate.
private struct VerticalTabRowDropDelegate: DropDelegate {
    let controller: TerminalController
    let destination: TerminalController
    let groupID: String
    let allowedSessionIDs: Set<UUID>
    @Binding var draggedSessionID: UUID?
    @Binding var dropTarget: VerticalTabDropTarget?
    @Binding var tabDropActivity: VerticalTabDropActivity
    @Binding var surfaceDropActivity: VerticalTabDropActivity

    private var tabDelegate: VerticalTabReorderDropDelegate {
        .init(
            controller: controller,
            destination: destination,
            groupID: groupID,
            allowedSessionIDs: allowedSessionIDs,
            draggedSessionID: $draggedSessionID,
            dropTarget: $dropTarget,
            dropActivity: $tabDropActivity
        )
    }

    private var surfaceDelegate: VerticalTabSurfaceDropDelegate {
        .init(
            controller: controller,
            destination: destination,
            groupID: groupID,
            placement: nil,
            dropTarget: $dropTarget,
            dropActivity: $surfaceDropActivity
        )
    }

    func validateDrop(info: DropInfo) -> Bool {
        switch payload(info) {
        case .surface: surfaceDelegate.validateDrop(info: info)
        case .tab: tabDelegate.validateDrop(info: info)
        case nil: false
        }
    }

    func dropEntered(info: DropInfo) {
        switch payload(info) {
        case .surface: surfaceDelegate.dropEntered(info: info)
        case .tab: tabDelegate.dropEntered(info: info)
        case nil: break
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        switch payload(info) {
        case .surface: surfaceDelegate.dropUpdated(info: info)
        case .tab: tabDelegate.dropUpdated(info: info)
        case nil: DropProposal(operation: .forbidden)
        }
    }

    func dropExited(info: DropInfo) {
        switch payload(info) {
        case .surface: surfaceDelegate.dropExited(info: info)
        case .tab: tabDelegate.dropExited(info: info)
        case nil: break
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        switch payload(info) {
        case .surface: surfaceDelegate.performDrop(info: info)
        case .tab: tabDelegate.performDrop(info: info)
        case nil: false
        }
    }

    private func payload(_ info: DropInfo) -> VerticalTabDropPayload? {
        VerticalTabDropPayload.resolve(
            hasSurface: info.hasItemsConforming(to: [.ghosttySurfaceId]),
            hasTab: info.hasItemsConforming(to: [UTType.utf8PlainText])
        )
    }
}

private struct VerticalTabReorderDropDelegate: DropDelegate {
    let controller: TerminalController
    let destination: TerminalController
    let groupID: String
    let allowedSessionIDs: Set<UUID>
    @Binding var draggedSessionID: UUID?
    @Binding var dropTarget: VerticalTabDropTarget?
    @Binding var dropActivity: VerticalTabDropActivity

    func validateDrop(info: DropInfo) -> Bool {
        dropActivity != .performed && VerticalTabDropPolicy.allows(
            source: draggedSessionID,
            in: allowedSessionIDs
        )
    }

    func dropEntered(info: DropInfo) {
        guard dropActivity != .performed else { return }
        dropActivity = .active
        updateTarget(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard dropActivity.acceptsUpdates,
              VerticalTabDropPolicy.allows(
                  source: draggedSessionID,
                  in: allowedSessionIDs
              ) else {
            return DropProposal(operation: .forbidden)
        }
        dropActivity = .active
        updateTarget(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        controller.clearVerticalTabHover()
        if dropActivity == .performed {
            dropActivity = .idle
            return
        }
        guard dropTarget?.tabSessionID == destination.tabSessionID else { return }
        dropTarget = nil
        dropActivity = .idle
    }

    func performDrop(info: DropInfo) -> Bool {
        controller.clearVerticalTabHover()
        let sourceID = draggedSessionID
        let source = sourceID.flatMap { sourceID in
            controller.tabControllers.first { $0.tabSessionID == sourceID }
        }
        let destinationIndex = controller.tabControllers.firstIndex {
            $0 === destination
        }
        let placement = dropTarget?.tabSessionID == destination.tabSessionID
            ? dropTarget?.placement
            : VerticalTabDropPolicy.placement(
                y: info.location.y,
                rowHeight: OhMyGhosttySettings.shared.tabRowDensity.rowHeight
            )
        let insertionIndex = destinationIndex.map {
            VerticalTabDropPolicy.insertionIndex(
                destinationIndex: $0,
                placement: placement ?? .before
            )
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            dropTarget = nil
            draggedSessionID = nil
            dropActivity = .performed
        }
        DispatchQueue.main.async {
            if dropActivity == .performed { dropActivity = .idle }
        }

        guard let sourceID,
              VerticalTabDropPolicy.allows(
                  source: sourceID,
                  in: allowedSessionIDs
              ),
              let source,
              let insertionIndex else { return false }

        // Commit the native tab order before returning from performDrop. If we
        // defer this to the next runloop, SwiftUI finishes the drop preview at
        // the old row first and then moves the real row one frame later, which
        // reads as a hitch. The visual state above is already cleared before
        // this synchronous, zero-duration AppKit reorder.
        _ = controller.reorderTab(source, toInsertionIndex: insertionIndex)
        return true
    }

    private func updateTarget(_ info: DropInfo) {
        guard VerticalTabDropPolicy.allows(
            source: draggedSessionID,
            in: allowedSessionIDs
        ) else { return }
        dropTarget = .init(
            tabSessionID: destination.tabSessionID,
            groupID: groupID,
            placement: VerticalTabDropPolicy.placement(
                y: info.location.y,
                rowHeight: OhMyGhosttySettings.shared.tabRowDensity.rowHeight
            )
        )
    }
}

private struct VerticalTabSurfaceDropDelegate: DropDelegate {
    let controller: TerminalController
    let destination: TerminalController
    let groupID: String?
    let placement: VerticalTabDropPolicy.Placement?
    @Binding var dropTarget: VerticalTabDropTarget?
    @Binding var dropActivity: VerticalTabDropActivity

    func validateDrop(info: DropInfo) -> Bool {
        dropActivity != .performed && info.hasItemsConforming(to: [.ghosttySurfaceId])
    }

    func dropEntered(info: DropInfo) {
        guard dropActivity != .performed else { return }
        dropActivity = .active
        updateTarget(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard dropActivity.acceptsUpdates,
              info.hasItemsConforming(to: [.ghosttySurfaceId]) else {
            return DropProposal(operation: .forbidden)
        }
        dropActivity = .active
        updateTarget(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        controller.clearVerticalTabHover()
        if dropActivity == .performed {
            dropActivity = .idle
            return
        }
        guard targetBelongsToDelegate else { return }
        dropTarget = nil
        dropActivity = .idle
    }

    func performDrop(info: DropInfo) -> Bool {
        controller.clearVerticalTabHover()
        let resolvedPlacement = placement ?? VerticalTabDropPolicy.placement(
            y: info.location.y,
            rowHeight: OhMyGhosttySettings.shared.tabRowDensity.rowHeight
        )
        let provider = info.itemProviders(for: [.ghosttySurfaceId]).first

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            dropTarget = nil
            dropActivity = .performed
        }
        DispatchQueue.main.async {
            if dropActivity == .performed { dropActivity = .idle }
        }

        guard let provider else { return false }
        _ = provider.loadTransferable(type: Ghostty.SurfaceView.self) { [weak controller, weak destination] result in
            guard case .success(let surface) = result else { return }
            DispatchQueue.main.async {
                guard let controller, let destination else { return }
                if !controller.moveSurfaceToNewTab(
                    surface,
                    relativeTo: destination,
                    placement: resolvedPlacement
                ) {
                    Ghostty.logger.warning("failed to move dropped surface into a tab")
                }
            }
        }
        return true
    }

    private var targetBelongsToDelegate: Bool {
        if placement == .end { return dropTarget?.placement == .end }
        return dropTarget?.tabSessionID == destination.tabSessionID
    }

    private func updateTarget(_ info: DropInfo) {
        dropTarget = .init(
            tabSessionID: placement == .end ? nil : destination.tabSessionID,
            groupID: groupID,
            placement: placement ?? VerticalTabDropPolicy.placement(
                y: info.location.y,
                rowHeight: OhMyGhosttySettings.shared.tabRowDensity.rowHeight
            )
        )
    }
}

private struct VerticalTabInsertionIndicator: View {
    let target: VerticalTabDropTarget?
    let tabSessionID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            if target?.tabSessionID == tabSessionID,
               target?.placement == .before {
                line
            }
            Spacer(minLength: 0)
            if target?.tabSessionID == tabSessionID,
               target?.placement == .after ||
                (tabSessionID == nil && target?.placement == .end) {
                line
            }
        }
        .allowsHitTesting(false)
    }

    private var line: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(height: 2)
            .padding(.horizontal, 3)
    }
}

private struct TabOrganizationMenu: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var layoutState: VerticalTabWindowLayoutState
    @State private var hovered = false

    var body: some View {
        Menu {
            Section("GROUP") {
                ForEach(GhosttyTabGroupingMode.allCases, id: \.self) { mode in
                    Button {
                        controller.setTabGroupingMode(mode)
                    } label: {
                        menuLabel(mode.title, selected: layoutState.groupingMode == mode)
                    }
                }
            }
            Section("ORDER") {
                ForEach(GhosttyTabOrderingMode.allCases, id: \.self) { mode in
                    Button {
                        controller.setTabOrderingMode(mode)
                    } label: {
                        menuLabel(mode.title, selected: layoutState.orderingMode == mode)
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 16, height: 16)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(hovered ? 0.07 : 0))
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovered = $0 }
        .help("Organize Tabs")
        .accessibilityLabel("Organize Tabs")
    }

    @ViewBuilder
    private func menuLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}

private struct VerticalTabGroupHeader: View {
    let title: String
    let icon: GhosttyTabIcon
    let collapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 10)
                GhosttyTabIconView(icon: icon, color: .secondary)
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .frame(height: 26)
        .accessibilityLabel(title)
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
    }
}

struct VerticalTabLayoutContainer<Content: View>: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var layoutState: VerticalTabWindowLayoutState
    @ObservedObject var statusStore: TabActivityStore
    let backgroundColor: Color
    let backgroundOpacity: Double
    let content: Content

    init(
        controller: TerminalController,
        layoutState: VerticalTabWindowLayoutState,
        statusStore: TabActivityStore,
        backgroundColor: Color,
        backgroundOpacity: Double = 1,
        @ViewBuilder content: () -> Content
    ) {
        self.controller = controller
        self.layoutState = layoutState
        self.statusStore = statusStore
        self.backgroundColor = backgroundColor
        self.backgroundOpacity = backgroundOpacity
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            if layoutState.isSidebarVisible {
                TerminalTabSidebarView(
                    controller: controller,
                    layoutState: layoutState,
                    statusStore: statusStore,
                    backgroundColor: backgroundColor,
                    backgroundOpacity: backgroundOpacity
                )
                .frame(width: presentedSidebarWidth)
                VerticalTabSidebarDivider(
                    controller: controller,
                    layoutState: layoutState,
                    color: controller.sidebarDividerColor,
                    background: backgroundColor.opacity(backgroundOpacity)
                )
            }
            content
        }
    }

    private var presentedSidebarWidth: CGFloat {
        controller.selectedTabID == ObjectIdentifier(controller)
            ? layoutState.sidebarWidth
            : layoutState.committedSidebarWidth
    }
}

struct VerticalTabSidebarDivider: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var layoutState: VerticalTabWindowLayoutState
    let color: Color
    var background: Color = .clear

    var body: some View {
        TerminalResizeBoundary(
            edge: .trailing,
            color: color,
            currentExtent: { layoutState.sidebarWidth },
            resize: controller.updateSidebarWidth,
            accessibilityLabel: "Resize Tabs Sidebar"
        )
        .background(background)
    }
}

struct SidebarResizeInteraction: NSViewRepresentable {
    enum Direction {
        case leading
        case trailing
        case top
        case bottom
    }

    let currentWidth: () -> CGFloat
    let resize: (CGFloat, Bool) -> Void
    let direction: Direction

    init(
        currentWidth: @escaping () -> CGFloat,
        resize: @escaping (CGFloat, Bool) -> Void,
        direction: Direction = .leading
    ) {
        self.currentWidth = currentWidth
        self.resize = resize
        self.direction = direction
    }

    func makeNSView(context: Context) -> DragView {
        DragView(currentWidth: currentWidth, resize: resize, direction: direction)
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.currentWidth = currentWidth
        view.resize = resize
        view.direction = direction
        view.window?.invalidateCursorRects(for: view)
    }

    final class DragView: NSView {
        var currentWidth: () -> CGFloat
        var resize: (CGFloat, Bool) -> Void
        var direction: Direction
        private var startWidth: CGFloat = 0
        private var startPosition: CGPoint = .zero
        private weak var resizeWindow: NSWindow?
        private var resizeDeferralActive = false
        private(set) var registeredCursorBounds: NSRect?

        init(
            currentWidth: @escaping () -> CGFloat,
            resize: @escaping (CGFloat, Bool) -> Void,
            direction: Direction = .leading
        ) {
            self.currentWidth = currentWidth
            self.resize = resize
            self.direction = direction
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.invalidateCursorRects(for: self)
            if window == nil {
                finishResizeDeferral()
            }
        }

        override func setFrameSize(_ newSize: NSSize) {
            let sizeChanged = frame.size != newSize
            super.setFrameSize(newSize)
            if sizeChanged {
                window?.invalidateCursorRects(for: self)
            }
        }

        override func resetCursorRects() {
            registeredCursorBounds = bounds
            let cursor: NSCursor = switch direction {
            case .leading, .trailing: .resizeLeftRight
            case .top, .bottom: .resizeUpDown
            }
            addCursorRect(bounds, cursor: cursor)
        }

        override func mouseDown(with event: NSEvent) {
            startWidth = currentWidth()
            startPosition = event.locationInWindow
            beginResizeDeferral()
        }

        override func mouseDragged(with event: NSEvent) {
            resize(proposedWidth(for: event), false)
        }

        override func mouseUp(with event: NSEvent) {
            resize(proposedWidth(for: event), true)
            finishResizeDeferral()
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        private func beginResizeDeferral() {
            if resizeDeferralActive {
                finishResizeDeferral()
            }
            guard let window else { return }
            resizeWindow = window
            resizeDeferralActive = true
            TerminalSurfaceResizeInteraction.begin(in: window)
        }

        private func finishResizeDeferral() {
            guard resizeDeferralActive else { return }
            let window = resizeWindow
            resizeWindow = nil
            resizeDeferralActive = false
            // Let the final @Published layout commit before flushing its one
            // terminal grid resize.
            DispatchQueue.main.async {
                TerminalSurfaceResizeInteraction.end(in: window)
            }
        }

        private func proposedWidth(for event: NSEvent) -> CGFloat {
            let position = event.locationInWindow
            switch direction {
            case .leading:
                return startWidth + position.x - startPosition.x
            case .trailing:
                return startWidth - position.x + startPosition.x
            case .top:
                return startWidth + position.y - startPosition.y
            case .bottom:
                return startWidth - position.y + startPosition.y
            }
        }
    }
}

typealias VerticalTabResizeInteraction = SidebarResizeInteraction

private struct VerticalTabRow: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var surface: Ghostty.SurfaceView
    @ObservedObject private var settings = OhMyGhosttySettings.shared
    let presentation: GhosttyTabPresentation
    let canClose: Bool
    let select: () -> Void
    let close: () -> Void
    let hoverChanged: (Bool) -> Void
    @State private var observedTitle = ""

    private var livePresentation: GhosttyTabPresentation {
        _ = observedTitle
        let activeSurface = controller.focusedSurface ?? controller.surfaceTree.first ?? surface
        let session = controller.paneSessionContext(for: activeSurface) ?? .init(
            workingDirectory: activeSurface.pwd,
            terminalTitle: activeSurface.title
        )
        let agentActivity = controller.agentActivity(for: activeSurface)
        let canonicalIcon = session.workspace?.icon ?? .systemSymbol(
            session.tabIconSystemName
        )
        let icon: GhosttyTabIcon = if let requested = agentActivity?.icon {
            switch requested.kind {
            case .systemSymbol: .systemSymbol(requested.name)
            case .bundledAsset: .asset(requested.name)
            }
        } else if activeSurface.id == surface.id {
            presentation.icon
        } else {
            canonicalIcon
        }
        let baseTitle = controller.titleOverride ?? (agentActivity == nil
            ? session.presentationTitle(pathDisplay: settings.tabPathDisplay)
            : session.agentPathTitle(pathDisplay: settings.tabPathDisplay))
        let pluginActivity = presentation.activity.flatMap {
            SupportedAgent(rawValue: $0.source) == nil ? $0 : nil
        }
        let activity = agentActivity ?? pluginActivity
        let title = activity
            .flatMap { SupportedAgent(rawValue: $0.source) }?
            .normalizedTitle(baseTitle) ?? baseTitle
        return .init(
            title: title,
            remoteBreadcrumb: controller.titleOverride == nil
                ? session.remoteTabBreadcrumb
                : nil,
            shortcut: presentation.shortcut,
            icon: icon,
            activity: activity,
            selected: presentation.selected,
            hovered: presentation.hovered
        )
    }

    var body: some View {
        let presentation = livePresentation
        let pluginActivity = presentation.activity.flatMap {
            SupportedAgent(rawValue: $0.source) == nil ? $0 : nil
        }
        let statusActivity = controller.preferredAgentActivity() ?? pluginActivity
        ZStack {
            Button(action: select) {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 4) {
                HStack(spacing: GhosttyTabStyle.contentSpacing) {
                    AgentTabIconView(
                        icon: presentation.icon,
                        color: GhosttyTabStyle.iconColor(
                            selected: presentation.selected,
                            hovered: presentation.hovered
                        ),
                        activity: presentation.activity
                    )

                    if let breadcrumb = presentation.remoteBreadcrumb {
                        RemoteTabBreadcrumbView(breadcrumb: breadcrumb)
                    } else {
                        Text(presentation.title)
                            .font(.system(size: 12.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 4)
                }
                .allowsHitTesting(false)

                if let statusActivity,
                   statusActivity.state != .idle,
                   !(SupportedAgent(rawValue: statusActivity.source) != nil &&
                        statusActivity.state == .working) {
                    TabActivityIndicator(activity: statusActivity)
                        .allowsHitTesting(false)
                }

                if presentation.hovered && canClose {
                    TerminalTitlebarIconButton(
                        systemName: "xmark",
                        help: "Close Tab",
                        action: close
                    )
                    .scaleEffect(0.8)
                } else if let shortcut = presentation.shortcut, !shortcut.isEmpty {
                    Text(shortcut)
                        .font(.system(size: GhosttyTabStyle.shortcutFontSize))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                        .allowsHitTesting(false)
                } else {
                    Color.clear
                        .frame(width: 28, height: 1)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, GhosttyTabStyle.horizontalPadding)
        }
        .frame(height: OhMyGhosttySettings.shared.tabRowDensity.rowHeight)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: GhosttyTabStyle.cornerRadius)
                .fill(Color.primary.opacity(GhosttyTabStyle.backgroundOpacity(
                    selected: presentation.selected,
                    hovered: presentation.hovered
                )))
        )
        .onHover(perform: hoverChanged)
        .onReceive(surface.$title.receive(on: DispatchQueue.main)) { _ in
            // Read committed session metadata. Folder-name and Agent labels
            // often remain identical while the terminal title animates.
            let nextTitle = livePresentation.title
            if observedTitle != nextTitle { observedTitle = nextTitle }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.title)
    }
}

private struct RemoteTabBreadcrumbView: View {
    let breadcrumb: RemoteTabBreadcrumb

    var body: some View {
        HStack(spacing: 3) {
            Text(breadcrumb.host)
                .font(.system(size: 11.75, weight: .regular))
                .foregroundStyle(Color.primary.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.middle)

            Text("›")
                .font(.system(size: 10.75, weight: .regular))
                .foregroundStyle(Color.primary.opacity(0.35))
                .fixedSize()

            Text(breadcrumb.directory)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.96))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
        }
    }
}

private struct TabActivityIndicator: View {
    let activity: TabActivity

    var body: some View {
        Group {
            if activity.state == .working {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.65)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(color)
            }
        }
        .frame(width: 12, height: 12)
        .help(activity.message ?? attentionDescription ?? activity.label ?? activity.state.rawValue)
        .accessibilityLabel(attentionDescription ?? activity.label ?? activity.state.rawValue)
    }

    private var systemImage: String {
        switch activity.state {
        case .idle: "circle"
        case .working: "circle"
        case .done: "checkmark.circle.fill"
        case .needsAttention:
            switch activity.attentionKind {
            case .question: "questionmark.bubble.fill"
            case .permission: "lock.shield.fill"
            case nil: "exclamationmark.circle.fill"
            }
        case .error: "xmark.circle.fill"
        }
    }

    private var attentionDescription: String? {
        switch activity.attentionKind {
        case .question: "Answer required"
        case .permission: "Approval required"
        case nil: nil
        }
    }

    private var color: Color {
        switch activity.state {
        case .idle, .working: .secondary
        case .done: .green
        case .needsAttention: .orange
        case .error: .red
        }
    }
}

private struct AgentTabIconView: View {
    @ObservedObject private var settings = OhMyGhosttySettings.shared
    let icon: GhosttyTabIcon
    let color: Color
    let activity: TabActivity?

    private var agent: SupportedAgent? {
        activity.flatMap { SupportedAgent(rawValue: $0.source) }
    }

    private var isSpinning: Bool {
        activity?.state == .working && activity?.progress == nil
    }

    var body: some View {
        TimelineView(.animation(
            minimumInterval: 1.0 / 30.0,
            paused: !isSpinning
        )) { timeline in
            ZStack {
                if agent != nil, let activity, activity.state != .idle {
                    Circle()
                        .trim(from: 0, to: ringProgress(activity))
                        .stroke(
                            ringColor(activity),
                            style: .init(lineWidth: 1.5, lineCap: .round)
                        )
                        .rotationEffect(.degrees(
                            isSpinning ? rotation(at: timeline.date) : -90
                        ))
                        .frame(
                            width: settings.tabIconSize + 3,
                            height: settings.tabIconSize + 3
                        )
                }

                GhosttyTabIconView(icon: icon, color: color)
                    .scaleEffect(agent?.definition.iconScale ?? 1)
            }
        }
        .frame(
            width: settings.tabIconSize,
            height: settings.tabIconSize + 3
        )
        .help(activity.map {
            $0.message ?? $0.label ?? $0.state.rawValue
        } ?? "Terminal")
    }

    private func rotation(at date: Date) -> Double {
        let period = 0.9
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: period) / period
        return phase * 360 - 90
    }

    private func ringProgress(_ activity: TabActivity) -> Double {
        switch activity.state {
        case .idle: 0
        case .working: activity.progress.map { max(0.05, $0) } ?? 0.25
        case .done, .needsAttention, .error: 1
        }
    }

    private func ringColor(_ activity: TabActivity) -> Color {
        switch activity.state {
        case .idle: .clear
        case .working:
            activity.phase == .background ? .purple : .accentColor
        case .done: .green
        case .needsAttention: .orange
        case .error: .red
        }
    }
}

private struct GhosttyTabIconView: View {
    @ObservedObject private var settings = OhMyGhosttySettings.shared
    let icon: GhosttyTabIcon
    let color: Color

    var body: some View {
        Group {
            switch icon {
            case .systemSymbol(let name):
                Image(systemName: name)
                    .font(.system(size: settings.tabIconSize))
            case .asset(let name):
                Image(name)
                    .resizable()
                    .scaledToFit()
            case .image(let image):
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            }
        }
        .foregroundStyle(color)
        .frame(width: settings.tabIconSize, height: settings.tabIconSize)
    }
}

struct VerticalTabTitleResolver {
    static func resolve(
        explicitTitle: String?,
        terminalTitle: String,
        workingDirectory: String?,
        isGitRoot: (String) -> Bool = defaultIsGitRoot
    ) -> String {
        if let explicit = normalized(explicitTitle) {
            return explicit
        }

        if let workingDirectory = normalized(workingDirectory) {
            if let project = gitProjectName(from: workingDirectory, isGitRoot: isGitRoot) {
                return project
            }
            let basename = URL(fileURLWithPath: workingDirectory).lastPathComponent
            if !basename.isEmpty { return basename }
        }

        if let terminalTitle = normalized(terminalTitle) {
            if terminalTitle.contains("/") {
                let basename = URL(fileURLWithPath: terminalTitle).lastPathComponent
                if !basename.isEmpty { return basename }
            }
            return terminalTitle
        }

        return "Terminal"
    }

    private static func gitProjectName(
        from workingDirectory: String,
        isGitRoot: (String) -> Bool
    ) -> String? {
        var url = URL(fileURLWithPath: workingDirectory).standardizedFileURL
        while url.path != "/" {
            if isGitRoot(url.path) {
                return url.lastPathComponent
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func defaultIsGitRoot(_ path: String) -> Bool {
        FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: path).appendingPathComponent(".git").path
        )
    }
}
