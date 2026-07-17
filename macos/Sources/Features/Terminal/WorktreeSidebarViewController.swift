import AppKit
import SwiftUI

struct WorktreeSidebarRow: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
}

protocol WorktreeSidebarDataSource {
    var rows: [WorktreeSidebarRow] { get }
}

struct PlaceholderWorktreeSidebarDataSource: WorktreeSidebarDataSource {
    let rows: [WorktreeSidebarRow] = [
        .init(id: "main", title: "main", subtitle: "Current repository"),
        .init(id: "feature", title: "feature/example", subtitle: "Placeholder worktree"),
        .init(id: "review", title: "review/design-notes", subtitle: "Placeholder worktree"),
    ]
}

final class WorktreeSidebarViewController: NSSplitViewController {
    private let terminalViewContainer: TerminalViewContainer
    private let dataSource: any WorktreeSidebarDataSource
    private var sidebarSplitViewItem: NSSplitViewItem?

    init(
        contentView terminalViewContainer: TerminalViewContainer,
        dataSource: any WorktreeSidebarDataSource = PlaceholderWorktreeSidebarDataSource()
    ) {
        self.terminalViewContainer = terminalViewContainer
        self.dataSource = dataSource
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let splitView = WorktreeSidebarSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.terminalViewContainer = terminalViewContainer

        view = splitView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let sidebarViewController = WorktreeSidebarListViewController(dataSource: dataSource)
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = true
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 280

        let terminalViewController = NSViewController()
        terminalViewController.view = terminalViewContainer
        let terminalItem = NSSplitViewItem(viewController: terminalViewController)
        terminalItem.canCollapse = false

        addSplitViewItem(sidebarItem)
        addSplitViewItem(terminalItem)

        sidebarSplitViewItem = sidebarItem
        (splitView as? WorktreeSidebarSplitView)?.sidebarItem = sidebarItem
    }

    var isSidebarCollapsed: Bool {
        sidebarSplitViewItem?.isCollapsed ?? true
    }

    func toggleSidebar(_ sender: Any?) {
        guard let sidebarSplitViewItem else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            sidebarSplitViewItem.animator().isCollapsed = !sidebarSplitViewItem.isCollapsed
        } completionHandler: {
            self.view.invalidateIntrinsicContentSize()
        }
    }
}

private final class WorktreeSidebarSplitView: NSSplitView {
    weak var terminalViewContainer: TerminalViewContainer?
    weak var sidebarItem: NSSplitViewItem?

    override var intrinsicContentSize: NSSize {
        if sidebarItem?.isCollapsed ?? true,
           let terminalViewContainer {
            return terminalViewContainer.intrinsicContentSize
        }

        return super.intrinsicContentSize
    }
}

private final class WorktreeSidebarListViewController: NSViewController {
    private let dataSource: any WorktreeSidebarDataSource

    init(dataSource: any WorktreeSidebarDataSource) {
        self.dataSource = dataSource
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = .sidebar
        visualEffectView.blendingMode = .withinWindow
        visualEffectView.state = .active

        let hostingView = NSHostingView(
            rootView: WorktreeSidebarList(dataSource: dataSource)
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
        ])

        view = visualEffectView
    }
}

private struct WorktreeSidebarList: View {
    let dataSource: any WorktreeSidebarDataSource

    var body: some View {
        List(dataSource.rows) { row in
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.body)
                Text(row.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }
}

extension TerminalController {
    func installWorktreeSidebar(around container: TerminalViewContainer, in window: NSWindow) {
        let controller = WorktreeSidebarViewController(contentView: container)
        worktreeSidebarViewController = controller
        window.contentViewController = controller
    }

    /// Semantic entry point for toggling the sidebar. This no-arg signature is kept
    /// aligned with the `toggle_worktree_sidebar` keybind stub in feat/wt-keybinds so
    /// that, at integration, the keybind path replaces that stub's body rather than
    /// silently adding a second no-op overload. A merge conflict here is intentional
    /// and correct — resolve it by keeping this real implementation.
    // worktree-sidebar:
    func toggleWorktreeSidebar() {
        worktreeSidebarViewController?.toggleSidebar(nil)
    }

    @IBAction func toggleWorktreeSidebar(_ sender: Any?) {
        toggleWorktreeSidebar()
    }
}
