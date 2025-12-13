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
    @State private var tabBeingRenamed: QuickTerminalTab?
    @State private var renameText: String = ""

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
        .sheet(item: $tabBeingRenamed) { tab in
            RenameTabSheet(
                title: $renameText,
                onCancel: { tabBeingRenamed = nil },
                onConfirm: {
                    tab.titleOverride = renameText.isEmpty ? nil : renameText
                    tabBeingRenamed = nil
                }
            )
        }
    }

    @ViewBuilder private func renderTabBar() -> some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(tabManager.tabs.enumerated()), id: \.element.id) { index, tab in
                            renderTabItem(tab, index: index)
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

    @ViewBuilder private func renderTabItem(_ tab: QuickTerminalTab, index: Int) -> some View {
        // Look up the keyboard shortcut for goto_tab:N (1-indexed)
        let tabNumber = index + 1
        let shortcut = tabNumber <= 9 ? tabManager.config?.keyboardShortcut(for: "goto_tab:\(tabNumber)") : nil

        DraggableTabView(
            content: QuickTerminalTabItemView(
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
                shortcut: shortcut
            )
            .modifier(QuickTerminalTabContextMenu(
                tab: tab,
                tabManager: tabManager,
                onChangeTitle: {
                    renameText = tab.titleOverride ?? tab.title
                    tabBeingRenamed = tab
                }
            )),
            tab: tab,
            tabManager: tabManager
        )
        .frame(maxWidth: .infinity)
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

// MARK: - Context Menu

/// A view modifier that adds an AppKit-based context menu to a view.
/// This allows us to use custom views like the color palette in the menu.
private struct QuickTerminalTabContextMenu: ViewModifier {
    let tab: QuickTerminalTab
    let tabManager: QuickTerminalTabManager
    let onChangeTitle: () -> Void

    func body(content: Content) -> some View {
        content.overlay {
            QuickTerminalTabContextMenuHelper(
                tab: tab,
                tabManager: tabManager,
                onChangeTitle: onChangeTitle
            )
        }
    }
}

/// NSViewRepresentable that handles right-click to show custom NSMenu
private struct QuickTerminalTabContextMenuHelper: NSViewRepresentable {
    let tab: QuickTerminalTab
    let tabManager: QuickTerminalTabManager
    let onChangeTitle: () -> Void

    func makeNSView(context: Context) -> QuickTerminalTabContextMenuView {
        let view = QuickTerminalTabContextMenuView()
        view.tab = tab
        view.tabManager = tabManager
        view.onChangeTitle = onChangeTitle
        return view
    }

    func updateNSView(_ nsView: QuickTerminalTabContextMenuView, context: Context) {
        nsView.tab = tab
        nsView.tabManager = tabManager
        nsView.onChangeTitle = onChangeTitle
    }
}

/// Custom NSView that shows context menu on right-click
private class QuickTerminalTabContextMenuView: NSView {
    var tab: QuickTerminalTab?
    var tabManager: QuickTerminalTabManager?
    var onChangeTitle: (() -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let tab = tab, let tabManager = tabManager else { return nil }
        return buildMenu(for: tab, tabManager: tabManager)
    }

    private func buildMenu(for tab: QuickTerminalTab, tabManager: QuickTerminalTabManager) -> NSMenu {
        let menu = NSMenu()

        // Close Tab
        let closeItem = NSMenuItem(title: "Close Tab", action: #selector(closeTab), keyEquivalent: "")
        closeItem.target = self
        closeItem.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        menu.addItem(closeItem)

        // Close Other Tabs
        let closeOthersItem = NSMenuItem(title: "Close Other Tabs", action: #selector(closeOtherTabs), keyEquivalent: "")
        closeOthersItem.target = self
        closeOthersItem.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        menu.addItem(closeOthersItem)

        menu.addItem(NSMenuItem.separator())

        // Change Title...
        let changeTitleItem = NSMenuItem(title: "Change Title...", action: #selector(changeTitle), keyEquivalent: "")
        changeTitleItem.target = self
        changeTitleItem.image = NSImage(systemSymbolName: "pencil.line", accessibilityDescription: nil)
        menu.addItem(changeTitleItem)

        // Tab Color with palette
        let colorPaletteItem = NSMenuItem()
        colorPaletteItem.view = makeTabColorPaletteView(
            selectedColor: tab.tabColor
        ) { [weak tab] color in
            tab?.tabColor = color
            menu.cancelTracking()
        }
        menu.addItem(colorPaletteItem)

        return menu
    }

    @objc private func closeTab() {
        guard let tab = tab else { return }
        tabManager?.closeTab(tab)
    }

    @objc private func closeOtherTabs() {
        guard let tab = tab, let tabManager = tabManager else { return }
        tabManager.tabs.forEach { otherTab in
            if otherTab.id != tab.id {
                tabManager.closeTab(otherTab)
            }
        }
    }

    @objc private func changeTitle() {
        onChangeTitle?()
    }

    private func makeTabColorPaletteView(
        selectedColor: TerminalTabColor,
        selectionHandler: @escaping (TerminalTabColor) -> Void
    ) -> NSView {
        // Shift left to better align with icon-bearing menu items.
        // TabColorMenuView has 12px built-in leading padding; we reduce it slightly.
        let wrappedView = TabColorMenuView(
            selectedColor: selectedColor,
            onSelect: selectionHandler
        ).padding(.leading, -4)

        let hostingView = NSHostingView(rootView: wrappedView)
        hostingView.frame.size = hostingView.intrinsicContentSize
        return hostingView
    }
}

// MARK: - Rename Tab Sheet

private struct RenameTabSheet: View {
    @Binding var title: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Change Tab Title")
                .font(.headline)

            TextField("Tab title", text: $title)
                .textFieldStyle(.roundedBorder)
                .frame(width: 250)

            Text("Leave blank to restore the default.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 12) {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Button("OK", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 300)
    }
}
