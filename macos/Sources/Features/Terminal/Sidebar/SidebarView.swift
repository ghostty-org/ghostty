import SwiftUI
import UniformTypeIdentifiers

/// The vertical tab sidebar: tabs grouped into user-defined sections.
struct SidebarView: View {
    @ObservedObject var tabManager: SidebarTabManager
    @ObservedObject var store: SidebarGroupStore

    /// One rendered section: a group (nil for the default section) and
    /// the tabs resolved into it.
    private struct Section: Identifiable {
        let group: SidebarGroup?
        let tabs: [SidebarTabManager.TabItem]

        var id: UUID { group?.id ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")! }
    }

    private var sections: [Section] {
        var byGroup: [UUID: [SidebarTabManager.TabItem]] = [:]
        var ungrouped: [SidebarTabManager.TabItem] = []

        for tab in tabManager.tabs {
            if let group = store.resolveGroup(surfaceId: tab.surfaceId, pwd: tab.pwd) {
                byGroup[group.id, default: []].append(tab)
            } else {
                ungrouped.append(tab)
            }
        }

        var result = store.groups.map { Section(group: $0, tabs: byGroup[$0.id] ?? []) }
        if !ungrouped.isEmpty || result.isEmpty {
            result.append(Section(group: nil, tabs: ungrouped))
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(sections) { section in
                        SidebarGroupSection(
                            group: section.group,
                            tabs: section.tabs,
                            tabManager: tabManager,
                            store: store
                        )
                    }
                }
                .padding(8)
            }

            Divider()

            SidebarFooter(store: store)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }
}

/// A group block: tinted header with icon, name and color dot, a colored
/// border around the whole block, and the tab rows when expanded.
private struct SidebarGroupSection: View {
    let group: SidebarGroup?
    let tabs: [SidebarTabManager.TabItem]
    let tabManager: SidebarTabManager
    @ObservedObject var store: SidebarGroupStore

    @State private var isDropTarget = false
    @State private var isEditing = false

    private var accent: Color? { group?.color.sidebarAccent }
    private var collapsed: Bool { group?.collapsed ?? false }

    var body: some View {
        VStack(spacing: 0) {
            header

            if !collapsed {
                VStack(spacing: 2) {
                    ForEach(tabs) { tab in
                        SidebarTabRow(tab: tab, tabManager: tabManager, store: store)
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
                .fill((accent ?? .secondary).opacity(group == nil ? 0 : 0.06))
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isDropTarget
                        ? (accent ?? .accentColor)
                        : (accent ?? .secondary).opacity(group == nil ? 0 : 0.35),
                    lineWidth: isDropTarget ? 2 : 1
                )
        )
        .onDrop(of: [.plainText], isTargeted: $isDropTarget) { providers in
            handleDrop(providers)
        }
        .popover(isPresented: $isEditing) {
            if let group {
                SidebarGroupEditor(group: group, store: store)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                if let group { store.toggleCollapsed(group.id) }
            } label: {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            .opacity(group == nil ? 0 : 1)
            .disabled(group == nil)

            SidebarGroupIcon(icon: group?.icon ?? "square.stack")
                .foregroundStyle(accent ?? Color.secondary)

            if let accent {
                Circle()
                    .fill(accent)
                    .frame(width: 6, height: 6)
            }

            Text(group?.name ?? "Tabs")
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)

            Spacer(minLength: 0)

            Text("\(tabs.count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(.quaternary))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background((accent ?? .clear).opacity(group == nil ? 0 : 0.18))
        .contentShape(Rectangle())
        .onTapGesture {
            if let group { store.toggleCollapsed(group.id) }
        }
        .contextMenu { groupMenu }
    }

    @ViewBuilder
    private var groupMenu: some View {
        if let group {
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
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String,
                  let surfaceId = UUID(uuidString: string)
            else { return }
            Task { @MainActor in
                store.assign(surfaceId: surfaceId, to: group?.id)
            }
        }
        return true
    }
}

/// One tab row: title + working directory, click to activate.
private struct SidebarTabRow: View {
    let tab: SidebarTabManager.TabItem
    let tabManager: SidebarTabManager
    @ObservedObject var store: SidebarGroupStore

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            if tab.needsAttention {
                Circle()
                    .fill(.orange)
                    .frame(width: 6, height: 6)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(tab.title.isEmpty ? "Terminal" : tab.title)
                    .font(.system(size: 11, weight: tab.isSelected ? .semibold : .regular))
                    .lineLimit(1)

                if let dir = tab.directoryName {
                    Text(dir)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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
        .onTapGesture { tabManager.select(tab) }
        .onHover { isHovered = $0 }
        .onDrag {
            NSItemProvider(object: (tab.surfaceId?.uuidString ?? "") as NSString)
        }
        .contextMenu { tabMenu }
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
        Menu("Move to Group") {
            ForEach(store.groups) { group in
                Button(group.name) {
                    guard let surfaceId = tab.surfaceId else { return }
                    store.assign(surfaceId: surfaceId, to: group.id)
                }
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

/// Footer with the "new group" action.
private struct SidebarFooter: View {
    @ObservedObject var store: SidebarGroupStore

    @State private var isCreating = false

    var body: some View {
        HStack {
            Button {
                isCreating = true
            } label: {
                Label("New Group", systemImage: "plus")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .popover(isPresented: $isCreating) {
                SidebarGroupEditor(group: nil, store: store)
            }

            Spacer()
        }
        .padding(8)
    }
}

/// Popover to create or edit a group: name, icon (emoji or SF Symbol),
/// project root for rule-based groups, and color.
private struct SidebarGroupEditor: View {
    let group: SidebarGroup?
    @ObservedObject var store: SidebarGroupStore

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var icon: String = "folder"
    @State private var color: TerminalTabColor = .none
    @State private var isProject: Bool = false
    @State private var projectRoot: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(group == nil ? "New Group" : "Edit Group")
                .font(.headline)

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)

            TextField("Icon (emoji or SF Symbol)", text: $icon)
                .textFieldStyle(.roundedBorder)

            Picker("Color", selection: $color) {
                ForEach(TerminalTabColor.allCases, id: \.self) { color in
                    Text(color.localizedName).tag(color)
                }
            }

            Toggle("Project group (auto-claim by directory)", isOn: $isProject)

            if isProject {
                TextField("Project root (e.g. ~/Projects/front-app-eita)", text: $projectRoot)
                    .textFieldStyle(.roundedBorder)
            }

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
        }
        .padding(12)
        .frame(width: 280)
        .onAppear { populate() }
    }

    private func populate() {
        guard let group else { return }
        name = group.name
        icon = group.icon
        color = group.color
        if case .project(let root) = group.kind {
            isProject = true
            projectRoot = root
        }
    }

    private func save() {
        let kind: SidebarGroup.Kind = isProject && !projectRoot.isEmpty
            ? .project(root: projectRoot)
            : .manual

        if let group {
            store.update(group.id) {
                $0.name = name
                $0.icon = icon
                $0.color = color
                $0.kind = kind
            }
        } else {
            _ = store.createGroup(name: name, icon: icon, color: color, kind: kind)
        }
    }
}
