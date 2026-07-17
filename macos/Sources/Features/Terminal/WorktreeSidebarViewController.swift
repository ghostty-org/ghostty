import AppKit
import SwiftUI

final class WorktreeSidebarViewController: NSSplitViewController {
    private let terminalViewContainer: TerminalViewContainer
    let viewModel: WorktreeSidebarViewModel
    private var sidebarSplitViewItem: NSSplitViewItem?

    init(
        contentView terminalViewContainer: TerminalViewContainer,
        viewModel: WorktreeSidebarViewModel = WorktreeSidebarViewModel()
    ) {
        self.terminalViewContainer = terminalViewContainer
        self.viewModel = viewModel
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

        let sidebarViewController = WorktreeSidebarListViewController(viewModel: viewModel)
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

    /// Reload the sidebar's worktrees for the given cwd. The cwd is sourced by
    /// the owning `TerminalController` from its first surface (see
    /// `TerminalController.refreshWorktreeSidebar`).
    func refresh(cwd: URL?) {
        Task { await viewModel.refresh(cwd: cwd) }
    }

    override func toggleSidebar(_ sender: Any?) {
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
    private let viewModel: WorktreeSidebarViewModel

    init(viewModel: WorktreeSidebarViewModel) {
        self.viewModel = viewModel
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
            rootView: WorktreeSidebarList(viewModel: viewModel)
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
    @ObservedObject var viewModel: WorktreeSidebarViewModel

    var body: some View {
        VStack(spacing: 0) {
            filterField

            if viewModel.isEmptyState {
                emptyState
            } else {
                list
            }
        }
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
            TextField("Filter", text: $viewModel.filterText)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text("Not a git repository")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List(viewModel.filteredWorktrees, id: \.path) { worktree in
            WorktreeSidebarRowView(
                worktree: worktree,
                isActive: worktree.path == viewModel.selectedWorktree?.path
            )
            .listRowBackground(
                worktree.path == viewModel.selectedWorktree?.path
                    ? Color.accentColor.opacity(0.18)
                    : Color.clear
            )
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }
}

private struct WorktreeSidebarRowView: View {
    let worktree: Worktree
    let isActive: Bool

    private var title: String {
        WorktreeSidebar.displayName(for: worktree)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: worktree.isDetached ? "arrow.triangle.pull" : "arrow.triangle.branch")
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            Text(title)
                // Truncate long branch names in the middle, with a tooltip
                // showing the full name.
                .truncationMode(.middle)
                .lineLimit(1)
                .fontWeight(worktree.isMain ? .semibold : .regular)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .help(title)
    }
}

extension TerminalController {
    func installWorktreeSidebar(around container: TerminalViewContainer, in window: NSWindow) {
        let controller = WorktreeSidebarViewController(contentView: container)
        worktreeSidebarViewController = controller
        window.contentViewController = controller
    }

    /// The cwd to source worktrees from: the window's first surface's live pwd,
    /// falling back to the configured `working-directory` (bare commands report
    /// no pwd). Returns nil when neither is available.
    // worktree-sidebar:
    private var worktreeSidebarCwd: URL? {
        let surface = surfaceTree.first
        return WorktreeSidebar.resolveCwd(
            pwd: surface?.pwd,
            configuredWorkingDirectory: ghostty.config.workingDirectory
        )
    }

    /// Reload the sidebar's worktrees from the current first-surface cwd.
    /// Refresh triggers: the window becoming key and the sidebar being toggled
    /// open (see `toggleWorktreeSidebar` / `windowDidBecomeKey`).
    // worktree-sidebar:
    func refreshWorktreeSidebar() {
        worktreeSidebarViewController?.refresh(cwd: worktreeSidebarCwd)
    }

    /// Semantic entry point for toggling the sidebar. This no-arg signature is kept
    /// aligned with the `toggle_worktree_sidebar` keybind stub in feat/wt-keybinds so
    /// that, at integration, the keybind path replaces that stub's body rather than
    /// silently adding a second no-op overload. A merge conflict here is intentional
    /// and correct — resolve it by keeping this real implementation.
    // worktree-sidebar:
    func toggleWorktreeSidebar() {
        guard let controller = worktreeSidebarViewController else { return }
        let willOpen = controller.isSidebarCollapsed
        controller.toggleSidebar(nil)

        // Refresh when the sidebar is being opened so it reflects the current
        // repository state without waiting for a window-focus change.
        if willOpen {
            refreshWorktreeSidebar()
        }
    }

    @IBAction func toggleWorktreeSidebar(_ sender: Any?) {
        toggleWorktreeSidebar()
    }
}
