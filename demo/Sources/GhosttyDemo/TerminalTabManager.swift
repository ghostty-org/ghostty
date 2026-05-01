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

    func newTab(app: ghostty_app_t, workspacePath: String? = nil) {
        // 通知旧的活跃 Tab: 失去焦点 + 不可见
        if let oldActive = activeTab {
            oldActive.surfaceView.focusDidChange(false)
            setOcclusion(false, for: oldActive)
        }

        let sv = GhosttySurfaceView(app)
        let tab = Tab(surfaceView: sv)
        tabs.append(tab)
        activeTabID = tab.id

        // 通知新的活跃 Tab: 获得焦点 + 可见
        tab.surfaceView.focusDidChange(true)
        setOcclusion(true, for: tab)

        if let ws = workspacePath {
            tab.surfaceView.sendText("cd \(ws)")
            tab.surfaceView.sendEnter()
        }
    }

    func selectTab(id: UUID) {
        guard id != activeTabID else { return }

        // 通知旧的活跃 Tab: 失去焦点 + 不可见
        if let oldActive = activeTab {
            oldActive.surfaceView.focusDidChange(false)
            setOcclusion(false, for: oldActive)
        }

        activeTabID = id

        // 通知新的活跃 Tab: 获得焦点 + 可见
        if let newActive = activeTab {
            newActive.surfaceView.focusDidChange(true)
            setOcclusion(true, for: newActive)
        }
    }

    func closeTab(id: UUID) {
        guard tabs.count > 1, let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = (id == activeTabID)
        tabs.remove(at: idx)
        if wasActive {
            activeTabID = tabs.last?.id
            // 通知新的活跃 Tab: 可见了
            if let newActive = activeTab {
                setOcclusion(true, for: newActive)
            }
        }
    }

    /// 设置 Surface 的 Occlusion 状态
    /// 当不可见时，libghostty 会：
    /// 1. 停止 DisplayLink（停止渲染循环）
    /// 2. 将 QoS 降为 .utility（降低 CPU 优先级）
    /// 3. 在 drawFrame() 中直接 return（跳过渲染）
    private func setOcclusion(_ visible: Bool, for tab: Tab) {
        guard let surface = tab.surfaceView.surface else { return }
        ghostty_surface_set_occlusion(surface, visible)
    }
}
