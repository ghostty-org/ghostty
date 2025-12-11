import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Custom UTType for quick terminal tab drag and drop operations.
    /// This prevents tab UUIDs from being pasted into the terminal when
    /// a tab is accidentally dropped onto the terminal surface.
    static let quickTerminalTab = UTType(exportedAs: "com.mitchellh.ghostty.quickterminal.tab")
}

struct QuickTerminalTabBarView: View {
    @ObservedObject var tabManager: QuickTerminalTabManager

    @State private var isHoveringNewTabButton = false

    private var newTabButtonBackgroundColor: Color {
        if isHoveringNewTabButton {
            Color(NSColor.underPageBackgroundColor)
        } else {
            Color(NSColor.controlBackgroundColor)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            renderTabBar()
            renderAddNewTabButton()
        }
        .frame(height: Constants.height)
        .background(Color(NSColor.controlBackgroundColor))
    }

    @ViewBuilder private func renderTabBar() -> some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(tabManager.tabs) { tab in
                            renderTabItem(tab)
                                .id(tab.id)
                        }
                    }
                    .frame(minWidth: geometry.size.width)
                }
                .onChange(of: tabManager.currentTab?.id) { newTabId in
                    if let tabId = newTabId {
                        withAnimation {
                            proxy.scrollTo(tabId, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func renderAddNewTabButton() -> some View {
        Image(systemName: "plus")
            .foregroundColor(Color(NSColor.secondaryLabelColor))
            .padding(.horizontal, Constants.addNewTabButtonHorizontalPadding)
            .frame(width: Constants.height, height: Constants.height)
            .background(
                Rectangle()
                    .fill(newTabButtonBackgroundColor)
            )
            .onHover { isHovering in
                isHoveringNewTabButton = isHovering
            }
            .onTapGesture {
                tabManager.addNewTab()
            }
            .buttonStyle(PlainButtonStyle())
            .help("Create a new Tab")
    }

    @ViewBuilder private func renderTabItem(_ tab: QuickTerminalTab) -> some View {
        QuickTerminalTabItemView(
            tab: tab,
            isHighlighted: tabManager.currentTab?.id == tab.id,
            onSelect: { tabManager.selectTab(tab) },
            onClose: {
                if NSEvent.modifierFlags.contains(.option) {
                    tabManager.closeAllTabs(except: tab)
                } else {
                    tabManager.closeTab(tab)
                }
            },
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
        .frame(maxWidth: .infinity)
        .onDrag {
            tabManager.draggedTab = tab
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: UTType.quickTerminalTab.identifier, visibility: .ownProcess) { completion in
                let data = tab.id.uuidString.data(using: .utf8)
                completion(data, nil)
                return nil
            }
            return provider
        }
        .onDrop(
            of: [.quickTerminalTab],
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
        // Clear the dragged tab state since drop was successful
        tabManager.draggedTab = nil
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

    func dropExited(info: DropInfo) {
        // Don't clear draggedTab here - let the event monitor handle drops outside the window
    }
}

extension QuickTerminalTabBarView {
    enum Constants {
        static let height: CGFloat = 24
        static let addNewTabButtonHorizontalPadding: CGFloat = 8
        static let addNewTabButtonSize: CGFloat = 50
    }
}
