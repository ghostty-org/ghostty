import Combine
import SwiftUI

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

    /// The tab color for visual identification
    @Published var tabColor: TerminalTabColor = .none

    /// The current background color of the focused surface (dynamic if set,
    /// otherwise the configured background color).
    @Published private(set) var backgroundColor: Color?

    /// The configured background opacity of the focused surface. Used to keep
    /// the active tab visually continuous with the translucent terminal below it.
    @Published private(set) var backgroundOpacity: Double = 1

    let id = UUID()
    var surfaceTree: SplitTree<Ghostty.SurfaceView>

    /// Tracks the current surface title (before any override)
    private var currentSurfaceTitle: String?
    private var cancellables: Set<AnyCancellable> = []

    init(surfaceTree: SplitTree<Ghostty.SurfaceView>, title: String = "Terminal") {
        self.surfaceTree = surfaceTree
        self.currentSurfaceTitle = surfaceTree.first { $0.focused }?.title ?? title
        self.title = self.currentSurfaceTitle ?? title

        subscribeToSurface(surfaceTree.first { $0.focused })
    }

    /// Updates the surface subscriptions to track the given surface.
    /// Called when the focused surface changes within this tab.
    func updateFocusedSurface(_ surface: Ghostty.SurfaceView?) {
        subscribeToSurface(surface)
    }

    private func subscribeToSurface(_ surface: Ghostty.SurfaceView?) {
        cancellables.removeAll()
        guard let surface else {
            backgroundColor = nil
            backgroundOpacity = 1
            return
        }

        surface.$title
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newTitle in
                guard let self else { return }
                self.currentSurfaceTitle = newTitle
                // Only update displayed title if no override is set
                if self.titleOverride == nil {
                    self.title = newTitle
                }
            }
            .store(in: &cancellables)

        // Prefer the dynamic background color (OSC 11, etc.) and fall back to the
        // surface's configured background. Opacity always comes from the config.
        surface.$backgroundColor
            .combineLatest(surface.$derivedConfig)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dynamic, config in
                guard let self else { return }
                self.backgroundColor = dynamic ?? config.backgroundColor
                self.backgroundOpacity = config.backgroundOpacity
            }
            .store(in: &cancellables)
    }
}
