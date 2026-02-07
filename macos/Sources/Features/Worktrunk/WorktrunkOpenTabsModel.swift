import AppKit
import Foundation

final class WorktrunkOpenTabsModel: ObservableObject {
    struct Tab: Identifiable, Equatable {
        let id: Int            // NSWindow.windowNumber
        let windowNumber: Int  // NSWindow.windowNumber
        let title: String
        let worktreeRootPath: String?
        let isActive: Bool
    }

    @Published private(set) var tabs: [Tab] = []

    @MainActor
    func refresh(for window: NSWindow?) {
        guard let window else {
            if !tabs.isEmpty { tabs = [] }
            return
        }

        let groupWindows = window.tabGroup?.windows ?? [window]
        let next: [Tab] = groupWindows.compactMap { w in
            let controller = w.windowController as? TerminalController
            let worktreeRootPath = controller?.worktreeTabRootPath
            return Tab(
                id: w.windowNumber,
                windowNumber: w.windowNumber,
                title: w.title,
                worktreeRootPath: worktreeRootPath,
                isActive: w == window
            )
        }

        if next != tabs {
            tabs = next
        }
    }
}

