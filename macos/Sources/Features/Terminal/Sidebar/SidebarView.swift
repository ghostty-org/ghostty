import SwiftUI
import UniformTypeIdentifiers

/// The single active drop-insertion target for the whole sidebar. One
/// shared instance (instead of per-row state) means a missed dropExited
/// can never leave a stale insertion indicator behind: the next
/// dropUpdated anywhere replaces it, and every performDrop clears it.
final class SidebarDragState: ObservableObject {
    @Published var target: (row: ObjectIdentifier, after: Bool)?
}

/// The vertical tab sidebar: tabs grouped into user-defined sections.
struct SidebarView: View {
    @ObservedObject var tabManager: SidebarTabManager
    @ObservedObject var store: SidebarGroupStore
    @ObservedObject var layout: SidebarLayoutModel

    @StateObject private var dragState = SidebarDragState()

    /// Creates a terminal tab inside the given group (nil for ungrouped),
    /// following the group's working-directory rule.
    var onNewTabInGroup: (SidebarGroup?) -> Void = { _ in }

    /// One rendered group section and the tabs resolved into it, in
    /// sidebar display order.
    private struct Section: Identifiable {
        let group: SidebarGroup
        let tabs: [SidebarTabManager.TabItem]

        var id: UUID { group.id }
    }

    private var resolved: (sections: [Section], ungrouped: [SidebarTabManager.TabItem]) {
        var byGroup: [UUID: [SidebarTabManager.TabItem]] = [:]
        var ungrouped: [SidebarTabManager.TabItem] = []

        for tab in tabManager.tabs {
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
        expanded
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.ultraThinMaterial)
    }

    private var expanded: some View {
        VStack(spacing: 0) {
            ScrollView {
                let content = resolved

                LazyVStack(spacing: 8) {
                    ForEach(content.sections) { section in
                        SidebarGroupSection(
                            group: section.group,
                            tabs: section.tabs,
                            tabManager: tabManager,
                            store: store,
                            dragState: dragState,
                            onNewTab: onNewTabInGroup
                        )
                    }

                    VStack(spacing: 2) {
                        ForEach(content.ungrouped) { tab in
                            SidebarTabRow(
                                tab: tab,
                                groupId: nil,
                                tabManager: tabManager,
                                store: store,
                                dragState: dragState
                            )
                        }
                    }
                }
                .padding(8)
            }
            .onDrop(of: [.plainText], isTargeted: nil) { providers in
                appendDroppedToUngrouped(providers)
            }
        }
    }

    /// Drop on the list background: tabs move to the end ungrouped,
    /// groups move to the end of the group list.
    private func appendDroppedToUngrouped(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        dragState.target = nil
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

    @State private var isCreatingGroup = false

    var body: some View {
        HStack(spacing: 2) {
            Spacer(minLength: 0)

            if !layout.isCollapsed {
                SidebarChromeButton(icon: "plus", help: "New Terminal") {
                    layout.onNewTab()
                }
                SidebarChromeButton(icon: "folder.badge.plus", help: "New Group") {
                    isCreatingGroup = true
                }
                .sheet(isPresented: $isCreatingGroup) {
                    SidebarGroupEditor(group: nil, store: store)
                }
            }

            SidebarChromeButton(
                icon: "sidebar.left",
                help: layout.isCollapsed ? "Show Sidebar" : "Hide Sidebar"
            ) {
                layout.isCollapsed.toggle()
            }
        }
        .padding(.trailing, 6)
        .frame(maxHeight: .infinity, alignment: .center)
    }
}

/// A small borderless icon button for the sidebar chrome row.
private struct SidebarChromeButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

/// A group block: tinted header with icon, name and color dot, a colored
/// border around the whole block, and the tab rows when expanded.
private struct SidebarGroupSection: View {
    let group: SidebarGroup
    let tabs: [SidebarTabManager.TabItem]
    let tabManager: SidebarTabManager
    @ObservedObject var store: SidebarGroupStore
    let dragState: SidebarDragState
    var onNewTab: (SidebarGroup?) -> Void = { _ in }

    @State private var isDropTarget = false
    @State private var isEditing = false
    @State private var isHeaderHovered = false

    private var accent: Color? { group.color.sidebarAccent }
    private var collapsed: Bool { group.collapsed }

    var body: some View {
        VStack(spacing: 0) {
            header

            if !collapsed {
                VStack(spacing: 2) {
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
                            .font(.caption)
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
                        ? (accent ?? .accentColor)
                        : (accent ?? .secondary).opacity(0.35),
                    lineWidth: isDropTarget ? 2 : 1
                )
        )
        .onDrop(of: [.plainText], isTargeted: $isDropTarget) { providers in
            handleDrop(providers)
        }
        .sheet(isPresented: $isEditing) {
            SidebarGroupEditor(group: group, store: store)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                store.toggleCollapsed(group.id)
            } label: {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)

            SidebarGroupIcon(icon: group.icon)
                .foregroundStyle(accent ?? Color.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(group.name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)

                if let details = group.details, !details.isEmpty {
                    Text(details)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            Button {
                onNewTab(group)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .opacity(isHeaderHovered ? 1 : 0)
            .allowsHitTesting(isHeaderHovered)
            .help("New Terminal in Group")

            Text("\(tabs.count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(.quaternary))
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

        Divider()

        Button("Edit Group…") { isEditing = true }

        Menu("Color") {
            ForEach(TerminalTabColor.allCases, id: \.self) { color in
                Button {
                    store.update(group.id) { $0.color = color }
                } label: {
                    HStack {
                        Text(color.localizedName)
                        if group.color == color {
                            Image(systemName: "checkmark")
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
        dragState.target = nil
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

/// Insert-between drop handling for a tab row: the drop position within
/// the row picks before/after, and the drop adopts the row's group.
private struct TabRowDropDelegate: DropDelegate {
    let target: SidebarTabManager.TabItem
    let groupId: UUID?
    let store: SidebarGroupStore
    let dragState: SidebarDragState

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dragState.target = (row: target.id, after: info.location.y > 18)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if dragState.target?.row == target.id {
            dragState.target = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        let after = dragState.target?.after ?? true
        dragState.target = nil

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
    let tab: SidebarTabManager.TabItem
    let groupId: UUID?
    let tabManager: SidebarTabManager
    @ObservedObject var store: SidebarGroupStore
    @ObservedObject var dragState: SidebarDragState
    @ObservedObject var stateCenter: TabStateCenter = .shared

    @State private var isHovered = false
    @State private var isCreatingGroup = false
    @State private var isCustomizing = false

    @AppStorage("SidebarShowDirectory") private var showDirectory = true
    @AppStorage("SidebarShowGitBranch") private var showGitBranch = true
    @AppStorage("SidebarShowGitStatus") private var showGitStatus = true
    @AppStorage("SidebarShowPullRequest") private var showPullRequest = true

    @ObservedObject private var gitCenter: GitStatusCenter = .shared

    private var repoInfo: GitStatusCenter.RepoInfo? {
        gitCenter.info(forRoot: tab.repoRoot)
    }

    private var insertAfter: Bool? {
        guard dragState.target?.row == tab.id else { return nil }
        return dragState.target?.after
    }

    private var override: SidebarGroupStore.TabOverride? {
        tab.surfaceId.flatMap { store.tabOverrides[$0] }
    }

    private var agentState: AgentTabState? {
        tab.surfaceId.flatMap { stateCenter.states[$0] }
    }

    private var displayTitle: String {
        if let custom = override?.name, !custom.isEmpty { return custom }
        return tab.title.isEmpty ? "Terminal" : tab.title
    }

    var body: some View {
        HStack(spacing: 6) {
            statusIndicator

            if let icon = override?.icon, !icon.isEmpty {
                SidebarGroupIcon(icon: icon, size: 11)
                    .foregroundStyle(.secondary)
            }

            if let accent = override?.color?.sidebarAccent {
                Circle()
                    .fill(accent)
                    .frame(width: 6, height: 6)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(displayTitle)
                    .font(.system(size: 11, weight: tab.isSelected ? .semibold : .regular))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if showDirectory, let dir = tab.directoryName {
                        Text(dir)
                            .lineLimit(1)
                    }

                    if showGitBranch, let branch = tab.gitBranch {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 8))
                            Text(branch)
                                .lineLimit(1)

                            if showGitStatus, repoInfo?.isDirty == true {
                                Circle()
                                    .fill(.yellow)
                                    .frame(width: 4, height: 4)
                                    .help("Uncommitted changes")
                            }
                        }
                    }

                    if showPullRequest, let prNumber = repoInfo?.prNumber {
                        Text("#\(prNumber)")
                            .foregroundStyle(Color.accentColor)
                            .help("Open pull request")
                    }
                }
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(rowBackground)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            tabManager.select(tab)
            if let surfaceId = tab.surfaceId {
                stateCenter.clearDone(surfaceId: surfaceId)
            }
        }
        .onChange(of: tab.isSelected) { selected in
            guard selected, let surfaceId = tab.surfaceId else { return }
            stateCenter.clearDone(surfaceId: surfaceId)
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
                Rectangle().fill(Color.accentColor).frame(height: 2)
            }
        }
        .overlay(alignment: .bottom) {
            if insertAfter == true {
                Rectangle().fill(Color.accentColor).frame(height: 2)
            }
        }
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

    /// Leading status: agent state takes precedence (spinner while
    /// working, bubble while waiting for input, green dot when output is
    /// ready), then the bell attention dot.
    @ViewBuilder
    private var statusIndicator: some View {
        switch agentState {
        case .working:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 12, height: 12)
        case .awaiting:
            Image(systemName: "questionmark.bubble.fill")
                .font(.system(size: 10))
                .foregroundStyle(.yellow)
        case .done:
            Circle()
                .fill(.green)
                .frame(width: 6, height: 6)
        case nil:
            if tab.needsAttention {
                Circle()
                    .fill(.orange)
                    .frame(width: 6, height: 6)
            }
        }
    }

    private var rowBackground: some ShapeStyle {
        if tab.isSelected {
            return AnyShapeStyle(Color(nsColor: .selectedContentBackgroundColor).opacity(0.6))
        } else if isHovered {
            return AnyShapeStyle(.quaternary)
        }
        return AnyShapeStyle(.clear)
    }

    @ViewBuilder
    private var tabMenu: some View {
        Button("Customize Tab…") { isCustomizing = true }
            .disabled(tab.surfaceId == nil)

        if let prNumber = repoInfo?.prNumber,
           let prURL = repoInfo?.prURL.flatMap(URL.init(string:)) {
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

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? .white : .primary)
                .frame(width: 32, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected
                            ? AnyShapeStyle(Color.accentColor)
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

    private static let symbols: [String] = [
        "folder", "terminal", "flame", "bolt", "star", "heart",
        "hammer", "wrench.and.screwdriver", "gearshape", "shippingbox", "cube", "globe",
        "server.rack", "cloud", "externaldrive", "chart.bar", "doc.text", "book",
        "briefcase", "building.2", "cart", "creditcard", "testtube.2", "ladybug",
        "leaf", "moon.stars", "sparkles", "gamecontroller", "music.note", "paintbrush",
    ]

    private let columns = [GridItem(.adaptive(minimum: 32), spacing: 6)]

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
            TextField("🔥", text: $emoji)
                .labelsHidden()
                .frame(width: 48)
                .multilineTextAlignment(.center)
                .onChange(of: emoji) { value in
                    guard let first = value.first else { return }
                    let single = String(first)
                    if emoji != single { emoji = single }
                    selection = single
                }
        }
        .onAppear {
            if !selection.isEmpty && !Self.symbols.contains(selection) {
                emoji = selection
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

    @State private var name = ""
    @State private var icon = ""
    @State private var color: TerminalTabColor = .none

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

                    LabeledContent("Color") {
                        HStack(spacing: 6) {
                            ForEach(TerminalTabColor.allCases, id: \.self) { swatch in
                                SidebarColorSwatch(color: swatch, isSelected: color == swatch) {
                                    color = swatch
                                }
                            }
                        }
                    }
                } footer: {
                    Text("Leave the name empty to keep the terminal's own title.")
                        .font(.caption)
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
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        store.setTabOverride(surfaceId: surfaceId, .init(
            name: trimmed.isEmpty ? nil : trimmed,
            icon: icon.isEmpty ? nil : icon,
            color: color == .none ? nil : color
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
    var assignSurfaceId: UUID? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var details: String = ""
    @State private var icon: String = "folder"
    @State private var color: TerminalTabColor = .none
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

                    LabeledContent("Color") {
                        HStack(spacing: 6) {
                            ForEach(TerminalTabColor.allCases, id: \.self) { swatch in
                                SidebarColorSwatch(color: swatch, isSelected: color == swatch) {
                                    color = swatch
                                }
                            }
                        }
                    }
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
                        .font(.caption)
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
        .frame(width: 330, height: 505)
        .onAppear { populate() }
    }

    private func populate() {
        guard let group else { return }
        name = group.name
        details = group.details ?? ""
        icon = group.icon
        color = group.color
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
            if let assignSurfaceId {
                store.assign(surfaceId: assignSurfaceId, to: created.id)
            }
        }
    }
}
