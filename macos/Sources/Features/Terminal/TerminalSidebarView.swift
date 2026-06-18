import AppKit
import SwiftUI
import GhosttyKit

struct TerminalSidebarView: View {
    @ObservedObject var ghostty: Ghostty.App

    weak var controller: TerminalController?

    @ObservedObject var spaces: SpacesModel

    @State private var hoveredID: ObjectIdentifier?
    @State private var refreshNonce = 0
    @State private var width: CGFloat = 281
    @State private var resizeStartWidth: CGFloat?
    @State private var isCreatingSpace = false
    @State private var editingSpace: EditingSpace?
    @State private var editorName = ""
    @State private var editorIcon = ""

    private let minimumWidth: CGFloat = 180
    private let maximumWidth: CGFloat = 420

    var body: some View {
        let rows = tabRows

        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(spaces.activeSpace.icon)
                    .font(.system(size: 13))
                Text(spaces.activeSpace.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)

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

                            Menu("Move to Space") {
                                ForEach(spaces.spaces) { space in
                                    Button {
                                        moveTab(row.window, to: space.id)
                                    } label: {
                                        Text("\(space.icon)  \(space.name)")
                                    }
                                    .disabled(space.id == spaces.spaceID(for: ObjectIdentifier(row.window)))
                                }
                            }
                            .disabled(spaces.spaces.count <= 1)

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

            Divider()

            SpaceSwitcherBar(
                spaces: spaces,
                onSelect: { switchToSpace($0) },
                onAdd: {
                    editorName = ""
                    editorIcon = ""
                    isCreatingSpace = true
                },
                onRename: { id in
                    if let space = spaces.space(id) {
                        editorName = space.name
                        editorIcon = space.icon
                        editingSpace = EditingSpace(id: id)
                    }
                },
                onDelete: { id in
                    _ = spaces.delete(id)
                    refreshSoon()
                }
            )
            .popover(isPresented: $isCreatingSpace, arrowEdge: .bottom) {
                SpaceEditorPopover(
                    title: "New Space",
                    name: $editorName,
                    icon: $editorIcon,
                    onConfirm: {
                        let created = spaces.addSpace(
                            name: editorName.isEmpty ? "New Space" : editorName,
                            icon: editorIcon)
                        isCreatingSpace = false
                        switchToSpace(created.id)
                    },
                    onCancel: { isCreatingSpace = false }
                )
            }
            .popover(item: $editingSpace, arrowEdge: .bottom) { editing in
                SpaceEditorPopover(
                    title: "Rename Space",
                    name: $editorName,
                    icon: $editorIcon,
                    onConfirm: {
                        spaces.rename(
                            editing.id,
                            name: editorName.isEmpty ? "Space" : editorName,
                            icon: editorIcon)
                        editingSpace = nil
                        refreshSoon()
                    },
                    onCancel: { editingSpace = nil }
                )
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
            syncSpaces()
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
        let allWindows = tabGroup?.windows ?? [anchorWindow]
        let activeWindows = allWindows.filter {
            spaces.spaceID(for: ObjectIdentifier($0)) == spaces.activeSpaceID
        }

        return activeWindows.enumerated().map { index, window in
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
        // Reorder within the active space's visible tabs only. Other spaces'
        // tabs may be interleaved in the native order and must be skipped, so
        // the chosen neighbor matches what the sidebar actually shows.
        let windows = tabGroup.windows.filter {
            spaces.spaceID(for: ObjectIdentifier($0)) == spaces.activeSpaceID
        }
        guard let index = windows.firstIndex(of: window) else { return }
        let targetIndex = min(max(index + amount, 0), windows.count - 1)
        guard targetIndex != index else { return }

        TerminalSidebarTabMover.move(window, to: windows[targetIndex])
        refreshSoon()
    }

    private func refresh() {
        syncNativeTabBar()
        syncSpaces()
        refreshNonce &+= 1
    }

    private func syncSpaces() {
        guard let anchorWindow = controller?.window else { return }
        let windows = anchorWindow.tabGroup?.windows ?? [anchorWindow]
        spaces.sync(liveWindows: windows.map(ObjectIdentifier.init))
        let selected = anchorWindow.tabGroup?.selectedWindow ?? anchorWindow
        // The front/selected window always belongs to the active space (the switch
        // and move logic maintain this), so noting it records the active space's
        // last-active tab for restore-on-switch.
        spaces.noteActiveWindow(ObjectIdentifier(selected))
    }

    private func refreshSoon() {
        DispatchQueue.main.async {
            self.refresh()
        }
    }

    private func syncNativeTabBar() {
        (controller?.window as? TerminalWindow)?.syncTabBarLocation()
    }

    private func switchToSpace(_ id: Space.ID) {
        spaces.setActive(id)

        guard let anchorWindow = controller?.window else {
            refreshSoon()
            return
        }

        // Bring the space's most-recent (or first) tab to front. If the space
        // is empty, create a fresh tab so the terminal is never blank.
        if !selectLastActiveTab(in: id, anchorWindow: anchorWindow) {
            _ = TerminalController.newTab(ghostty, from: anchorWindow)
            refreshSoon()
        }
    }

    private func moveTab(_ window: NSWindow, to id: Space.ID) {
        let movedKey = ObjectIdentifier(window)
        let wasActiveSpace = spaces.spaceID(for: movedKey) == spaces.activeSpaceID
        spaces.move(movedKey, to: id)

        // If we moved the front tab out of the active space and the active
        // space is now empty, follow the tab into its new space.
        if wasActiveSpace, spaces.isEmpty(spaces.activeSpaceID) {
            switchToSpace(id)
            return
        }

        // If we moved the currently-selected tab elsewhere, select another
        // tab still in the active space so the terminal matches the sidebar.
        if wasActiveSpace,
           let anchorWindow = controller?.window,
           selectLastActiveTab(in: spaces.activeSpaceID, anchorWindow: anchorWindow) {
            return
        }

        refreshSoon()
    }

    /// Bring the given space's last-active (or first) tab to the front.
    /// Returns false if the space currently has no tabs.
    @discardableResult
    private func selectLastActiveTab(in id: Space.ID, anchorWindow: NSWindow) -> Bool {
        let allWindows = anchorWindow.tabGroup?.windows ?? [anchorWindow]
        let keys = allWindows.map(ObjectIdentifier.init)
        guard let targetKey = spaces.lastActiveWindow(in: id, from: keys),
              let target = allWindows.first(where: { ObjectIdentifier($0) == targetKey })
        else { return false }
        select(target)
        return true
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

private struct SpaceSwitcherBar: View {
    @ObservedObject var spaces: SpacesModel
    let onSelect: (Space.ID) -> Void
    let onAdd: () -> Void
    let onRename: (Space.ID) -> Void
    let onDelete: (Space.ID) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(spaces.spaces) { space in
                Button {
                    onSelect(space.id)
                } label: {
                    Text(space.icon)
                        .font(.system(size: 14))
                        .frame(width: 28, height: 28)
                        .background(background(for: space))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(space.name)
                .accessibilityLabel(space.name)
                .contextMenu {
                    Button("Rename Space…") { onRename(space.id) }
                    Button("Delete Space") { onDelete(space.id) }
                        .disabled(!spaces.canDelete(space.id))
                }
            }

            Spacer(minLength: 0)

            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New Space")
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
    }

    private func background(for space: Space) -> Color {
        space.id == spaces.activeSpaceID
            ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.28)
            : .clear
    }
}

private struct EditingSpace: Identifiable {
    let id: Space.ID
}

private struct SpaceEditorPopover: View {
    let title: String
    @Binding var name: String
    @Binding var icon: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))

            HStack(spacing: 8) {
                TextField("💻", text: $icon)
                    .frame(width: 44)
                    .multilineTextAlignment(.center)
                    // Clamp to two grapheme clusters while typing, but let an
                    // empty field stay empty (don't substitute the "•" fallback
                    // mid-edit — that only applies when a Space is constructed).
                    .onChange(of: icon) { newValue in
                        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            icon = String(trimmed.prefix(2))
                        }
                    }
                    .onSubmit(onConfirm)

                TextField("Name", text: $name)
                    .frame(width: 160)
                    .onSubmit(onConfirm)
            }
            .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Done", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(width: 240)
    }
}
