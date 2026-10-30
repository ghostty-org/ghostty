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

/// Shared by every native window in a tab group. Weak references avoid a
/// controller -> layout state -> controller ownership cycle.
struct VerticalTabSnapshot {
    struct Tab {
        weak var controller: TerminalController?
    }

    var tabs: [Tab] = []
    var selectedID: ObjectIdentifier?
    var controllers: [TerminalController] { tabs.compactMap(\.controller) }
}

@MainActor
final class VerticalTabPresentationState: ObservableObject {
    @Published var pendingSelectedTabID: ObjectIdentifier?
    @Published private(set) var tabSnapshot = VerticalTabSnapshot()
    // Pointer movement is row-local: do not broadcast objectWillChange to
    // every sidebar in the native tab group.
    let hoverChanges = CurrentValueSubject<ObjectIdentifier?, Never>(nil)
    var hoveredTabID: ObjectIdentifier? {
        get { hoverChanges.value }
        set {
            guard hoverChanges.value != newValue else { return }
            hoverChanges.send(newValue)
        }
    }

    func updateTabs(_ controllers: [TerminalController], selectedID: ObjectIdentifier?) {
        let current = tabSnapshot.controllers
        guard current.map(ObjectIdentifier.init) != controllers.map(ObjectIdentifier.init) ||
                tabSnapshot.selectedID != selectedID else { return }
        // Tracking rectangles will re-evaluate the pointer after layout. Never
        // carry a hover from the old row geometry into a different native window.
        if current.map(ObjectIdentifier.init) != controllers.map(ObjectIdentifier.init) {
            hoveredTabID = nil
        }
        tabSnapshot = VerticalTabSnapshot(
            tabs: controllers.map { VerticalTabSnapshot.Tab(controller: $0) },
            selectedID: selectedID
        )
    }

}

@MainActor
final class VerticalTabWindowLayoutState: ObservableObject {
    // Frequent tab/hover changes must not invalidate shell geometry or inspector views.
    let tabPresentation = VerticalTabPresentationState()
    let sidebarHost = VerticalTabSidebarHost()
    weak var nativeTabGroup: NSWindowTabGroup?
    private var workspaceID: UUID?
    var workspaceBindingID: UUID? { workspaceID }
    private weak var workspaceStore: TerminalWorkspaceStore?
    private var workspaceObservation: AnyCancellable?
    private struct WorkspaceChrome: Equatable {
        let sidebarVisible: Bool
        let sidebarWidth: Double
        let inspectorVisible: Bool
        let inspectorWidth: Double
        let inspectorPane: String?

        init(_ value: TerminalWorkspaceStore.Presentation) {
            sidebarVisible = value.sidebarVisible
            sidebarWidth = value.sidebarWidth
            inspectorVisible = value.inspectorVisible
            inspectorWidth = value.inspectorWidth
            inspectorPane = value.inspectorPane
        }
    }
    private var appliedWorkspaceChrome: WorkspaceChrome?
    private var applyingWorkspace = false

    func bindWorkspace(_ id: UUID, store: TerminalWorkspaceStore = .shared) {
        guard workspaceID != id || workspaceStore !== store else { return }
        workspaceID = id
        workspaceStore = store
        appliedWorkspaceChrome = nil
        workspaceObservation = store.presentationChanges.sink { [weak self] changed, value in
            guard let self, changed == self.workspaceID else { return }
            self.applyWorkspacePresentation(value)
        }
        applyWorkspacePresentation(store.presentation(for: id))
    }

    private func applyWorkspacePresentation(_ value: TerminalWorkspaceStore.Presentation) {
        let chrome = WorkspaceChrome(value)
        guard appliedWorkspaceChrome != chrome else { return }
        appliedWorkspaceChrome = chrome
        applyingWorkspace = true
        defer { applyingWorkspace = false }
        resizeWorkItem?.cancel()
        sidebarPersistenceWorkItem?.cancel()
        inspectorResizeWorkItem?.cancel()
        pendingSidebarWidth = nil
        pendingInspectorWidth = nil
        if isSidebarVisible != value.sidebarVisible { isSidebarVisible = value.sidebarVisible }
        if sidebarWidth != CGFloat(value.sidebarWidth) { sidebarWidth = CGFloat(value.sidebarWidth) }
        if committedSidebarWidth != sidebarWidth { committedSidebarWidth = sidebarWidth }
        if isInspectorVisible != value.inspectorVisible { isInspectorVisible = value.inspectorVisible }
        if inspectorWidth != CGFloat(value.inspectorWidth) { inspectorWidth = CGFloat(value.inspectorWidth) }
        if committedInspectorWidth != inspectorWidth { committedInspectorWidth = inspectorWidth }
        if selectedInspectorPaneID != value.inspectorPane { selectedInspectorPaneID = value.inspectorPane }
    }

    private func saveWorkspacePresentation() {
        guard !applyingWorkspace, let workspaceID else { return }
        workspaceStore?.updatePresentation(for: workspaceID) {
            $0.sidebarVisible = isSidebarVisible
            $0.sidebarWidth = Double(committedSidebarWidth)
            $0.inspectorVisible = isInspectorVisible
            $0.inspectorWidth = Double(committedInspectorWidth)
            $0.inspectorPane = selectedInspectorPaneID
        }
    }

    func detachedCopy() -> VerticalTabWindowLayoutState {
        let copy = VerticalTabWindowLayoutState(
            isSidebarVisible: isSidebarVisible,
            sidebarWidth: sidebarWidth,
            isInspectorVisible: isInspectorVisible,
            settings: settings,
            inspectorPresentation: inspectorPresentation
        )
        copy.committedSidebarWidth = committedSidebarWidth
        copy.groupingMode = groupingMode
        copy.orderingMode = orderingMode
        copy.collapsedGroupIDs = collapsedGroupIDs
        copy.inspectorWidth = inspectorWidth
        copy.committedInspectorWidth = committedInspectorWidth
        copy.selectedInspectorPaneID = selectedInspectorPaneID
        if let workspaceID, let workspaceStore { copy.bindWorkspace(workspaceID, store: workspaceStore) }
        return copy
    }
    var tabSnapshot: VerticalTabSnapshot { tabPresentation.tabSnapshot }
    var hoveredTabID: ObjectIdentifier? {
        get { tabPresentation.hoveredTabID }
        set {
            guard tabPresentation.hoveredTabID != newValue else { return }
            tabPresentation.hoveredTabID = newValue
        }
    }
    var pendingSelectedTabID: ObjectIdentifier? {
        get { tabPresentation.pendingSelectedTabID }
        set { tabPresentation.pendingSelectedTabID = newValue }
    }

    func updateTabs(_ controllers: [TerminalController], selectedID: ObjectIdentifier?) {
        tabPresentation.updateTabs(controllers, selectedID: selectedID)
    }

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

    private var pendingSelectionSourceID: ObjectIdentifier?
    private(set) var selectionGeneration: UInt64 = 0
    private var deferredSelectionTarget: ObjectIdentifier?

    func beginDeferredTabSelection(_ target: ObjectIdentifier) -> UInt64 {
        // The intent was registered by anticipateTabSelection. A generation
        // outlives its acknowledgement so a late callback cannot regain focus.
        deferredSelectionTarget = target
        return selectionGeneration
    }

    func permitsDeferredTabSelection(_ target: ObjectIdentifier, generation: UInt64) -> Bool {
        selectionGeneration == generation && deferredSelectionTarget == target
    }

    func finishDeferredTabSelection(_ target: ObjectIdentifier, generation: UInt64) {
        guard permitsDeferredTabSelection(target, generation: generation) else { return }
        deferredSelectionTarget = nil
    }
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
        saveWorkspacePresentation()
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

    func anticipateTabSelection(_ target: ObjectIdentifier, from source: ObjectIdentifier?) {
        selectionGeneration &+= 1
        deferredSelectionTarget = nil
        pendingSelectionSourceID = source
        pendingSelectedTabID = target
    }

    func reconcileTabSelection(_ selected: ObjectIdentifier?) {
        guard let pendingSelectedTabID else { return }
        // Ignore observations of the old window during AppKit's tab switch.
        // A different selection means an external action superseded ours.
        guard deferredSelectionTarget == nil || selected == pendingSelectedTabID else { return }
        guard selected == pendingSelectedTabID ||
                (selected != nil && selected != pendingSelectionSourceID) else { return }
        pendingSelectionSourceID = nil
        self.pendingSelectedTabID = nil
    }

    func cancelPendingTabSelection(_ target: ObjectIdentifier) {
        if deferredSelectionTarget == target {
            selectionGeneration &+= 1
            deferredSelectionTarget = nil
        }
        guard pendingSelectedTabID == target else { return }
        pendingSelectionSourceID = nil
        pendingSelectedTabID = nil
    }

    func setInspectorVisible(_ visible: Bool) {
        guard isInspectorVisible != visible else { return }
        isInspectorVisible = visible
        if workspaceID == nil { inspectorPresentation.setVisible(visible) }
        saveWorkspacePresentation()
    }

    func toggleInspector() {
        setInspectorVisible(!isInspectorVisible)
    }

    func selectInspectorPane(_ paneID: String?) {
        guard selectedInspectorPaneID != paneID else { return }
        selectedInspectorPaneID = paneID
        if workspaceID == nil { inspectorPresentation.selectPane(paneID) }
        saveWorkspacePresentation()
    }

    func toggleInspectorPane(atSlot slot: Int, registry: InspectorRegistry) {
        guard slot >= 1, !registry.entries.isEmpty else { return }
        let index = slot - 1
        guard index < registry.entries.count else { return }
        let targetID = registry.entries[index].id

        let currentSelectedID = selectedInspectorPaneID ?? registry.entries.first?.id

        if isInspectorVisible {
            if currentSelectedID == targetID {
                setInspectorVisible(false)
            } else {
                selectInspectorPane(targetID)
            }
        } else {
            selectInspectorPane(targetID)
            setInspectorVisible(true)
        }
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
        if workspaceID != nil {
            saveWorkspacePresentation()
            return
        }
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
            if workspaceID == nil { inspectorPresentation.setWidth(width) }
            saveWorkspacePresentation()
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
        if let surface, let session = controller.paneSessionContext(for: surface) {
            switch session.state {
            case .sshReady(let ssh, let remotePath):
                // Remote paths belong to that connection, never the local filesystem.
                return .init(id: "remote:\(ssh.transferTarget):\(remotePath)",
                             title: "\(ssh.alias) · \(WorkspacePathPresentation.folderName(remotePath))",
                             icon: .systemSymbol("network"))
            case .sshConnecting(let ssh):
                return .init(id: "remote:\(ssh.transferTarget)", title: ssh.alias, icon: .systemSymbol("network"))
            case .local: break
            }
        }
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
                SharedTerminalTabSidebar(
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
    /// OMG: reports hover-or-drag so the divider line can highlight.
    let onActiveChange: (Bool) -> Void

    init(
        currentWidth: @escaping () -> CGFloat,
        resize: @escaping (CGFloat, Bool) -> Void,
        direction: Direction = .leading,
        onActiveChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.currentWidth = currentWidth
        self.resize = resize
        self.direction = direction
        self.onActiveChange = onActiveChange
    }

    func makeNSView(context: Context) -> DragView {
        let view = DragView(currentWidth: currentWidth, resize: resize, direction: direction)
        view.onActiveChange = onActiveChange
        return view
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.currentWidth = currentWidth
        view.resize = resize
        view.onActiveChange = onActiveChange
        if view.direction != direction {
            view.direction = direction
            view.window?.invalidateCursorRects(for: view)
        }
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
        var onActiveChange: (Bool) -> Void = { _ in }
        private var isHovering = false { didSet { updateActive() } }
        private var isDragging = false { didSet { updateActive() } }
        /// Hover or drag. Changes only on enter/exit/down/up, never per move.
        private(set) var isActive = false

        init(
            currentWidth: @escaping () -> CGFloat,
            resize: @escaping (CGFloat, Bool) -> Void,
            direction: Direction = .leading
        ) {
            self.currentWidth = currentWidth
            self.resize = resize
            self.direction = direction
            super.init(frame: .zero)
            // inVisibleRect follows geometry, so the area is never replaced
            // (replacing it would synthesize exit/enter pairs).
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self
            ))
        }

        private func updateActive() {
            let active = isHovering || isDragging
            guard active != isActive else { return }
            isActive = active
            onActiveChange(active)
        }

        override func mouseEntered(with event: NSEvent) { isHovering = true }

        override func mouseExited(with event: NSEvent) { isHovering = false }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.invalidateCursorRects(for: self)
            if window == nil {
                finishResizeDeferral()
                isHovering = false
                isDragging = false
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
            isDragging = true
            beginResizeDeferral()
        }

        override func mouseDragged(with event: NSEvent) {
            resize(proposedWidth(for: event), false)
        }

        override func mouseUp(with event: NSEvent) {
            resize(proposedWidth(for: event), true)
            finishResizeDeferral()
            isDragging = false
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
