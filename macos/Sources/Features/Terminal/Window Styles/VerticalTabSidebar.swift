import SwiftUI
import Cocoa

/// A vertical tab sidebar that displays tabs in a vertical list.
/// This provides an alternative to the native horizontal tab bar.
struct VerticalTabSidebar: View {
    /// Whether tab color-coding is enabled (read from config by the parent view)
    var tabColorEnabled: Bool

    /// Border color for the selected tab row.
    var selectedBorderColor: Color

    /// The window controller that manages the tabs
    weak var windowController: BaseTerminalController?

    /// Whether the sidebar is on the right side (affects resize handle position)
    var isRightSide: Bool = false

    /// The tab data model that tracks all tabs
    @ObservedObject private var tabModel: TabModel

    /// For the rename dialog
    @State private var isShowingRenameDialog: Bool = false
    @State private var renameText: String = ""
    @State private var windowToRename: NSWindow? = nil

    /// Sidebar width - persisted in UserDefaults
    @AppStorage("verticalTabSidebarWidth") private var sidebarWidth: Double = 200

    /// Whether we're currently resizing
    @State private var isResizing: Bool = false

    /// The tab currently being dragged within the sidebar.
    @State private var draggedWindow: NSWindow? = nil

    /// Minimum and maximum width constraints
    private let minWidth: CGFloat = 120
    private let maxWidth: CGFloat = 400

    init(
        tabColorEnabled: Bool,
        selectedBorderColor: Color,
        windowController: BaseTerminalController?,
        isRightSide: Bool = false
    ) {
        self.tabColorEnabled = tabColorEnabled
        self.selectedBorderColor = selectedBorderColor
        self.windowController = windowController
        self.isRightSide = isRightSide
        self._tabModel = ObservedObject(
            wrappedValue: (windowController as? TerminalController)?.verticalTabModel ?? TabModel()
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            // Resize handle on the left if sidebar is on the right
            if isRightSide {
                resizeHandle
            }

            // Main sidebar content
            VStack(spacing: 0) {
                // Tab list
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(tabModel.tabs) { tab in
                            TabRow(
                                title: tab.title,
                                isSelected: tab.isSelected,
                                keyEquivalent: tab.index < 9 ? "\(tab.index + 1)" : nil,
                                hasCustomTitle: tab.hasCustomTitle,
                                color: tabColorEnabled ? tab.color : nil,
                                selectedBorderColor: selectedBorderColor,
                                onSelect: {
                                    selectTab(tab.window)
                                },
                                onClose: {
                                    closeTab(tab.window)
                                },
                                onRename: {
                                    windowToRename = tab.window
                                    renameText = tab.titleOverride ?? tab.title
                                    isShowingRenameDialog = true
                                },
                                onClearCustomTitle: {
                                    (tab.window.windowController as? BaseTerminalController)?
                                        .titleOverride = nil
                                    refreshTabs()
                                }
                            )
                            .onDrag {
                                draggedWindow = tab.window
                                return NSItemProvider(object: String(describing: tab.id) as NSString)
                            }
                            .onDrop(
                                of: [.text],
                                delegate: TabReorderDropDelegate(
                                    target: tab,
                                    draggedWindow: $draggedWindow,
                                    reorder: reorderTab
                                )
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }

                Divider()

                // Footer with new tab button
                HStack(spacing: 8) {
                    Button(action: createNewTab) {
                        Image(systemName: "plus")
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    .help("New Tab")

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(width: sidebarWidth)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            // Resize handle on the right if sidebar is on the left
            if !isRightSide {
                resizeHandle
            }
        }
        .onAppear {
            refreshTabs()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyVerticalTabsDidChange)) { notification in
            guard shouldRefresh(for: notification) else { return }
            refreshTabs()
        }
        .sheet(isPresented: $isShowingRenameDialog) {
            RenameTabSheet(
                title: $renameText,
                isPresented: $isShowingRenameDialog,
                onSave: {
                    if let window = windowToRename {
                        (window.windowController as? BaseTerminalController)?
                            .titleOverride = renameText.isEmpty ? nil : renameText
                        refreshTabs()
                    }
                }
            )
        }
    }

    /// The resize handle view
    private var resizeHandle: some View {
        ZStack {
            // Subtle border line
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
                .frame(maxHeight: .infinity)

            // Wider invisible hit area for dragging
            Rectangle()
                .fill(isResizing ? Color.accentColor.opacity(0.3) : Color.clear)
                .frame(width: 6)
        }
        .frame(width: 6)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    isResizing = true
                    let delta = isRightSide ? -value.translation.width : value.translation.width
                    let newWidth = sidebarWidth + delta
                    sidebarWidth = min(maxWidth, max(minWidth, newWidth))
                }
                .onEnded { _ in
                    isResizing = false
                }
        )
    }

    // MARK: - Rename Sheet

    struct RenameTabSheet: View {
        @Binding var title: String
        @Binding var isPresented: Bool
        let onSave: () -> Void

        var body: some View {
            VStack(spacing: 16) {
                Text("Rename Tab")
                    .font(.headline)

                TextField("Tab title", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 250)
                    .onSubmit {
                        save()
                    }

                Text("Leave empty to use automatic title")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 12) {
                    Button("Cancel") {
                        isPresented = false
                    }
                    .keyboardShortcut(.escape)

                    Button("Save", action: save)
                        .keyboardShortcut(.return)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .frame(minWidth: 300)
        }

        private func save() {
            onSave()
            isPresented = false
        }
    }

    // MARK: - Tab Data Model

    /// Generate a tab color for the nth tab using golden-ratio hue spacing.
    /// Saturation and brightness also rotate so adjacent tabs don't feel like
    /// the same color treatment with a different hue.
    private static func tabColor(at index: Int) -> Color {
        let goldenRatioConjugate = 0.618033988749895
        let hue = (Double(index) * goldenRatioConjugate).truncatingRemainder(dividingBy: 1.0)
        let saturations = [1.0, 0.92, 0.78, 0.96, 0.84, 0.70]
        let brightnesses = [0.54, 0.70, 0.46, 0.62, 0.78, 0.50]
        let saturation = saturations[index % saturations.count]
        let brightness = brightnesses[(index / saturations.count + index) % brightnesses.count]
        return Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    /// Represents a single tab's data
    struct TabData: Identifiable {
        let id: ObjectIdentifier
        let window: NSWindow
        let titleOverride: String?
        let title: String
        let index: Int
        let isSelected: Bool
        let color: Color
        let colorIndex: Int
        let customTabColor: TerminalTabColor
        let hasCustomTitle: Bool

        init(
            window: NSWindow,
            controller: BaseTerminalController?,
            index: Int,
            isSelected: Bool,
            resolvedTitle: String,
            colorIndex: Int
        ) {
            self.window = window
            self.titleOverride = controller?.titleOverride
            self.index = index
            self.isSelected = isSelected
            self.colorIndex = colorIndex
            self.customTabColor = (window as? TerminalWindow)?.tabColor ?? .none
            if let displayColor = customTabColor.displayColor {
                self.color = Color(nsColor: displayColor)
            } else {
                self.color = VerticalTabSidebar.tabColor(at: colorIndex)
            }
            self.id = ObjectIdentifier(window)
            self.hasCustomTitle = self.titleOverride != nil
            self.title = self.titleOverride ?? resolvedTitle
        }
    }

    /// Observable model that holds the tab list and shared sidebar state.
    class TabModel: ObservableObject {
        @Published var tabs: [TabData] = []
        /// Persistent generated color index assigned to each window for the session.
        var tabColorIndexes: [ObjectIdentifier: Int] = [:]
        /// Index for the next generated tab color.
        var nextColorIndex: Int = 0

        var knownWindowCount: Int {
            max(tabs.count, tabColorIndexes.count)
        }

        func mergeState(from other: TabModel) {
            var usedIndexes = Set(tabColorIndexes.values)
            var nextIndex = max(
                nextColorIndex,
                other.nextColorIndex,
                (usedIndexes.max() ?? -1) + 1)

            for (id, index) in other.tabColorIndexes where tabColorIndexes[id] == nil {
                if !usedIndexes.contains(index) {
                    tabColorIndexes[id] = index
                    usedIndexes.insert(index)
                    nextIndex = max(nextIndex, index + 1)
                    continue
                }

                while usedIndexes.contains(nextIndex) {
                    nextIndex += 1
                }

                tabColorIndexes[id] = nextIndex
                usedIndexes.insert(nextIndex)
                nextIndex += 1
            }

            nextColorIndex = nextIndex
        }

        func colorIndex(for window: NSWindow) -> Int {
            let id = ObjectIdentifier(window)
            if let index = tabColorIndexes[id] {
                return index
            }

            let index = nextColorIndex
            tabColorIndexes[id] = index
            nextColorIndex += 1
            return index
        }
    }

    /// Get the title for a window
    private func resolveTitle(for window: NSWindow, controller: BaseTerminalController?) -> String {
        return controller?.titleOverride ?? window.title
    }

    private func shouldRefresh(for notification: Notification) -> Bool {
        guard let window = windowController?.window else { return true }
        guard let changedWindow = notification.object as? NSWindow else { return true }

        if changedWindow == window {
            return true
        }

        if let tabGroup = window.tabGroup {
            return tabGroup.windows.contains(changedWindow)
        }

        return false
    }

    // MARK: - Tab Row

    private struct TabReorderDropDelegate: DropDelegate {
        let target: TabData
        @Binding var draggedWindow: NSWindow?
        let reorder: (NSWindow, NSWindow) -> Void

        func validateDrop(info: DropInfo) -> Bool {
            draggedWindow != nil && info.hasItemsConforming(to: [.text])
        }

        func dropEntered(info: DropInfo) {
            guard let sourceWindow = draggedWindow else { return }
            guard sourceWindow !== target.window else { return }

            reorder(sourceWindow, target.window)
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            DropProposal(operation: .move)
        }

        func performDrop(info: DropInfo) -> Bool {
            draggedWindow = nil
            return true
        }
    }

    struct TabRow: View {
        let title: String
        let isSelected: Bool
        let keyEquivalent: String?
        let hasCustomTitle: Bool
        let color: Color?
        let selectedBorderColor: Color
        let onSelect: () -> Void
        let onClose: () -> Void
        let onRename: () -> Void
        let onClearCustomTitle: () -> Void

        @State private var isHovering: Bool = false

        private var backgroundFill: Color {
            if let c = color {
                return c.opacity(isSelected ? 0.55 : isHovering ? 0.40 : 0.28)
            }
            if isSelected { return Color.accentColor.opacity(0.2) }
            if isHovering { return Color.primary.opacity(0.05) }
            return Color.clear
        }

        private var borderColor: Color {
            guard isSelected else { return Color.clear }
            return selectedBorderColor
        }

        var body: some View {
            HStack(spacing: 6) {
                // Key equivalent badge
                if let keyEquiv = keyEquivalent {
                    Text("⌘\(keyEquiv)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 28)
                }

                // Custom title indicator
                if hasCustomTitle {
                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.accentColor.opacity(0.7))
                }

                // Tab title
                Text(title.isEmpty ? "Ghostty" : title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundColor(isSelected ? .primary : .secondary)

                Spacer()

                // Close button (shown on hover)
                if isHovering {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Close Tab")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(backgroundFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(borderColor, lineWidth: isSelected ? 2.5 : 0)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                onSelect()
            }
            .simultaneousGesture(
                TapGesture(count: 2)
                    .onEnded {
                        onRename()
                    }
            )
            .onHover { hovering in
                isHovering = hovering
            }
            .contextMenu {
                Button("Rename Tab...") {
                    onRename()
                }
                if hasCustomTitle {
                    Button("Clear Custom Title") {
                        onClearCustomTitle()
                    }
                }
                Divider()
                Button("Close Tab") {
                    onClose()
                }
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Actions

    private func refreshTabs() {
        syncTabModel()

        guard let window = windowController?.window else {
            return
        }
        guard window.isVisible || window.tabGroup != nil else {
            return
        }

        // Get all tabbed windows and the selected one
        let windows: [NSWindow]
        let selectedWindow: NSWindow?

        if let tabGroup = window.tabGroup {
            windows = tabGroup.windows
            selectedWindow = tabGroup.selectedWindow
        } else {
            windows = [window]
            selectedWindow = window
        }

        // If the window list shrank but the "missing" windows are still alive, we're
        // in a transitional state. Skip this tick; the next refresh will have the full list.
        if !tabModel.tabs.isEmpty && windows.count < tabModel.tabs.count {
            let current = Set(windows)
            let hasLivingMissingWindow = tabModel.tabs.contains { tab in
                !current.contains(tab.window) && tab.window.isVisible
            }
            if hasLivingMissingWindow { return }
        }

        // Build the tab data with current titles
        let newTabs = windows.enumerated().map { index, win in
            let controller = win.windowController as? BaseTerminalController
            let resolvedTitle = resolveTitle(for: win, controller: controller)
            let colorIndex = tabModel.colorIndex(for: win)

            return TabData(
                window: win,
                controller: controller,
                index: index,
                isSelected: win == selectedWindow,
                resolvedTitle: resolvedTitle,
                colorIndex: colorIndex
            )
        }

        let changed = newTabs.count != tabModel.tabs.count ||
            zip(newTabs, tabModel.tabs).contains { new, old in
                new.id != old.id ||
                new.isSelected != old.isSelected ||
                new.title != old.title ||
                new.hasCustomTitle != old.hasCustomTitle ||
                new.customTabColor != old.customTabColor ||
                new.colorIndex != old.colorIndex
            }

        if changed {
            tabModel.tabs = newTabs
        }
    }

    private func syncTabModel() {
        guard let sharedModel = (windowController as? TerminalController)?.verticalTabModel,
              sharedModel !== tabModel
        else { return }

        sharedModel.mergeState(from: tabModel)
        tabModel.mergeState(from: sharedModel)
    }

    private func selectTab(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        refreshTabs()
    }

    private func reorderTab(_ sourceWindow: NSWindow, around targetWindow: NSWindow) {
        guard sourceWindow !== targetWindow else { return }
        guard let tabGroup = sourceWindow.tabGroup ?? targetWindow.tabGroup else { return }

        let windows = tabGroup.windows
        guard let sourceIndex = windows.firstIndex(of: sourceWindow),
              let targetIndex = windows.firstIndex(of: targetWindow),
              sourceIndex != targetIndex else { return }

        let selectedWindow = tabGroup.selectedWindow
        let ordering: NSWindow.OrderingMode = targetIndex < sourceIndex ? .below : .above

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0

        tabGroup.removeWindow(sourceWindow)
        targetWindow.addTabbedWindowSafely(sourceWindow, ordered: ordering)
        (selectedWindow ?? sourceWindow).makeKey()

        NSAnimationContext.endGrouping()

        refreshTabs()
        windowController?.postVerticalTabsDidChange()
    }

    private func closeTab(_ window: NSWindow) {
        // If this is the only tab, close the window
        if tabModel.tabs.count <= 1 {
            window.close()
            return
        }

        // Otherwise just close this tab
        window.close()

        // Refresh after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            refreshTabs()
        }
    }

    private func createNewTab() {
        guard let surface = windowController?.focusedSurface?.surface else { return }
        windowController?.ghostty.newTab(surface: surface)

        // Refresh after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            refreshTabs()
        }
    }

}

// MARK: - Preview

#if DEBUG
struct VerticalTabSidebar_Previews: PreviewProvider {
    static var previews: some View {
        VerticalTabSidebar(
            tabColorEnabled: true,
            selectedBorderColor: Color(red: Double(0x39) / 255, green: 1, blue: Double(0x14) / 255),
            windowController: nil
        )
            .frame(height: 400)
    }
}
#endif
