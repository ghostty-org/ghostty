import Combine

class QuickTerminalTab: ObservableObject, Identifiable {
    @Published var title: String

    let id = UUID()
    var surfaceTree: SplitTree<Ghostty.SurfaceView>

    private var cancellable: AnyCancellable?

    init(surfaceTree: SplitTree<Ghostty.SurfaceView>, title: String = "Terminal") {
        self.surfaceTree = surfaceTree
        self.title = surfaceTree.first { $0.focused }?.pwd ?? title

        let targetSurface = surfaceTree.first { $0.focused }
        self.cancellable = targetSurface?.$title
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newTitle in
                self?.title = newTitle
            }
    }

    deinit {
        cancellable?.cancel()
    }
}
