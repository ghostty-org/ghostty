import AppKit

/// Container for the browser panel content: navigation bar + browser view area.
/// This view sits inside `browserShadowHost` (which provides shadow and rounded corners).
@MainActor
final class BrowserPanelView: NSView {
    let navigationBar = BrowserNavigationBar()

    /// Placeholder for the browser content area (CEFBrowserView goes here in Step 9).
    let contentArea: NSView = {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        return view
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        addSubview(navigationBar)
        addSubview(contentArea)

        navigationBar.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            navigationBar.topAnchor.constraint(equalTo: topAnchor),
            navigationBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            navigationBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            navigationBar.heightAnchor.constraint(
                equalToConstant: WorkspaceLayout.terminalTitleBarHeight),

            contentArea.topAnchor.constraint(equalTo: navigationBar.bottomAnchor),
            contentArea.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentArea.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentArea.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}
