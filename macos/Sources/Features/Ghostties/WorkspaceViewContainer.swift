import AppKit
import SwiftUI

/// An NSView that contains the workspace sidebar alongside the existing terminal view.
/// This replaces TerminalViewContainer as the window's contentView.
///
/// The sidebar is a SwiftUI view hierarchy (icon rail + detail panel) embedded in an
/// NSHostingView. The terminal side is the standard TerminalViewContainer, untouched.
/// Both are arranged via Auto Layout with the sidebar at a fixed 220pt width.
///
/// This container also creates and owns the `SessionCoordinator`, which bridges
/// the sidebar's SwiftUI world to the terminal controller's AppKit world.
class WorkspaceViewContainer<ViewModel: TerminalViewModel>: NSView {
    private let sidebarHostingView: NSView
    private let terminalContainer: TerminalViewContainer<ViewModel>
    private let coordinator: SessionCoordinator

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
        return NSSize(width: termSize.width + WorkspaceLayout.sidebarWidth, height: termSize.height)
    }

    private func setup() {
        addSubview(sidebarHostingView)
        addSubview(terminalContainer)

        sidebarHostingView.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            // Sidebar: pinned to leading edge, full height, fixed width
            sidebarHostingView.topAnchor.constraint(equalTo: topAnchor),
            sidebarHostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebarHostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
            sidebarHostingView.widthAnchor.constraint(equalToConstant: WorkspaceLayout.sidebarWidth),

            // Terminal: fills remaining space
            terminalContainer.topAnchor.constraint(equalTo: topAnchor),
            terminalContainer.leadingAnchor.constraint(equalTo: sidebarHostingView.trailingAnchor),
            terminalContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            terminalContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
}
