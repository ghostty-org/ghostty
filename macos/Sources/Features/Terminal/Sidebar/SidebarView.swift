import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The single active drop-insertion target for the whole sidebar. One
/// shared instance (instead of per-row state) means a missed dropExited
/// can never leave a stale insertion indicator behind: the next
/// dropUpdated anywhere replaces it, and every performDrop clears it.
final class SidebarDragState: ObservableObject {
    @Published private(set) var target: (row: ObjectIdentifier, after: Bool)?

    private var expiry: DispatchWorkItem?

    /// How long the indicator outlives the last drag update.
    private static let expiryDelay: TimeInterval = 0.6

    /// Places the insertion indicator, and arms its expiry.
    ///
    /// Drop delegates report where the indicator goes, but nothing reports a
    /// drag that ended *without* a drop — released over a gap, or cancelled
    /// — which left the indicator on screen for good. A live drag keeps
    /// refreshing this (AppKit sends periodic updates even while the pointer
    /// holds still), so letting it lapse is what reliably clears it.
    func mark(row: ObjectIdentifier, after: Bool) {
        if target?.row != row || target?.after != after {
            target = (row: row, after: after)
        }

        expiry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.target = nil
            self?.expiry = nil
        }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.expiryDelay, execute: work)
    }

    /// Clears the indicator. Pass `row` to only clear it when that row is
    /// the one currently marked, so a row being exited doesn't wipe the
    /// indicator the row being entered just placed.
    func clear(row: ObjectIdentifier? = nil) {
        if let row, target?.row != row { return }
        expiry?.cancel()
        expiry = nil
        if target != nil { target = nil }
    }
}

enum SidebarMetrics {
    /// The one gap used between every item in the list — groups, loose
    /// terminals, and tabs within a group — so the whole sidebar keeps a
    /// single rhythm regardless of what an item is.
    static let itemSpacing: CGFloat = 8
}

/// The vertical tab sidebar: tabs grouped into user-defined sections.
struct SidebarView: View {
    @ObservedObject var tabManager: SidebarTabManager
    @ObservedObject var store: SidebarGroupStore
    @ObservedObject var layout: SidebarLayoutModel

    /// This window's open files, so the file tree can mark the one on screen.
    @ObservedObject var editorCenter: EditorCenter

    @StateObject private var dragState = SidebarDragState()

    /// Creates a terminal tab inside the given group (nil for ungrouped),
    /// following the group's working-directory rule.
    var onNewTabInGroup: (SidebarGroup?) -> Void = { _ in }

    /// Same as `onNewTabInGroup`, with a Claude session started in it.
    var onNewClaudeTabInGroup: (SidebarGroup?) -> Void = { _ in }

    /// Opens a terminal directly beside the selected one — same group, or
    /// ungrouped if that's where the selection lives — and hands back its
    /// surface. The panels open every file in one of these; see
    /// `FileOpener.openInTerminal`.
    var onSpawnTerminalBesideSelection: () -> Ghostty.SurfaceView? = { nil }

    /// Opens a file in this window's editor pane, which takes the
    /// terminal's place while anything is open.
    var onOpenInEditor: (URL) -> Void = { _ in }

    /// List animations are suspended while the sidebar first populates.
    private var listAnimation: Animation? {
        tabManager.animationsEnabled ? .snappy(duration: 0.22) : nil
    }

    /// One rendered group section and the tabs resolved into it, in
    /// sidebar display order.
    private struct Section: Identifiable {
        let group: SidebarGroup
        let tabs: [SidebarTabModel]

        var id: UUID { group.id }
    }

    private var resolved: (sections: [Section], ungrouped: [SidebarTabModel]) {
        var byGroup: [UUID: [SidebarTabModel]] = [:]
        var ungrouped: [SidebarTabModel] = []

        for tab in tabManager.models {
            if let group = store.resolveGroup(surfaceId: tab.surfaceId, pwd: tab.pwd) {
                byGroup[group.id, default: []].append(tab)
            } else {
                ungrouped.append(tab)
            }
        }

        let sections = store.groups.map { group in
            Section(
                group: group,
                tabs: store.sorted(byGroup[group.id] ?? [], id: \.surfaceId)
            )
        }
        return (sections, store.sorted(ungrouped, id: \.surfaceId))
    }

    var body: some View {
        // No background of its own: the window paints the theme color,
        // opacity and blur, so the sidebar always matches the terminal.
        expanded
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The panels the user has switched on. Read through `@AppStorage` so
    /// the sidebar follows the setting live — `SidebarPane.isEnabled` goes
    /// to `UserDefaults` directly, which SwiftUI has no way to observe.
    @AppStorage("SidebarShowFilesPane") private var showFilesPane = true
    @AppStorage("SidebarShowGitPane") private var showGitPane = true

    private var enabledPanes: [SidebarPane] {
        SidebarPane.allCases.filter { pane in
            switch pane {
            case .terminals: return true
            case .files: return showFilesPane
            case .git: return showGitPane
            }
        }
    }

    /// Falls back to terminals when the selected panel has been switched
    /// off. Resolved here rather than by writing back to `selectedPane`,
    /// because turning the last extra panel off also hides the tab bar —
    /// and a correction that lives in the bar would never run, leaving the
    /// sidebar stuck on a panel with no way back to the terminals.
    private var visiblePane: SidebarPane {
        enabledPanes.contains(layout.selectedPane) ? layout.selectedPane : .terminals
    }

    private var expanded: some View {
        VStack(spacing: 0) {
            if enabledPanes.count > 1 {
                SidebarPaneTabBar(selection: $layout.selectedPane, panes: enabledPanes)
            }

            switch visiblePane {
            case .terminals:
                terminalList
            case .files:
                FileExplorerView(
                    tabManager: tabManager,
                    store: store,
                    onSpawnTerminal: onSpawnTerminalBesideSelection,
                    onOpenInEditor: onOpenInEditor,
                    editorCenter: editorCenter
                )
            case .git:
                GitPanelView(
                    tabManager: tabManager,
                    onSpawnTerminal: onSpawnTerminalBesideSelection,
                    onOpenInEditor: onOpenInEditor
                )
            }
        }
    }

    private var terminalList: some View {
        VStack(spacing: 0) {
            ScrollView {
                let content = resolved

                VStack(spacing: SidebarMetrics.itemSpacing) {
                    ForEach(content.sections) { section in
                        SidebarGroupSection(
                            group: section.group,
                            tabs: section.tabs,
                            tabManager: tabManager,
                            store: store,
                            dragState: dragState,
                            onNewTab: onNewTabInGroup,
                            onNewClaudeTab: onNewClaudeTabInGroup
                        )
                        .transition(.opacity)
                    }

                    // Same spacing as between groups: every item in the
                    // list sits on the one rhythm, whether it's a group or
                    // a loose terminal.
                    ForEach(content.ungrouped) { tab in
                        SidebarTabRow(
                            tab: tab,
                            groupId: nil,
                            tabManager: tabManager,
                            store: store,
                            dragState: dragState
                        )
                        .transition(.opacity)
                    }
                }
                .padding(8)
                .animation(listAnimation, value: content.sections.map(\.id))
                .animation(listAnimation, value: store.tabOrder)
                .animation(listAnimation, value: tabManager.models.map(\.id))
                .background(alignment: .top) { OverlayScrollers() }
            }
            .scrollIndicators(.automatic)
            .onDrop(of: [.plainText], isTargeted: nil) { providers in
                appendDroppedToUngrouped(providers)
            }
        }
    }

    /// Drop on the list background: tabs move to the end ungrouped,
    /// groups move to the end of the group list.
    private func appendDroppedToUngrouped(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        dragState.clear()
        let lastUngrouped = resolved.ungrouped.last?.surfaceId
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String else { return }
            Task { @MainActor in
                switch SidebarDragPayload(string) {
                case .tab(let surfaceId):
                    if let lastUngrouped, lastUngrouped != surfaceId {
                        store.insert(surfaceId: surfaceId, near: lastUngrouped, after: true, groupId: nil)
                    } else {
                        store.assign(surfaceId: surfaceId, to: nil)
                    }
                case .group(let movedId):
                    store.moveGroup(movedId, toIndex: store.groups.count)
                case nil:
                    break
                }
            }
        }
        return true
    }

}

/// The sidebar action icons rendered inside the window titlebar (as a
/// leading titlebar accessory), trailing-aligned so they hug the
/// sidebar's edge like a native toolbar.
struct SidebarTitlebarChrome: View {
    @ObservedObject var store: SidebarGroupStore
    @ObservedObject var layout: SidebarLayoutModel
    @ObservedObject var collapse: SidebarCollapseState = .shared

    @State private var isCreatingGroup = false

    /// Mirrors `SidebarView`'s own fallback: a panel switched off in
    /// settings must not leave its buttons behind in the titlebar.
    @AppStorage("SidebarShowFilesPane") private var showFilesPane = true
    @AppStorage("SidebarShowGitPane") private var showGitPane = true

    private var visiblePane: SidebarPane {
        switch layout.selectedPane {
        case .files where !showFilesPane: return .terminals
        case .git where !showGitPane: return .terminals
        default: return layout.selectedPane
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            if !collapse.isCollapsed {
                paneActions
                    // The tab bar wraps the pane change in `withAnimation`,
                    // and that animation reached in here too: switching
                    // panels animated the whole row, sliding every button
                    // back into place from the left. Which buttons apply is
                    // a toggle, not a movement.
                    .transaction { $0.animation = nil }
            }

            SidebarChromeButton(
                icon: "sidebar.left",
                help: collapse.isCollapsed ? "Show Sidebar" : "Hide Sidebar"
            ) {
                collapse.isCollapsed.toggle()
            }
        }
        .animation(.easeOut(duration: 0.15), value: collapse.isCollapsed)
    }

    /// The buttons here belong to whichever panel is showing — creating a
    /// terminal makes no sense while browsing files, and refreshing a tree
    /// makes none while looking at terminals.
    ///
    /// One `if`/`else` rather than a `switch` over the three panes, so that
    /// what the panels have in common stays put. Refresh is the same button
    /// in Files and in Git; under a `switch` it lived in a different branch
    /// in each, which made SwiftUI tear it down and build a new one just
    /// for moving between two panels that both show it.
    @ViewBuilder
    private var paneActions: some View {
        if visiblePane == .terminals {
            SidebarChromeButton(icon: "plus", help: "New Terminal") {
                layout.onNewTab()
            }
            SidebarIconButton(help: "New Claude Session") {
                layout.onNewClaudeTab()
            } label: {
                ClaudeIcon(size: 12)
            }
            SidebarChromeButton(icon: "folder.badge.plus", help: "New Group") {
                isCreatingGroup = true
            }
            .sheet(isPresented: $isCreatingGroup) {
                SidebarGroupEditor(group: nil, store: store)
            }
        } else {
            SidebarChromeButton(icon: "arrow.clockwise", help: "Refresh") {
                switch visiblePane {
                case .files: FileExplorerRefresh.shared.request()
                case .git: GitPanelRefresh.shared.request()
                case .terminals: break
                }
            }
        }
    }
}

/// The hit area and hover treatment shared by every icon button in the
/// sidebar. Group headers and tab rows reuse this so their icons are as
/// easy to hit as the chrome row's — undersized targets there meant a near
/// miss landed on the row or header gesture behind the button instead.
struct SidebarIconButton<Label: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            label().sidebarIconChip()
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

extension View {
    /// The hover treatment every icon control in the sidebar shares — one
    /// hit area, one corner radius, one highlight. Kept as a modifier
    /// rather than living only inside `SidebarIconButton` so the things
    /// that can't be a `Button` still look and feel identical to the ones
    /// that can.
    ///
    /// A `Menu` is the exception and must use `SidebarIconMenu` instead —
    /// see there for why.
    func sidebarIconChip() -> some View {
        modifier(SidebarIconChip())
    }
}

/// "How many of these are there" — terminals in a group, changed files in
/// a section, commits waiting to be pushed. One capsule for all of them so
/// a count always looks like a count, instead of each panel inventing its
/// own treatment.
struct SidebarCountBadge: View {
    let count: Int

    /// Drawn before the number, for counts that need to say *which* kind.
    var symbol: String?

    @ObservedObject private var palette: ThemePalette = .shared

    var body: some View {
        HStack(spacing: 2) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 8, weight: .semibold))
            }
            Text(verbatim: "\(count)")
                .font(palette.font(size: 10, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Capsule().fill(.quaternary))
    }
}

enum SidebarIconChipMetrics {
    static let width: CGFloat = 24
    static let height: CGFloat = 22
    static let cornerRadius: CGFloat = 5

    /// Breathing room between a chip and the edge of the row it sits in.
    /// A row exactly as tall as its chip puts the highlight flush against
    /// the row's own background, which reads as a rendering seam rather
    /// than a button.
    static let rowInset: CGFloat = 3

    /// The height a list row needs for its chips to sit inside it.
    static var rowHeight: CGFloat { height + rowInset * 2 }
}

private struct SidebarIconChip: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .frame(width: SidebarIconChipMetrics.width, height: SidebarIconChipMetrics.height)
            .contentShape(Rectangle())
            .sidebarIconChipHighlight(isHovered)
            .onHover { isHovered = $0 }
    }
}

extension View {
    fileprivate func sidebarIconChipHighlight(_ isHovered: Bool) -> some View {
        background(
            RoundedRectangle(cornerRadius: SidebarIconChipMetrics.cornerRadius)
                .fill(isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
        )
    }
}

/// A panel's overflow menu, wearing the same chip as the icon buttons
/// beside it.
///
/// The chip can't ride on the menu's *label* the way it does on a button's:
/// `Menu` lays its own tracking area over the label to drive highlighting
/// and menu opening, so an `.onHover` attached in there never fires and the
/// highlight simply never appears — which is exactly how the panel headers
/// ended up as the one control in the sidebar with no hover. Observing the
/// hover on the wrapper and drawing the highlight behind the menu gets the
/// same look without fighting for the same events.
struct SidebarIconMenu<Content: View>: View {
    let help: String
    var icon: String = "ellipsis"
    @ViewBuilder let content: () -> Content

    @State private var isHovered = false

    var body: some View {
        Menu(content: content) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .frame(width: SidebarIconChipMetrics.width, height: SidebarIconChipMetrics.height)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // Pinned again on the outside: `fixedSize` hands the menu its own
        // intrinsic height, which is shorter than the label's frame, so
        // without this the highlight came out squatter than every other
        // chip in the same row.
        .frame(width: SidebarIconChipMetrics.width, height: SidebarIconChipMetrics.height)
        .sidebarIconChipHighlight(isHovered)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

/// A small borderless icon button for the sidebar chrome row.
private struct SidebarChromeButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        SidebarIconButton(help: help, action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

/// A group block: tinted header with icon, name and color dot, a colored
/// border around the whole block, and the tab rows when expanded.
private struct SidebarGroupSection: View {
    let group: SidebarGroup
    let tabs: [SidebarTabModel]
    let tabManager: SidebarTabManager
    @ObservedObject var store: SidebarGroupStore
    let dragState: SidebarDragState
    var onNewTab: (SidebarGroup?) -> Void = { _ in }
    var onNewClaudeTab: (SidebarGroup?) -> Void = { _ in }

    @ObservedObject private var palette: ThemePalette = .shared

    @AppStorage("SidebarGroupShowPullRequests") private var showPullRequests = true
    @AppStorage("SidebarGroupShowClaude") private var showClaude = true
    @AppStorage("SidebarGroupShowNewTerminal") private var showNewTerminal = true
    @AppStorage("SidebarGroupShowCount") private var showCount = true

    @State private var isDropTarget = false
    @State private var isEditing = false
    @State private var isHeaderHovered = false
    @State private var isShowingPRs = false

    private var accent: Color? { group.accentColor }
    private var collapsed: Bool { group.collapsed }

    var body: some View {
        VStack(spacing: 0) {
            header

            if !collapsed {
                VStack(spacing: SidebarMetrics.itemSpacing) {
                    ForEach(tabs) { tab in
                        SidebarTabRow(
                            tab: tab,
                            groupId: group.id,
                            tabManager: tabManager,
                            store: store,
                            dragState: dragState
                        )
                    }
                    if tabs.isEmpty {
                        Text("No tabs")
                            .font(palette.captionFont)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                }
                .padding(4)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill((accent ?? .secondary).opacity(0.06))
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isDropTarget
                        ? (accent ?? palette.accent ?? .accentColor)
                        : (accent ?? .secondary).opacity(0.35),
                    lineWidth: isDropTarget ? 2 : 1
                )
        )
        .onDrop(of: [.plainText], isTargeted: $isDropTarget) { providers in
            handleDrop(providers)
        }
        .animation(.snappy(duration: 0.2), value: collapsed)
        .animation(.easeOut(duration: 0.12), value: isDropTarget)
        .sheet(isPresented: $isEditing) {
            SidebarGroupEditor(group: group, store: store)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            SidebarIconButton(
                help: collapsed ? "Expand Group" : "Collapse Group"
            ) {
                store.toggleCollapsed(group.id)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
            }

            SidebarGroupIcon(icon: group.icon)
                .foregroundStyle(accent ?? Color.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(group.name)
                    .font(palette.font(size: 11, weight: .semibold))
                    .lineLimit(1)

                if let details = group.details, !details.isEmpty {
                    Text(details)
                        .font(palette.font(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            if collapsed {
                GroupStatusRollup(tabs: tabs, accent: accent)
            }

            Spacer(minLength: 0)

            if showPullRequests {
                SidebarIconButton(help: "Pull Requests in Group") {
                    isShowingPRs = true
                } label: {
                    GitIcon(size: 11)
                        .foregroundStyle(.secondary)
                }
                .opacity(isHeaderHovered ? 1 : 0)
                .allowsHitTesting(isHeaderHovered)
                .popover(isPresented: $isShowingPRs) {
                    GroupPRListView(
                        group: group,
                        openTabRoots: Array(Set(tabs.compactMap(\.repoRoot)))
                    )
                }
            }

            if showClaude {
                SidebarIconButton(help: "New Claude Session in Group") {
                    onNewClaudeTab(group)
                } label: {
                    ClaudeIcon(size: 12)
                }
                .opacity(isHeaderHovered ? 1 : 0)
                .allowsHitTesting(isHeaderHovered)
            }

            if showNewTerminal {
                SidebarIconButton(help: "New Terminal in Group") {
                    onNewTab(group)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .opacity(isHeaderHovered ? 1 : 0)
                .allowsHitTesting(isHeaderHovered)
            }

            if showCount {
                SidebarCountBadge(count: tabs.count)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background((accent ?? .clear).opacity(0.18))
        .contentShape(Rectangle())
        .onTapGesture {
            store.toggleCollapsed(group.id)
        }
        .onHover { isHeaderHovered = $0 }
        .onDrag {
            NSItemProvider(object: "group:\(group.id.uuidString)" as NSString)
        }
        .contextMenu { groupMenu }
    }

    @ViewBuilder
    private var groupMenu: some View {
        Button("New Terminal in Group") { onNewTab(group) }
        Button("New Claude Session in Group") { onNewClaudeTab(group) }

        Divider()

        Button("Edit Group…") { isEditing = true }

        Menu("Color") {
            Section("General") {
                ForEach(TerminalTabColor.allCases, id: \.self) { color in
                    Button {
                        store.update(group.id) {
                            $0.color = color
                            $0.colorHex = nil
                        }
                    } label: {
                        HStack {
                            Image(nsImage: color.menuSwatch)
                            Text(color.localizedName)
                            if group.color == color && group.colorHex == nil {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            if !ThemePalette.shared.colors.isEmpty {
                Section("Theme") {
                    ForEach(Array(ThemePalette.shared.colors.enumerated()), id: \.offset) { index, nsColor in
                        let hex = nsColor.hexString ?? ""
                        Button {
                            store.update(group.id) { $0.colorHex = hex }
                        } label: {
                            HStack {
                                Image(nsImage: TerminalTabColor.menuSwatch(for: nsColor))
                                Text(ThemePalette.ansiNames[index])
                                if group.colorHex == hex {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
        }

        Divider()

        Button(collapsed ? "Expand" : "Collapse") {
            store.toggleCollapsed(group.id)
        }

        Divider()

        Button("Delete Group", role: .destructive) {
            store.deleteGroup(group.id)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        let targetGroupId = group.id
        dragState.clear()
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String else { return }
            Task { @MainActor in
                switch SidebarDragPayload(string) {
                case .group(let movedId):
                    store.moveGroup(movedId, before: targetGroupId)
                case .tab(let surfaceId):
                    store.assign(surfaceId: surfaceId, to: targetGroupId)
                case nil:
                    break
                }
            }
        }
        return true
    }
}

/// Rolls every tab's agent state into one glyph on the group header,
/// shown only while the group is collapsed — expanded, each tab already
/// carries its own indicator (`SidebarTabRow.statusIndicator`), so this
/// would just be a second copy of the same thing.
///
/// `SidebarGroupSection` holds `tabs` as a plain, non-observed array —
/// membership changes re-render it, but an existing tab's own `agentState`
/// flipping doesn't, the same way it doesn't for the list overall (each
/// row observes its own model directly instead). This does the same thing
/// at the group level: it subscribes to every tab's publisher itself
/// rather than trusting `tabs` to change identity when only their
/// contents do.
private struct GroupStatusRollup: View {
    let tabs: [SidebarTabModel]
    let accent: Color?

    @State private var tick = 0

    var body: some View {
        content
            .font(.system(size: 10))
            .onReceive(Publishers.MergeMany(tabs.map { $0.objectWillChange })) { _ in
                tick &+= 1
            }
    }

    @ViewBuilder
    private var content: some View {
        if tabs.contains(where: { $0.agentState == .awaiting }) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
                .help("A terminal in this group needs your input")
        } else if tabs.contains(where: { $0.needsAttention }) {
            Circle()
                .fill(.orange)
                .frame(width: 6, height: 6)
                .help("A terminal in this group needs attention")
        } else if tabs.contains(where: { $0.agentState == .working }) {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 10, height: 10)
                .help("A terminal in this group is working")
        } else if tabs.contains(where: { $0.agentState == .done }) {
            Circle()
                .fill(accent ?? Color.accentColor)
                .frame(width: 6, height: 6)
                .help("A terminal in this group has a response ready")
        }
    }
}

/// The two things draggable in the sidebar, encoded as plain strings:
/// a raw surface UUID for tabs, `group:<uuid>` for group headers.
private enum SidebarDragPayload {
    case tab(UUID)
    case group(UUID)

    init?(_ string: String) {
        if string.hasPrefix("group:") {
            guard let id = UUID(uuidString: String(string.dropFirst("group:".count)))
            else { return nil }
            self = .group(id)
        } else if let id = UUID(uuidString: string) {
            self = .tab(id)
        } else {
            return nil
        }
    }
}

/// Lists every open pull request of the repositories present in a
/// group, fetched on demand — one click opens the PR in the browser.
private struct GroupPRListView: View {
    let group: SidebarGroup
    let openTabRoots: [String]

    @State private var roots: [String] = []
    @ObservedObject private var gitCenter: GitStatusCenter = .shared
    @ObservedObject private var palette: ThemePalette = .shared

    /// Repos a tab happens to be open in, plus — for a project (workspace)
    /// group — every repo discovered under its root, so one that nobody
    /// has a tab open in still shows up.
    private func resolveRoots() -> [String] {
        var found = Set(openTabRoots)
        if case .project(let root) = group.kind {
            found.formUnion(SidebarGroup.discoverRepoRoots(under: root))
        }
        // By project name rather than full path: workspaces group repos
        // that share a path prefix, but that's not guaranteed in general,
        // and the name is what the section header actually shows.
        return found.sorted {
            ($0 as NSString).lastPathComponent.localizedCaseInsensitiveCompare(
                ($1 as NSString).lastPathComponent
            ) == .orderedAscending
        }
    }

    /// Content taller than this scrolls instead of growing. A workspace
    /// with a few busy repos produces a list longer than the screen, and a
    /// popover that tall is both ugly and unusable — it covers the window
    /// it belongs to and runs off the bottom.
    ///
    /// The 60% budget is for the *popover*, so the title, the padding and
    /// the popover's own arrow come out of it instead of being added on
    /// top — capping only the list left the whole thing a little over.
    private var maxListHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(200, screen * 0.6 - 72)
    }

    /// Measured so the popover is only as tall as it needs to be. A bare
    /// `maxHeight` won't do: a `ScrollView` takes everything it is offered
    /// along its scroll axis, so two pull requests would get the same
    /// full-height popover as fifty.
    @State private var contentHeight: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pull Requests")
                .font(palette.headlineFont)

            if roots.isEmpty {
                Text("No repositories in this group.")
                    .font(palette.captionFont)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                repoSections
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: PRListHeightKey.self,
                                value: proxy.size.height
                            )
                        }
                    )
            }
            .scrollIndicators(.automatic)
            .onPreferenceChange(PRListHeightKey.self) { height in
                contentHeight = height
            }
            .frame(height: contentHeight.map { min($0, maxListHeight) })
        }
        .padding(14)
        .frame(width: 340)
        .onAppear {
            roots = resolveRoots()
            roots.forEach { gitCenter.requestPRList(root: $0) }
        }
    }

    private var repoSections: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(roots, id: \.self) { root in
                VStack(alignment: .leading, spacing: 4) {
                    if roots.count > 1 {
                        Text((root as NSString).lastPathComponent)
                            .font(palette.font(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                    }

                    if let prs = gitCenter.repoPRLists[root] {
                        if prs.isEmpty {
                            Text("No open pull requests.")
                                .font(palette.captionFont)
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(prs) { pr in
                                    PRRow(pr: pr, palette: palette) {
                                        if let url = URL(string: pr.url) {
                                            NSWorkspace.shared.open(url)
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading…")
                                .font(palette.captionFont)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

private struct PRListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// One PR in the group's list: hovering marks it clickable (pointer cursor,
/// a tinted background) and a small person badge calls out a PR that's the
/// signed-in user's own, so it doesn't take reading every row to spot.
private struct PRRow: View {
    let pr: GitStatusCenter.PullRequest
    @ObservedObject var palette: ThemePalette
    let action: () -> Void

    @State private var isHovered = false

    private var isMine: Bool {
        guard let author = pr.author, let me = GitStatusCenter.currentUserLogin else { return false }
        return author == me
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text("#\(pr.number)")
                    .font(palette.font(size: 11, weight: .medium))
                    .foregroundStyle(palette.accent ?? .accentColor)

                if isMine {
                    Image(systemName: "person.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(palette.accent ?? .accentColor)
                        .help("Your pull request")
                }

                Text(pr.title)
                    .font(palette.font(size: 11))
                    .lineLimit(1)

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovered ? (palette.accent ?? .accentColor).opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }
}

/// Insert-between drop handling for a tab row: the drop position within
/// the row picks before/after, and the drop adopts the row's group.
private struct TabRowDropDelegate: DropDelegate {
    let target: SidebarTabModel
    let groupId: UUID?
    let store: SidebarGroupStore
    let dragState: SidebarDragState

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dragState.mark(row: target.id, after: info.location.y > 18)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        dragState.clear(row: target.id)
    }

    func performDrop(info: DropInfo) -> Bool {
        let after = dragState.target?.after ?? true
        dragState.clear()

        guard let provider = info.itemProviders(for: [.plainText]).first,
              let targetId = target.surfaceId
        else { return false }

        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String else { return }
            Task { @MainActor in
                switch SidebarDragPayload(string) {
                case .tab(let surfaceId):
                    store.insert(
                        surfaceId: surfaceId,
                        near: targetId,
                        after: after,
                        groupId: groupId
                    )
                case .group(let movedId):
                    if let groupId {
                        store.moveGroup(movedId, before: groupId)
                    } else {
                        store.moveGroup(movedId, toIndex: store.groups.count)
                    }
                case nil:
                    break
                }
            }
        }
        return true
    }
}

/// One tab row: title + working directory, click to activate.
private struct SidebarTabRow: View {
    @ObservedObject var tab: SidebarTabModel
    let groupId: UUID?
    let tabManager: SidebarTabManager
    @ObservedObject var store: SidebarGroupStore
    @ObservedObject var dragState: SidebarDragState
    @ObservedObject private var themePalette: ThemePalette = .shared
    @ObservedObject private var planCenter: ClaudePlanCenter = .shared

    /// Observed so a tab's file icon follows a theme change live, the same
    /// as the explorer's and the Git panel's.
    @ObservedObject private var icons: FileIconProvider = .shared

    @State private var isHovered = false
    @State private var isCreatingGroup = false
    @State private var isCustomizing = false

    @AppStorage("SidebarShowDirectory") private var showDirectory = true
    @AppStorage("SidebarShowGitBranch") private var showGitBranch = true
    @AppStorage("SidebarShowGitStatus") private var showGitStatus = true
    @AppStorage("SidebarShowPullRequest") private var showPullRequest = true
    @AppStorage("SidebarShowDevServer") private var showDevServer = true
    @AppStorage("SidebarTabDensity") private var density = "default"

    private var isCompact: Bool { density == "compact" }

    private var insertAfter: Bool? {
        guard dragState.target?.row == tab.id else { return nil }
        return dragState.target?.after
    }

    private var override: SidebarGroupStore.TabOverride? {
        tab.surfaceId.flatMap { store.tabOverrides[$0] }
    }

    private var displayTitle: String {
        if let custom = override?.name, !custom.isEmpty { return custom }
        return tab.title.isEmpty ? "Terminal" : tab.title
    }

    /// The program holding a file open, for the tabs that were opened for
    /// one.
    ///
    /// Read from the terminal's foreground process rather than from the
    /// editor we asked for. `$EDITOR` is resolved by the user's shell, so
    /// the command sent was `${EDITOR:-vim}` and only the shell knows what
    /// that became — and this way the chip is right for a `nano` opened by
    /// hand, and goes away by itself the moment the editor is quit.
    private var editorName: String? {
        guard let file = override?.fileName, !file.isEmpty else { return nil }
        guard let name = tab.foregroundName, !TerminalIdleCheck.isShell(name) else { return nil }
        return name
    }

    var body: some View {
        HStack(spacing: 6) {
            // A tab opened for a file wears that file's icon, from whichever
            // icon theme is active — the same artwork the explorer and the
            // Git panel show it with, so the three read as one thing. A hand
            // -picked icon still wins: it was chosen on purpose.
            if let icon = override?.icon, !icon.isEmpty {
                SidebarGroupIcon(icon: icon, size: 13)
                    .foregroundStyle(.secondary)
            } else if let file = override?.fileName, !file.isEmpty {
                FileIconView(icon: icons.icon(forFile: file), size: 14)
            }

            if let accent = override?.accentColor {
                Circle()
                    .fill(accent)
                    .frame(width: 6, height: 6)
            }

            VStack(alignment: .leading, spacing: isCompact ? 2 : 4) {
                Text(displayTitle)
                    .font(themePalette.font(
                        size: isCompact ? 11 : 12,
                        weight: tab.isSelected ? .semibold : .regular
                    ))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if let editor = editorName {
                        metaChip(icon: "square.and.pencil", text: editor)
                    }

                    if showDirectory, let dir = tab.directoryName {
                        metaChip(text: dir)
                    }

                    if showGitBranch, let branch = tab.gitBranch {
                        metaChip(
                            gitIcon: true,
                            text: branch,
                            dirty: showGitStatus && tab.isDirty == true
                        )
                    }

                    if showPullRequest, let prNumber = tab.prNumber {
                        prChip(number: prNumber)
                    }

                    if showDevServer, let port = tab.devServerPort {
                        devServerChip(port: port)
                    }

                    if let plan = planCenter.plan(forTerminalAt: tab.pwd) {
                        planChip(plan: plan)
                    }

                    // Reserve the metadata line even while pwd/branch
                    // haven't arrived yet so row heights never shift.
                    if showDirectory || showGitBranch {
                        Text(" ").font(.system(size: 9))
                    }
                }
                .frame(height: isCompact ? 14 : 18)
            }

            Spacer(minLength: 0)

            ZStack {
                statusIndicator
                    .opacity(isHovered ? 0 : 1)

                SidebarIconButton(help: "Close Terminal") {
                    tab.window.performClose(nil)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
            }
            .frame(width: 24, height: 22)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, isCompact ? 5 : 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(rowBackground)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            tabManager.select(tab)
            if let surfaceId = tab.surfaceId {
                TabStateCenter.shared.clearDone(surfaceId: surfaceId)
            }
        }
        .onChange(of: tab.isSelected) { selected in
            guard selected, let surfaceId = tab.surfaceId else { return }
            TabStateCenter.shared.clearDone(surfaceId: surfaceId)
        }
        .onHover { isHovered = $0 }
        .onDrag {
            NSItemProvider(object: (tab.surfaceId?.uuidString ?? "") as NSString)
        }
        .onDrop(
            of: [.plainText],
            delegate: TabRowDropDelegate(
                target: tab,
                groupId: groupId,
                store: store,
                dragState: dragState
            )
        )
        .overlay(alignment: .top) {
            if insertAfter == false {
                Rectangle().fill(themePalette.accent ?? .accentColor).frame(height: 2)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if insertAfter == true {
                Rectangle().fill(themePalette.accent ?? .accentColor).frame(height: 2)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.1), value: insertAfter)
        .contextMenu { tabMenu }
        .sheet(isPresented: $isCreatingGroup) {
            SidebarGroupEditor(
                group: nil,
                store: store,
                assignSurfaceId: tab.surfaceId
            )
        }
        .sheet(isPresented: $isCustomizing) {
            if let surfaceId = tab.surfaceId {
                SidebarTabEditor(
                    surfaceId: surfaceId,
                    currentTitle: tab.title,
                    store: store
                )
            }
        }
    }

    /// Trailing status: spinner while the agent works, a raised hand
    /// while it waits for input, an accent dot when a response is ready
    /// (cleared on selection), and the bell attention dot otherwise.
    @ViewBuilder
    private var statusIndicator: some View {
        switch tab.agentState {
        case .working:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 12, height: 12)
        case .awaiting:
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
        case .done:
            Circle()
                .fill(themePalette.accent ?? .accentColor)
                .frame(width: 8, height: 8)
        case .ended, nil:
            if tab.needsAttention {
                Circle()
                    .fill(.orange)
                    .frame(width: 6, height: 6)
            }
        }
    }

    /// The shared line box every chip element is centered within.
    private var chipLineHeight: CGFloat { 11 }

    /// The clickable Plan tag: opens the plan the agent wrote for this
    /// project.
    ///
    /// Attributed to the *project*, not to this terminal — nothing in a plan
    /// file says which window wrote it, and the only link that exists runs
    /// through the session transcript to a working directory. So every
    /// terminal in the project shows it, which is also true to what a plan
    /// is: it belongs to the work.
    private func planChip(plan: ClaudePlanIndex.Plan) -> some View {
        Button {
            openPlan(plan)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "text.rectangle.page")
                    // A size, not a text style: the glyph inherited the row's
                    // font metrics and came out taller than the chip.
                    .font(.system(size: isCompact ? 7 : 8))
                    .imageScale(.small)
                Text("Plan")
                    .font(.system(size: isCompact ? 9 : 10, weight: .medium))
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.18))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .help(plan.title)
    }

    /// Opens a plan through the same opener a file in the panels uses, so the
    /// Settings choice means the same thing everywhere.
    private func openPlan(_ plan: ClaudePlanIndex.Plan) {
        guard let controller = tab.window.windowController as? TerminalController else { return }
        controller.openClickedPath(URL(fileURLWithPath: plan.path), line: nil as Int?, column: nil)
    }

    /// A small rounded tag for row metadata (directory, git branch).
    private func metaChip(
        icon: String? = nil,
        gitIcon: Bool = false,
        text: String,
        dirty: Bool = false
    ) -> some View {
        // Every element is centered in one fixed-height line box: the symbol's
        // layout box is taller than the text's, so letting each size itself
        // pushes the label and the dirty dot visibly below the icon.
        HStack(alignment: .center, spacing: 3) {
            if gitIcon {
                GitIcon(size: 8)
                    .frame(height: chipLineHeight)
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: 8))
                    .frame(height: chipLineHeight)
            }
            Text(text)
                .lineLimit(1)
                .frame(height: chipLineHeight)
            if dirty {
                Circle()
                    .fill(.yellow)
                    .frame(width: 4, height: 4)
                    .frame(height: chipLineHeight)
            }
        }
        .font(themePalette.font(size: 9))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary.opacity(0.6))
        )
        .help(dirty ? "Uncommitted changes" : "")
    }

    /// The clickable PR tag: opens the branch's open pull request.
    private func prChip(number: Int) -> some View {
        Button {
            if let url = tab.prURL.flatMap(URL.init(string:)) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            Text(verbatim: "#\(number)")
                .font(themePalette.font(size: 9, weight: .medium))
                .foregroundStyle(themePalette.accent ?? .accentColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill((themePalette.accent ?? .accentColor).opacity(0.15))
                )
        }
        .buttonStyle(.plain)
        .help("Open Pull Request #\(number)")
    }

    /// The clickable dev-server tag: opens the port this tab is serving.
    private func devServerChip(port: Int) -> some View {
        Button {
            if let url = URL(string: "http://localhost:\(port)") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(alignment: .center, spacing: 3) {
                Image(systemName: "globe")
                    .font(.system(size: 8))
                    .frame(height: chipLineHeight)
                // Verbatim: a plain interpolation is a LocalizedStringKey,
                // which formats the number for the locale and turns port
                // 8899 into "8.899".
                Text(verbatim: ":\(port)")
                    .frame(height: chipLineHeight)
            }
            .font(themePalette.font(size: 9, weight: .medium))
            .foregroundStyle(Color.green)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.green.opacity(0.15))
            )
        }
        .buttonStyle(.plain)
        .help("Open http://localhost:\(port)")
    }

    /// Rows always carry a fill, not only when hovered or selected: over a
    /// transparent window an unfilled row leaves its text floating on the
    /// desktop with nothing to separate one terminal from the next. The
    /// tint comes from the theme so the sidebar matches the terminal.
    private var rowBackground: AnyShapeStyle {
        let accent = themePalette.primary.map { Color(nsColor: $0) }
            ?? Color(nsColor: .selectedContentBackgroundColor)

        let opacity: Double = if tab.isSelected {
            0.6
        } else if isHovered {
            0.28
        } else {
            0.12
        }

        return AnyShapeStyle(accent.opacity(opacity))
    }

    @ViewBuilder
    private var tabMenu: some View {
        Button("Customize Tab…") { isCustomizing = true }
            .disabled(tab.surfaceId == nil)

        if let prNumber = tab.prNumber,
           let prURL = tab.prURL.flatMap(URL.init(string:)) {
            Button("Open Pull Request #\(prNumber)…") {
                NSWorkspace.shared.open(prURL)
            }
        }

        Divider()

        Menu("Move to Group") {
            ForEach(store.groups) { group in
                Button(group.name) {
                    guard let surfaceId = tab.surfaceId else { return }
                    store.assign(surfaceId: surfaceId, to: group.id)
                }
            }

            if !store.groups.isEmpty {
                Divider()
            }

            Button("New Group…") {
                isCreatingGroup = true
            }

            Divider()

            Button("No Group") {
                guard let surfaceId = tab.surfaceId else { return }
                store.assign(surfaceId: surfaceId, to: nil)
            }
        }

        Button("Close Tab", role: .destructive) {
            tab.window.performClose(nil)
        }
    }
}

/// One cell of the icon grid: hover highlight, accent fill when selected.
private struct SidebarIconCell: View {
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false
    @ObservedObject private var palette: ThemePalette = .shared

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? .white : .primary)
                .frame(width: 32, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected
                            ? AnyShapeStyle(palette.accent ?? .accentColor)
                            : isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// Visual icon picker: an evenly-filled grid of curated SF Symbols plus
/// a compact emoji field for anything the grid doesn't cover.
private struct SidebarIconPicker: View {
    @Binding var selection: String

    @State private var emoji: String = ""

    @FocusState private var emojiFieldFocused: Bool

    /// A full 5×7 grid of terminal-life symbols.
    private static let symbols: [String] = [
        "folder", "terminal", "flame", "bolt", "star", "heart", "hammer",
        "wrench.and.screwdriver", "gearshape", "shippingbox", "cube", "globe", "server.rack", "cloud",
        "externaldrive", "chart.bar", "doc.text", "book", "briefcase", "building.2", "cart",
        "creditcard", "testtube.2", "ladybug", "leaf", "moon.stars", "sparkles", "gamecontroller",
        "music.note", "paintbrush", "curlybraces", "cpu", "network", "lock", "bell",
    ]

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 6),
        count: 7
    )

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(Self.symbols, id: \.self) { symbol in
                SidebarIconCell(symbol: symbol, isSelected: selection == symbol) {
                    selection = symbol
                    emoji = ""
                }
            }
        }
        .padding(.vertical, 4)

        LabeledContent("Emoji") {
            HStack(spacing: 6) {
                TextField("", text: $emoji, prompt: Text("🔥"))
                    .labelsHidden()
                    .focused($emojiFieldFocused)
                    .frame(width: 48)
                    .multilineTextAlignment(.center)
                    .onChange(of: emoji) { value in
                        guard let first = value.first else { return }
                        let single = String(first)
                        if emoji != single { emoji = single }
                        selection = single
                    }

                Button {
                    emojiFieldFocused = true
                    DispatchQueue.main.async {
                        NSApp.orderFrontCharacterPalette(nil)
                    }
                } label: {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .help("Choose Emoji…")
            }
        }
        .onAppear {
            if !selection.isEmpty && !Self.symbols.contains(selection) {
                emoji = selection
            }
        }
    }
}

/// A circular swatch for an arbitrary color (theme palette entries).
private struct SidebarHexSwatch: View {
    let nsColor: NSColor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(
                        isSelected ? Color.primary.opacity(0.6) : .clear,
                        lineWidth: 1.5
                    )
                    .frame(width: 22, height: 22)

                Circle()
                    .fill(Color(nsColor: nsColor))
                    .frame(width: 15, height: 15)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Both color rows used by the group and tab editors: the preset
/// palette ("General") plus the current theme's ANSI colors.
private struct SidebarColorRows: View {
    @Binding var color: TerminalTabColor
    @Binding var colorHex: String?

    @ObservedObject private var palette: ThemePalette = .shared

    private let themeColumns = Array(
        repeating: GridItem(.flexible(), spacing: 4),
        count: 8
    )

    var body: some View {
        LabeledContent("Color") {
            HStack(spacing: 6) {
                ForEach(TerminalTabColor.allCases, id: \.self) { swatch in
                    SidebarColorSwatch(
                        color: swatch,
                        isSelected: color == swatch && colorHex == nil
                    ) {
                        color = swatch
                        colorHex = nil
                    }
                }
            }
        }

        if !palette.colors.isEmpty {
            LabeledContent("Theme") {
                LazyVGrid(columns: themeColumns, spacing: 4) {
                    ForEach(Array(palette.colors.enumerated()), id: \.offset) { _, nsColor in
                        let hex = nsColor.hexString ?? ""
                        SidebarHexSwatch(
                            nsColor: nsColor,
                            isSelected: colorHex == hex
                        ) {
                            colorHex = hex
                        }
                    }
                }
            }
        }
    }
}

/// One circular color swatch, ringed when selected — the Reminders
/// list-editor pattern.
private struct SidebarColorSwatch: View {
    let color: TerminalTabColor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(
                        isSelected ? Color.primary.opacity(0.6) : .clear,
                        lineWidth: 1.5
                    )
                    .frame(width: 22, height: 22)

                if let accent = color.sidebarAccent {
                    Circle()
                        .fill(accent)
                        .frame(width: 15, height: 15)
                } else {
                    Circle()
                        .strokeBorder(Color.secondary, lineWidth: 1)
                        .frame(width: 15, height: 15)
                        .overlay(
                            Image(systemName: "line.diagonal")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.secondary)
                        )
                }
            }
        }
        .buttonStyle(.plain)
        .help(color.localizedName)
    }
}

/// Per-tab customization sheet: custom display name, icon and color dot.
private struct SidebarTabEditor: View {
    let surfaceId: UUID
    let currentTitle: String
    @ObservedObject var store: SidebarGroupStore

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var palette: ThemePalette = .shared

    @State private var name = ""
    @State private var icon = ""
    @State private var color: TerminalTabColor = .none
    @State private var colorHex: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Name") {
                        TextField(
                            "",
                            text: $name,
                            prompt: Text(currentTitle.isEmpty ? "Terminal" : currentTitle)
                        )
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    SidebarColorRows(color: $color, colorHex: $colorHex)
                } footer: {
                    Text("Leave the name empty to keep the terminal's own title.")
                        .font(palette.captionFont)
                        .foregroundStyle(.secondary)
                }

                Section("Icon") {
                    SidebarIconPicker(selection: $icon)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Reset") {
                    store.setTabOverride(surfaceId: surfaceId, .init())
                    dismiss()
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 330, height: 420)
        .onAppear { populate() }
    }

    private func populate() {
        guard let override = store.tabOverrides[surfaceId] else { return }
        name = override.name ?? ""
        icon = override.icon ?? ""
        color = override.color ?? .none
        colorHex = override.colorHex
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        store.setTabOverride(surfaceId: surfaceId, .init(
            name: trimmed.isEmpty ? nil : trimmed,
            icon: icon.isEmpty ? nil : icon,
            color: color == .none ? nil : color,
            colorHex: colorHex
        ))
    }
}

/// Popover to create or edit a group: name, icon (emoji or SF Symbol),
/// project root for rule-based groups, and color.
private struct SidebarGroupEditor: View {
    let group: SidebarGroup?
    @ObservedObject var store: SidebarGroupStore

    /// When creating a group from a tab's context menu, the tab to move
    /// into the new group on save.
    var assignSurfaceId: UUID?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var palette: ThemePalette = .shared

    @State private var name: String = ""
    @State private var details: String = ""
    @State private var icon: String = "folder"
    @State private var color: TerminalTabColor = .none
    @State private var colorHex: String?
    @State private var isProject: Bool = false
    @State private var projectRoot: String = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Name") {
                        TextField("", text: $name, prompt: Text("Group name"))
                            .labelsHidden()
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    LabeledContent("Description") {
                        TextField("", text: $details, prompt: Text("Optional"))
                            .labelsHidden()
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    SidebarColorRows(color: $color, colorHex: $colorHex)
                }

                Section("Icon") {
                    SidebarIconPicker(selection: $icon)
                }

                Section {
                    Toggle("Project group", isOn: $isProject)
                        .toggleStyle(.switch)

                    if isProject {
                        HStack(spacing: 6) {
                            TextField(
                                "",
                                text: $projectRoot,
                                prompt: Text("~/Projects/front-app-eita")
                            )
                            .labelsHidden()
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Button {
                                if let pasted = NSPasteboard.general.string(forType: .string) {
                                    projectRoot = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                            } label: {
                                Image(systemName: "doc.on.clipboard")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.borderless)
                            .help("Paste Path")

                            Button {
                                chooseProjectRoot()
                            } label: {
                                Image(systemName: "folder")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.borderless)
                            .help("Choose Folder…")
                        }
                    }
                } footer: {
                    Text("Project groups automatically claim tabs whose working directory is inside the project root.")
                        .font(palette.captionFont)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(group == nil ? "Create" : "Save") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 380, height: 780)
        .onAppear { populate() }
    }

    private func populate() {
        guard let group else { return }
        name = group.name
        details = group.details ?? ""
        icon = group.icon
        color = group.color
        colorHex = group.colorHex
        if case .project(let root) = group.kind {
            isProject = true
            projectRoot = root
        }
    }

    /// Opens a Finder panel to pick the project root directory.
    private func chooseProjectRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if !projectRoot.isEmpty {
            panel.directoryURL = URL(
                fileURLWithPath: (projectRoot as NSString).expandingTildeInPath
            )
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        projectRoot = (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func save() {
        let kind: SidebarGroup.Kind = isProject && !projectRoot.isEmpty
            ? .project(root: projectRoot)
            : .manual

        let trimmedDetails = details.trimmingCharacters(in: .whitespaces)

        if let group {
            store.update(group.id) {
                $0.name = name
                $0.details = trimmedDetails.isEmpty ? nil : trimmedDetails
                $0.icon = icon
                $0.color = color
                $0.colorHex = colorHex
                $0.kind = kind
            }
        } else {
            let created = store.createGroup(
                name: name,
                details: trimmedDetails.isEmpty ? nil : trimmedDetails,
                icon: icon,
                color: color,
                kind: kind
            )
            if let colorHex {
                store.update(created.id) { $0.colorHex = colorHex }
            }
            if let assignSurfaceId {
                store.assign(surfaceId: assignSurfaceId, to: created.id)
            }
        }
    }
}
