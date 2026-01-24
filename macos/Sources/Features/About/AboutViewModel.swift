import Combine

class AboutViewModel: ObservableObject {
    @Published var currentIcon: Ghostty.MacOSIcon?
    @Published var isHovering: Bool = false

    private var timerCancellable: AnyCancellable?

    private let icons: [Ghostty.MacOSIcon] = [
        .official,
        .blueprint,
        .chalkboard,
        .microchip,
        .glass,
        .holographic,
        .paper,
        .retro,
        .xray,
    ]

    func startCyclingIcons() {
        timerCancellable = Timer.publish(every: 3, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, !isHovering else { return }
                advanceToNextIcon()
            }
    }

    func stopCyclingIcons() {
        timerCancellable = nil
        currentIcon = nil
    }

    func advanceToNextIcon() {
        let currentIndex = currentIcon.flatMap(icons.firstIndex(of:)) ?? 0
        let nextIndex = icons.indexWrapping(after: currentIndex)
        currentIcon = icons[nextIndex]
    }
}
