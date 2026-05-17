import Cocoa

struct QuickTerminalRestorableState: TerminalRestorable {
    static var version: Int { 1 }

    var focusedSurface: String? {
        internalState.focusedSurface
    }

    var surfaceTree: SplitTree<Ghostty.SurfaceView> {
        internalState.surfaceTree
    }

    var screenStateEntries: QuickTerminalScreenStateCache.Entries {
        internalState.screenStateEntries
    }

    private let internalState: InternalState<Ghostty.SurfaceView>

    init(from controller: QuickTerminalController) {
        controller.saveScreenState(exitFullscreen: true)
        self.internalState = .init(from: controller)
    }

    init(copy other: QuickTerminalRestorableState) {
        self = other
    }

    var baseConfig: Ghostty.SurfaceConfiguration? {
        var config = Ghostty.SurfaceConfiguration()
        config.environmentVariables["GHOSTTY_QUICK_TERMINAL"] = "1"
        return config
    }
}

extension QuickTerminalRestorableState {
    /// Internal State we use to perform unit tests
    ///
    /// Since we can't really change the type of `QuickTerminalRestorableState`
    /// due to `CodableBridge<QuickTerminalRestorableState>` supporting secure coding,
    /// we use an internal type to perform migration and tests
    struct InternalState<ViewType: NSView & Codable & Identifiable>: Codable {
        // MARK: - Version 1 (1.3.0)
        let focusedSurface: String?
        let surfaceTree: SplitTree<ViewType>
        let screenStateEntries: QuickTerminalScreenStateCache.Entries

        init(
            focusedSurface: String?,
            surfaceTree: SplitTree<ViewType>,
            screenStateEntries: QuickTerminalScreenStateCache.Entries,
        ) {
            self.focusedSurface = focusedSurface
            self.surfaceTree = surfaceTree
            self.screenStateEntries = screenStateEntries
        }
    }
}

extension QuickTerminalRestorableState.InternalState where ViewType == Ghostty.SurfaceView {
    init(from controller: QuickTerminalController) {
        self.init(
            focusedSurface: controller.focusedSurface?.id.uuidString,
            surfaceTree: controller.surfaceTree,
            screenStateEntries: controller.screenStateCache.stateByDisplay,
        )
    }
}
