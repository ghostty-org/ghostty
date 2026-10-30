import AppKit
import Combine
import SwiftUI

/// The native owner of Inspector presentation. All pre-change notifications are
/// coalesced into a single read of committed model state on the main queue.
final class InspectorHostController: NSViewController {
    private let terminal: TerminalController
    private let layoutState: VerticalTabWindowLayoutState
    private let registry: InspectorRegistry
    let deck = InspectorPaneDeck.Container()
    private var observations: [AnyCancellable] = []
    private var surfaceObservation: AnyCancellable?
    private weak var observedSurface: Ghostty.SurfaceView?
    private var requestedPresentation = false
    private var refreshPending = false
    private var stopped = false
    private var lastContext: InspectorPaneContext?
    private var environment = EnvironmentValues()
    private var backgroundColor = Color.clear
    private var backgroundOpacity = 0.0

    init(controller: TerminalController, layoutState: VerticalTabWindowLayoutState,
         registry: InspectorRegistry) {
        self.terminal = controller
        self.layoutState = layoutState
        self.registry = registry
        super.init(nibName: nil, bundle: nil)
        observations = [controller.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() },
                        layoutState.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() },
                        registry.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() }]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = InspectorAttachmentView()
        root.attachmentChanged = { [weak self] in self?.scheduleRefresh() }
        root.setAccessibilityLabel("Inspector")
        root.wantsLayer = true
        deck.autoresizingMask = [.width, .height]
        deck.frame = root.bounds
        root.addSubview(deck)
        view = root
    }

    func configure(isPresented: Bool, backgroundColor: Color, backgroundOpacity: Double,
                   environment: EnvironmentValues) {
        _ = view
        requestedPresentation = isPresented
        self.backgroundColor = backgroundColor
        self.backgroundOpacity = backgroundOpacity
        self.environment = environment
        scheduleRefresh()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        observations.removeAll()
        surfaceObservation = nil
        if let lastContext { registry.presentationDidChange(to: nil, context: lastContext) }
    }

    private func scheduleRefresh() {
        guard !stopped, !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshPending = false
            guard !self.stopped else { return }
            self.refresh()
        }
    }

    private func refresh() {
        _ = view
        let surface = terminal.focusedSurface ?? terminal.surfaceTree.first
        if observedSurface !== surface {
            observedSurface = surface
            surfaceObservation = surface.map {
                Publishers.CombineLatest3($0.$pwd, $0.$title, $0.$contextSignal)
                    .dropFirst().sink { [weak self] _ in self?.scheduleRefresh() }
            }
        }
        let session = terminal.paneSessionContext(for: surface) ?? .init(
            workingDirectory: surface?.pwd, terminalTitle: surface?.title ?? "Terminal"
        )
        let context = InspectorPaneContext(
            tabID: terminal.tabSessionID, surfaceID: surface?.id,
            title: terminal.titleOverride ?? session.presentationTitle,
            workingDirectory: session.workingDirectory, workspace: session.workspace, session: session
        )
        lastContext = context
        let selected = layoutState.selectedInspectorPaneID
        let paneID = selected.flatMap { registry.descriptor(id: $0) == nil ? nil : $0 } ?? registry.entries.first?.id
        if selected != paneID { layoutState.selectInspectorPane(paneID) }
        let visible = requestedPresentation && layoutState.isInspectorVisible &&
            view.window != nil && !view.isHiddenOrHasHiddenAncestor
        registry.presentationDidChange(to: visible ? paneID : nil, context: context)
        deck.reconcile(tabID: context.tabID, availableIDs: Set(registry.entries.map(\.id)))
        view.layer?.backgroundColor = NSColor(backgroundColor.opacity(backgroundOpacity)).cgColor
        guard visible, let paneID, let content = registry.content(for: paneID, context: context) else { return }
        let root = InspectorPaneContentView(content: content, paneID: paneID, context: context,
                                            dividerColor: terminal.sidebarDividerColor, registry: registry)
            .environment(\.self, environment)
            .environment(\.gitCollectionColors, GitCollectionColors(
                config: terminal.ghostty.config, background: NSColor(backgroundColor)))
        deck.show(AnyView(root), paneID: paneID, tabID: context.tabID,
                  availableIDs: Set(registry.entries.map(\.id)))
    }
}

private final class InspectorAttachmentView: NSView {
    var attachmentChanged: (() -> Void)?
    override func viewDidHide() {
        super.viewDidHide()
        attachmentChanged?()
    }
    override func viewDidUnhide() {
        super.viewDidUnhide()
        attachmentChanged?()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachmentChanged?()
    }
}
