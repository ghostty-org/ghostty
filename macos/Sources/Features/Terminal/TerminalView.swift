import SwiftUI
import GhosttyKit
import os

/// This delegate is notified of actions and property changes regarding the terminal view. This
/// delegate is optional and can be used by a TerminalView caller to react to changes such as
/// titles being set, cell sizes being changed, etc.
protocol TerminalViewDelegate: AnyObject {
    /// Called when the currently focused surface changed. This can be nil.
    func focusedSurfaceDidChange(to: Ghostty.SurfaceView?)

    /// The URL of the pwd should change.
    func pwdDidChange(to: URL?)

    /// The cell size changed.
    func cellSizeDidChange(to: NSSize)

    /// Perform an action. At the time of writing this is only triggered by the command palette.
    func performAction(_ action: String, on: Ghostty.SurfaceView)

    /// A split tree operation
    func performSplitAction(_ action: TerminalSplitOperation)
}

/// The view model is a required implementation for TerminalView callers. This contains
/// the main state between the TerminalView caller and SwiftUI. This abstraction is what
/// allows AppKit to own most of the data in SwiftUI.
protocol TerminalViewModel: ObservableObject {
    /// The tree of terminal surfaces (splits) within the view. This is mutated by TerminalView
    /// and children. This should be @Published.
    var surfaceTree: SplitTree<Ghostty.SurfaceView> { get set }

    /// The command palette state.
    var commandPaletteIsShowing: Bool { get set }

    /// The update overlay should be visible.
    var updateOverlayIsVisible: Bool { get }

    /// The model for the tab sidebar. This is nil for terminals that can never
    /// show a sidebar, in which case `tabsLocation` is always `top`.
    var sideTabs: SideTabsViewModel? { get }

    /// Where the tabs of this terminal are shown. This can change at runtime so
    /// implementations must publish changes to it.
    var tabsLocation: Ghostty.Config.MacOSTabsLocation { get }
}

/// The main terminal view. This terminal view supports splits.
struct TerminalView<ViewModel: TerminalViewModel>: View {
    @ObservedObject var ghostty: Ghostty.App

    // The required view model
    @ObservedObject var viewModel: ViewModel

    // An optional delegate to receive information about terminal changes.
    weak var delegate: (any TerminalViewDelegate)?

    /// The most recently focused surface, equal to `focusedSurface` when it is non-nil.
    @State private var lastFocusedSurface: Weak<Ghostty.SurfaceView>?

    // This seems like a crutch after switching from SwiftUI to AppKit lifecycle.
    @FocusState private var focused: Bool

    // Various state values sent back up from the currently focused terminals.
    @FocusedValue(\.ghosttySurfaceView) private var focusedSurface
    @FocusedValue(\.ghosttySurfacePwd) private var surfacePwd
    @FocusedValue(\.ghosttySurfaceCellSize) private var cellSize

    // The pwd of the focused surface as a URL
    private var pwdURL: URL? {
        guard let surfacePwd, surfacePwd != "" else { return nil }
        return URL(fileURLWithPath: surfacePwd)
    }

    var body: some View {
        switch ghostty.readiness {
        case .loading:
            Text("Loading")
        case .error:
            ErrorView()
        case .ready:
            if let sideTabs = viewModel.sideTabs {
                // Terminals that can show a sidebar always lay out in an HStack,
                // even while the sidebar is hidden. The terminal content stays
                // at the same position in the view tree that way, so moving the
                // sidebar at runtime doesn't tear down the surfaces.
                HStack(spacing: 0) {
                    if viewModel.tabsLocation == .left {
                        SideTabsView(viewModel: sideTabs)
                        Divider()
                    }

                    terminalContent

                    if viewModel.tabsLocation == .right {
                        Divider()
                        SideTabsView(viewModel: sideTabs)
                    }
                }
            } else {
                terminalContent
            }
        }
    }

    private var terminalContent: some View {
        ZStack {
            VStack(spacing: 0) {
                // If we're running in debug mode we show a warning so that users
                // know that performance will be degraded.
                if Ghostty.info.mode == GHOSTTY_BUILD_MODE_DEBUG || Ghostty.info.mode == GHOSTTY_BUILD_MODE_RELEASE_SAFE {
                    DebugBuildWarningView()
                }

                TerminalSplitTreeView(
                    tree: viewModel.surfaceTree,
                    action: { delegate?.performSplitAction($0) })
                    .environmentObject(ghostty)
                    .ghosttyLastFocusedSurface(lastFocusedSurface)
                    .focused($focused)
                    .onAppear { self.focused = true }
                    .onChange(of: focusedSurface) { newValue in
                        // We want to keep track of our last focused surface so even if
                        // we lose focus we keep this set to the last non-nil value.
                        if newValue != nil {
                            lastFocusedSurface = .init(newValue)
                            self.delegate?.focusedSurfaceDidChange(to: newValue)
                        }
                    }
                    .onChange(of: pwdURL) { newValue in
                        self.delegate?.pwdDidChange(to: newValue)
                    }
                    .onChange(of: cellSize) { newValue in
                        guard let size = newValue else { return }
                        self.delegate?.cellSizeDidChange(to: size)
                    }
                    .frame(idealWidth: lastFocusedSurface?.value?.initialSize?.width,
                           idealHeight: lastFocusedSurface?.value?.initialSize?.height)
            }
            // Ignore safe area to extend up in to the titlebar region if we have the "hidden" titlebar style
            .ignoresSafeArea(.container, edges: ghostty.config.macosTitlebarStyle == .hidden ? .top : [])

            if let surfaceView = lastFocusedSurface?.value {
                TerminalCommandPaletteView(
                    surfaceView: surfaceView,
                    isPresented: $viewModel.commandPaletteIsShowing,
                    ghosttyConfig: ghostty.config,
                    updateViewModel: (NSApp.delegate as? AppDelegate)?.updateViewModel) { action in
                    self.delegate?.performAction(action, on: surfaceView)
                }
            }

            // Show update information above all else.
            if viewModel.updateOverlayIsVisible {
                UpdateOverlay()
            }
        }
        .frame(maxWidth: .greatestFiniteMagnitude, maxHeight: .greatestFiniteMagnitude)
    }
}

/// The model behind the tab sidebar that is shown when `macos-tabs-location` is
/// `left` or `right`.
///
/// Tabs on macOS are windows in an `NSWindowTabGroup`, so this mirrors the tab
/// group of the window it belongs to. Every tab has its own controller and
/// therefore its own model, but only the selected tab's sidebar is on screen.
final class SideTabsViewModel: ObservableObject {
    struct Tab: Identifiable, Equatable {
        /// A tab is a window and windows have no identifier of their own, so we
        /// identify a tab by the window that backs it.
        let id: ObjectIdentifier
        let title: String
        let shortcut: String?
        let color: TerminalTabColor
        let isSelected: Bool
    }

    @Published private(set) var tabs: [Tab] = []

    private weak var controller: TerminalController?

    /// True while we're mirroring the tab group. We track this so that we only
    /// tear our observations down (and restore the tab bar) once.
    private var mirroring: Bool = false

    private weak var observedTabGroup: NSWindowTabGroup?
    private var tabGroupObservations: [NSKeyValueObservation] = []
    private var titleObservations: [NSKeyValueObservation] = []
    private var observedWindows: [ObjectIdentifier] = []

    init(controller: TerminalController) {
        self.controller = controller
    }

    deinit {
        tabGroupObservations.forEach { $0.invalidate() }
        titleObservations.forEach { $0.invalidate() }
    }

    // MARK: Tab List

    /// Resync our tab list with the window's tab group. This is safe to call as
    /// often as needed and does nothing while the sidebar is hidden.
    func refresh() {
        // Reading `window.tabGroup` materializes AppKit's tab group machinery,
        // which is expensive (see TerminalController.windowDidLoad), so don't
        // touch it at all unless the sidebar is (or was) showing.
        guard let controller, controller.tabsLocation != .top else {
            if mirroring { stopMirroring() }
            return
        }
        guard let hostWindow = controller.window else { return }

        mirroring = true
        observe(hostWindow)
        syncNativeTabBar(hostWindow)
        refreshTabs(hostWindow)
    }

    /// Stop mirroring the tab group and undo everything we changed for the
    /// sidebar.
    private func stopMirroring() {
        mirroring = false

        if let hostWindow = controller?.window {
            syncNativeTabBar(hostWindow)
        }

        tabGroupObservations.forEach { $0.invalidate() }
        tabGroupObservations = []
        observedTabGroup = nil
        titleObservations.forEach { $0.invalidate() }
        titleObservations = []
        observedWindows = []
        tabs = []
    }

    private func observe(_ hostWindow: NSWindow) {
        let tabGroup = hostWindow.tabGroup

        if observedTabGroup !== tabGroup {
            observedTabGroup = tabGroup
            tabGroupObservations.forEach { $0.invalidate() }

            tabGroupObservations = [
                // Tabs added, removed, or reordered.
                tabGroup?.observe(\.windows, options: [.new]) { [weak self] _, _ in
                    self?.refreshLater()
                },

                // Which tab is selected, which is the row we highlight. We can't
                // rely on our controller becoming key for this since a tab can
                // be selected without that happening.
                tabGroup?.observe(\.selectedWindow, options: [.new]) { [weak self] _, _ in
                    self?.refreshLater()
                },
            ].compactMap { $0 }
        }

        // The tab titles are what we render, and AppKit gives us no single
        // notification for "some tab's title changed", so observe each window.
        let windows = tabGroup?.windows ?? [hostWindow]
        let windowIDs = windows.map(ObjectIdentifier.init)
        guard observedWindows != windowIDs else { return }
        observedWindows = windowIDs
        titleObservations.forEach { $0.invalidate() }
        titleObservations = windows.map { window in
            window.observe(\.title, options: [.new]) { [weak self] _, _ in
                self?.refreshLater()
            }
        }
    }

    /// Refresh on the next main queue turn. Our observations rebind themselves,
    /// and replacing an observation from inside its own callback leaves the
    /// observed object retained, so we never refresh directly from one.
    private func refreshLater() {
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    /// The sidebar replaces the macOS tab bar, so the tab bar is hidden while the
    /// sidebar is shown and restored when it isn't. Each tab has its own tab bar,
    /// so the whole group is synced: a tab that joins the group can't hide its
    /// own tab bar until it knows where the group shows its tabs.
    private func syncNativeTabBar(_ hostWindow: NSWindow) {
        for window in hostWindow.tabGroup?.windows ?? [hostWindow] {
            (window as? TerminalWindow)?.syncNativeTabBarVisibility()
        }
    }

    private func refreshTabs(_ hostWindow: NSWindow) {
        let tabGroup = hostWindow.tabGroup
        let windows = tabGroup?.windows ?? [hostWindow]
        let selectedWindow = tabGroup?.selectedWindow ?? hostWindow

        let tabs = windows.enumerated().map { index, window in
            Tab(
                id: ObjectIdentifier(window),
                title: window.title.isEmpty ? "Terminal \(index + 1)" : window.title,
                shortcut: shortcut(forTabAt: index),
                color: (window as? TerminalWindow)?.tabColor ?? .none,
                isSelected: window === selectedWindow)
        }

        // We refresh on every title change and shells retitle constantly, so
        // don't redraw the sidebar unless something it shows actually changed.
        guard tabs != self.tabs else { return }
        self.tabs = tabs
    }

    /// The keyboard shortcut that activates the tab at the given index. Only the
    /// first nine tabs get one, matching the labels we put on native tabs (see
    /// `TerminalController.relabelTabs`).
    private func shortcut(forTabAt index: Int) -> String? {
        guard index < 9 else { return nil }
        guard let config = controller?.ghostty.config else { return nil }
        guard let shortcut = config.keyboardShortcut(for: "goto_tab:\(index + 1)") else { return nil }
        return "\(shortcut)"
    }

    // MARK: Actions

    func select(_ id: ObjectIdentifier) {
        // Making a tabbed window key selects its tab, the same way the
        // `goto_tab` action switches tabs.
        tabWindow(for: id)?.makeKeyAndOrderFront(nil)
    }

    func newTab() {
        // Our controller is the selected tab because the sidebar is only ever
        // on screen for the selected tab.
        controller?.newTab(nil)
    }

    func close(_ id: ObjectIdentifier) {
        tabController(for: id)?.closeTab(nil)
    }

    func promptTitle(_ id: ObjectIdentifier) {
        tabController(for: id)?.promptTabTitle()
    }

    func closeOtherTabs(_ id: ObjectIdentifier) {
        tabController(for: id)?.closeOtherTabs(nil)
    }

    func closeTabsOnTheRight(_ id: ObjectIdentifier) {
        tabController(for: id)?.closeTabsOnTheRight(nil)
    }

    func setColor(_ color: TerminalTabColor, for id: ObjectIdentifier) {
        guard let window = tabWindow(for: id) as? TerminalWindow else { return }
        window.tabColor = color
        refresh()
    }

    func hasTabsOnTheRight(of id: ObjectIdentifier) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        return index < tabs.count - 1
    }

    private func tabController(for id: ObjectIdentifier) -> TerminalController? {
        tabWindow(for: id)?.windowController as? TerminalController
    }

    private func tabWindow(for id: ObjectIdentifier) -> NSWindow? {
        guard let hostWindow = controller?.window else { return nil }
        return (hostWindow.tabGroup?.windows ?? [hostWindow]).first {
            ObjectIdentifier($0) == id
        }
    }
}

/// The tab sidebar shown on the left or right of a terminal window.
struct SideTabsView: View {
    /// The width of the sidebar.
    static let width: CGFloat = 220

    /// The width the sidebar takes from the window content, including the
    /// divider that separates it from the terminal.
    static let totalWidth: CGFloat = width + 1

    @ObservedObject var viewModel: SideTabsViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(viewModel.tabs) { tab in
                        tabRow(tab)
                    }
                }
                .padding(6)
            }

            Divider()

            Button(action: viewModel.newTab) {
                Label("New Tab", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("Side Tabs New Tab")
        }
        .frame(width: Self.width)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Side Tabs")
        .onAppear(perform: viewModel.refresh)
    }

    private func tabRow(_ tab: SideTabsViewModel.Tab) -> some View {
        ZStack(alignment: .trailing) {
            Button { viewModel.select(tab.id) } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(tab.color.displayColor.map { Color(nsColor: $0) } ?? .clear)
                        .frame(width: 7, height: 7)

                    Text(tab.title)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 4)

                    if let shortcut = tab.shortcut {
                        Text(shortcut)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Reserve the space that the close button is drawn in.
                    Color.clear.frame(width: 18, height: 18)
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(tab.isSelected ? Color.accentColor.opacity(0.2) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityIdentifier("Side Tab")

            Button { viewModel.close(tab.id) } label: {
                Image(systemName: "xmark")
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 7)
            .help("Close Tab")
            .accessibilityIdentifier("Side Tab Close")
            .accessibilityLabel("Close \(tab.title)")
        }
        .contextMenu {
            Button("Rename Tab...") { viewModel.promptTitle(tab.id) }
            Divider()
            Button("Close Tab") { viewModel.close(tab.id) }
            Button("Close Other Tabs") { viewModel.closeOtherTabs(tab.id) }
                .disabled(viewModel.tabs.count < 2)
            Button("Close Tabs to the Right") { viewModel.closeTabsOnTheRight(tab.id) }
                .disabled(!viewModel.hasTabsOnTheRight(of: tab.id))
            Divider()
            Menu("Tab Color") {
                ForEach(TerminalTabColor.allCases, id: \.self) { color in
                    Button(color.localizedName) { viewModel.setColor(color, for: tab.id) }
                }
            }
        }
    }
}

private struct UpdateOverlay: View {
    var body: some View {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            VStack {
                Spacer()

                HStack {
                    Spacer()
                    UpdatePill(model: appDelegate.updateViewModel)
                        .padding(.bottom, 9)
                        .padding(.trailing, 9)
                }
            }
        }
    }
}

struct DebugBuildWarningView: View {
    @State private var isPopover = false

    var body: some View {
        HStack {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)

            Text("You're running a debug build of Ghostty! Performance will be degraded.")
                .padding(.all, 8)
                .popover(isPresented: $isPopover, arrowEdge: .bottom) {
                    Text("""
                    Debug builds of Ghostty are very slow and you may experience
                    performance problems. Debug builds are only recommended during
                    development.
                    """)
                    .padding(.all)
                }

            Spacer()
        }
        .background(Color(.windowBackgroundColor))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Debug build warning")
        .accessibilityValue("Debug builds of Ghostty are very slow and you may experience performance problems. Debug builds are only recommended during development.")
        .accessibilityAddTraits(.isStaticText)
        .onTapGesture {
            isPopover = true
        }
    }
}
