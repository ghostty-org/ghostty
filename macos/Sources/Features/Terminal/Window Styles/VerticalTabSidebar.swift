import SwiftUI
import Cocoa

/// A vertical tab sidebar that displays tabs in a vertical list.
/// This provides an alternative to the native horizontal tab bar.
struct VerticalTabSidebar: View {
    /// Whether tab color-coding is enabled (read from config by the parent view)
    var tabColorEnabled: Bool

    /// The window controller that manages the tabs
    weak var windowController: BaseTerminalController?

    /// Whether the sidebar is on the right side (affects resize handle position)
    var isRightSide: Bool = false
    
    /// The tab data model that tracks all tabs
    @ObservedObject private var tabModel: TabModel
    
    /// Timer for refreshing the tab list
    @State private var refreshTimer: Timer?
    
    /// For the rename dialog
    @State private var isShowingRenameDialog: Bool = false
    @State private var renameText: String = ""
    @State private var windowToRename: NSWindow? = nil
    
    /// Sidebar width - persisted in UserDefaults
    @AppStorage("verticalTabSidebarWidth") private var sidebarWidth: Double = 200
    
    /// Whether we're currently resizing
    @State private var isResizing: Bool = false
    
    /// Minimum and maximum width constraints
    private let minWidth: CGFloat = 120
    private let maxWidth: CGFloat = 400

    init(tabColorEnabled: Bool, windowController: BaseTerminalController?, isRightSide: Bool = false) {
        self.tabColorEnabled = tabColorEnabled
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
                                hasCustomTitle: tabModel.getCustomTitle(for: tab.window) != nil,
                                color: tabColorEnabled ? tab.color : nil,
                                onSelect: {
                                    selectTab(tab.window)
                                },
                                onClose: {
                                    closeTab(tab.window)
                                },
                                onRename: {
                                    windowToRename = tab.window
                                    renameText = tabModel.getCustomTitle(for: tab.window) ?? tab.title
                                    isShowingRenameDialog = true
                                },
                                onClearCustomTitle: {
                                    tabModel.clearCustomTitle(for: tab.window)
                                    refreshTabs()
                                }
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
            startRefreshTimer()
        }
        .onDisappear {
            stopRefreshTimer()
        }
        .sheet(isPresented: $isShowingRenameDialog) {
            RenameTabSheet(
                title: $renameText,
                isPresented: $isShowingRenameDialog,
                onSave: {
                    if let window = windowToRename {
                        tabModel.setCustomTitle(renameText.isEmpty ? nil : renameText, for: window)
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
        let id: ObjectIdentifier  // Stable ID based on window identity — title changes update in place
        let window: NSWindow
        let title: String
        let index: Int
        let isSelected: Bool
        let color: Color

        init(window: NSWindow, index: Int, isSelected: Bool, customTitles: [ObjectIdentifier: String], resolvedTitle: String, color: Color) {
            self.window = window
            self.index = index
            self.isSelected = isSelected
            self.color = color
            self.id = ObjectIdentifier(window)

            // Use custom title if set, otherwise use resolved title (based on tab-title-mode)
            let windowId = ObjectIdentifier(window)
            if let customTitle = customTitles[windowId], !customTitle.isEmpty {
                self.title = customTitle
            } else {
                self.title = resolvedTitle
            }
        }
    }

    /// Observable model that holds the tab list and custom titles
    class TabModel: ObservableObject {
        @Published var tabs: [TabData] = []
        /// Custom titles set by the user (keyed by window ObjectIdentifier)
        var customTitles: [ObjectIdentifier: String] = [:]
        /// Persistent color assigned to each window for the session
        var tabColors: [ObjectIdentifier: Color] = [:]
        /// Index into tabColorPalette for the next new window
        var nextColorIndex: Int = 0

        func setCustomTitle(_ title: String?, for window: NSWindow) {
            let id = ObjectIdentifier(window)
            if let title = title, !title.isEmpty {
                customTitles[id] = title
            } else {
                customTitles.removeValue(forKey: id)
            }
        }

        func getCustomTitle(for window: NSWindow) -> String? {
            return customTitles[ObjectIdentifier(window)]
        }

        func clearCustomTitle(for window: NSWindow) {
            customTitles.removeValue(forKey: ObjectIdentifier(window))
        }
    }
    
    /// Get the title for a window
    private func resolveTitle(for window: NSWindow, controller: BaseTerminalController?) -> String {
        return window.title
    }
    
    // MARK: - Tab Row
    
    struct TabRow: View {
        let title: String
        let isSelected: Bool
        let keyEquivalent: String?
        let hasCustomTitle: Bool
        let color: Color?
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
        guard let window = windowController?.window else {
            tabModel.tabs = []
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
        // in a transitional state (e.g. macOS hasn't finished adding the new tab to
        // the tab group yet). Skip this tick — the next refresh will have the full list.
        if !tabModel.tabs.isEmpty && windows.count < tabModel.tabs.count {
            let current = Set(windows)
            let hasLivingMissingWindow = tabModel.tabs.contains { tab in
                !current.contains(tab.window) && tab.window.isVisible
            }
            if hasLivingMissingWindow { return }
        }

        // Assign a persistent color to each window the first time it's seen
        for win in windows {
            let winId = ObjectIdentifier(win)
            if tabModel.tabColors[winId] == nil {
                tabModel.tabColors[winId] = VerticalTabSidebar.tabColor(at: tabModel.nextColorIndex)
                tabModel.nextColorIndex += 1
            }
        }

        // Build the tab data with current titles (using custom titles if set)
        let newTabs = windows.enumerated().map { index, win in
            let controller = win.windowController as? BaseTerminalController
            let resolvedTitle = resolveTitle(for: win, controller: controller)
            let winId = ObjectIdentifier(win)
            let color = tabModel.tabColors[winId] ?? VerticalTabSidebar.tabColor(at: 0)

            return TabData(
                window: win,
                index: index,
                isSelected: win == selectedWindow,
                customTitles: tabModel.customTitles,
                resolvedTitle: resolvedTitle,
                color: color
            )
        }

        // Only update if something visible actually changed to avoid spurious re-renders
        let changed = newTabs.count != tabModel.tabs.count ||
            zip(newTabs, tabModel.tabs).contains { new, old in
                new.id != old.id ||
                new.isSelected != old.isSelected ||
                new.title != old.title
            }

        if changed {
            tabModel.tabs = newTabs
        }
    }
    
    private func selectTab(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        refreshTabs()
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
    
    // MARK: - Timer
    
    private func startRefreshTimer() {
        // Refresh tabs periodically to catch changes
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            refreshTabs()
        }
    }
    
    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}

// MARK: - Preview

#if DEBUG
struct VerticalTabSidebar_Previews: PreviewProvider {
    static var previews: some View {
        VerticalTabSidebar(tabColorEnabled: true, windowController: nil)
            .frame(height: 400)
    }
}
#endif
