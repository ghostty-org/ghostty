import Combine

class QuickTerminalTab: ObservableObject, Identifiable {
    @Published var title: String

    let id = UUID()
    var surface: SplitTree<Ghostty.SurfaceView>

    private var cancellable: AnyCancellable?

    init(surface: SplitTree<Ghostty.SurfaceView>, title: String = "Terminal") {
        self.surface = surface
        self.title = surface.first { $0.focused }?.pwd ?? title

        let targetSurface = surface.first { $0.focused }
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
