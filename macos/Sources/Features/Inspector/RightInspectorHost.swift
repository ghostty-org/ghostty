import AppKit
import Combine
import SwiftUI

enum TerminalShellStyle {
    static let resizeHitWidth: CGFloat = 8
    static let dividerWidth: CGFloat = 1
    static let minimumTerminalWidth: CGFloat = 320
    static let resizeOverlap = resizeHitWidth - dividerWidth

    static func presentedInspectorWidth(
        preferred: CGFloat,
        totalWidth: CGFloat,
        leadingWidth: CGFloat
    ) -> CGFloat {
        let maximum = max(
            RightInspectorMetrics.minimumWidth,
            totalWidth - leadingWidth - minimumTerminalWidth - dividerWidth
        )
        return min(preferred, maximum)
    }
}

enum InspectorContentMetrics {
    static let leadingInset: CGFloat = 12
    static let treeOuterInset: CGFloat = 4
    static let treeRowLeadingInset = leadingInset - treeOuterInset

    static func titlebarLeadingInset(firstItemHasTitle: Bool) -> CGFloat {
        let buttonInset = firstItemHasTitle
            ? TerminalTitlebarControlStyle.horizontalLabelPadding
            : TerminalTitlebarControlStyle.iconHorizontalPadding
        return max(0, leadingInset - buttonInset)
    }
}

struct TerminalSidebarDividerLine: View {
    let color: Color

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: TerminalShellStyle.dividerWidth)
            .frame(maxHeight: .infinity)
    }
}

struct TerminalResizeBoundary: View {
    enum Edge {
        case leading
        case trailing
        case top
    }

    let edge: Edge
    let color: Color
    let currentExtent: () -> CGFloat
    let resize: (CGFloat, Bool) -> Void
    let accessibilityLabel: String
    /// OMG: hover-or-drag state from the AppKit tracking area. It flips only on
    /// enter/exit/down/up, so the line never flickers while the mouse moves.
    @State private var isActive = false

    /// Theme-consistent highlight; OMG uses the accent for selection chrome.
    static let activeColor = Color.accentColor

    private var lineColor: Color { isActive ? Self.activeColor : color }

    @ViewBuilder
    var body: some View {
        switch edge {
        case .leading:
            ZStack(alignment: .leading) {
                TerminalSidebarDividerLine(color: lineColor)
                interaction(direction: .trailing)
            }
            .frame(width: TerminalShellStyle.resizeHitWidth)
            .padding(.trailing, -TerminalShellStyle.resizeOverlap)

        case .trailing:
            ZStack(alignment: .trailing) {
                TerminalSidebarDividerLine(color: lineColor)
                interaction(direction: .leading)
            }
            .frame(width: TerminalShellStyle.resizeHitWidth)
            .padding(.leading, -TerminalShellStyle.resizeOverlap)

        case .top:
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(lineColor)
                    .frame(height: TerminalShellStyle.dividerWidth)
                    .frame(maxWidth: .infinity)
                interaction(direction: .top)
            }
            .frame(height: TerminalShellStyle.resizeHitWidth)
            .padding(.bottom, -TerminalShellStyle.resizeOverlap)
        }
    }

    private func interaction(
        direction: SidebarResizeInteraction.Direction
    ) -> some View {
        SidebarResizeInteraction(
            currentWidth: currentExtent,
            resize: resize,
            direction: direction,
            onActiveChange: { isActive = $0 }
        )
        .contentShape(Rectangle())
        .accessibilityLabel(accessibilityLabel)
    }
}

final class InspectorTitlebarPresentation: ObservableObject {
    @Published private(set) var width = TerminalTitlebarMetrics.inspectorCollapsedWidth
    @Published private(set) var isVisible = false
    @Published var navigationInPane = false

    func setWidth(_ width: CGFloat) {
        guard self.width != width else { return }
        self.width = width
    }

    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
    }
}

enum InspectorTitlebarLayout {
    static func pluginWidth(totalWidth: CGFloat) -> CGFloat {
        max(0, totalWidth - TerminalTitlebarMetrics.inspectorCollapsedWidth)
    }
}

struct InspectorPluginBarLayout: Equatable {
    let visibleIDs: [String]
    let overflowIDs: [String]

    static func resolve(
        descriptors: [InspectorPaneDescriptor],
        selectedID: String?,
        availableWidth: CGFloat
    ) -> Self {
        let bucket = TerminalTitlebarMetrics.inspectorOverflowBucket
        let bucketedWidth = floor(max(availableWidth, 0) / bucket) * bucket
        let firstItemHasTitle = descriptors.first?.id == selectedID
        let leadingInset = InspectorContentMetrics.titlebarLeadingInset(
            firstItemHasTitle: firstItemHasTitle
        )
        let overflowWidth = TerminalTitlebarControlStyle.controlWidth(title: nil)
        let spacing = TerminalTitlebarControlStyle.itemSpacing
        let usable = max(0, bucketedWidth - leadingInset)

        func itemWidth(_ descriptor: InspectorPaneDescriptor) -> CGFloat {
            TerminalTitlebarControlStyle.controlWidth(
                title: descriptor.id == selectedID ? descriptor.title : nil
            )
        }

        let allItemsWidth = descriptors.enumerated().reduce(0) { result, item in
            result + (item.offset == 0 ? 0 : spacing) + itemWidth(item.element)
        }
        if allItemsWidth <= usable {
            return .init(
                visibleIDs: descriptors.map(\.id),
                overflowIDs: []
            )
        }

        var visible: [String] = []
        var used = overflowWidth
        for descriptor in descriptors {
            let candidate = itemWidth(descriptor) + spacing
            guard used + candidate <= usable else { break }
            visible.append(descriptor.id)
            used += candidate
        }
        return .init(
            visibleIDs: visible,
            overflowIDs: descriptors.map(\.id).filter { !visible.contains($0) }
        )
    }
}

extension TerminalWindow {
    func installInspectorToggle(
        controller: TerminalController,
        registry: InspectorRegistry
    ) {
        guard styleMask.contains(.titled) else { return }
        let installed = titlebarAccessoryViewControllers.contains(inspectorToggleAccessory)
        inspectorToggleAccessory.layoutAttribute = .right
        inspectorToggleAccessory.view = AlignedTerminalTitlebarControlsView(
            minimumWidth: TerminalTitlebarMetrics.inspectorCollapsedWidth,
            rootView: InspectorTitlebarControls(
                layoutState: controller.tabLayoutState,
                presentation: inspectorTitlebarPresentation,
                registry: registry,
                toggleInspector: { [weak controller] in controller?.toggleInspectorPane() }
            )
        )
        inspectorToggleAccessory.view.translatesAutoresizingMaskIntoConstraints = false
        inspectorToggleWidthConstraint?.isActive = false
        let widthConstraint = inspectorToggleAccessory.view.widthAnchor.constraint(
            equalToConstant: TerminalTitlebarMetrics.inspectorCollapsedWidth
        )
        inspectorToggleWidthConstraint = widthConstraint
        widthConstraint.isActive = true
        if !installed {
            addTitlebarAccessoryViewController(inspectorToggleAccessory)
        }
        inspectorTitlebarPresentation.navigationInPane = controller.tabLayout == .horizontal
        let state = controller.tabLayoutState
        inspectorTitlebarPresentation.setVisible(false)
        inspectorTitlebarPresentation.setWidth(
            TerminalTitlebarMetrics.inspectorCollapsedWidth
        )
        let layoutChanges = Publishers.CombineLatest3(
            state.$isInspectorVisible,
            state.$inspectorWidth,
            state.$sidebarWidth
        )
        let resizeChanges = NotificationCenter.default.publisher(
            for: NSWindow.didResizeNotification,
            object: self
        )
        .map { _ in () }
        .prepend(())
        inspectorToggleCancellable = Publishers.CombineLatest(
            layoutChanges,
            resizeChanges
        )
        .sink { [weak self, weak controller] layout, _ in
            guard let self, let controller else { return }
            let (isVisible, inspectorWidth, sidebarWidth) = layout
            let totalWidth = self.contentLayoutRect.width
            let leadingWidth = controller.supportsSidebar
                ? sidebarWidth + TerminalShellStyle.dividerWidth
                : 0
            let presentedWidth = TerminalShellStyle.presentedInspectorWidth(
                preferred: inspectorWidth,
                totalWidth: totalWidth,
                leadingWidth: leadingWidth
            )
            let targetWidth = isVisible && controller.supportsSidebar
                ? presentedWidth
                : TerminalTitlebarMetrics.inspectorCollapsedWidth
            // Resize the native accessory and its controls in the same turn
            // as the pane. No delayed collapse or separate titlebar animation.
            self.applyInspectorAccessoryWidth(targetWidth, controller: controller)
            self.inspectorTitlebarPresentation.setVisible(isVisible)
        }

        // AppKit may reset an already-visible transparent window to opaque when
        // adding or resizing a trailing titlebar accessory. Restore appearance
        // once the titlebar layout has settled rather than on every resize event.
        scheduleInspectorAppearanceSync(controller: controller)
    }

    private func applyInspectorAccessoryWidth(
        _ width: CGFloat,
        controller: TerminalController
    ) {
        let sizing = inspectorToggleAccessory.view as? TerminalTitlebarWidthSynchronizing
        guard inspectorToggleWidthConstraint?.constant != width ||
                sizing?.titlebarWidth != width else { return }
        inspectorToggleWidthConstraint?.constant = width
        inspectorTitlebarPresentation.setWidth(width)
        sizing?.setTitlebarWidth(width)
        inspectorToggleAccessory.view.needsLayout = true
        titlebarContainer?.needsLayout = true
        scheduleInspectorAppearanceSync(controller: controller)
    }

    private func scheduleInspectorAppearanceSync(controller: TerminalController) {
        inspectorAppearanceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self, weak controller] in
            guard let self,
                  let surface = controller?.focusedSurface ?? controller?.surfaceTree.first else {
                return
            }
            self.syncAppearance(surface.derivedConfig)
        }
        inspectorAppearanceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }

    var inspectorToggleIsInstalled: Bool {
        titlebarAccessoryViewControllers.contains(inspectorToggleAccessory)
    }

    var inspectorControlsCenterY: CGFloat? {
        (inspectorToggleAccessory.view as? TerminalTitlebarControlsCentering)?.contentCenterYInWindow
    }

    var inspectorControlsHeight: CGFloat? {
        guard inspectorToggleAccessory.view.window != nil else { return nil }
        return inspectorToggleAccessory.view.bounds.height
    }

    var inspectorControlsWidth: CGFloat? {
        guard inspectorToggleAccessory.view.window != nil else { return nil }
        return inspectorToggleAccessory.view.bounds.width
    }

}

private struct InspectorTitlebarControls: View {
    @ObservedObject var layoutState: VerticalTabWindowLayoutState
    @ObservedObject var presentation: InspectorTitlebarPresentation
    @ObservedObject var registry: InspectorRegistry
    let toggleInspector: () -> Void

    private var selectedPaneID: String? {
        if let selected = layoutState.selectedInspectorPaneID,
           registry.descriptor(id: selected) != nil {
            return selected
        }
        return registry.entries.first?.id
    }

    var body: some View {
        let inspectorVisible = presentation.isVisible
        let descriptors = inspectorVisible && !presentation.navigationInPane
            ? registry.entries.map(\.descriptor)
            : []
        let pluginWidth = InspectorTitlebarLayout.pluginWidth(
            totalWidth: presentation.width
        )
        let layout = InspectorPluginBarLayout.resolve(
            descriptors: descriptors,
            selectedID: selectedPaneID,
            availableWidth: pluginWidth
        )
        let titlebarLeadingInset = InspectorContentMetrics.titlebarLeadingInset(
            firstItemHasTitle: layout.visibleIDs.first == selectedPaneID
        )
        HStack(spacing: 0) {
            if inspectorVisible && !presentation.navigationInPane {
                HStack(spacing: TerminalTitlebarControlStyle.itemSpacing) {
                    ForEach(layout.visibleIDs, id: \.self) { id in
                        if let descriptor = registry.descriptor(id: id) {
                            InspectorTitlebarPaneButton(
                                descriptor: descriptor,
                                selected: selectedPaneID == id,
                                select: { select(id) }
                            )
                        }
                    }
                    if !layout.overflowIDs.isEmpty {
                        InspectorPluginOverflowMenu(
                            descriptors: layout.overflowIDs.compactMap {
                                registry.descriptor(id: $0)
                            },
                            selectedID: selectedPaneID,
                            select: select
                        )
                    }
                }
                .padding(.leading, titlebarLeadingInset)
                .frame(width: pluginWidth, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }

            TerminalTitlebarIconButton(
                systemName: "sidebar.right",
                help: inspectorVisible ? "Hide Inspector · ⌘⇧B" : "Show Inspector · ⌘⇧B",
                action: toggleInspector
            )
            .frame(width: TerminalTitlebarMetrics.inspectorCollapsedWidth)
            .disabled(registry.isEmpty)
            .opacity(
                registry.isEmpty ? TerminalTitlebarControlStyle.disabledOpacity : 1
            )
        }
        .frame(width: presentation.width, alignment: .trailing)
        .frame(maxHeight: .infinity)
        .transaction { $0.animation = nil }
    }

    private func select(_ paneID: String) {
        layoutState.selectInspectorPane(paneID)
        layoutState.setInspectorVisible(true)
    }
}

private struct InspectorTitlebarPaneButton: View {
    let descriptor: InspectorPaneDescriptor
    let selected: Bool
    let select: () -> Void

    var body: some View {
        TerminalTitlebarButton(
            systemName: descriptor.systemImage,
            title: selected ? descriptor.title : nil,
            help: descriptor.title,
            action: select
        )
        .accessibilityValue(selected ? "Selected" : "")
    }
}

struct TerminalShellLayoutContainer<Content: View>: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var layoutState: VerticalTabWindowLayoutState
    @ObservedObject var statusStore: TabActivityStore
    @ObservedObject var inspectorRegistry: InspectorRegistry
    let showsTabSidebar: Bool
    let backgroundColor: Color
    let backgroundOpacity: Double
    /// Effective chrome background (color with effective opacity applied).
    let chromeBackground: Color
    let content: Content

    init(
        controller: TerminalController,
        layoutState: VerticalTabWindowLayoutState,
        statusStore: TabActivityStore,
        inspectorRegistry: InspectorRegistry,
        showsTabSidebar: Bool,
        backgroundColor: Color,
        backgroundOpacity: Double,
        chromeBackground: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.controller = controller
        self.layoutState = layoutState
        self.statusStore = statusStore
        self.inspectorRegistry = inspectorRegistry
        self.showsTabSidebar = showsTabSidebar
        self.backgroundColor = backgroundColor
        self.backgroundOpacity = backgroundOpacity
        self.chromeBackground = chromeBackground
        self.content = content()
    }

    var body: some View {
        let leftVisible = showsTabSidebar && layoutState.isSidebarVisible
        let rightVisible = layoutState.isInspectorVisible && !inspectorRegistry.isEmpty
        NativeTerminalShell(
            leadingWidth: presentedSidebarWidth + TerminalShellStyle.dividerWidth,
            trailingWidth: preferredInspectorWidth,
            leadingVisible: leftVisible,
            trailingVisible: rightVisible,
            leading: AnyView(HStack(spacing: 0) {
                SharedTerminalTabSidebar(
                    controller: controller, layoutState: layoutState,
                    statusStore: statusStore, backgroundColor: backgroundColor,
                    backgroundOpacity: 0
                )
                VerticalTabSidebarDivider(
                    controller: controller, layoutState: layoutState,
                    color: controller.sidebarDividerColor, background: .clear
                )
            }.background(chromeBackground)),
            center: AnyView(AgentQuickInputDock(
                controller: controller, model: controller.quickInputModel,
                backgroundColor: backgroundColor, backgroundOpacity: backgroundOpacity
            ) {
                VStack(spacing: 0) {
                    if !showsTabSidebar && !controller.horizontalWorkspaceInTitlebar {
                        HStack {
                            TerminalWorkspaceButton(controller: controller)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 32)
                        .background(chromeBackground)
                    }
                    SSHAgentHookOnboardingBanner(controller: controller)
                    content
                }
            }),
            trailing: AnyView(HStack(spacing: 0) {
                RightInspectorResizeHandle(
                    color: controller.sidebarDividerColor, background: .clear,
                    currentWidth: { layoutState.inspectorWidth },
                    resize: controller.updateInspectorWidth
                )
                .zIndex(10)
                RightInspectorHost(
                    controller: controller, layoutState: layoutState,
                    registry: inspectorRegistry, isPresented: rightVisible,
                    backgroundColor: backgroundColor, backgroundOpacity: 0
                )
            }.background(chromeBackground))
        )
    }

    private var presentedSidebarWidth: CGFloat {
        controller.selectedTabID == ObjectIdentifier(controller)
            ? layoutState.sidebarWidth
            : layoutState.committedSidebarWidth
    }

    private var preferredInspectorWidth: CGFloat {
        controller.selectedTabID == ObjectIdentifier(controller)
            ? layoutState.inspectorWidth
            : layoutState.committedInspectorWidth
    }
}

/// A SwiftUI adapter only; observation, pane caching and provider presentation
/// belong to the native controller rather than SwiftUI appearance callbacks.
struct RightInspectorHost: NSViewControllerRepresentable {
    let controller: TerminalController
    let layoutState: VerticalTabWindowLayoutState
    let registry: InspectorRegistry
    var isPresented = true
    let backgroundColor: Color
    let backgroundOpacity: Double

    func makeNSViewController(context: Context) -> InspectorHostController {
        InspectorHostController(controller: controller, layoutState: layoutState, registry: registry)
    }

    func updateNSViewController(_ host: InspectorHostController, context: Context) {
        host.configure(isPresented: isPresented, backgroundColor: backgroundColor,
                       backgroundOpacity: backgroundOpacity, environment: context.environment)
    }

    static func dismantleNSViewController(_ host: InspectorHostController, coordinator: ()) {
        host.stop()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: InspectorHostController,
                      context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

struct InspectorPaneContentView: View {
    let content: InspectorPaneContent
    let paneID: String
    let context: InspectorPaneContext
    let dividerColor: Color
    let registry: InspectorRegistry

    var body: some View {
        switch content {
        case .empty(let title, let message):
            VStack(spacing: 8) {
                Image(systemName: "sidebar.trailing")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .fields(let fields):
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    ForEach(fields) { field in
                        GridRow {
                            Text(field.label)
                                .foregroundStyle(.secondary)
                            Text(field.value)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        case .list(let items):
            List(items) { item in
                HStack(spacing: 8) {
                    if let systemImage = item.systemImage {
                        Image(systemName: systemImage)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                        if let subtitle = item.subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)

        case .fileTree(let tree):
            InspectorFileTreeView(
                tree: tree,
                perform: { kind in
                    registry.performAction(
                        paneID: paneID,
                        action: .init(context: context, kind: kind)
                    )
                }
            )

        case .info(let info):
            InspectorInfoView(
                info: info,
                dividerColor: dividerColor,
                perform: { kind in
                    registry.performAction(
                        paneID: paneID,
                        action: .init(context: context, kind: kind)
                    )
                }
            )
        case .agentHistory(let history):
            InspectorAgentHistoryView(
                history: history,
                currentDirectory: context.workingDirectory,
                perform: { kind in
                    registry.performAction(
                        paneID: paneID,
                        action: .init(context: context, kind: kind)
                    )
                }
            )
        case .git(let gitContent):
            InspectorGitView(
                content: gitContent,
                perform: { kind in
                    registry.performAction(
                        paneID: paneID,
                        action: .init(context: context, kind: kind)
                    )
                }
            )
        }
    }
}

enum AgentHistoryGroupingMode: String, CaseIterable, Sendable {
    case none
    case project
    case agent
    case date
}

enum AgentHistoryOrderingMode: String, CaseIterable, Sendable {
    case recentlyUpdated
    case title
}

enum AgentHistoryDirectoryFilter: String, CaseIterable, Sendable {
    case any
    case currentTree
}

enum AgentHistoryTimeFilter: String, CaseIterable, Sendable {
    case any
    case day
    case week
    case month
    case quarter
    case year

    /// Inclusive lower bound for a session's last update.
    func cutoff(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .any: return nil
        case .day: return calendar.date(byAdding: .day, value: -1, to: now)
        case .week: return calendar.date(byAdding: .day, value: -7, to: now)
        case .month: return calendar.date(byAdding: .month, value: -1, to: now)
        case .quarter: return calendar.date(byAdding: .month, value: -3, to: now)
        case .year: return calendar.date(byAdding: .year, value: -1, to: now)
        }
    }
}

/// Filter and organize selection for Agent History. Held as one value so the
/// trigger can show a single "modified" state and Reset is unambiguous.
struct AgentHistoryFilterState: Equatable, Sendable {
    var agent: SupportedAgent?
    var directory: AgentHistoryDirectoryFilter = .any
    var time: AgentHistoryTimeFilter = .quarter
    var grouping: AgentHistoryGroupingMode = .none
    var ordering: AgentHistoryOrderingMode = .recentlyUpdated

    static let initial = Self()

    var isDefault: Bool { self == Self.initial }
    var narrowsSessions: Bool { agent != nil || directory != .any || time != .any }

    mutating func reset() { self = Self.initial }

    /// Directories match on the resolved path so a session started in a
    /// subfolder of the current one still counts as "this project".
    func includes(
        _ session: AgentHistorySession,
        currentDirectory: String?,
        now: Date = Date()
    ) -> Bool {
        includes(session, currentDirectory: currentDirectory, cutoff: time.cutoff(now: now))
    }

    func filtered(_ sessions: [AgentHistorySession], currentDirectory: String?, now: Date = Date()) -> [AgentHistorySession] {
        let cutoff = time.cutoff(now: now)
        return sessions.filter { includes($0, currentDirectory: currentDirectory, cutoff: cutoff) }
    }

    private func includes(_ session: AgentHistorySession, currentDirectory: String?, cutoff: Date?) -> Bool {
        if let agent, session.agent != agent { return false }
        if directory == .currentTree {
            guard let root = Self.normalizedPath(currentDirectory),
                  let value = Self.normalizedPath(session.workingDirectory) else {
                return false
            }
            let prefix = root == "/" ? "/" : root + "/"
            guard value == root || value.hasPrefix(prefix) else { return false }
        }
        if let cutoff, session.updatedAt < cutoff { return false }
        return true
    }

    static func normalizedPath(_ value: String?) -> String? {
        guard let value, value.hasPrefix("/"), !value.contains("\0") else { return nil }
        var path = value
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

private struct InspectorAgentHistoryView: View {
    let history: InspectorAgentHistoryContent
    /// Working directory of the presented pane, used by the folder filter.
    let currentDirectory: String?
    let perform: (InspectorPaneActionKind) -> Void
    @ObservedObject private var settings = OhMyGhosttySettings.shared
    @State private var visibleSessionCount = 60
    @State private var visibleMessageCount = 30
    @State private var query = ""
    @State private var committedQuery = ""
    @State private var searchMatches: [String: String] = [:]
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var filter = AgentHistoryFilterState()
    @State private var collapsedGroupIDs: Set<String> = []
    @State private var transcriptSearch = ""
    @State private var isTranscriptSearchVisible = false
    @State private var transcriptSearchFocusRequestID = 0

    private var strings: AgentHistoryStrings {
        .init(language: settings.language)
    }

    /// Sessions inside the selected folder/time scope, before the Agent filter.
    /// Agent counts in the popover come from this list so they stay meaningful.
    private var scopedSessions: [AgentHistorySession] {
        var scope = filter
        scope.agent = nil
        return scope.filtered(history.sessions, currentDirectory: currentDirectory)
    }

    private var availableAgents: [SupportedAgent] {
        let present = Set(scopedSessions.map(\.agent))
        return SupportedAgent.allCases.filter { present.contains($0) }
    }

    private var filteredAndOrderedSessions: [AgentHistorySession] {
        let needle = committedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = scopedSessions.filter { session in
            guard filter.agent == nil || session.agent == filter.agent else {
                return false
            }
            return needle.isEmpty || searchMatches[session.id] != nil
        }
        switch filter.ordering {
        case .recentlyUpdated:
            // Store snapshots are already newest-first. Preserve that order to
            // avoid sorting thousands of rows on every SwiftUI body update.
            return matching
        case .title:
            return matching.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
    }

    private struct GroupedSection: Identifiable {
        let id: String
        let title: String
        let icon: GhosttyTabIcon
        let sessions: [AgentHistorySession]
    }

    private var groupedSections: [GroupedSection] {
        let list = filteredAndOrderedSessions
        switch filter.grouping {
        case .none:
            return [.init(id: "all", title: "", icon: .systemSymbol("folder"), sessions: list)]
        case .project:
            var buckets: [String: (title: String, icon: GhosttyTabIcon, sessions: [AgentHistorySession])] = [:]
            for session in list {
                let key = session.workingDirectory ?? "Other"
                let title = WorkspacePathPresentation.folderName(key)
                if buckets[key] == nil {
                    buckets[key] = (title: title.isEmpty ? key : title, icon: .systemSymbol("folder"), sessions: [])
                }
                buckets[key]?.sessions.append(session)
            }
            return buckets.map { key, value in
                GroupedSection(id: key, title: value.title, icon: value.icon, sessions: value.sessions)
            }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .agent:
            var buckets: [SupportedAgent: [AgentHistorySession]] = [:]
            for session in list {
                buckets[session.agent, default: []].append(session)
            }
            return buckets.map { agent, sessions in
                GroupedSection(
                    id: agent.rawValue,
                    title: agent.displayName,
                    icon: .systemSymbol("terminal"),
                    sessions: sessions
                )
            }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .date:
            let calendar = Calendar.current
            var buckets: [String: (title: String, sessions: [AgentHistorySession])] = [:]
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            for session in list {
                let key: String
                let title: String
                if calendar.isDateInToday(session.updatedAt) {
                    key = "1_today"
                    title = strings.today
                } else if calendar.isDateInYesterday(session.updatedAt) {
                    key = "2_yesterday"
                    title = strings.yesterday
                } else {
                    key = "3_" + formatter.string(from: session.updatedAt)
                    title = formatter.string(from: session.updatedAt)
                }
                if buckets[key] == nil {
                    buckets[key] = (title: title, sessions: [])
                }
                buckets[key]?.sessions.append(session)
            }
            return buckets.sorted { $0.key < $1.key }.map { key, value in
                GroupedSection(id: key, title: value.title, icon: .systemSymbol("calendar"), sessions: value.sessions)
            }
        }
    }

    private var selectedSession: AgentHistorySession? {
        guard let id = history.selectedSessionID else { return nil }
        return history.sessions.first { $0.id == id }
    }

    var body: some View {
        if let session = selectedSession {
            transcriptView(session)
        } else {
            sessionList
        }
    }

    private var sessionList: some View {
        VStack(spacing: 0) {
            AgentHistorySessionListHeader(
                title: history.hostLabel.map {
                    strings.remoteSessionCount(filteredAndOrderedSessions.count, host: $0)
                } ?? strings.sessionCount(filteredAndOrderedSessions.count),
                isRemote: history.hostLabel != nil,
                isLoading: history.isLoadingSessions,
                strings: strings,
                refresh: { perform(.refreshAgentHistory) }
            )
            .frame(height: 40)
            .padding(.horizontal, InspectorContentMetrics.leadingInset)

            AgentHistoryToolbar(
                query: query,
                isSearching: isSearching,
                filter: filter,
                sessions: scopedSessions,
                agents: availableAgents,
                strings: strings,
                currentDirectory: currentDirectory,
                searchChanged: { query = $0 },
                filterChanged: {
                    filter = $0
                    perform(.setAgentHistoryTimeRange($0.time))
                }
            )
            .frame(height: 28)
            .padding(.horizontal, InspectorContentMetrics.leadingInset)
            .padding(.bottom, 8)

            if history.isLoadingSessions && history.sessions.isEmpty {
                AgentHistoryEmptyView(
                    systemImage: "clock.arrow.circlepath",
                    title: strings.loading,
                    message: nil,
                    showsProgress: true
                )
            } else if history.sessions.isEmpty {
                AgentHistoryEmptyView(
                    systemImage: "clock.badge.questionmark",
                    title: strings.noSessions,
                    message: strings.noSessionsMessage
                )
            } else if filteredAndOrderedSessions.isEmpty, isSearching {
                AgentHistoryEmptyView(
                    systemImage: "magnifyingglass",
                    title: strings.searchingSessions,
                    message: strings.searchingSessionsMessage,
                    showsProgress: true
                )
            } else if filteredAndOrderedSessions.isEmpty {
                AgentHistoryEmptyView(
                    systemImage: "magnifyingglass",
                    title: strings.noMatches,
                    message: strings.noMatchesMessage
                )
            } else {
                InspectorAgentHistoryList(
                    rows: nativeSessionRows,
                    query: committedQuery.trimmingCharacters(in: .whitespacesAndNewlines),
                    strings: strings,
                    select: selectSession,
                    toggleGroup: { id in
                        if collapsedGroupIDs.contains(id) {
                            collapsedGroupIDs.remove(id)
                        } else {
                            collapsedGroupIDs.insert(id)
                        }
                    },
                    loadMore: { visibleSessionCount += 60 },
                    perform: perform
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            perform(.setAgentHistoryTimeRange(filter.time))
            scheduleSessionSearch(query, immediately: true)
        }
        .onChange(of: history.hostLabel) { _ in perform(.setAgentHistoryTimeRange(filter.time)) }
        .onChange(of: query) { value in
            visibleSessionCount = 60
            scheduleSessionSearch(value)
        }
        .onChange(of: history.sessions.count) { _ in
            scheduleSessionSearch(query, immediately: true)
        }
        .onChange(of: filter) { _ in
            visibleSessionCount = 60
            scheduleSessionSearch(query, immediately: true)
        }
        .onDisappear { searchTask?.cancel() }
    }

    private var nativeSessionRows: [InspectorAgentHistoryListRow] {
        let needle = committedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        func row(_ session: AgentHistorySession) -> InspectorAgentHistoryListRow {
            let snippet = searchMatches[session.id]
            return .session(session, snippet: !needle.isEmpty && snippet != session.title ? snippet : nil)
        }
        if filter.grouping == .none {
            let sessions = filteredAndOrderedSessions
            var rows = sessions.prefix(visibleSessionCount).map(row)
            if visibleSessionCount < sessions.count {
                rows.append(.more(remaining: sessions.count - visibleSessionCount))
            }
            return rows
        }
        return groupedSections.flatMap { section in
            let collapsed = collapsedGroupIDs.contains(section.id)
            var rows: [InspectorAgentHistoryListRow] = [
                .group(id: section.id, title: section.title, count: section.sessions.count, collapsed: collapsed),
            ]
            if !collapsed { rows.append(contentsOf: section.sessions.map(row)) }
            return rows
        }
    }

    private func selectSession(_ session: AgentHistorySession) {
        let needle = committedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        visibleMessageCount = 30
        transcriptSearch = needle
        isTranscriptSearchVisible = !needle.isEmpty
        if !needle.isEmpty { transcriptSearchFocusRequestID &+= 1 }
        perform(.selectAgentHistorySession(id: session.id))
    }

    private func toggleTranscriptSearch() {
        isTranscriptSearchVisible.toggle()
        if isTranscriptSearchVisible {
            transcriptSearchFocusRequestID &+= 1
        } else {
            transcriptSearch = ""
        }
    }

    private func closeTranscriptSearch() {
        isTranscriptSearchVisible = false
        transcriptSearch = ""
    }

    private func scheduleSessionSearch(
        _ value: String,
        immediately: Bool = false
    ) {
        searchTask?.cancel()
        let needle = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            committedQuery = ""
            searchMatches = [:]
            isSearching = false
            return
        }
        let sessions = filter.filtered(history.sessions, currentDirectory: currentDirectory)
        isSearching = true
        searchTask = Task {
            if !immediately {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled else { return }
            committedQuery = needle
            searchMatches = [:]
            for await matches in AgentHistoryStore.searchUpdates(
                sessions: sessions,
                query: needle
            ) {
                guard !Task.isCancelled else { return }
                searchMatches = matches
            }
            guard !Task.isCancelled else { return }
            isSearching = false
            searchTask = nil
        }
    }

    private func transcriptMessages(
        _ messages: [AgentHistoryMessage],
        aroundMatchesFor query: String
    ) -> [AgentHistoryMessage] {
        guard !query.isEmpty else { return messages }
        var indexes = Set<Int>()
        for index in messages.indices where
            messages[index].text.range(
                of: query,
                options: .caseInsensitive
            ) != nil {
            for nearby in max(messages.startIndex, index - 1)...min(
                messages.index(before: messages.endIndex),
                index + 1
            ) {
                indexes.insert(nearby)
            }
        }
        return indexes.sorted().map { messages[$0] }
    }

    private func transcriptView(_ session: AgentHistorySession) -> some View {
        let needle = transcriptSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allMessages = history.transcript?.sessionID == session.id
            ? (history.transcript?.messages ?? [])
            : []
        let matchCount = needle.isEmpty ? 0 : allMessages.count {
            $0.text.range(of: needle, options: .caseInsensitive) != nil
        }
        let matchingMessages = transcriptMessages(
            allMessages,
            aroundMatchesFor: needle
        )

        return VStack(spacing: 0) {
            AgentHistoryTranscriptToolbar(
                session: session,
                strings: strings,
                query: transcriptSearch,
                isSearchVisible: isTranscriptSearchVisible,
                focusRequestID: transcriptSearchFocusRequestID,
                matchCount: matchCount,
                onQueryChange: { transcriptSearch = $0 },
                onToggleSearch: toggleTranscriptSearch,
                onEscape: closeTranscriptSearch,
                onBack: {
                    closeTranscriptSearch()
                    perform(.clearAgentHistorySelection)
                },
                onResume: { perform(.resumeAgentHistorySession(id: session.id)) }
            )
            .frame(height: isTranscriptSearchVisible ? 72 : 38)

            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                    .font(.system(size: 13, weight: .semibold))
                    .textSelection(.enabled)
                if let workingDirectory = session.workingDirectory {
                    Text(workingDirectory)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(workingDirectory)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, InspectorContentMetrics.leadingInset)
            .padding(.bottom, 9)

            Divider()

            if history.isLoadingTranscript {
                AgentHistoryEmptyView(
                    systemImage: "text.bubble",
                    title: strings.loadingTranscript,
                    message: nil,
                    showsProgress: true
                )
            } else if let transcript = history.transcript,
                      transcript.sessionID == session.id,
                      transcript.messages.isEmpty {
                AgentHistoryEmptyView(
                    systemImage: "text.bubble",
                    title: strings.emptyTranscript,
                    message: strings.emptyTranscriptMessage
                )
            } else if matchingMessages.isEmpty, !needle.isEmpty {
                AgentHistoryEmptyView(
                    systemImage: "magnifyingglass",
                    title: strings.noMatches,
                    message: strings.noMatchesMessage
                )
            } else if let transcript = history.transcript,
                      transcript.sessionID == session.id {
                let displayedMessages = needle.isEmpty
                    ? Array(matchingMessages.prefix(visibleMessageCount))
                    : matchingMessages

                VStack(spacing: 0) {
                    AgentHistoryTranscriptTable(
                        messages: displayedMessages,
                        agentName: session.agent.displayName,
                        strings: strings,
                        highlightText: needle,
                        onFork: {
                            perform(.forkAgentHistorySession(id: session.id))
                        },
                        onFind: toggleTranscriptSearch
                    )

                    if needle.isEmpty && visibleMessageCount < matchingMessages.count {
                        Divider()
                        NativeActionButton(
                            title: strings.loadMoreMessages(matchingMessages.count - visibleMessageCount),
                            symbol: "arrow.down.circle",
                            expands: true
                        ) { _ in
                            visibleMessageCount += 50
                        }
                    }

                    if transcript.wasTruncated && needle.isEmpty {
                        Text(strings.truncated)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, InspectorContentMetrics.leadingInset)
                            .padding(.vertical, 6)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct AgentHistoryEmptyView: View {
    let systemImage: String
    let title: String
    let message: String?
    var showsProgress = false

    var body: some View {
        VStack(spacing: 8) {
            if showsProgress {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 25))
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.headline)
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct InspectorInfoView: View {
    let info: InspectorInfoContent
    let dividerColor: Color
    let perform: (InspectorPaneActionKind) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if info.status != nil || !info.fields.isEmpty {
                if let status = info.status {
                    HStack(spacing: 8) {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(.green)
                        Text(status.label)
                        Spacer()
                        Text(status.value)
                            .foregroundStyle(.secondary)
                    }
                    .padding(InspectorContentMetrics.leadingInset)
                }

                if !info.fields.isEmpty {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        ForEach(info.fields) { field in
                            GridRow {
                                Text(field.label)
                                    .foregroundStyle(.secondary)
                                Text(field.value)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(InspectorContentMetrics.leadingInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Rectangle()
                    .fill(dividerColor)
                    .frame(height: TerminalShellStyle.dividerWidth)
            }

            if !info.portForwards.hostAlias.isEmpty {
                InspectorPortForwardListView(forwards: info.portForwards, perform: perform)
                    .frame(height: InfoHistoryLayout.portHeight(count: info.portForwards.items.count))
                Rectangle().fill(dividerColor).frame(height: TerminalShellStyle.dividerWidth)
            }

            InspectorTerminalHistoryListView(
                items: info.historyItems.filter { $0.kind == .command },
                isAgent: false,
                agentName: nil,
                state: .ready,
                perform: perform
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

enum InfoHistoryLayout {
    static func portHeight(count: Int) -> CGFloat {
        count == 0 ? 64 : min(180, 54 + CGFloat(count) * 38)
    }
}

private struct InspectorTerminalHistoryListView: View {
    let items: [InspectorHistoryItem]
    let isAgent: Bool
    let agentName: String?
    let state: PaneAgentHistoryService.State
    let perform: (InspectorPaneActionKind) -> Void
    @ObservedObject private var settings = OhMyGhosttySettings.shared

    private var strings: InfoStrings { .init(language: settings.language) }
    private var statusMessage: String? {
        switch state {
        case .loading: strings.historyLoading
        case .unavailable: strings.historyUnavailable
        case .limited: strings.historyLimited
        case .ready: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: isAgent ? "sparkles" : "terminal").foregroundStyle(.secondary)
                Text(isAgent ? (agentName ?? strings.agentPromptsTitle) : strings.historyTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(String(items.count)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)

            if isAgent && !items.isEmpty {
                Text(strings.noTerminalAnchor)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            }
            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            }
            if items.isEmpty {
                if state == .ready {
                    Text(isAgent ? strings.noAgentPromptsMessage : strings.noHistoryMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
                Spacer(minLength: 0)
            } else {
                TerminalHistoryTable(items: items) { perform(.jumpToHistoryItem($0)) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct InspectorPortForwardListView: View {
    private static let targetColumnWidth: CGFloat = 96
    private static let actionColumnWidth: CGFloat = 64

    let forwards: InspectorPortForwardList
    let perform: (InspectorPaneActionKind) -> Void
    @ObservedObject private var settings = OhMyGhosttySettings.shared
    @State private var isAdding = false
    @State private var targetValue = ""
    @State private var hoveredID: String?

    private var strings: InfoStrings {
        .init(language: settings.language)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
                Text(strings.portsTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .help(forwards.hostAlias)
                Text(String(forwardedCount))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button {
                    targetValue = ""
                    isAdding = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .onHover { inside in
                    (inside ? NSCursor.pointingHand : NSCursor.arrow).set()
                }
                .disabled(!forwards.canCreate)
                .help(forwards.canCreate ? strings.forwardAPort : strings.identityUnavailable())
                .accessibilityLabel(strings.forwardAPort)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)

            if !forwards.items.isEmpty {
                HStack(spacing: 8) {
                    Color.clear.frame(width: 10, height: 1)
                    Text(strings.remoteTargetColumn)
                        .frame(width: Self.targetColumnWidth, alignment: .leading)
                    Text(strings.forwardedAddressColumn)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(width: Self.actionColumnWidth, height: 1)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, InspectorContentMetrics.leadingInset)
                .padding(.bottom, 5)
            }

            if forwards.items.isEmpty {
                Text(strings.noForwardedPorts)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(forwards.items) { item in
                            portRow(item)
                            Divider()
                                .padding(.leading, InspectorContentMetrics.leadingInset + 18)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $isAdding) {
            VStack(alignment: .leading, spacing: 16) {
                Text(strings.forwardAPort)
                    .font(.headline)
                Text(strings.targetHelp(alias: forwards.hostAlias))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField(strings.targetPlaceholder, text: $targetValue)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addForward)
                HStack {
                    Spacer()
                    Button(strings.cancel) { isAdding = false }
                    Button(strings.forward) { addForward() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(parsedTarget == nil)
                }
            }
            .padding(20)
            .frame(width: 380)
        }
    }

    private func portRow(_ item: InspectorPortForwardItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor(item.status))
                    .frame(width: 8, height: 8)
                    .frame(width: 10)
                Text(remoteTarget(item))
                    .monospacedDigit()
                    .frame(width: Self.targetColumnWidth, alignment: .leading)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(localAddress(item))
                    .monospacedDigit()
                    .foregroundStyle(item.status == .active ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                HStack(spacing: 2) {
                    InspectorHoverIconButton(
                        systemImage: "safari",
                        help: strings.openInBrowser,
                        enabled: item.status == .active
                    ) {
                        perform(.openPortForward(id: item.id))
                    }
                    InspectorHoverIconButton(
                        systemImage: "doc.on.doc",
                        help: strings.copyForwardedAddress,
                        enabled: item.status == .active
                    ) {
                        perform(.copyPortForward(id: item.id))
                    }
                    InspectorHoverIconButton(
                        systemImage: "xmark",
                        help: strings.stopForwarding
                    ) {
                        perform(.removePortForward(id: item.id))
                    }
                }
                .foregroundStyle(.secondary)
                .frame(width: Self.actionColumnWidth, alignment: .trailing)
                .opacity(hoveredID == item.id ? 1 : 0)
            }

            if let detail = detailTitle(item) {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(detailColor(item.status))
                    .lineLimit(2)
                    .padding(.leading, 18 + Self.targetColumnWidth + 8)
            }
        }
        .padding(.horizontal, InspectorContentMetrics.leadingInset)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onHover { hovered in
            hoveredID = hovered ? item.id : (hoveredID == item.id ? nil : hoveredID)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(strings.remotePortAccessibility(
            item.remotePort,
            detail: detailTitle(item) ?? localAddress(item)
        ))
    }

    private var forwardedCount: Int {
        forwards.items.count { $0.status == .active }
    }

    private var parsedTarget: PortForwardTarget? {
        PortForwardTarget.parse(targetValue)
    }

    private func addForward() {
        guard parsedTarget != nil else { return }
        perform(.createPortForward(target: targetValue))
        isAdding = false
    }

    private func remoteTarget(_ item: InspectorPortForwardItem) -> String {
        PortForwardTarget(
            host: item.remoteHost,
            port: item.remotePort
        ).displayValue
    }

    private func localAddress(_ item: InspectorPortForwardItem) -> String {
        item.localPort.map { "localhost:\($0)" } ?? "—"
    }

    private func detailTitle(_ item: InspectorPortForwardItem) -> String? {
        switch item.status {
        case .starting: strings.startingForward
        case .active: item.processName
        case .failed(let message): message
        }
    }

    private func statusColor(_ status: InspectorPortForwardStatus) -> Color {
        switch status {
        case .starting: .secondary
        case .active: .green
        case .failed: .red
        }
    }

    private func detailColor(_ status: InspectorPortForwardStatus) -> Color {
        if case .failed = status { return .red }
        return .secondary
    }
}

private struct InspectorHoverIconButton: View {
    let systemImage: String
    let help: String
    var enabled = true
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 16, height: 16)
                .padding(3)
                .background(
                    hovered && enabled ? Color.primary.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 4)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { inside in
            hovered = inside
            if enabled {
                (inside ? NSCursor.pointingHand : NSCursor.arrow).set()
            }
        }
        .onDisappear {
            if hovered { NSCursor.arrow.set() }
        }
        .help(help)
    }
}

private struct InspectorPluginOverflowMenu: View {
    let descriptors: [InspectorPaneDescriptor]
    let selectedID: String?
    let select: (String) -> Void
    @State private var hovered = false

    var body: some View {
        Menu {
            ForEach(descriptors) { descriptor in
                Toggle(isOn: Binding(
                    get: { selectedID == descriptor.id },
                    set: { enabled in if enabled { select(descriptor.id) } }
                )) {
                    Label(descriptor.title, systemImage: descriptor.systemImage)
                }
            }
        } label: {
            TerminalTitlebarControlLabel(
                systemName: "ellipsis",
                title: nil,
                hovered: hovered
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovered = $0 }
        .help("More Inspector Plugins")
        .accessibilityLabel("More Inspector Plugins")
    }
}

struct InspectorPluginContextHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, InspectorContentMetrics.leadingInset)
            .padding(.top, 10)
            .padding(.bottom, 6)
    }
}

private struct RightInspectorResizeHandle: View {
    let color: Color
    let background: Color
    let currentWidth: () -> CGFloat
    let resize: (CGFloat, Bool) -> Void

    var body: some View {
        TerminalResizeBoundary(
            edge: .leading,
            color: color,
            currentExtent: currentWidth,
            resize: resize,
            accessibilityLabel: "Resize Inspector"
        )
        .background(background)
    }
}
