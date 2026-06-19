import AppKit
import SwiftUI
import GhosttyKit

struct TerminalSidebarView: View {
    @ObservedObject var ghostty: Ghostty.App

    weak var controller: TerminalController?

    @ObservedObject var spaces: SpacesModel

    @State private var hoveredID: ObjectIdentifier?
    @State private var refreshNonce = 0
    @State private var lastSignature = ""
    @State private var resizeStartWidth: CGFloat?
    @State private var spaceEditor: SpaceEditor?
    @State private var editorName = ""
    @State private var editorIcon = ""

    private let minimumWidth: CGFloat = 180
    private let maximumWidth: CGFloat = 420
    private static let defaultSpaceName = "New Space"

    var body: some View {
        let rows = tabRows

        VStack(spacing: 0) {
            HStack(spacing: 6) {
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
                                        Label(space.name, systemImage: space.icon)
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
                                closeOtherTabs(keeping: row.window, in: rows)
                            }
                            .disabled(rows.count <= 1)

                            Button("Close Tabs Below") {
                                closeTabsBelow(row, in: rows)
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
                    editorIcon = Space.defaultIcon
                    spaceEditor = .create
                },
                onRename: { id in
                    if let space = spaces.space(id) {
                        editorName = space.name
                        editorIcon = space.icon
                        spaceEditor = .rename(id)
                    }
                },
                onDelete: { id in
                    deleteSpace(id)
                }
            )
            // A single popover handles both create and rename. Two separate
            // popovers on one view conflict on macOS and can present the wrong
            // one, so the mode is carried in `spaceEditor`.
            .popover(item: $spaceEditor, arrowEdge: .bottom) { editor in
                SpaceEditorPopover(
                    title: editor.isCreate ? "Create a Space" : "Rename Space",
                    name: $editorName,
                    icon: $editorIcon,
                    onConfirm: {
                        switch editor {
                        case .create:
                            let created = spaces.addSpace(
                                name: editorName.isEmpty ? Self.defaultSpaceName : editorName,
                                icon: editorIcon)
                            spaceEditor = nil
                            switchToSpace(created.id)
                        case .rename(let id):
                            spaces.rename(
                                id,
                                name: editorName.isEmpty ? Self.defaultSpaceName : editorName,
                                icon: editorIcon)
                            spaceEditor = nil
                            refreshSoon()
                        }
                    },
                    onCancel: { spaceEditor = nil }
                )
            }
        }
        .frame(width: spaces.sidebarWidth)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.clear)
                .frame(width: 6)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let startWidth = resizeStartWidth ?? spaces.sidebarWidth
                            resizeStartWidth = startWidth
                            spaces.sidebarWidth = min(max(startWidth + value.translation.width, minimumWidth), maximumWidth)
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
        .onReceive(NotificationCenter.default.publisher(for: TerminalWindow.terminalWillCloseNotification)) { notification in
            handleTabWillClose(notification.object as? NSWindow)
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
        let selectedWindow = anchorWindow.tabGroup?.selectedWindow ?? anchorWindow

        return windows(in: spaces.activeSpaceID).enumerated().map { index, window in
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

    /// Like select() but without force-activating the app — for programmatic
    /// pre-selection (e.g. bulk close from a possibly-background window).
    private func selectQuiet(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        refreshSoon()
    }

    private func rename(_ window: NSWindow) {
        select(window)
        (window.windowController as? BaseTerminalController)?.promptTabTitle()
    }

    /// Windows in the controller's tab group assigned to `id`, in tab order.
    private func windows(in id: Space.ID) -> [NSWindow] {
        let all = controller?.window?.tabGroup?.windows ?? [controller?.window].compactMap { $0 }
        return all.filter { spaces.spaceID(for: ObjectIdentifier($0)) == id }
    }

    private func close(_ window: NSWindow) {
        // Just close. Keeping the user in the space (selecting a same-space
        // sibling) is handled centrally in handleTabWillClose, so every close
        // path — sidebar X, context menu, native ⌘W, split close — behaves the
        // same, and we never mutate space state before the (cancellable) close.
        (window.windowController as? TerminalController)?.closeTab(nil)
        refreshSoon()
    }

    /// Close a set of tabs with ONE aggregated confirmation (matching native
    /// bulk close) instead of a confirm sheet per tab. After the user confirms
    /// once, all close immediately so a per-tab cancel can't half-finish it.
    private func closeWindows(_ targets: [NSWindow]) {
        guard !targets.isEmpty else { return }
        let doClose = {
            for window in targets {
                (window.windowController as? TerminalController)?.closeTabImmediately()
            }
            refreshSoon()
        }
        let needsConfirm = targets.contains { window in
            (window.windowController as? BaseTerminalController)?
                .surfaceTree.contains(where: { $0.needsConfirmQuit }) ?? false
        }
        if needsConfirm {
            let count = targets.count
            controller?.confirmClose(
                messageText: "Close \(count) Tab\(count == 1 ? "" : "s")?",
                informativeText: "At least one has a running process that will be killed."
            ) { doClose() }
        } else {
            doClose()
        }
    }

    /// Close every tab in the active space except `window`.
    private func closeOtherTabs(keeping window: NSWindow, in rows: [TerminalSidebarRow.Model]) {
        selectQuiet(window)
        closeWindows(rows.filter { $0.window != window }.map(\.window))
    }

    /// Close every tab in the active space below `row` in the sidebar's order.
    private func closeTabsBelow(_ row: TerminalSidebarRow.Model, in rows: [TerminalSidebarRow.Model]) {
        selectQuiet(row.window)
        closeWindows(rows.filter { $0.index > row.index }.map(\.window))
    }

    /// When the frontmost tab is about to close, select a same-space sibling
    /// first so we stay in the space. Closing a background tab leaves the
    /// selection alone; closing a space's last tab selects nothing here, so
    /// AppKit picks the next window and the active space follows it (the emptied
    /// space is then pruned). One handler for every close path (X, ⌘W, split).
    private func handleTabWillClose(_ closing: NSWindow?) {
        defer { refreshSoon() }
        guard let closing,
              let tabGroup = controller?.window?.tabGroup,
              tabGroup.selectedWindow == closing,
              let spaceID = spaces.spaceID(for: ObjectIdentifier(closing)),
              let sibling = tabGroup.windows.first(where: {
                  $0 != closing && spaces.spaceID(for: ObjectIdentifier($0)) == spaceID
              })
        else { return }
        sibling.makeKeyAndOrderFront(nil)
    }

    /// Delete a space: confirm, then close its tabs. The emptied space is removed
    /// by the post-close prune (so a cancelled close can't orphan a tab in a
    /// deleted space). An already-empty space is removed immediately, since the
    /// prune deliberately keeps the active space.
    private func deleteSpace(_ id: Space.ID) {
        guard let anchorWindow = controller?.window, let space = spaces.space(id) else { return }
        let spaceWindows = windows(in: id)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete the “\(space.name)” space?"
        alert.informativeText = spaceWindows.isEmpty
            ? "This space has no tabs."
            : "This will close \(spaceWindows.count) tab\(spaceWindows.count == 1 ? "" : "s") in this space."
        alert.addButton(withTitle: "Delete Space")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: anchorWindow) { response in
            guard response == .alertFirstButtonReturn else { return }
            if spaceWindows.isEmpty {
                spaces.removeSpace(id)
            } else {
                // Bring a surviving-space tab to front first, so the deleted
                // space's tabs close as background tabs (no per-tab focus
                // bounce). The single confirmation above already covered them,
                // so close immediately (no per-tab re-prompt).
                if let survivor = anchorWindow.tabGroup?.windows.first(where: {
                    spaces.spaceID(for: ObjectIdentifier($0)) != id
                }) {
                    selectQuiet(survivor)
                }
                for window in spaceWindows {
                    (window.windowController as? TerminalController)?.closeTabImmediately()
                }
            }
            refreshSoon()
        }
    }

    private func move(_ window: NSWindow, by amount: Int) {
        // Reorder within the active space's visible tabs only (other spaces' tabs
        // are interleaved in native order and must be skipped). The mover only
        // re-keys the window if it was already selected, so reordering a
        // background tab leaves the selection put.
        let spaceWindows = windows(in: spaces.activeSpaceID)
        guard let index = spaceWindows.firstIndex(of: window) else { return }
        let targetIndex = min(max(index + amount, 0), spaceWindows.count - 1)
        guard targetIndex != index else { return }

        TerminalSidebarTabMover.move(window, to: spaceWindows[targetIndex])
        refreshSoon()
    }

    /// The single refresh path. The active space always follows the frontmost
    /// window (the sole writer of `activeSpaceID`), so the sidebar and the
    /// visible terminal can never diverge regardless of how the front window
    /// changed — sidebar switch, native ⌘1-9, a close, a delete. Reconcile runs
    /// before the empty-space prune so a space whose last tab just closed (now
    /// non-active) is removed in the same cycle. Running on every event,
    /// including the timer, means it always converges even without a key
    /// notification.
    private func refresh() {
        syncNativeTabBar()
        syncSpaces()
        reconcileActiveSpace()
        spaces.pruneEmptySpaces()
        bumpIfChanged()
    }

    /// Re-render only when the displayed data actually changed. The 0.5s timer
    /// calls refresh() constantly; bumping `refreshNonce` every tick re-evaluated
    /// `body` and rebuilt the row context menus, which made an open "Move to
    /// Space" submenu flash and become unclickable. Comparing a cheap signature
    /// of what the sidebar shows avoids those no-op re-renders.
    private func bumpIfChanged() {
        let signature = currentSignature()
        guard signature != lastSignature else { return }
        lastSignature = signature
        refreshNonce &+= 1
    }

    /// A string fingerprint of everything the sidebar renders, so `bumpIfChanged`
    /// can skip re-renders when nothing visible changed.
    private func currentSignature() -> String {
        guard let anchorWindow = controller?.window else { return "" }
        let selected = anchorWindow.tabGroup?.selectedWindow ?? anchorWindow

        var parts: [String] = [spaces.activeSpaceID.uuidString]
        for space in spaces.spaces {
            parts.append("\(space.id.uuidString)\u{1}\(space.name)\u{1}\(space.icon)")
        }
        for window in windows(in: spaces.activeSpaceID) {
            let terminalWindow = window as? TerminalWindow
            let terminalController = window.windowController as? BaseTerminalController
            parts.append([
                String(UInt(bitPattern: ObjectIdentifier(window).hashValue)),
                window.title,
                window == selected ? "1" : "0",
                (terminalController?.bell ?? false) ? "1" : "0",
                terminalWindow?.keyEquivalent ?? "",
                String(describing: terminalWindow?.tabColor ?? .none),
            ].joined(separator: "\u{1}"))
        }
        return parts.joined(separator: "\u{2}")
    }

    /// Make the active space follow the frontmost window, if that window has a
    /// known assignment that differs from the current active space. This is the
    /// only place `activeSpaceID` changes, so there is never a fight between an
    /// optimistic switch and the front window — actions just bring the right
    /// window to front and the active space follows.
    private func reconcileActiveSpace() {
        guard let anchorWindow = controller?.window else { return }
        let selected = anchorWindow.tabGroup?.selectedWindow ?? anchorWindow
        if let id = spaces.spaceID(for: ObjectIdentifier(selected)), id != spaces.activeSpaceID {
            spaces.setActive(id)
        }
    }

    private func syncSpaces() {
        guard let anchorWindow = controller?.window else { return }
        if let tabGroup = anchorWindow.tabGroup {
            // Authoritative full window list -> safe to prune dead windows.
            spaces.sync(liveWindows: tabGroup.windows.map(ObjectIdentifier.init))
            let selected = tabGroup.selectedWindow ?? anchorWindow
            spaces.noteActiveWindow(ObjectIdentifier(selected))
        } else {
            // Only a partial view (standalone window, or this window is being
            // torn down): NEVER prune the shared model from here — doing so
            // would drop every other window's assignment and collapse all tabs
            // into the active space. Just register this window.
            spaces.registerIfNeeded(ObjectIdentifier(anchorWindow))
            spaces.noteActiveWindow(ObjectIdentifier(anchorWindow))
        }
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
        guard let anchorWindow = controller?.window else { return }

        // Bring the space's most-recent (or first) tab to front. Since that
        // window is now front AND assigned to `id`, writing the active space
        // synchronously can't diverge from the front window — it's instant and
        // reconcile later agrees. If the space is empty (just created), make a
        // tab in it and assign it; reconcile activates the space once that tab
        // is frontmost (no optimistic write, so nothing can revert it).
        if selectLastActiveTab(in: id, anchorWindow: anchorWindow) {
            spaces.setActive(id)
        } else {
            if let created = TerminalController.newTab(ghostty, from: anchorWindow),
               let newWindow = created.window {
                spaces.move(ObjectIdentifier(newWindow), to: id)
            } else {
                // A tab couldn't be created (e.g. non-native fullscreen); drop
                // the just-created empty space rather than strand it.
                spaces.removeSpace(id)
            }
            refreshSoon()
        }
    }

    private func moveTab(_ window: NSWindow, to id: Space.ID) {
        // Only re-home focus if the user moved the tab they were looking at.
        // Moving a background tab must not steal focus / activate the app.
        let wasSelected = window == window.tabGroup?.selectedWindow
        spaces.move(ObjectIdentifier(window), to: id)

        // If the moved tab was the front one and the active space still has other
        // tabs, bring one of them to front so the terminal matches the active
        // space. If the active space is now empty, the moved tab is still front
        // and now in `id`, so reconcile simply follows it into its new space —
        // do NOT select a sibling (that would background the just-moved tab).
        if wasSelected, !spaces.isEmpty(spaces.activeSpaceID),
           let anchorWindow = controller?.window {
            selectLastActiveTab(in: spaces.activeSpaceID, anchorWindow: anchorWindow)
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
    // Weak: a live drag is strongly referenced elsewhere, so a cancelled drag
    // (released off any row, so performDrop never clears it) can't retain a
    // closed window (and, via the weakly-keyed store, its SpacesModel).
    static weak var window: NSWindow?
}

private struct TerminalSidebarDropDelegate: DropDelegate {
    let targetWindow: NSWindow
    let refresh: () -> Void

    func performDrop(info: DropInfo) -> Bool {
        // Commit the reorder once, on drop — not on every dropEntered hover
        // (which fired a full tab-group mutation + makeKey per row crossed,
        // stealing focus mid-drag).
        if let sourceWindow = TerminalSidebarDragState.window,
           sourceWindow != targetWindow {
            TerminalSidebarTabMover.move(sourceWindow, to: targetWindow)
        }
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
        // Removing the source can drop selection; only restore it to the source
        // if it was the selected tab. Reordering a background tab keeps the
        // current selection put (no focus steal).
        let wasSelected = tabGroup.selectedWindow == sourceWindow

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0

        tabGroup.removeWindow(sourceWindow)
        targetWindow.addTabbedWindowSafely(sourceWindow, ordered: ordering)
        if wasSelected { sourceWindow.makeKey() }

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
            Spacer(minLength: 0)

            ForEach(spaces.spaces) { space in
                Button {
                    onSelect(space.id)
                } label: {
                    Image(systemName: space.icon)
                        .font(.system(size: 14))
                        .frame(width: 28, height: 28)
                        .foregroundStyle(Color.primary)
                        // No box around the active space (Arc-style): the active
                        // icon is full strength, the others are muted.
                        .opacity(space.id == spaces.activeSpaceID ? 1.0 : 0.4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(space.name)
                .accessibilityLabel(space.name)
                .contextMenu {
                    Button("Rename Space…") { onRename(space.id) }
                    Button("Delete Space", role: .destructive) { onDelete(space.id) }
                        .disabled(spaces.spaces.count <= 1)
                }
            }

            Spacer(minLength: 0)
        }
        // The space icons stay centered; the add button floats on the right.
        .overlay(alignment: .trailing) {
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
}

/// Which space-editor popover is open. A single `.popover(item:)` is driven by
/// this so create and rename can't conflict (two popovers on one macOS view do).
private enum SpaceEditor: Identifiable {
    case create
    case rename(Space.ID)

    var id: String {
        switch self {
        case .create: return "create"
        case .rename(let spaceID): return "rename-\(spaceID)"
        }
    }

    var isCreate: Bool {
        if case .create = self { return true }
        return false
    }
}

private struct SpaceEditorPopover: View {
    let title: String
    @Binding var name: String
    @Binding var icon: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private static let gridColumns = Array(repeating: GridItem(.fixed(30), spacing: 6), count: 7)

    /// Curated SF Symbols offered in the icon grid. All are available on the
    /// app's minimum macOS deployment target.
    private static let iconChoices: [String] = [
        "globe.americas.fill", "star.fill", "bookmark.fill", "heart.fill", "flag.fill", "bolt.fill", "bell.fill",
        "folder.fill", "tray.fill", "archivebox.fill", "doc.fill", "doc.on.doc.fill", "calendar", "envelope.fill",
        "book.fill", "bubble.left.fill", "terminal.fill", "wrench.and.screwdriver.fill", "hammer.fill", "gearshape.fill", "paintpalette.fill",
        "person.2.fill", "briefcase.fill", "graduationcap.fill", "cart.fill", "bag.fill", "gift.fill", "creditcard.fill",
        "house.fill", "bed.double.fill", "cup.and.saucer.fill", "fork.knife", "leaf.fill", "flame.fill", "drop.fill",
        "cloud.fill", "sun.max.fill", "moon.fill", "pawprint.fill", "airplane", "car.fill", "map.fill",
        "music.note", "video.fill", "gamecontroller.fill", "lightbulb.fill", "square.grid.2x2.fill", "chevron.left.forwardslash.chevron.right", "checkmark.seal.fill",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))

            TextField("Space name…", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(onConfirm)

            LazyVGrid(columns: Self.gridColumns, spacing: 6) {
                ForEach(Self.iconChoices, id: \.self) { symbol in
                    let isSelected = symbol == icon
                    Button {
                        icon = symbol
                    } label: {
                        Image(systemName: symbol)
                            .font(.system(size: 14))
                            .frame(width: 30, height: 30)
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.06))
                            )
                    }
                    .buttonStyle(.plain)
                    .help(symbol)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Done", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}
