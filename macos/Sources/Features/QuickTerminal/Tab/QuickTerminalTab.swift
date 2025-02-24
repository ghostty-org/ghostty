import Combine

class QuickTerminalTab: ObservableObject, Identifiable {
    let id = UUID()
    var surface: Ghostty.SplitNode
    @Published var title: String
    @Published var isActive: Bool = false

    private var cancellable: AnyCancellable?

    init(surface: Ghostty.SplitNode, title: String = "Terminal") {
        self.surface = surface
        self.title = surface.first { $0.surface.focused }?.surface.pwd ?? "Terminal"

        let targetSurface = surface.first { $0.surface.focused }?.surface ?? surface.preferredFocus()
        self.cancellable = targetSurface.$title
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newTitle in
                self?.title = newTitle
            }

    }

    deinit {
        cancellable?.cancel()
    }
}
