import Combine

class QuickTerminalTab: ObservableObject, Identifiable {
    @Published var title: String

    let id = UUID()
    var surfaceTree: SplitTree<Ghostty.SurfaceView>

    private var cancellable: AnyCancellable?

    init(surfaceTree: SplitTree<Ghostty.SurfaceView>, title: String = "Terminal") {
        self.surfaceTree = surfaceTree
        self.title = surfaceTree.first { $0.focused }?.title ?? title

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
                self?.title = newTitle
            }
    }
}
