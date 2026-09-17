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

    /// Window-level state for the vertical tab presentation.
    var tabLayoutState: VerticalTabWindowLayoutState { get }

    /// Whether this terminal presentation supports the native vertical tab bar.
    var supportsSidebar: Bool { get }

    /// Whether content extends into a hidden titlebar.
    var contentExtendsIntoTitlebar: Bool { get }

    /// The update overlay should be visible.
    var updateOverlayIsVisible: Bool { get }
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

    private var terminalBackground: Color {
        if let controller = viewModel as? TerminalController {
            return controller.terminalBackgroundColor
        }
        guard let surface = lastFocusedSurface?.value else {
            return ghostty.config.backgroundColor
        }
        return surface.backgroundColor ?? surface.derivedConfig.backgroundColor
    }

    private var terminalBackgroundOpacity: Double {
        if let controller = viewModel as? TerminalController {
            return controller.terminalBackgroundOpacity
        }
        return lastFocusedSurface?.value?.derivedConfig.backgroundOpacity ??
            ghostty.config.backgroundOpacity
    }

    @ViewBuilder
    private var terminalContent: some View {
        VStack(spacing: 0) {
            // If we're running in debug mode we show a warning so that users
            // know that performance will be degraded.
            if Ghostty.info.mode == GHOSTTY_BUILD_MODE_DEBUG || Ghostty.info.mode == GHOSTTY_BUILD_MODE_RELEASE_SAFE {
                DebugBuildWarningView()
            }

            TerminalSplitTreeView(
                tree: viewModel.surfaceTree,
                action: { delegate?.performSplitAction($0) })
                .environment(\.editorTerminalController, viewModel as? TerminalController)
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
    }

    var body: some View {
        switch ghostty.readiness {
        case .loading:
            Text("Loading")
        case .error:
            ErrorView()
        case .ready:
            ZStack {
                Group {
                    if let controller = viewModel as? TerminalController,
                       let appDelegate = NSApp.delegate as? AppDelegate {
                        TerminalShellLayoutContainer(
                            controller: controller,
                            layoutState: viewModel.tabLayoutState,
                            statusStore: appDelegate.tabActivities,
                            inspectorRegistry: appDelegate.inspectorRegistry,
                            showsTabSidebar: viewModel.supportsSidebar,
                            backgroundColor: terminalBackground,
                            backgroundOpacity: terminalBackgroundOpacity,
                            chromeBackground: controller.terminalChromeBackground
                        ) {
                            terminalContent
                        }
                    } else {
                        // The Ghostty surface renderer owns terminal background alpha.
                        // A SwiftUI fill here would make transparent surfaces opaque.
                        terminalContent
                    }
                }
                // Ignore safe area to extend up in to the titlebar region if we have the "hidden" titlebar style
                .ignoresSafeArea(.container, edges: viewModel.contentExtendsIntoTitlebar ? .top : [])

                if let surfaceView = lastFocusedSurface?.value {
                    TerminalCommandPaletteView(
                        surfaceView: surfaceView,
                        isPresented: $viewModel.commandPaletteIsShowing,
                        ghosttyConfig: ghostty.config,
                        updateViewModel: (NSApp.delegate as? AppDelegate)?.updateViewModel,
                        sidebarIsSupported: viewModel.supportsSidebar,
                        onToggleSidebar: {
                            if let controller = viewModel as? BaseTerminalController {
                                controller.toggleSidebar(nil)
                            } else {
                                viewModel.tabLayoutState.toggleSidebar()
                            }
                        },
                        inspectorIsSupported: (NSApp.delegate as? AppDelegate)?
                            .inspectorRegistry.isEmpty == false,
                        onToggleInspector: {
                            (viewModel as? TerminalController)?.toggleInspectorPane()
                        },
                        onAction: { action in
                            self.delegate?.performAction(action, on: surfaceView)
                        })
                }

                // Show update information above all else.
                if viewModel.updateOverlayIsVisible {
                    UpdateOverlay()
                }
            }
            .frame(maxWidth: .greatestFiniteMagnitude, maxHeight: .greatestFiniteMagnitude)
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

            Text("You're running a debug build of OMG! Performance will be degraded.")
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
        .accessibilityValue("Debug builds of OMG are very slow and you may experience performance problems. Debug builds are only recommended during development.")
        .accessibilityAddTraits(.isStaticText)
        .onTapGesture {
            isPopover = true
        }
    }
}
