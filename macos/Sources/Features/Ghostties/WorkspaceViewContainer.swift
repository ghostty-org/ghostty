import AppKit
import SwiftUI

/// An NSView that contains the workspace sidebar alongside the existing terminal view.
/// This replaces TerminalViewContainer as the window's contentView.
///
/// The sidebar is a SwiftUI view hierarchy (icon rail + detail panel) embedded in an
/// NSHostingView. The terminal side is the standard TerminalViewContainer, untouched.
/// Both are arranged via Auto Layout with an animated sidebar width constraint.
///
/// This container also creates and owns the `SessionCoordinator`, which bridges
/// the sidebar's SwiftUI world to the terminal controller's AppKit world.
class WorkspaceViewContainer<ViewModel: TerminalViewModel>: NSView {
    private let sidebarHostingView: NSView
    private let dividerView: NSView
    private let terminalContainer: TerminalViewContainer<ViewModel>
    private let coordinator: SessionCoordinator

    /// Stored constraint for animating sidebar show/hide.
    private var sidebarWidthConstraint: NSLayoutConstraint!
    private var dividerWidthConstraint: NSLayoutConstraint!

    init(ghostty: Ghostty.App, viewModel: ViewModel, delegate: (any TerminalViewDelegate)? = nil) {
        self.terminalContainer = TerminalViewContainer(
            ghostty: ghostty,
            viewModel: viewModel,
            delegate: delegate
        )

        self.coordinator = SessionCoordinator(ghostty: ghostty)

        let sidebarView = WorkspaceSidebarView()
            .environmentObject(WorkspaceStore.shared)
            .environmentObject(coordinator)
        let hostingView = NSHostingView(rootView: sidebarView)
        // Auto Layout controls the sidebar width; disable intrinsic size reporting
        // to avoid unnecessary layout computation from the hosting view.
        hostingView.sizingOptions = []
        self.sidebarHostingView = hostingView

        // 1px divider between sidebar and terminal
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        self.dividerView = divider

        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Give the coordinator a reference to this view so it can discover
        // the window controller through the responder chain.
        coordinator.containerView = self
    }

    override var intrinsicContentSize: NSSize {
        let termSize = terminalContainer.intrinsicContentSize
        guard termSize.width != NSView.noIntrinsicMetric else { return termSize }
        let sidebarWidth = sidebarWidthConstraint?.constant ?? WorkspaceLayout.sidebarWidth
        return NSSize(width: termSize.width + sidebarWidth, height: termSize.height)
    }

    // MARK: - Sidebar Toggle

    /// Whether the sidebar is currently visible.
    var isSidebarVisible: Bool {
        sidebarWidthConstraint.constant > 0
    }

    /// Toggle sidebar visibility with animation.
    @objc func toggleSidebar() {
        let hiding = isSidebarVisible
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            sidebarWidthConstraint.animator().constant = hiding ? 0 : WorkspaceLayout.sidebarWidth
            dividerWidthConstraint.animator().constant = hiding ? 0 : 1
        }
        WorkspaceStore.shared.sidebarVisible = !hiding
    }

    /// Set sidebar visibility without animation (used on initial layout).
    func setSidebarVisible(_ visible: Bool) {
        sidebarWidthConstraint.constant = visible ? WorkspaceLayout.sidebarWidth : 0
        dividerWidthConstraint.constant = visible ? 1 : 0
    }

    // MARK: - Layout

    private func setup() {
        addSubview(sidebarHostingView)
        addSubview(dividerView)
        addSubview(terminalContainer)

        sidebarHostingView.translatesAutoresizingMaskIntoConstraints = false
        dividerView.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.translatesAutoresizingMaskIntoConstraints = false

        // Read persisted sidebar visibility.
        let initialWidth: CGFloat = WorkspaceStore.shared.sidebarVisible
            ? WorkspaceLayout.sidebarWidth : 0
        let initialDivider: CGFloat = WorkspaceStore.shared.sidebarVisible ? 1 : 0

        sidebarWidthConstraint = sidebarHostingView.widthAnchor.constraint(equalToConstant: initialWidth)
        dividerWidthConstraint = dividerView.widthAnchor.constraint(equalToConstant: initialDivider)

        NSLayoutConstraint.activate([
            // Sidebar: pinned to leading edge, full height
            sidebarHostingView.topAnchor.constraint(equalTo: topAnchor),
            sidebarHostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebarHostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
            sidebarWidthConstraint,

            // Divider: 1px between sidebar and terminal
            dividerView.topAnchor.constraint(equalTo: topAnchor),
            dividerView.leadingAnchor.constraint(equalTo: sidebarHostingView.trailingAnchor),
            dividerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            dividerWidthConstraint,

            // Terminal: fills remaining space
            terminalContainer.topAnchor.constraint(equalTo: topAnchor),
            terminalContainer.leadingAnchor.constraint(equalTo: dividerView.trailingAnchor),
            terminalContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            terminalContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
}
