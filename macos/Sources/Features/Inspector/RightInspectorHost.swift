import AppKit
import Combine
import SwiftUI

enum TerminalShellStyle {
    static let resizeHitWidth: CGFloat = 8
    static let dividerWidth: CGFloat = 1
    static let minimumTerminalWidth: CGFloat = 320
    static let resizeOverlap = resizeHitWidth - dividerWidth
    static let sidebarTransitionDuration = 0.18
    static let sidebarTransitionAnimation = Animation.easeOut(
        duration: sidebarTransitionDuration
    )

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

    @ViewBuilder
    var body: some View {
        switch edge {
        case .leading:
            ZStack(alignment: .leading) {
                TerminalSidebarDividerLine(color: color)
                interaction(direction: .trailing)
            }
            .frame(width: TerminalShellStyle.resizeHitWidth)
            .padding(.trailing, -TerminalShellStyle.resizeOverlap)

        case .trailing:
            ZStack(alignment: .trailing) {
                TerminalSidebarDividerLine(color: color)
                interaction(direction: .leading)
            }
            .frame(width: TerminalShellStyle.resizeHitWidth)
            .padding(.leading, -TerminalShellStyle.resizeOverlap)

        case .top:
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(color)
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
            direction: direction
        )
        .contentShape(Rectangle())
        .accessibilityLabel(accessibilityLabel)
    }
}

struct TerminalSidebarTransitionContainer<Content: View>: View {
    enum Edge {
        case left
        case right

        var alignment: Alignment { self == .left ? .leading : .trailing }
        func hiddenOffset(for width: CGFloat) -> CGFloat {
            self == .left ? -width : width
        }
    }

    let isVisible: Bool
    let width: CGFloat
    let edge: Edge
    let animationsEnabled: Bool
    let retainsContent: Bool
    let background: Color
    let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var occupiesSpace: Bool
    @State private var hasMounted: Bool
    @State private var revealProgress: CGFloat
    @State private var transitionTask: Task<Void, Never>?

    init(
        isVisible: Bool,
        width: CGFloat,
        edge: Edge,
        animationsEnabled: Bool,
        retainsContent: Bool = false,
        background: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.isVisible = isVisible
        self.width = width
        self.edge = edge
        self.animationsEnabled = animationsEnabled
        self.retainsContent = retainsContent
        self.background = background
        self.content = content()
        self._occupiesSpace = State(initialValue: isVisible)
        self._hasMounted = State(initialValue: isVisible)
        self._revealProgress = State(initialValue: isVisible ? 1 : 0)
    }

    var body: some View {
        ZStack(alignment: edge.alignment) {
            if occupiesSpace || (retainsContent && hasMounted) {
                content
                    .transaction { if retainsContent { $0.animation = nil } }
                    .frame(width: width, alignment: edge.alignment)
                    .offset(
                        x: (1 - revealProgress) * edge.hiddenOffset(for: width)
                    )
                    .opacity(occupiesSpace ? 1 : 0)
                    .allowsHitTesting(isVisible && revealProgress == 1)
                    .accessibilityHidden(!isVisible || revealProgress != 1)
            }
        }
        .frame(
            width: occupiesSpace ? width : 0,
            alignment: edge.alignment
        )
        .background(background)
        .clipped()
        .onAppear { synchronizeImmediately() }
        .onChange(of: isVisible) { visible in transition(to: visible) }
        .onChange(of: reduceMotion) { _ in synchronizeImmediately() }
        .onChange(of: animationsEnabled) { _ in synchronizeImmediately() }
        .onDisappear { transitionTask?.cancel() }
    }

    private func transition(to visible: Bool) {
        if visible { hasMounted = true }
        transitionTask?.cancel()
        transitionTask = nil
        guard !reduceMotion, animationsEnabled else {
            occupiesSpace = visible
            revealProgress = visible ? 1 : 0
            return
        }

        if visible {
            let needsMount = !occupiesSpace
            occupiesSpace = true
            if needsMount { revealProgress = 0 }
            transitionTask = Task { @MainActor in
                if needsMount { await Task.yield() }
                guard !Task.isCancelled else { return }
                withAnimation(TerminalShellStyle.sidebarTransitionAnimation) {
                    revealProgress = 1
                }
            }
        } else {
            withAnimation(TerminalShellStyle.sidebarTransitionAnimation) {
                revealProgress = 0
            }
            transitionTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(
                    TerminalShellStyle.sidebarTransitionDuration
                ))
                guard !Task.isCancelled else { return }
                occupiesSpace = false
            }
        }
    }

    private func synchronizeImmediately() {
        transitionTask?.cancel()
        transitionTask = nil
        occupiesSpace = isVisible
        if isVisible { hasMounted = true }
        revealProgress = isVisible ? 1 : 0
    }
}

final class InspectorTitlebarPresentation: ObservableObject {
    @Published private(set) var width = TerminalTitlebarMetrics.inspectorCollapsedWidth
    @Published private(set) var isVisible = false

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
            let targetWidth = isVisible
                ? presentedWidth
                : TerminalTitlebarMetrics.inspectorCollapsedWidth
            self.inspectorCollapseWorkItem?.cancel()
            self.inspectorCollapseWorkItem = nil
            if isVisible {
                // Expand the AppKit accessory before revealing Plugin controls.
                // The next-turn reveal then animates with the content pane rather
                // than appearing in the old collapsed frame first.
                self.applyInspectorAccessoryWidth(
                    targetWidth,
                    controller: controller
                )
                guard !self.inspectorTitlebarPresentation.isVisible else { return }
                let workItem = DispatchWorkItem { [weak self, weak controller] in
                    guard let self, let controller,
                          controller.tabLayoutState.isInspectorVisible else { return }
                    self.inspectorCollapseWorkItem = nil
                    self.inspectorTitlebarPresentation.setVisible(true)
                }
                self.inspectorCollapseWorkItem = workItem
                DispatchQueue.main.async(execute: workItem)
            } else {
                // Animate Plugin controls out with the pane, then contract the
                // accessory only after the shared transition duration.
                self.inspectorTitlebarPresentation.setVisible(false)
                let workItem = DispatchWorkItem { [weak self, weak controller] in
                    guard let self, let controller,
                          !controller.tabLayoutState.isInspectorVisible else { return }
                    self.inspectorCollapseWorkItem = nil
                    self.applyInspectorAccessoryWidth(
                        targetWidth,
                        controller: controller
                    )
                }
                self.inspectorCollapseWorkItem = workItem
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + TerminalShellStyle.sidebarTransitionDuration,
                    execute: workItem
                )
            }
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
        let descriptors = inspectorVisible
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
            if inspectorVisible {
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
                .transition(.opacity.combined(with: .offset(x: 6, y: 0)))
            } else {
                Spacer(minLength: 0)
            }

            TerminalTitlebarIconButton(
                systemName: "sidebar.right",
                help: inspectorVisible ? "Hide Inspector" : "Show Inspector",
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
        .animation(
            TerminalShellStyle.sidebarTransitionAnimation,
            value: inspectorVisible
        )
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
        GeometryReader { geometry in
            let selectedPresentation = controller.selectedTabID == ObjectIdentifier(controller)
            let leftVisible = showsTabSidebar && layoutState.isSidebarVisible
            let leftWidth = presentedSidebarWidth + TerminalShellStyle.dividerWidth
            let inspectorWidth = presentedInspectorWidth(totalWidth: geometry.size.width)
            let rightVisible = layoutState.isInspectorVisible && !inspectorRegistry.isEmpty
            let rightWidth = inspectorWidth + TerminalShellStyle.dividerWidth

            HStack(spacing: 0) {
                TerminalSidebarTransitionContainer(
                    isVisible: leftVisible,
                    width: leftWidth,
                    edge: .left,
                    animationsEnabled: selectedPresentation,
                    background: chromeBackground
                ) {
                    HStack(spacing: 0) {
                        TerminalTabSidebarView(
                            controller: controller,
                            layoutState: layoutState,
                            statusStore: statusStore,
                            backgroundColor: backgroundColor,
                            backgroundOpacity: 0
                        )
                        .frame(width: presentedSidebarWidth)
                        VerticalTabSidebarDivider(
                            controller: controller,
                            layoutState: layoutState,
                            color: controller.sidebarDividerColor,
                            background: .clear
                        )
                    }
                }

                AgentQuickInputDock(
                    controller: controller,
                    model: controller.quickInputModel,
                    backgroundColor: backgroundColor,
                    backgroundOpacity: backgroundOpacity
                ) {
                    content
                }

                TerminalSidebarTransitionContainer(
                    isVisible: rightVisible,
                    width: rightWidth,
                    edge: .right,
                    animationsEnabled: selectedPresentation,
                    retainsContent: true,
                    background: chromeBackground
                ) {
                    HStack(spacing: 0) {
                        RightInspectorResizeHandle(
                            color: controller.sidebarDividerColor,
                            background: .clear,
                            currentWidth: { layoutState.inspectorWidth },
                            resize: controller.updateInspectorWidth
                        )
                        // The 8pt resize hit target overlaps Inspector content.
                        // Keep it above native scroll/table views so they cannot
                        // steal the initial mouseDown at the divider boundary.
                        .zIndex(10)
                        RightInspectorHost(
                            controller: controller,
                            layoutState: layoutState,
                            registry: inspectorRegistry,
                            isPresented: rightVisible,
                            backgroundColor: backgroundColor,
                            backgroundOpacity: 0
                        )
                        .frame(width: inspectorWidth)
                    }
                }
            }
        }
    }

    private var presentedSidebarWidth: CGFloat {
        controller.selectedTabID == ObjectIdentifier(controller)
            ? layoutState.sidebarWidth
            : layoutState.committedSidebarWidth
    }

    private func presentedInspectorWidth(totalWidth: CGFloat) -> CGFloat {
        let preferred = controller.selectedTabID == ObjectIdentifier(controller)
            ? layoutState.inspectorWidth
            : layoutState.committedInspectorWidth
        let leadingWidth = showsTabSidebar
            ? presentedSidebarWidth + TerminalShellStyle.dividerWidth
            : 0
        return TerminalShellStyle.presentedInspectorWidth(
            preferred: preferred,
            totalWidth: totalWidth,
            leadingWidth: leadingWidth
        )
    }
}

struct RightInspectorHost: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var layoutState: VerticalTabWindowLayoutState
    @ObservedObject var registry: InspectorRegistry
    var isPresented = true
    let backgroundColor: Color
    let backgroundOpacity: Double
    @State private var contextRevision: UInt64 = 0

    private var context: InspectorPaneContext {
        _ = contextRevision
        let surface = controller.focusedSurface ?? controller.surfaceTree.first
        let session = controller.paneSessionContext(for: surface) ?? .init(
            workingDirectory: surface?.pwd,
            terminalTitle: surface?.title ?? "Terminal"
        )
        return .init(
            tabID: controller.tabSessionID,
            surfaceID: surface?.id,
            title: controller.titleOverride ?? session.presentationTitle,
            workingDirectory: session.workingDirectory,
            workspace: session.workspace,
            session: session
        )
    }

    private var contextChanges: AnyPublisher<Void, Never> {
        guard let surface = controller.focusedSurface ?? controller.surfaceTree.first else {
            return Empty().eraseToAnyPublisher()
        }
        let metadata: AnyPublisher<Void, Never>
        if selectedPaneID == BuiltInGitInspectorProvider.paneID {
            metadata = surface.$pwd.removeDuplicates().dropFirst()
                .map { _ in () }.eraseToAnyPublisher()
        } else {
            metadata = Publishers.CombineLatest(surface.$pwd, surface.$title)
                .dropFirst().map { _ in () }.eraseToAnyPublisher()
        }
        let session = surface.$contextSignal
            .dropFirst()
            .map { _ in () }
        return Publishers.Merge(metadata, session).eraseToAnyPublisher()
    }

    private var selectedPaneID: String? {
        let paneID = layoutState.selectedInspectorPaneID
        if let paneID, registry.descriptor(id: paneID) != nil { return paneID }
        return registry.entries.first?.id
    }

    private var presentedPaneID: String? { isPresented ? selectedPaneID : nil }

    var body: some View {
        Group {
            if let paneID = selectedPaneID,
               let content = registry.content(for: paneID, context: context) {
                InspectorPaneDeck(paneID: paneID, tabID: context.tabID,
                    availableIDs: Set(registry.entries.map(\.id)),
                    content: AnyView(InspectorPaneContentView(
                        content: content,
                        paneID: paneID,
                        context: context,
                        dividerColor: controller.sidebarDividerColor,
                        registry: registry
                    )), updatesEnabled: isPresented)
            }
        }
        .background(backgroundColor.opacity(backgroundOpacity))
        .environment(\.gitCollectionColors, GitCollectionColors(config: controller.ghostty.config, background: NSColor(backgroundColor)))
        .onAppear {
            reconcileSelection()
            registry.presentationDidChange(to: presentedPaneID, context: context)
        }
        .onChange(of: registry.entries.map(\.id)) { _ in
            reconcileSelection()
            registry.presentationDidChange(to: presentedPaneID, context: context)
        }
        .onChange(of: layoutState.selectedInspectorPaneID) { _ in
            registry.presentationDidChange(to: presentedPaneID, context: context)
        }
        .onChange(of: isPresented) { _ in
            registry.presentationDidChange(to: presentedPaneID, context: context)
        }
        .onReceive(contextChanges) { _ in
            guard isPresented else { return }
            // @Published emits before its property storage is updated. Defer
            // one main-queue turn so the Inspector context reads the committed
            // Surface cwd/title, then notify the provider directly rather than
            // relying only on a SwiftUI body diff.
            DispatchQueue.main.async {
                contextRevision &+= 1
                registry.presentationDidChange(
                    to: presentedPaneID,
                    context: context
                )
            }
        }
        .onChange(of: context) { nextContext in
            registry.presentationDidChange(to: presentedPaneID, context: nextContext)
        }
        .onDisappear {
            registry.presentationDidChange(to: nil, context: context)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector")
    }

    private func reconcileSelection() {
        if selectedPaneID != layoutState.selectedInspectorPaneID {
            layoutState.selectInspectorPane(selectedPaneID)
        }
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

private struct InspectorAgentHistoryView: View {
    let history: InspectorAgentHistoryContent
    let perform: (InspectorPaneActionKind) -> Void
    @ObservedObject private var settings = OhMyGhosttySettings.shared
    @State private var visibleSessionCount = 60
    @State private var visibleMessageCount = 30
    @State private var query = ""
    @State private var committedQuery = ""
    @State private var searchMatches: [String: String] = [:]
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var selectedAgent: SupportedAgent?
    @State private var groupingMode: AgentHistoryGroupingMode = .none
    @State private var orderingMode: AgentHistoryOrderingMode = .recentlyUpdated
    @State private var collapsedGroupIDs: Set<String> = []
    @State private var transcriptSearch = ""
    @State private var isTranscriptSearchVisible = false
    @FocusState private var isTranscriptSearchFocused: Bool

    private var strings: AgentHistoryStrings {
        .init(language: settings.language)
    }

    private var availableAgents: [SupportedAgent] {
        SupportedAgent.allCases.filter { agent in
            history.sessions.contains { $0.agent == agent }
        }
    }

    private var filteredAndOrderedSessions: [AgentHistorySession] {
        let needle = committedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = history.sessions.filter { session in
            guard selectedAgent == nil || session.agent == selectedAgent else {
                return false
            }
            return needle.isEmpty || searchMatches[session.id] != nil
        }
        switch orderingMode {
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
        switch groupingMode {
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
            HStack(spacing: 8) {
                Image(systemName: history.hostLabel == nil ? "clock.arrow.circlepath" : "cloud")
                    .foregroundStyle(.secondary)
                if let host = history.hostLabel {
                    Text(strings.remoteSessionCount(filteredAndOrderedSessions.count, host: host))
                        .font(.headline)
                        .lineLimit(1)
                } else {
                    Text(strings.sessionCount(filteredAndOrderedSessions.count))
                        .font(.headline)
                }
                Spacer(minLength: 8)
                Button {
                    perform(.refreshAgentHistory)
                } label: {
                    if history.isLoadingSessions {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(history.isLoadingSessions)
                .help(strings.refresh)
                .accessibilityLabel(strings.refresh)
            }
            .padding(.horizontal, InspectorContentMetrics.leadingInset)
            .padding(.vertical, 10)

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(strings.searchPlaceholder, text: $query)
                        .textFieldStyle(.plain)
                        .foregroundStyle(.primary)
                    if isSearching {
                        ProgressView().controlSize(.mini)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(
                    Color.primary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.18), lineWidth: 1)
                }

                filterAndOrganizeMenu
            }
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
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if groupingMode == .none {
                            let total = filteredAndOrderedSessions.count
                            let displayed = Array(filteredAndOrderedSessions.prefix(visibleSessionCount))
                            ForEach(displayed) { session in
                                sessionRow(
                                    session,
                                    matchSnippet: searchMatches[session.id]
                                )
                                Divider().padding(.leading, 44)
                            }
                            if visibleSessionCount < total {
                                HStack {
                                    Spacer()
                                    Button {
                                        visibleSessionCount += 60
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "arrow.down.circle")
                                            Text(strings.loadMoreSessions(total - visibleSessionCount))
                                        }
                                        .font(.caption)
                                        .padding(.vertical, 8)
                                    }
                                    .buttonStyle(.borderless)
                                    Spacer()
                                }
                                .padding(.vertical, 6)
                                .onAppear {
                                    visibleSessionCount += 60
                                }
                            }
                        } else {
                            ForEach(groupedSections) { section in
                                sectionHeader(section)
                                if !collapsedGroupIDs.contains(section.id) {
                                    ForEach(section.sessions) { session in
                                        sessionRow(
                                            session,
                                            matchSnippet: searchMatches[session.id]
                                        )
                                        Divider().padding(.leading, 44)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { scheduleSessionSearch(query, immediately: true) }
        .onChange(of: query) { value in
            visibleSessionCount = 60
            scheduleSessionSearch(value)
        }
        .onChange(of: history.sessions.count) { _ in
            scheduleSessionSearch(query, immediately: true)
        }
        .onDisappear { searchTask?.cancel() }
    }

    private var filterAndOrganizeMenu: some View {
        Menu {
            Section(strings.filterAgentSection) {
                Button {
                    selectedAgent = nil
                } label: {
                    menuRow(
                        "\(strings.allAgents) (\(history.sessions.count))",
                        selected: selectedAgent == nil
                    )
                }
                ForEach(availableAgents) { agent in
                    Button {
                        selectedAgent = agent
                    } label: {
                        let count = history.sessions.count { $0.agent == agent }
                        menuRow(
                            "\(agent.displayName) (\(count))",
                            selected: selectedAgent == agent
                        )
                    }
                }
            }

            Section(strings.groupSection) {
                Button {
                    groupingMode = .none
                } label: {
                    menuRow(strings.groupNone, selected: groupingMode == .none)
                }
                Button {
                    groupingMode = .project
                } label: {
                    menuRow(strings.groupProject, selected: groupingMode == .project)
                }
                Button {
                    groupingMode = .agent
                } label: {
                    menuRow(strings.groupAgent, selected: groupingMode == .agent)
                }
                Button {
                    groupingMode = .date
                } label: {
                    menuRow(strings.groupDate, selected: groupingMode == .date)
                }
            }

            Section(strings.orderSection) {
                Button {
                    orderingMode = .recentlyUpdated
                } label: {
                    menuRow(strings.orderRecentlyUpdated, selected: orderingMode == .recentlyUpdated)
                }
                Button {
                    orderingMode = .title
                } label: {
                    menuRow(strings.orderTitle, selected: orderingMode == .title)
                }
            }
        } label: {
            HStack(spacing: 4) {
                if let selectedAgent {
                    Image(selectedAgent.assetName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .frame(width: 28, height: 28)
            .background(
                Color.primary.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.18), lineWidth: 1)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(strings.organize)
        .accessibilityLabel(strings.organize)
    }

    @ViewBuilder
    private func menuRow(_ text: String, selected: Bool) -> some View {
        if selected {
            Label(text, systemImage: "checkmark")
        } else {
            Text(text)
        }
    }

    private func sectionHeader(_ section: GroupedSection) -> some View {
        let isCollapsed = collapsedGroupIDs.contains(section.id)
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if isCollapsed {
                    collapsedGroupIDs.remove(section.id)
                } else {
                    collapsedGroupIDs.insert(section.id)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 10)
                Text(section.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(String(section.sessions.count))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, InspectorContentMetrics.leadingInset)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sessionRow(
        _ session: AgentHistorySession,
        matchSnippet: String?
    ) -> some View {
        let needle = committedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return Button {
            visibleMessageCount = 30
            transcriptSearch = needle
            isTranscriptSearchVisible = !needle.isEmpty
            perform(.selectAgentHistorySession(id: session.id))
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(session.agent.assetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(highlightedText(session.title, query: needle))
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 4)
                        if session.isActive {
                            Text(strings.live)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.green)
                        }
                    }
                    HStack(spacing: 5) {
                        Text(session.agent.displayName)
                        Text("·")
                        Text(strings.relativeTime(from: session.updatedAt))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if !needle.isEmpty,
                       let matchSnippet,
                       matchSnippet != session.title {
                        Text(highlightedText(matchSnippet, query: needle))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    } else if let workingDirectory = session.workingDirectory {
                        Text(workingDirectory)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 5)
            }
            .padding(.horizontal, InspectorContentMetrics.leadingInset)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(session.isActive ? strings.openLive : strings.resume) {
                perform(.resumeAgentHistorySession(id: session.id))
            }
            if session.remoteHost == nil {
                Button(strings.forkSession) {
                    perform(.forkAgentHistorySession(id: session.id))
                }
            }
        }
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
        let sessions = history.sessions
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

    private func highlightedText(
        _ text: String,
        query: String
    ) -> AttributedString {
        var result = AttributedString(text)
        guard !query.isEmpty else { return result }
        var searchRange = result.startIndex..<result.endIndex
        while let range = result[searchRange].range(
            of: query,
            options: .caseInsensitive
        ) {
            result[range].backgroundColor = Color.yellow.opacity(0.45)
            result[range].font = .system(size: 12.5, weight: .semibold)
            searchRange = range.upperBound..<result.endIndex
        }
        return result
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
            HStack(spacing: 8) {
                Button {
                    transcriptSearch = ""
                    isTranscriptSearchVisible = false
                    perform(.clearAgentHistorySelection)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help(strings.back)
                .accessibilityLabel(strings.back)

                Image(session.agent.assetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                Text(session.agent.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isTranscriptSearchVisible.toggle()
                        if isTranscriptSearchVisible {
                            isTranscriptSearchFocused = true
                        } else {
                            transcriptSearch = ""
                        }
                    }
                } label: {
                    Image(systemName: isTranscriptSearchVisible ? "magnifyingglass.circle.fill" : "magnifyingglass")
                        .font(.system(size: 13))
                }
                .buttonStyle(.borderless)
                .help("⌘F")

                Button(session.isActive ? strings.openLive : strings.resume) {
                    perform(.resumeAgentHistorySession(id: session.id))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, InspectorContentMetrics.leadingInset)
            .padding(.vertical, 9)

            if isTranscriptSearchVisible {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(strings.searchTranscriptPlaceholder, text: $transcriptSearch)
                        .textFieldStyle(.plain)
                        .focused($isTranscriptSearchFocused)
                    if !transcriptSearch.isEmpty {
                        Text("\(matchCount) \(strings.matchesCount)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Button {
                            transcriptSearch = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(
                    Color.primary.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .padding(.horizontal, InspectorContentMetrics.leadingInset)
                .padding(.bottom, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

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
                        }
                    )

                    if needle.isEmpty && visibleMessageCount < matchingMessages.count {
                        Divider()
                        Button {
                            visibleMessageCount += 50
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.down.circle")
                                Text(strings.loadMoreMessages(
                                    matchingMessages.count - visibleMessageCount
                                ))
                            }
                            .font(.caption)
                            .padding(.vertical, 7)
                        }
                        .buttonStyle(.borderless)
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
        .background(
            Button("") {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isTranscriptSearchVisible.toggle()
                    if isTranscriptSearchVisible {
                        isTranscriptSearchFocused = true
                    } else {
                        transcriptSearch = ""
                    }
                }
            }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
        )
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

private struct InspectorInfoView: View {
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

            InspectorPortForwardListView(
                forwards: info.portForwards,
                perform: perform
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                Text(forwards.hostAlias)
                    .font(.headline)
                    .lineLimit(1)
                Text(String(forwardedCount))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.18), in: Capsule())
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
                .help(strings.forwardAPort)
                .accessibilityLabel(strings.forwardAPort)
            }
            .padding(.horizontal, InspectorContentMetrics.leadingInset)
            .padding(.vertical, 10)

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
                VStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 25))
                        .foregroundStyle(.secondary)
                    Text(strings.noForwardedPorts)
                        .font(.headline)
                    Text(strings.noForwardedPortsMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

struct InspectorFileTreeView: View {
    let tree: InspectorFileTree
    let perform: (InspectorPaneActionKind) -> Void
    @State private var selectedNodeID: String?

    var body: some View {
        VStack(spacing: 0) {
            InspectorPluginContextHeader(title: tree.rootName)
                .help(tree.rootPath)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(tree.nodes) { node in
                        InspectorFileTreeNodeView(
                            node: node,
                            depth: 0,
                            selectedNodeID: $selectedNodeID,
                            perform: perform
                        )
                    }
                }
                .padding(.top, 2)
                .padding(.bottom, 4)
            }
        }
        .onChange(of: tree.rootPath) { _ in
            selectedNodeID = nil
        }
    }
}

private struct InspectorFileTreeNodeView: View {
    let node: InspectorFileNode
    let depth: Int
    @Binding var selectedNodeID: String?
    let perform: (InspectorPaneActionKind) -> Void
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                selectedNodeID = node.id
                guard node.isDirectory else { return }
                withAnimation(.easeInOut(duration: 0.16)) {
                    perform(.toggleNode(id: node.id, expanded: !node.isExpanded))
                }
            } label: {
                HStack(spacing: 6) {
                    Group {
                        if node.isDirectory {
                            Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: InspectorTreeLayout.disclosureWidth - 6, height: 14)

                    InspectorFileIconView(node: node)
                    Text(node.name)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if node.isLoading {
                        ProgressView().controlSize(.mini)
                    }
                }
                .padding(
                    .leading,
                    CGFloat(depth) * InspectorTreeLayout.indent + InspectorTreeLayout.leading
                )
                .padding(.trailing, 8)
                .frame(height: 27)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(
                            selectedNodeID == node.id ? 0.12 : hovered ? 0.07 : 0
                        ))
                )
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .help(node.id)
            .onTapGesture(count: 2) {
                selectedNodeID = node.id
                if node.isDirectory {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        perform(.toggleNode(id: node.id, expanded: !node.isExpanded))
                    }
                } else {
                    perform(.openFile(path: node.id))
                }
            }
            .contextMenu {
                Button("Copy Path") { perform(.copyFilePath(path: node.id, relative: false)) }
                Button("Copy Relative Path") { perform(.copyFilePath(path: node.id, relative: true)) }
                Button("Rename…") { perform(.renameFile(path: node.id)) }
                Button("Open in…") { perform(.openFileExternally(path: node.id)) }
                Divider()
                if !node.isDirectory {
                    Button("Open in Editor") {
                        selectedNodeID = node.id
                        perform(.openFile(path: node.id, destination: .currentPane))
                    }
                    Menu("Open to the Side") {
                        ForEach(EditorOpenDestination.allCases, id: \.rawValue) { destination in
                            Button(destination.title) {
                                selectedNodeID = node.id
                                perform(.openFile(path: node.id, destination: destination))
                            }
                        }
                    }
                }
            }

            if node.isExpanded, let children = node.children {
                VStack(spacing: 0) {
                    ForEach(children) { child in
                        InspectorFileTreeNodeView(
                            node: child,
                            depth: depth + 1,
                            selectedNodeID: $selectedNodeID,
                            perform: perform
                        )
                    }
                }
                .transition(.opacity)
                .clipped()
            }
        }
        .animation(.easeInOut(duration: 0.16), value: node.isExpanded)
        .animation(
            .easeInOut(duration: 0.16),
            value: node.children?.map(\.id) ?? []
        )
    }
}

private struct InspectorFileIconView: View {
    let node: InspectorFileNode
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let name = MaterialFileIcons.assetName(
                for: node.name,
                isDirectory: node.isDirectory,
                isExpanded: node.isExpanded,
                isLight: colorScheme == .light
            ), let image = NSImage(named: name) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: node.icon.systemImage)
                    .foregroundStyle(color)
            }
        }
        .frame(width: InspectorTreeLayout.iconWidth, height: InspectorTreeLayout.iconWidth)
    }

    private var color: Color {
        switch node.icon.tint {
        case .secondary: .secondary
        case .blue: .blue
        case .green: .green
        case .orange: .orange
        case .yellow: .yellow
        case .purple: .purple
        case .red: .red
        }
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
