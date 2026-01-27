import Foundation
import GhosttyKit

final class GitDiffTerminalViewModel: ObservableObject, TerminalViewModel {
    @Published var surfaceTree: SplitTree<Ghostty.SurfaceView> = .init()
    @Published var commandPaletteIsShowing: Bool = false
    var updateOverlayIsVisible: Bool { false }

    func setSurface(_ surfaceView: Ghostty.SurfaceView) {
        surfaceTree = SplitTree(view: surfaceView)
    }

    func clear() {
        surfaceTree = .init()
    }
}
