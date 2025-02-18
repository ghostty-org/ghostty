import SwiftUI

struct QuickTerminalTabBarView: View {
    @ObservedObject var tabManager: QuickTerminalTabManager

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(tabManager.tabs) { tab in
                    QuickTerminalTabItemView(
                        tab: tab,
                        isHighlighted: tab.isActive,
                        onSelect: { tabManager.selectTab(tab) },
                        onClose: { tabManager.closeTab(tab) }
                    )
                    .contextMenu {
                        Button("Close Tab") {
                            tabManager.closeTab(tab)
                        }
                        Button("Close Other Tabs") {
                            tabManager.tabs.forEach { otherTab in
                                if otherTab.id != tab.id {
                                    tabManager.closeTab(otherTab)
                                }
                            }
                        }
                    }
                    .onDrag {
                        tabManager.draggedTab = tab
                        return NSItemProvider(object: tab.id.uuidString as NSString)
                    }
                    .onDrop(
                        of: [.text],
                        delegate: QuickTerminalTabDropDelegate(
                            item: tab,
                            tabManager: tabManager,
                            currentTab: tabManager.draggedTab
                        )
                    )
                    Divider()
                        .background(Color(NSColor.separatorColor))
                }
            }

            Image(systemName: "plus")
                .foregroundColor(Color(NSColor.secondaryLabelColor))
                .padding(.horizontal, 8)
                .frame(width: 50)
                .contentShape(Rectangle())
                .onTapGesture {
                    tabManager.newTab()
                }
                .buttonStyle(PlainButtonStyle())
                .help("New Tab")
        }
        .frame(height: 32)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

struct QuickTerminalTabDropDelegate: DropDelegate {
    let item: QuickTerminalTab
    let tabManager: QuickTerminalTabManager
    let currentTab: QuickTerminalTab?

    func performDrop(info: DropInfo) -> Bool {
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let currentTab = currentTab,
            let from = tabManager.tabs.firstIndex(where: { $0.id == currentTab.id }),
            let to = tabManager.tabs.firstIndex(where: { $0.id == item.id })
        else { return }

        if tabManager.tabs[to].id != currentTab.id {
            tabManager.tabs.move(
                fromOffsets: IndexSet(integer: from),
                toOffset: to > from ? to + 1 : to)
        }
    }
}
