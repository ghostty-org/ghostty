import AppKit
import SwiftUI

/// Each native tab reserves sidebar space, but the group owns one live list.
/// Containers retain the host; the group keeps weak references so a sidebar
/// cannot keep its terminal controllers (and therefore the group) alive.
@MainActor
final class VerticalTabSidebarHost {
    private weak var hostingView: NativeTabSidebarHostingView?
    private var containers: [ObjectIdentifier: Weak<VerticalTabSidebarContainer>] = [:]
    private weak var outgoingContainer: VerticalTabSidebarContainer?
    private(set) var mountCount = 0

    var liveView: NSView? { hostingView }
    private var pendingScrollOffset: Double?
    private var rememberedScrollOffset: Double?
    private var scrollRestorationGeneration = 0

    var scrollOffset: Double? {
        if let pendingScrollOffset { return pendingScrollOffset }
        guard let scroll = scrollView(in: hostingView) else { return rememberedScrollOffset }
        let value = Double(scroll.contentView.bounds.origin.y)
        rememberedScrollOffset = value
        return value
    }

    func restoreScrollOffset(_ value: Double?) {
        guard let value, value.isFinite, value >= 0 else { return }
        rememberedScrollOffset = value
        pendingScrollOffset = value
        applyScrollOffset()
        scrollRestorationGeneration += 1
        let generation = scrollRestorationGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.scrollRestorationGeneration else { return }
            if self.applyScrollOffset() { self.pendingScrollOffset = nil }
        }
    }

    /// Native selection updates can run after host mounting.
    /// Reapply a saved group position instead of auto-scrolling to a
    /// selected tab the user may intentionally have scrolled away from.
    func restorePendingScrollPosition() -> Bool {
        guard pendingScrollOffset != nil else { return false }
        return applyScrollOffset()
    }

    private func scrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }

    @discardableResult
    private func applyScrollOffset() -> Bool {
        guard let offset = pendingScrollOffset, let scroll = scrollView(in: hostingView),
              let document = scroll.documentView else { return false }
        let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(CGFloat(offset), maximum)))
        scroll.reflectScrolledClipView(scroll.contentView)
        return true
    }

    func register(_ container: VerticalTabSidebarContainer) {
        containers[ObjectIdentifier(container)] = Weak(container)
        presentSelectedWindow()
    }

    func unregister(_ container: VerticalTabSidebarContainer) {
        containers.removeValue(forKey: ObjectIdentifier(container))
        if hostingView?.superview === container {
            presentSelectedWindow()
            if hostingView?.superview === container { hostingView?.removeFromSuperview() }
        }
    }

    func presentSelectedWindow(updateContent: Bool = false) {
        guard !TerminalWorkspacePresentation.isChanging else { return }
        containers = containers.filter { $0.value.value != nil }
        guard let destination = containers.values.compactMap(\.value).first(where: { $0.isSelectedWindow }) else { return }
        present(in: destination, updateContent: updateContent)
    }

    func windowWillClose(_ window: NSWindow, successor: NSWindow?) {
        guard hostingView?.window === window, let successor,
              let destination = containers.values.compactMap(\.value).first(where: { $0.window === successor }) else { return }
        // BaseTerminalController clears contentView during willClose. Move the
        // existing host first so its row state survives that teardown too.
        present(in: destination)
    }

    private func present(in destination: VerticalTabSidebarContainer, updateContent: Bool = false) {
        guard let content = destination.content else { return }
        if let hostingView {
            let moved = hostingView.superview !== destination
            if moved {
                // Reparenting a hosting view crosses two native window backing
                // stores. Layout alone does not paint the incoming store; keep
                // the handoff atomic until its first display is prepared.
                NSDisableScreenUpdates()
                defer { NSEnableScreenUpdates() }
                outgoingContainer?.discardLastFrame()
                outgoingContainer = hostingView.superview as? VerticalTabSidebarContainer
                outgoingContainer?.retainLastFrame(of: hostingView)
                hostingView.removeFromSuperview()
                hostingView.configure(content)
                destination.install(hostingView)
            }
            // Reconfigure the existing controller without replacing row/scroll
            // identity. Background containers never update this root.
            if !moved && updateContent { hostingView.configure(content) }
        } else {
            let host = NativeTabSidebarHostingView(configuration: content)
            self.hostingView = host
            mountCount += 1
            destination.install(host)
        }
        applyScrollOffset()
    }
}

@MainActor
final class VerticalTabSidebarContainer: NSView {
    weak var controller: TerminalController?
    weak var owner: VerticalTabSidebarHost?
    var content: NativeTabSidebarConfiguration?
    private let lastFrame = NSImageView()
    private var keyObserver: NSObjectProtocol?

    var isSelectedWindow: Bool {
        guard let window, let controller, controller.window === window,
              !controller.workspacePresentationIsParked,
              controller.tabLayoutState.sidebarHost === owner else { return false }
        // A newly loaded window temporarily has its own native tab group while
        // already sharing the parent's layout state. It must not steal the list
        // before it has joined the group and become its committed selection.
        let selectedID = controller.tabLayoutState.tabSnapshot.selectedID
        guard selectedID == nil || selectedID == ObjectIdentifier(controller) else { return false }
        return (window.tabGroup?.selectedWindow ?? window) === window
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        lastFrame.imageScaling = .scaleAxesIndependently
        lastFrame.autoresizingMask = [.width, .height]
        lastFrame.frame = bounds
        addSubview(lastFrame)
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let window = notification.object as? NSWindow, self.window === window else { return }
                self.owner?.presentSelectedWindow()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            owner?.register(self)
        } else {
            owner?.unregister(self)
        }
    }

    override func layout() {
        super.layout()
        // Fullscreen tab attachment may register while selection/publication is
        // suspended. A later layout must complete the mount even if SwiftUI's
        // representable content did not change and updateNSView is not called.
        if isSelectedWindow, owner?.liveView?.superview !== self {
            owner?.presentSelectedWindow()
        }
    }

    func configure(
        controller: TerminalController,
        owner: VerticalTabSidebarHost,
        content: NativeTabSidebarConfiguration
    ) {
        if self.owner !== owner { self.owner?.unregister(self) }
        self.controller = controller
        self.owner = owner
        self.content = content
        owner.register(self)
        if isSelectedWindow { owner.presentSelectedWindow(updateContent: true) }
    }

    func install(_ host: NativeTabSidebarHostingView) {
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            host.layoutSubtreeIfNeeded()
            host.needsDisplay = true
            host.displayIfNeeded()
        }
        // Keep the fallback until the incoming host has actually displayed,
        // rather than exposing an empty backing store during layout.
        lastFrame.isHidden = true
        lastFrame.image = nil
    }

    func discardLastFrame() {
        lastFrame.image = nil
        lastFrame.isHidden = true
    }

    func retainLastFrame(of host: NSView) {
        // AppKit can expose the outgoing window for one more frame during a
        // tab switch. Keep its pixels, not a second live sidebar hierarchy.
        guard host.bounds.width > 0, host.bounds.height > 0,
              let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(bitmap)
        lastFrame.image = image
        lastFrame.isHidden = false
    }

    deinit {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
    }
}

struct SharedTerminalTabSidebar: NSViewRepresentable {
    let controller: TerminalController
    let layoutState: VerticalTabWindowLayoutState
    let statusStore: TabActivityStore
    let backgroundColor: Color
    var backgroundOpacity: Double = 0

    func makeNSView(context: Context) -> VerticalTabSidebarContainer {
        VerticalTabSidebarContainer(frame: .zero)
    }

    func updateNSView(_ container: VerticalTabSidebarContainer, context: Context) {
        container.configure(
            controller: controller,
            owner: layoutState.sidebarHost,
            content: NativeTabSidebarConfiguration(
                controller: controller,
                layoutState: layoutState,
                statusStore: statusStore,
                backgroundColor: NSColor(backgroundColor),
                backgroundOpacity: backgroundOpacity
            )
        )
    }

    static func dismantleNSView(_ container: VerticalTabSidebarContainer, coordinator: ()) {
        container.owner?.unregister(container)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: VerticalTabSidebarContainer, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}
