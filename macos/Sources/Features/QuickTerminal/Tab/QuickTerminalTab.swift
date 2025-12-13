import Combine

class QuickTerminalTab: ObservableObject, Identifiable {
    /// The displayed title (uses titleOverride if set, otherwise the surface title)
    @Published var title: String

    /// User-defined title override. When set, this is displayed instead of the surface title.
    @Published var titleOverride: String? {
        didSet {
            if let override = titleOverride {
                title = override
            } else {
                // Restore surface title
                title = currentSurfaceTitle ?? "Terminal"
            }
        }
    }

    let id = UUID()
    var surfaceTree: SplitTree<Ghostty.SurfaceView>

    /// Tracks the current surface title (before any override)
    private var currentSurfaceTitle: String?
    private var cancellable: AnyCancellable?

    init(surfaceTree: SplitTree<Ghostty.SurfaceView>, title: String = "Terminal") {
        self.surfaceTree = surfaceTree
        self.currentSurfaceTitle = surfaceTree.first { $0.focused }?.title ?? title
        self.title = self.currentSurfaceTitle ?? title

        subscribeToTitle(of: surfaceTree.first { $0.focused })
    }

    deinit {
        cancellable?.cancel()
    }

    /// Updates the title subscription to track the given surface's title.
    /// Called when the focused surface changes within this tab.
    func updateFocusedSurface(_ surface: Ghostty.SurfaceView?) {
        subscribeToTitle(of: surface)
    }

    private func subscribeToTitle(of surface: Ghostty.SurfaceView?) {
        cancellable?.cancel()
        cancellable = surface?.$title
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newTitle in
                guard let self else { return }
                self.currentSurfaceTitle = newTitle
                // Only update displayed title if no override is set
                if self.titleOverride == nil {
                    self.title = newTitle
                }
            }
    }
}
