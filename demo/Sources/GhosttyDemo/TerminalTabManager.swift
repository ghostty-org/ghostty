import SwiftUI
import GhosttyRuntime
import GhosttyKit

@MainActor
class TerminalTabManager: ObservableObject {
    struct Tab: Identifiable {
        let id = UUID()
        let surfaceView: GhosttySurfaceView
        var title: String { surfaceView.title }
    }

    @Published var tabs: [Tab] = []
    @Published var activeTabID: UUID?

    var activeTab: Tab? {
        tabs.first { $0.id == activeTabID }
    }

    func newTab(app: ghostty_app_t) {
        let sv = GhosttySurfaceView(app)
        let tab = Tab(surfaceView: sv)
        tabs.append(tab)
        activeTabID = tab.id
    }

    func selectTab(id: UUID) {
        activeTabID = id
    }

    func closeTab(id: UUID) {
        guard tabs.count > 1, let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: idx)
        if activeTabID == id {
            activeTabID = tabs.last?.id
        }
    }
}
