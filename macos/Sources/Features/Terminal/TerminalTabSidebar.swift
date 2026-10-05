import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted when the tabs of any terminal window may have changed: their order, titles,
    /// colors, key equivalents, or which one is selected.
    static let terminalTabsDidChange = Notification.Name("com.mitchellh.ghostty.terminalTabsDidChange")
}

/// The tabs of one terminal window's tab group, as listed by the vertical tab sidebar.
///
/// Every tab is its own window, so each window owns a model and shows its own copy of the
/// sidebar. Only the selected tab's window is on screen, so that is the copy the user sees.
final class TerminalTabSidebarModel: ObservableObject {
    struct Tab: Identifiable, Equatable {
        let id: ObjectIdentifier

        /// The 1-based position of the tab in its window.
        let index: Int
        let title: String
        let keyEquivalent: String?
        let color: TerminalTabColor
        let isSelected: Bool
    }

    @Published private(set) var tabs: [Tab] = []

    /// The window this sidebar is shown in.
    weak var window: NSWindow? {
        didSet { refresh() }
    }

    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .terminalTabsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()

            // The tab group takes an event loop cycle to settle after a tab is added or closed.
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// The windows in our tab group in tab order. A window that isn't tabbed is its own only tab.
    private var tabWindows: [NSWindow] {
        guard let window else { return [] }
        return window.tabbedWindows ?? [window]
    }

    func refresh() {
        let newTabs = tabWindows.enumerated().map { offset, tabWindow in
            let terminalWindow = tabWindow as? TerminalWindow
            let keyEquivalent = terminalWindow?.keyEquivalent ?? ""
            return Tab(
                id: ObjectIdentifier(tabWindow),
                index: offset + 1,
                title: tabWindow.title,
                keyEquivalent: keyEquivalent.isEmpty ? nil : keyEquivalent,
                color: terminalWindow?.tabColor ?? .none,
                // Our window is only on screen while it is the selected tab.
                isSelected: tabWindow === window
            )
        }

        guard newTabs != tabs else { return }
        tabs = newTabs
    }

    func newTab() {
        (window?.windowController as? TerminalController)?.newTab(nil)
    }

    func select(_ tab: Tab) {
        tabWindow(for: tab)?.makeKeyAndOrderFront(nil)
    }

    func close(_ tab: Tab) {
        controller(for: tab)?.closeTab(nil)
    }

    func closeOthers(_ tab: Tab) {
        select(tab)
        controller(for: tab)?.closeOtherTabs(nil)
    }

    func promptTitle(_ tab: Tab) {
        select(tab)
        controller(for: tab)?.promptTabTitle()
    }

    private func tabWindow(for tab: Tab) -> NSWindow? {
        tabWindows.first { ObjectIdentifier($0) == tab.id }
    }

    private func controller(for tab: Tab) -> TerminalController? {
        tabWindow(for: tab)?.windowController as? TerminalController
    }
}

/// Places the vertical tab sidebar beside a terminal window's content.
struct TerminalTabSidebarLayout<Content: View>: View {
    @ObservedObject var model: TerminalTabSidebarModel
    @ObservedObject var ghostty: Ghostty.App
    let content: Content

    @AppStorage(TerminalTabSidebar.collapsedKey) private var isCollapsed = false
    @AppStorage(TerminalTabSidebar.widthKey) private var width = TerminalTabSidebar.defaultWidth

    /// The sidebar width when the current resize drag began.
    @State private var widthAtDragStart: Double?

    init(model: TerminalTabSidebarModel, ghostty: Ghostty.App, @ViewBuilder content: () -> Content) {
        self.model = model
        self.ghostty = ghostty
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            TerminalTabSidebar(model: model, isCollapsed: $isCollapsed)
                .frame(width: isCollapsed ? TerminalTabSidebar.collapsedWidth : width)
                .background(ghostty.config.backgroundColor.opacity(ghostty.config.backgroundOpacity))
                .environment(\.colorScheme, NSColor(ghostty.config.backgroundColor).isLightColor ? .light : .dark)

            divider

            content
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.15))
            .frame(width: TerminalTabSidebar.dividerWidth)
            .overlay {
                if !isCollapsed {
                    // A wider invisible strip so the divider is easy to grab.
                    Color.clear
                        .frame(width: 7)
                        .contentShape(Rectangle())
                        .gesture(resizeGesture)
                        .onHover { isHovering in
                            if isHovering {
                                NSCursor.resizeLeftRight.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                }
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let start = widthAtDragStart ?? width
                widthAtDragStart = start
                let range = TerminalTabSidebar.widthRange
                width = min(max(start + value.translation.width, range.lowerBound), range.upperBound)
            }
            .onEnded { _ in
                widthAtDragStart = nil
            }
    }
}

/// The vertical list of a terminal window's tabs, replacing the native tab bar.
struct TerminalTabSidebar: View {
    static let collapsedKey = "TerminalTabSidebarCollapsed"
    static let widthKey = "TerminalTabSidebarWidth"
    static let defaultWidth: Double = 200
    static let widthRange: ClosedRange<Double> = 120...400
    static let collapsedWidth: Double = 36
    static let dividerWidth: Double = 1

    /// The width the sidebar and its divider currently take out of a window's content.
    static var occupiedWidth: CGFloat {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: collapsedKey) {
            return collapsedWidth + dividerWidth
        }

        let width = defaults.object(forKey: widthKey) as? Double ?? defaultWidth
        return width + dividerWidth
    }

    @ObservedObject var model: TerminalTabSidebarModel
    @Binding var isCollapsed: Bool

    var body: some View {
        VStack(spacing: 0) {
            if isCollapsed {
                VStack(spacing: 2) {
                    collapseButton
                    newTabButton
                }
                .padding(.top, 4)
                .padding(.bottom, 4)

                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 2) {
                        ForEach(model.tabs) { tab in
                            TerminalTabSidebarRow(model: model, tab: tab, isCompact: true)
                        }
                    }
                    .padding(.bottom, 6)
                }
            } else {
                HStack {
                    collapseButton
                    Spacer()
                    newTabButton
                }
                .padding(.horizontal, 6)
                .frame(height: 36)

                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.tabs) { tab in
                            TerminalTabSidebarRow(model: model, tab: tab, isCompact: false)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var collapseButton: some View {
        TerminalTabSidebarButton(
            systemName: "sidebar.left",
            label: isCollapsed ? "Show Tab Sidebar" : "Hide Tab Sidebar"
        ) {
            isCollapsed.toggle()
        }
    }

    private var newTabButton: some View {
        TerminalTabSidebarButton(systemName: "plus", label: "New Tab") {
            model.newTab()
        }
    }
}

/// An icon button in the tab sidebar. The click target is the whole padded square, not
/// just the glyph, and it highlights on hover so the target is visible.
private struct TerminalTabSidebarButton: View {
    let systemName: String
    let label: String
    var glyphSize: CGFloat = 13
    var targetSize: CGFloat = 28
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: glyphSize, weight: .medium))
                .frame(width: targetSize, height: targetSize)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(isHovering ? 0.12 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// One tab in the sidebar: a full row when the sidebar is expanded, or a numbered tile
/// in the collapsed rail.
private struct TerminalTabSidebarRow: View {
    let model: TerminalTabSidebarModel
    let tab: TerminalTabSidebarModel.Tab
    let isCompact: Bool

    @State private var isHovering = false

    var body: some View {
        content
            .font(.system(size: 12))
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(tab.isSelected ? 0.14 : (isHovering ? 0.07 : 0)))
            )
            .contentShape(Rectangle())
            .onTapGesture { model.select(tab) }
            .onHover { isHovering = $0 }
            .help(isCompact ? tab.title : "")
            .contextMenu {
                Button("Close Tab") { model.close(tab) }
                Button("Close Other Tabs") { model.closeOthers(tab) }
                Divider()
                Button("Change Tab Title...") { model.promptTitle(tab) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(tab.title)
            .accessibilityAddTraits(tab.isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { model.select(tab) }
    }

    @ViewBuilder
    private var content: some View {
        if isCompact {
            tile
        } else {
            row
        }
    }

    private var tile: some View {
        Text("\(tab.index)")
            .foregroundStyle(tab.isSelected ? .primary : .secondary)
            .frame(width: 28, height: 28)
            .overlay(alignment: .topTrailing) {
                if let color = tab.color.displayColor {
                    Circle()
                        .fill(Color(nsColor: color))
                        .frame(width: 6, height: 6)
                        .padding(3)
                }
            }
    }

    private var row: some View {
        HStack(spacing: 6) {
            if let color = tab.color.displayColor {
                Circle()
                    .fill(Color(nsColor: color))
                    .frame(width: 8, height: 8)
            }

            Text(tab.title)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if isHovering {
                TerminalTabSidebarButton(
                    systemName: "xmark",
                    label: "Close Tab",
                    glyphSize: 9,
                    targetSize: 22
                ) {
                    model.close(tab)
                }
            } else if let keyEquivalent = tab.keyEquivalent {
                Text(keyEquivalent)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 5)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 3)
        .frame(height: 28)
    }
}
