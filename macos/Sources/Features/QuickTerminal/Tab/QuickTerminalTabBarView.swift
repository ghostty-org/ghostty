import SwiftUI

struct QuickTerminalTabBarView: View {
    @ObservedObject var tabManager: QuickTerminalTabManager

    var body: some View {
        HStack(spacing: 0) {
            renderTabBar()
            renderAddNewTabButton()
        }
        .frame(height: Constants.height)
        .background(Color(NSColor.controlBackgroundColor))
    }

    @ViewBuilder private func renderTabBar() -> some View {
        HStack(spacing: 0) {
            ForEach(tabManager.tabs, content: renderTabItem)
        }
    }

    @ViewBuilder private func renderAddNewTabButton() -> some View {
        Image(systemName: "plus")
            .foregroundColor(Color(NSColor.secondaryLabelColor))
            .padding(.horizontal, Constants.addNewTabButtonHorizontalPadding)
            .frame(width: Constants.addNewTabButtonSize)
            .contentShape(Rectangle())
            .onTapGesture {
                tabManager.addNewTab()
            }
            .buttonStyle(PlainButtonStyle())
            .help("New Tab")
    }

    @ViewBuilder private func renderTabItem(_ tab: QuickTerminalTab) -> some View {
        QuickTerminalTabItemView(
            tab: tab,
            isHighlighted: tabManager.currentTab?.id == tab.id,
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

struct QuickTerminalTabDropDelegate: DropDelegate {
    let item: QuickTerminalTab
    let tabManager: QuickTerminalTabManager
    let currentTab: QuickTerminalTab?

    func performDrop(info: DropInfo) -> Bool {
        return true
    }

    func dropEntered(info: DropInfo) {
        guard
            let currentTab,
            let source = tabManager.tabs.firstIndex(where: { $0.id == currentTab.id }),
            let dest = tabManager.tabs.firstIndex(where: { $0.id == item.id })
        else { return }

        if tabManager.tabs[dest].id != currentTab.id {
            let guardedDest = dest > source ? dest + 1 : dest
            tabManager.moveTab(from: IndexSet(integer: source), to: guardedDest)
        }
    }
}

extension QuickTerminalTabBarView {
    enum Constants {
        static let height: CGFloat = 32
        static let addNewTabButtonHorizontalPadding: CGFloat = 8
        static let addNewTabButtonSize: CGFloat = 50
    }
}
