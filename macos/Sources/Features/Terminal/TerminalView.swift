import SwiftUI
import GhosttyKit

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

    /// A split is resizing to a given value.
    func splitDidResize(node: SplitTree<Ghostty.SurfaceView>.Node, to newRatio: Double)
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
}

/// The main terminal view. This terminal view supports splits.
struct TerminalView<ViewModel: TerminalViewModel>: View {
    @ObservedObject var ghostty: Ghostty.App

    // The required view model
    @ObservedObject var viewModel: ViewModel

    // An optional delegate to receive information about terminal changes.
    weak var delegate: (any TerminalViewDelegate)? = nil

    // The most recently focused surface, equal to focusedSurface when
    // it is non-nil.
    @State private var lastFocusedSurface: Weak<Ghostty.SurfaceView> = .init()

    // This seems like a crutch after switching from SwiftUI to AppKit lifecycle.
    @FocusState private var focused: Bool

    // Various state values sent back up from the currently focused terminals.
    @FocusedValue(\.ghosttySurfaceView) private var focusedSurface
    @FocusedValue(\.ghosttySurfacePwd) private var surfacePwd
    @FocusedValue(\.ghosttySurfaceCellSize) private var cellSize

    // Preview manager for tab sidebar mode
    @StateObject private var previewManager = TabPreviewManager()

    // Currently selected surface ID for tab sidebar
    @State private var selectedSurfaceID: UUID?

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
            if ghostty.config.macosTabSidebar {
                sidebarLayout
            } else {
                mainContent
            }
        }
    }

    // MARK: - Sidebar Layout

    @ViewBuilder
    private var sidebarLayout: some View {
        GeometryReader { geometry in
            let sidebarWidth = geometry.size.width * 0.5

            HStack(spacing: 0) {
                TabSidebarView(
                    previewManager: previewManager,
                    tabItems: gatherTabItems(),
                    selectedSurfaceID: $selectedSurfaceID,
                    sidebarWidth: sidebarWidth,
                    sidebarHeight: geometry.size.height,
                    onNewTab: handleNewTab,
                    onCloseTab: handleCloseTab,
                    onSelectTab: handleSelectTab
                )
                .environmentObject(ghostty)

                // In sidebar mode, only show the selected surface, not all splits
                sidebarMainContent
            }
            .background(Color.clear)
        }
        .background(Color.clear)
        .onAppear {
            startPreviewTracking()
        }
        .onDisappear {
            previewManager.stopTracking()
        }
        .onChange(of: viewModel.surfaceTree.count) { newCount in
            let oldCount = previewManager.previews.count
            updatePreviewTracking()

            // If a new surface was added, select and focus it
            if newCount > oldCount {
                let surfaces = Array(viewModel.surfaceTree)
                if let newSurface = surfaces.last {
                    selectedSurfaceID = newSurface.id
                    lastFocusedSurface = .init(newSurface)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        Ghostty.moveFocus(to: newSurface)
                    }
                }
            }
        }
        .onChange(of: focusedSurface) { newValue in
            if let surface = newValue {
                selectedSurfaceID = surface.id
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Ghostty.Notification.ghosttySelectSidebarTab)) { notification in
            guard let surfaceID = notification.userInfo?[Ghostty.Notification.SidebarTabSurfaceIDKey] as? UUID else { return }
            handleSelectTab(surfaceID)
        }
    }

    // MARK: - Sidebar Main Content (shows only selected tab)

    @ViewBuilder
    private var sidebarMainContent: some View {
        ZStack {
            VStack(spacing: 0) {
                if (Ghostty.info.mode == GHOSTTY_BUILD_MODE_DEBUG || Ghostty.info.mode == GHOSTTY_BUILD_MODE_RELEASE_SAFE) {
                    DebugBuildWarningView()
                }

                // Only show the selected surface, not all splits
                if let selectedID = selectedSurfaceID,
                   let selectedSurface = findSurface(by: selectedID) {
                    Ghostty.InspectableSurface(surfaceView: selectedSurface, isSplit: false)
                        .id(selectedID) // Force view recreation when selected tab changes
                        .environmentObject(ghostty)
                        .focused($focused)
                        .onAppear { self.focused = true }
                        .onChange(of: focusedSurface) { newValue in
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
                } else {
                    // Fallback: show the first surface if no selection
                    TerminalSplitTreeView(
                        tree: viewModel.surfaceTree,
                        onResize: { delegate?.splitDidResize(node: $0, to: $1) })
                        .environmentObject(ghostty)
                        .focused($focused)
                        .onAppear { self.focused = true }
                }
            }
            .ignoresSafeArea(.container, edges: ghostty.config.macosTitlebarStyle == "hidden" ? .top : [])

            if let surfaceView = lastFocusedSurface.value {
                TerminalCommandPaletteView(
                    surfaceView: surfaceView,
                    isPresented: $viewModel.commandPaletteIsShowing,
                    ghosttyConfig: ghostty.config,
                    updateViewModel: (NSApp.delegate as? AppDelegate)?.updateViewModel) { action in
                    self.delegate?.performAction(action, on: surfaceView)
                }
            }

            if viewModel.updateOverlayIsVisible {
                UpdateOverlay()
            }
        }
        .frame(maxWidth: .greatestFiniteMagnitude, maxHeight: .greatestFiniteMagnitude)
        .background(Color.clear)
    }

    // MARK: - Main Content (standard mode)

    @ViewBuilder
    private var mainContent: some View {
        ZStack {
            VStack(spacing: 0) {
                // If we're running in debug mode we show a warning so that users
                // know that performance will be degraded.
                if (Ghostty.info.mode == GHOSTTY_BUILD_MODE_DEBUG || Ghostty.info.mode == GHOSTTY_BUILD_MODE_RELEASE_SAFE) {
                    DebugBuildWarningView()
                }

                TerminalSplitTreeView(
                    tree: viewModel.surfaceTree,
                    onResize: { delegate?.splitDidResize(node: $0, to: $1) })
                    .environmentObject(ghostty)
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
                    .frame(idealWidth: lastFocusedSurface.value?.initialSize?.width,
                           idealHeight: lastFocusedSurface.value?.initialSize?.height)
            }
            // Ignore safe area to extend up in to the titlebar region if we have the "hidden" titlebar style
            .ignoresSafeArea(.container, edges: ghostty.config.macosTitlebarStyle == "hidden" ? .top : [])

            if let surfaceView = lastFocusedSurface.value {
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

    // MARK: - Tab Sidebar Helpers

    /// Finds a surface by its ID in the surface tree.
    private func findSurface(by id: UUID) -> Ghostty.SurfaceView? {
        for surface in viewModel.surfaceTree {
            if surface.id == id {
                return surface
            }
        }
        return nil
    }

    /// Gathers all surfaces from the split tree into tab items.
    private func gatherTabItems() -> [SidebarTabItem] {
        var items: [SidebarTabItem] = []
        var index = 0
        for surface in viewModel.surfaceTree {
            items.append(SidebarTabItem(surface: surface, index: index))
            index += 1
        }
        return items
    }

    /// Starts preview tracking for all current surfaces.
    private func startPreviewTracking() {
        let surfaces = Array(viewModel.surfaceTree)
        previewManager.startTracking(surfaces: surfaces)
        // Set initial selection to focused surface or first surface
        if selectedSurfaceID == nil {
            selectedSurfaceID = focusedSurface?.id ?? surfaces.first?.id
        }
    }

    /// Updates the preview manager when the surface tree changes.
    private func updatePreviewTracking() {
        let surfaces = Array(viewModel.surfaceTree)
        previewManager.updateSurfaces(surfaces)
        // If selected surface was removed, select the first one
        if let selectedID = selectedSurfaceID, findSurface(by: selectedID) == nil {
            selectedSurfaceID = surfaces.first?.id
        }
    }

    /// Handles new tab creation from the sidebar.
    private func handleNewTab() {
        // In sidebar mode, create a new split (which adds a surface to the tree)
        // The new surface will appear as a new tab in the sidebar

        // Try to find a surface to split from: selected, last focused, or first in tree
        let targetSurface: Ghostty.SurfaceView?
        if let selectedID = selectedSurfaceID, let surface = findSurface(by: selectedID) {
            targetSurface = surface
        } else if let surface = lastFocusedSurface.value {
            targetSurface = surface
        } else {
            targetSurface = Array(viewModel.surfaceTree).first
        }

        guard let surface = targetSurface else { return }

        NotificationCenter.default.post(
            name: Ghostty.Notification.ghosttyNewSplit,
            object: surface,
            userInfo: [
                "direction": GHOSTTY_SPLIT_DIRECTION_RIGHT
            ]
        )
    }

    /// Handles tab closing from the sidebar.
    private func handleCloseTab(_ surfaceID: UUID) {
        // Find the surface with the given ID and close it
        if let surface = findSurface(by: surfaceID) {
            // If this is the selected tab, select another one first
            var newSurfaceToFocus: Ghostty.SurfaceView? = nil
            if surfaceID == selectedSurfaceID {
                let surfaces = Array(viewModel.surfaceTree)
                if let currentIndex = surfaces.firstIndex(where: { $0.id == surfaceID }) {
                    // Select the previous tab, or next if this is the first
                    if currentIndex > 0 {
                        newSurfaceToFocus = surfaces[currentIndex - 1]
                        selectedSurfaceID = newSurfaceToFocus?.id
                    } else if surfaces.count > 1 {
                        newSurfaceToFocus = surfaces[1]
                        selectedSurfaceID = newSurfaceToFocus?.id
                    }
                }
            }

            // Close the surface
            NotificationCenter.default.post(
                name: Ghostty.Notification.ghosttyCloseSurface,
                object: surface
            )

            // Focus the new surface after a short delay to allow the close to process
            if let newSurface = newSurfaceToFocus {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.lastFocusedSurface = .init(newSurface)
                    Ghostty.moveFocus(to: newSurface)
                }
            }
        }
    }

    /// Handles tab selection from the sidebar.
    private func handleSelectTab(_ surfaceID: UUID) {
        // Find the surface and move focus to it
        if let surface = findSurface(by: surfaceID) {
            selectedSurfaceID = surfaceID
            lastFocusedSurface = .init(surface)
            Ghostty.moveFocus(to: surface)
        }
    }
}

fileprivate struct UpdateOverlay: View {
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
