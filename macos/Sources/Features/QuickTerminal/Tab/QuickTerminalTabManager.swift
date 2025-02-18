import GhosttyKit

class QuickTerminalTabManager: ObservableObject {
    @Published var tabs: [QuickTerminalTab] = []
    @Published var currentTab: QuickTerminalTab?
    @Published var draggedTab: QuickTerminalTab?

    private weak var controller: QuickTerminalController?

    init(controller: QuickTerminalController) {
        self.controller = controller
    }

    func newTab() {
        guard let ghostty = controller?.ghostty else { return }

        let leaf: Ghostty.SplitNode.Leaf = .init(ghostty.app!, baseConfig: nil)
        let surface: Ghostty.SplitNode = .leaf(leaf)
        let tabIndex = tabs.count + 1

        let newTab = QuickTerminalTab(surface: surface, title: "Terminal \(tabIndex)")
        tabs.append(newTab)

        selectTab(newTab)
    }

    func selectTab(_ tab: QuickTerminalTab) {
        guard currentTab?.id != tab.id else { return }  // Avoid unnecessary updates

        currentTab?.isActive = false
        tab.isActive = true
        currentTab = tab

        controller?.updateSurfaceTree(to: tab.surface)
    }

    func closeTab(_ tab: QuickTerminalTab) {
        if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
            tabs.remove(at: index)

            if currentTab?.id == tab.id {
                if tabs.isEmpty {
                    newTab()
                    controller?.animateOut()
                } else {
                    let newIndex = min(index, tabs.count - 1)
                    selectTab(tabs[newIndex])
                }
            }
        }
    }

    func moveTab(from source: IndexSet, to destination: Int) {
        tabs.move(fromOffsets: source, toOffset: destination)
    }

    func selectNextTab() {
        guard let currentTab = currentTab,
            let currentIndex = tabs.firstIndex(where: { $0.id == currentTab.id })
        else { return }

        let nextIndex = (currentIndex + 1) % tabs.count
        selectTab(tabs[nextIndex])
    }

    func selectPreviousTab() {
        guard let currentTab = currentTab,
            let currentIndex = tabs.firstIndex(where: { $0.id == currentTab.id })
        else { return }

        let previousIndex = (currentIndex - 1 + tabs.count) % tabs.count
        selectTab(tabs[previousIndex])
    }

    //MARK: - Notifications

    @objc func onMoveTab(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == controller?.focusedSurface else { return }

        // Get the move action
        guard
            let action = notification.userInfo?[Notification.Name.GhosttyMoveTabKey]
                as? Ghostty.Action.MoveTab
        else { return }
        guard action.amount != 0 else { return }

        guard let currentTabIndex = tabs.firstIndex(where: { $0.id == currentTab?.id }) else {
            return
        }

        // Determine the final index we want to insert our tab
        let finalIndex: Int
        if action.amount < 0 {
            finalIndex = max(0, currentTabIndex - min(currentTabIndex, -action.amount))
        } else {
            let remaining: Int = tabs.count - 1 - currentTabIndex
            finalIndex = currentTabIndex + min(remaining, action.amount)
        }

        // If our index is the same we do nothing
        guard finalIndex != currentTabIndex else { return }

        // move the tab
        moveTab(from: IndexSet(integer: currentTabIndex), to: finalIndex)
    }

    @objc func onGoToTab(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == controller?.focusedSurface else { return }

        guard let tabEnumAny = notification.userInfo?[Ghostty.Notification.GotoTabKey] else {
            return
        }
        guard let tabEnum = tabEnumAny as? ghostty_action_goto_tab_e else { return }
        let tabIndex: Int32 = tabEnum.rawValue

        if tabIndex == GHOSTTY_GOTO_TAB_PREVIOUS.rawValue {
            selectPreviousTab()
        } else if tabIndex == GHOSTTY_GOTO_TAB_NEXT.rawValue {
            selectNextTab()
        } else if tabIndex == GHOSTTY_GOTO_TAB_LAST.rawValue {
            selectTab(tabs[tabs.count - 1])
        } else {
            return
        }
    }
}
