import AppKit
import SwiftUI
import GhosttyKit

struct TerminalSidebarView: View {
    @ObservedObject var ghostty: Ghostty.App

    weak var controller: TerminalController?

    @State private var hoveredID: ObjectIdentifier?
    @State private var refreshNonce = 0
    @State private var width: CGFloat = 281
    @State private var resizeStartWidth: CGFloat?

    private let minimumWidth: CGFloat = 180
    private let maximumWidth: CGFloat = 420

    var body: some View {
        let rows = tabRows

        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Spacer()

                Button {
                    guard let window = controller?.window else { return }
                    _ = TerminalController.newTab(ghostty, from: window)
                    refreshSoon()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("New Tab")
            }
            .padding(.horizontal, 8)
            .frame(height: 30)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(rows) { row in
                        TerminalSidebarRow(
                            row: row,
                            isHovered: hoveredID == row.id,
                            closeAction: {
                                close(row.window)
                            }
                        )
                        .onHover { hovering in
                            hoveredID = hovering ? row.id : nil
                        }
                        .onTapGesture {
                            select(row.window)
                        }
                        .onTapGesture(count: 2) {
                            rename(row.window)
                        }
                        .onDrag {
                            TerminalSidebarDragState.window = row.window
                            return NSItemProvider(object: row.title as NSString)
                        }
                        .onDrop(
                            of: [.plainText],
                            delegate: TerminalSidebarDropDelegate(
                                targetWindow: row.window,
                                refresh: refreshSoon
                            )
                        )
                        .contextMenu {
                            Button("New Tab") {
                                _ = TerminalController.newTab(ghostty, from: row.window)
                                refreshSoon()
                            }

                            Button("Rename Tab") {
                                rename(row.window)
                            }

                            Divider()

                            Button("Move Up") {
                                move(row.window, by: -1)
                            }
                            .disabled(row.index == 0)

                            Button("Move Down") {
                                move(row.window, by: 1)
                            }
                            .disabled(row.index == rows.count - 1)

                            Divider()

                            Button("Close Tab") {
                                close(row.window)
                            }

                            Button("Close Other Tabs") {
                                (row.window.windowController as? TerminalController)?.closeOtherTabs(nil)
                                refreshSoon()
                            }
                            .disabled(rows.count <= 1)

                            Button("Close Tabs Below") {
                                (row.window.windowController as? TerminalController)?.closeTabsOnTheRight(nil)
                                refreshSoon()
                            }
                            .disabled(row.index == rows.count - 1)
                        }
                    }
                }
                .padding(.horizontal, 7)
                .padding(.bottom, 8)
            }
        }
        .frame(width: width)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.clear)
                .frame(width: 6)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let startWidth = resizeStartWidth ?? width
                            resizeStartWidth = startWidth
                            width = min(max(startWidth + value.translation.width, minimumWidth), maximumWidth)
                        }
                        .onEnded { _ in
                            resizeStartWidth = nil
                        }
                )
        }
        .onAppear {
            syncNativeTabBar()
            refreshSoon()
        }
        .onReceive(NotificationCenter.default.publisher(for: TerminalWindow.terminalDidAwake)) { _ in
            refreshSoon()
        }
        .onReceive(NotificationCenter.default.publisher(for: TerminalWindow.terminalWillCloseNotification)) { _ in
            refreshSoon()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeMainNotification)) { _ in
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalWindowBellDidChangeNotification)) { _ in
            refresh()
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            refresh()
        }
    }

    private var tabRows: [TerminalSidebarRow.Model] {
        _ = refreshNonce
        guard let anchorWindow = controller?.window else { return [] }
        let tabGroup = anchorWindow.tabGroup
        let selectedWindow = tabGroup?.selectedWindow ?? anchorWindow
        let windows = tabGroup?.windows ?? [anchorWindow]

        return windows.enumerated().map { index, window in
            let terminalWindow = window as? TerminalWindow
            let terminalController = window.windowController as? BaseTerminalController

            return .init(
                id: ObjectIdentifier(window),
                window: window,
                index: index,
                title: window.title.isEmpty ? "Ghostty" : window.title,
                keyEquivalent: terminalWindow?.keyEquivalent,
                isSelected: window == selectedWindow,
                hasBell: terminalController?.bell ?? false,
                tabColor: terminalWindow?.tabColor ?? .none
            )
        }
    }

    private func select(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshSoon()
    }

    private func rename(_ window: NSWindow) {
        select(window)
        (window.windowController as? BaseTerminalController)?.promptTabTitle()
    }

    private func close(_ window: NSWindow) {
        (window.windowController as? TerminalController)?.closeTab(nil)
        refreshSoon()
    }

    private func move(_ window: NSWindow, by amount: Int) {
        guard let tabGroup = window.tabGroup else { return }
        let windows = tabGroup.windows
        guard let index = windows.firstIndex(of: window) else { return }
        let targetIndex = min(max(index + amount, 0), windows.count - 1)
        guard targetIndex != index else { return }

        TerminalSidebarTabMover.move(window, to: windows[targetIndex])
        refreshSoon()
    }

    private func refresh() {
        syncNativeTabBar()
        refreshNonce &+= 1
    }

    private func refreshSoon() {
        DispatchQueue.main.async {
            self.refresh()
        }
    }

    private func syncNativeTabBar() {
        (controller?.window as? TerminalWindow)?.syncTabBarLocation()
    }
}

private struct TerminalSidebarRow: View {
    struct Model: Identifiable {
        let id: ObjectIdentifier
        let window: NSWindow
        let index: Int
        let title: String
        let keyEquivalent: String?
        let isSelected: Bool
        let hasBell: Bool
        let tabColor: TerminalTabColor
    }

    let row: Model
    let isHovered: Bool
    let closeAction: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            colorIndicator

            Text(row.title)
                .font(.system(size: 12, weight: row.isSelected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(row.isSelected ? Color.primary : Color.secondary)

            Spacer(minLength: 6)

            if row.hasBell {
                Image(systemName: "bell.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .controlAccentColor))
                    .help("Bell")
            }

            if let keyEquivalent = row.keyEquivalent, !keyEquivalent.isEmpty {
                Text(keyEquivalent)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(minWidth: 12, alignment: .trailing)
            }

            Button(action: closeAction) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 15, height: 15)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHovered || row.isSelected ? 1 : 0)
            .help("Close Tab")
        }
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .frame(height: 28)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var colorIndicator: some View {
        if let color = row.tabColor.displayColor {
            Circle()
                .fill(Color(nsColor: color))
                .frame(width: 7, height: 7)
        } else {
            Circle()
                .fill(row.isSelected ? Color(nsColor: .controlAccentColor) : Color(nsColor: .tertiaryLabelColor))
                .frame(width: 6, height: 6)
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(backgroundColor)
    }

    private var backgroundColor: Color {
        if row.isSelected {
            return Color(nsColor: .selectedContentBackgroundColor).opacity(0.28)
        }

        if isHovered {
            return Color(nsColor: .labelColor).opacity(0.06)
        }

        return .clear
    }
}

private enum TerminalSidebarDragState {
    static var window: NSWindow?
}

private struct TerminalSidebarDropDelegate: DropDelegate {
    let targetWindow: NSWindow
    let refresh: () -> Void

    func dropEntered(info: DropInfo) {
        guard let sourceWindow = TerminalSidebarDragState.window,
              sourceWindow != targetWindow
        else { return }

        TerminalSidebarTabMover.move(sourceWindow, to: targetWindow)
        refresh()
    }

    func performDrop(info: DropInfo) -> Bool {
        TerminalSidebarDragState.window = nil
        refresh()
        return true
    }
}

private enum TerminalSidebarTabMover {
    static func move(_ sourceWindow: NSWindow, to targetWindow: NSWindow) {
        guard sourceWindow != targetWindow else { return }
        guard let tabGroup = sourceWindow.tabGroup,
              let targetTabGroup = targetWindow.tabGroup,
              targetTabGroup === tabGroup
        else { return }

        let windows = tabGroup.windows
        guard let sourceIndex = windows.firstIndex(of: sourceWindow),
              let targetIndex = windows.firstIndex(of: targetWindow)
        else { return }

        let ordering: NSWindow.OrderingMode = sourceIndex < targetIndex ? .above : .below

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0

        tabGroup.removeWindow(sourceWindow)
        targetWindow.addTabbedWindowSafely(sourceWindow, ordered: ordering)
        sourceWindow.makeKey()

        NSAnimationContext.endGrouping()

        (sourceWindow.windowController as? TerminalController)?.relabelTabs()
    }
}
