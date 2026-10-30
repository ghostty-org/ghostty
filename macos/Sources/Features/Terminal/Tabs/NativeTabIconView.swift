import AppKit

/// Native split composition. Source images are never resized in the shared catalog.
final class NativeTabIconView: NSView {
    private weak var controller: TerminalController?
    private var marks: [NSImageView] = []
    private var slots: [CGRect] = []
    private var tracking: NSTrackingArea?
    private var previewTask: Task<Void, Never>?
    private let preview = NSPopover()
    private var lastIcon: GhosttyTabIcon = .systemSymbol("terminal")
    private var lastSelected = false
    private var lastActivity: TabActivity?
    private var windowObservers: [NSObjectProtocol] = []
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        preview.behavior = .transient
        preview.animates = false
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refreshPresentation),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func refreshPresentation() {
        configure(controller: controller, icon: lastIcon, selected: lastSelected, activity: lastActivity)
    }

    static func image(_ icon: GhosttyTabIcon) -> NSImage? {
        switch icon {
        case .systemSymbol(let name): NSImage(systemSymbolName: name, accessibilityDescription: nil)
        case .asset(let name): NSImage(named: name)
        case .image(let image): image
        }
    }

    func configure(controller: TerminalController?, icon: GhosttyTabIcon, selected: Bool, activity: TabActivity?) {
        if self.controller !== controller { preview.close(); previewTask?.cancel() }
        self.controller = controller
        lastIcon = icon
        lastSelected = selected
        lastActivity = activity
        let theme = OMGNativeTheme.resolve(for: self)
        let composition = controller.map { SplitTabIconLayout.layout(tree: $0.surfaceTree) } ?? []
        let split = controller?.surfaceTree.isSplit == true
        slots = split ? composition.map(\.rect) : [CGRect(x: 0, y: 0, width: 1, height: 1)]
        while marks.count > slots.count { marks.removeLast().removeFromSuperview() }
        while marks.count < slots.count {
            let image = NSImageView()
            image.imageScaling = .scaleProportionallyUpOrDown
            image.wantsLayer = true
            image.layer?.cornerRadius = 3
            addSubview(image)
            marks.append(image)
        }
        for (index, mark) in marks.enumerated() {
            var glyph = icon
            var state = activity
            var focused = selected
            if split, let controller {
                let surfaces = composition[index].views
                let id = controller.tabPaneFocusHistory.representative(in: surfaces.map(\.id), focused: controller.focusedSurface?.id)
                if let surface = surfaces.first(where: { $0.id == id }) ?? surfaces.first {
                    state = controller.agentActivity(for: surface)
                    let session = controller.paneSessionContext(for: surface)
                    if let requested = state?.icon {
                        glyph = requested.kind == .bundledAsset ? .asset(requested.name) : .systemSymbol(requested.name)
                    } else {
                        glyph = session?.workspace?.icon ?? .systemSymbol(session?.tabIconSystemName ?? "terminal")
                    }
                    focused = SplitTabPane.isPaneFocused(selected: selected, surfaceID: surface.id, focusedID: controller.focusedSurface?.id)
                }
            }
            mark.image = Self.image(glyph)
            mark.contentTintColor = focused ? theme.accent : theme.secondary
            let color: NSColor
            switch state?.state {
            case .needsAttention: color = .systemOrange
            case .error: color = .systemRed
            case .done: color = .systemGreen
            default: color = focused && split ? theme.accent : .clear
            }
            mark.layer?.borderColor = color.withAlphaComponent(0.55).cgColor
            mark.layer?.borderWidth = color == .clear ? 0 : 0.75
            if let state, state.state != .idle {
                mark.contentTintColor = state.state == .working
                    ? (state.phase == .background ? .systemPurple : theme.accent) : color
            }
            if let layer = mark.layer {
                let visible = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
                AgentLogoLayerBreath.setRunning(state?.state == .working && visible &&
                    !isHiddenOrHasHiddenAncestor && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, on: layer)
            }
        }
        toolTip = split ? "\(controller?.surfaceTree.count ?? 0) Panes" : nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        for (index, mark) in marks.enumerated() {
            let slot = slots[index]
            let area = CGRect(x: slot.minX * bounds.width, y: slot.minY * bounds.height,
                              width: slot.width * bounds.width, height: slot.height * bounds.height)
            let size = slots.count > 1 ? min(13, min(area.width, area.height) - 1)
                : TabIconMetrics.singleLogo(OhMyGhosttySettings.shared.tabIconSize)
            mark.frame = CGRect(x: area.midX - size / 2, y: area.midY - size / 2, width: size, height: size)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        tracking = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        guard controller?.surfaceTree.isSplit == true else { return }
        previewTask?.cancel()
        previewTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(550)) } catch { return }
            guard let self, NativePointerLocation.contains(self), let controller = self.controller, let window = self.window else { return }
            let panes = Array(controller.surfaceTree)
            let entries: [NativeMenuEntry] = [.action("\(panes.count) Panes", enabled: false) {}] + panes.map { surface in
                .action(surface.title.isEmpty ? "Terminal" : surface.title, symbol: "terminal",
                        checked: controller.focusedSurface === surface) { [weak controller, weak surface] in
                    guard let controller, let surface, controller.surfaceTree.contains(where: { $0 === surface }) else { return }
                    controller.selectVerticalTab(controller)
                    Ghostty.moveFocus(to: surface)
                }
            }
            let content = NativeActionPopoverController(entries: entries)
            let panel = NativeTabPanePreviewController(controller: controller, actions: content)
            panel.surface.bindTheme(to: window)
            content.onCancel = { [weak self] in self?.preview.close() }
            content.onSelect = { [weak self] index in
                guard entries.indices.contains(index), case let .action(_, _, enabled, _, action) = entries[index], enabled else { return }
                self?.preview.close()
                action()
            }
            self.preview.contentViewController = panel
            self.preview.contentSize = panel.preferredContentSize
            self.preview.show(relativeTo: self.bounds, of: self, preferredEdge: .maxX)
        }
    }
    override func mouseExited(with event: NSEvent) { previewTask?.cancel() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        if window == nil {
            previewTask?.cancel()
            preview.close()
            marks.forEach { $0.layer?.removeAllAnimations() }
        } else {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshPresentation() }
                })
            }
            refreshPresentation()
        }
    }
    override func viewDidHide() { super.viewDidHide(); refreshPresentation() }
    override func viewDidUnhide() { super.viewDidUnhide(); refreshPresentation() }
}

private final class NativeTabPanePreviewController: NSViewController {
    let surface = OMGNativeSurfaceView()
    private let diagram: NativeSplitPreviewView
    private let actions: NativeActionPopoverController

    init(controller: TerminalController, actions: NativeActionPopoverController) {
        self.diagram = NativeSplitPreviewView(controller: controller)
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
        _ = view
        preferredContentSize = .init(width: 320, height: min(260, actions.preferredContentSize.height) + 146)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = surface
        addChild(actions)
        actions.surface.paintsBackground = false
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        actions.view.frame = .init(x: 0, y: 0, width: 320, height: actions.preferredContentSize.height)
        actions.view.autoresizingMask = [.width]
        scroll.documentView = actions.view
        let stack = NSStackView(views: [diagram, scroll])
        stack.orientation = .vertical
        stack.distribution = .fill
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            stack.topAnchor.constraint(equalTo: surface.topAnchor),
            stack.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            diagram.widthAnchor.constraint(equalTo: stack.widthAnchor),
            diagram.heightAnchor.constraint(equalToConstant: 140),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        surface.onThemeChange = { [weak self] theme in
            self?.diagram.applyTheme(theme)
        }
    }
}

private final class NativeSplitPreviewView: NSView {
    private weak var controller: TerminalController?
    private var images: [UUID: NSImageView] = [:]
    private var theme = OMGNativeTheme(background: .windowBackgroundColor, foreground: .labelColor)
    override var isFlipped: Bool { true }

    init(controller: TerminalController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        for surface in controller.surfaceTree {
            let image = NSImageView()
            image.imageScaling = .scaleProportionallyUpOrDown
            let activity = controller.agentActivity(for: surface)
            let icon: GhosttyTabIcon
            if let requested = activity?.icon {
                icon = requested.kind == .bundledAsset ? .asset(requested.name) : .systemSymbol(requested.name)
            } else {
                icon = controller.paneSessionContext(for: surface)?.workspace?.icon ?? .systemSymbol("terminal")
            }
            image.image = NativeTabIconView.image(icon)
            images[surface.id] = image
            addSubview(image)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func applyTheme(_ theme: OMGNativeTheme) {
        self.theme = theme
        images.forEach { id, view in
            view.contentTintColor = controller?.focusedSurface?.id == id ? theme.accent : theme.foreground
        }
        needsDisplay = true
    }
    override func layout() {
        super.layout()
        guard let spatial = controller?.surfaceTree.root?.spatial(within: bounds.size) else { return }
        for slot in spatial.slots {
            guard case .leaf(let surface) = slot.node, let image = images[surface.id] else { continue }
            let size = min(22, max(1, min(slot.bounds.width, slot.bounds.height) - 10))
            image.frame = .init(x: slot.bounds.midX - size / 2, y: slot.bounds.midY - size / 2, width: size, height: size)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let controller else { return }
        theme.controlFill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 4), xRadius: 5, yRadius: 5).fill()
        theme.border.setStroke()
        let path = NSBezierPath()
        for divider in TabSplitPreviewLayout.dividers(tree: controller.surfaceTree, size: bounds.size) {
            path.move(to: divider.start)
            path.line(to: divider.end)
        }
        path.lineWidth = 0.75
        path.stroke()
    }
}
