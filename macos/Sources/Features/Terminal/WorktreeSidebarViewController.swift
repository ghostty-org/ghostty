import AppKit
import SwiftUI

final class WorktreeSidebarViewController: NSSplitViewController {
    private let terminalViewContainer: TerminalViewContainer
    let viewModel: WorktreeSidebarViewModel
    private var sidebarSplitViewItem: NSSplitViewItem?
    private var sidebarState = WorktreeSidebarState()

    init(
        contentView terminalViewContainer: TerminalViewContainer,
        viewModel: WorktreeSidebarViewModel? = nil
    ) {
        self.terminalViewContainer = terminalViewContainer
        // Construct the default view model in the init body (main-actor isolated)
        // rather than as a default argument, which Swift evaluates in a nonisolated
        // context and would reject for the @MainActor view model.
        self.viewModel = viewModel ?? WorktreeSidebarViewModel()
        super.init(nibName: nil, bundle: nil)

        // NSSplitViewController manages `splitView`, not `view`: items added
        // via addSplitViewItem land in `splitView`. Assigning a custom split
        // view to `view` in loadView leaves `splitView` as a detached default
        // NSSplitView, so the window's content view stays empty. The custom
        // subclass must be assigned to `splitView` before the view loads.
        let splitView = WorktreeSidebarSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.terminalViewContainer = terminalViewContainer
        self.splitView = splitView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let sidebarViewController = WorktreeSidebarListViewController(viewModel: viewModel)
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = sidebarState.isCollapsed
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
        let willOpen = sidebarSplitViewItem.isCollapsed

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            sidebarSplitViewItem.animator().isCollapsed = !sidebarSplitViewItem.isCollapsed
        } completionHandler: {
            self.rememberSidebarState()
            if willOpen {
                self.restoreSidebarWidth()
            }
            self.view.invalidateIntrinsicContentSize()
        }
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        rememberSidebarState()
    }

    private func rememberSidebarState() {
        guard let sidebarSplitViewItem else { return }

        sidebarState.isCollapsed = sidebarSplitViewItem.isCollapsed
        let width = sidebarSplitViewItem.viewController.view.frame.width
        if !sidebarSplitViewItem.isCollapsed,
           width >= sidebarSplitViewItem.minimumThickness,
           width <= sidebarSplitViewItem.maximumThickness {
            sidebarState.width = width
        }
    }

    private func restoreSidebarWidth() {
        guard let sidebarSplitViewItem, !sidebarSplitViewItem.isCollapsed else { return }
        let width = min(max(sidebarState.width, sidebarSplitViewItem.minimumThickness), sidebarSplitViewItem.maximumThickness)
        splitView.setPosition(width, ofDividerAt: 0)
    }
}

private struct WorktreeSidebarState {
    var isCollapsed = true
    var width: CGFloat = 220
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

            if let message = viewModel.sidebarMessage {
                WorktreeSidebarMessageView(message: message)
            }

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
        List {
            ForEach(viewModel.filteredWorktrees, id: \.path) { worktree in
                WorktreeSidebarRowView(
                    worktree: worktree,
                    isActive: worktree.path == viewModel.selectedWorktree?.path
                )
                // Whole row is clickable; the click switches workspaces (M3).
                .contentShape(Rectangle())
                .onTapGesture {
                    viewModel.select(worktree)
                }
                .listRowBackground(
                    worktree.path == viewModel.selectedWorktree?.path
                        ? Color.accentColor.opacity(0.18)
                        : Color.clear
                )
            }

            Button {
                viewModel.requestCreateWorktree()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: viewModel.isCreatingWorktree ? "hourglass" : "plus")
                        .foregroundStyle(.secondary)
                    Text(viewModel.isCreatingWorktree ? "Creating worktree..." : "New worktree...")
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isCreatingWorktree || viewModel.worktrees.isEmpty)
            .help("Create a new git worktree")
            .listRowBackground(Color.clear)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }
}

private struct WorktreeSidebarMessageView: View {
    let message: WorktreeSidebarMessage

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: message.kind == .error ? "exclamationmark.triangle" : "info.circle")
                .foregroundStyle(message.kind == .error ? Color.orange : Color.secondary)
            Text(message.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            (message.kind == .error ? Color.orange : Color.secondary)
                .opacity(0.10)
        )
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

        // Clicking a row switches to that worktree's workspace (M3).
        controller.viewModel.onSelect = { [weak self] worktree in
            self?.switchToWorktree(worktree)
        }
        controller.viewModel.onCreate = { [weak self] in
            self?.promptForNewWorktree()
        }
    }

    /// The cwd to source worktrees from: the window's first surface's live pwd,
    /// falling back to the configured `working-directory` (bare commands report
    /// no pwd). Returns nil when neither is available.
    ///
    /// Internal (not private) because the goto_worktree keybind path in
    /// TerminalController.swift loads the sidebar data on demand from this cwd
    /// when the sidebar has never been opened.
    // worktree-sidebar:
    var worktreeSidebarCwd: URL? {
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

    // worktree-sidebar:
    private func promptForNewWorktree() {
        guard let viewModel = worktreeSidebarViewController?.viewModel,
              let window else { return }

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = "branch-name"

        let alert = NSAlert()
        alert.messageText = "New Worktree"
        alert.informativeText = "Enter the branch name to create. The worktree will be created beside this repository."
        alert.accessoryView = input
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self, weak viewModel] response in
            guard response == .alertFirstButtonReturn,
                  let self,
                  let viewModel else { return }

            let branchName = input.stringValue
            Task { @MainActor in
                if let worktree = await viewModel.createWorktree(branchName: branchName) {
                    self.switchToWorktree(worktree)
                }
            }
        }
    }
}
