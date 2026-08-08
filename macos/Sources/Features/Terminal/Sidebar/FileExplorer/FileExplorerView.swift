import AppKit
import Combine
import SwiftUI

/// The file explorer panel: the workspace tree for whichever terminal is
/// selected.
struct FileExplorerView: View {
    @ObservedObject var tabManager: SidebarTabManager
    @ObservedObject var store: SidebarGroupStore

    @StateObject private var model = FileExplorerModel()
    @ObservedObject private var palette: ThemePalette = .shared
    @ObservedObject private var icons: FileIconProvider = .shared
    @ObservedObject private var refresh: FileExplorerRefresh = .shared

    private var selectedTab: SidebarTabModel? {
        tabManager.models.first { $0.isSelected }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if model.root == nil {
                empty
            } else {
                tree
            }
        }
        .onAppear {
            model.onRootModeChanged = syncRoot
            syncRoot()
        }
        .onChange(of: tabManager.groupingVersion) { _ in syncRoot() }
        .onChange(of: refresh.token) { _ in model.reloadVisible() }
        .onReceive(
            Publishers.MergeMany(tabManager.models.map { $0.objectWillChange })
        ) { _ in
            DispatchQueue.main.async { syncRoot() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 4) {
            Text(model.root?.lastPathComponent ?? "No Folder")
                .font(palette.font(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.head)

            Spacer(minLength: 0)

            Menu {
                Picker("Root", selection: $model.rootMode) {
                    ForEach(WorkspaceRootMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.inline)

                Divider()

                Toggle("Show Hidden Files", isOn: $model.showHiddenFiles)

                if !icons.themes.isEmpty {
                    Menu("Icon Theme") {
                        Button("SF Symbols") {
                            icons.select(FileIconProvider.symbolsOnly)
                        }
                        Divider()
                        ForEach(icons.themes, id: \.name) { theme in
                            Button(theme.name.capitalized) { icons.select(theme.name) }
                                .disabled(!theme.isSupported)
                        }
                    }
                }

                Divider()

                Button("Choose Editor App…") {
                    FileOpener.chooseApp(in: NSApp.keyWindow) { _ in }
                }
                if FileOpener.preferredApp != nil {
                    Button("Forget Editor App") { FileOpener.clearPreferredApp() }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(model.rootMode.detail)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text("No folder for this terminal")
                .font(palette.captionFont)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    // MARK: Tree

    private var tree: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.rows) { row in
                        FileExplorerRow(
                            row: row,
                            isExpanded: model.isExpanded(row.node),
                            isCurrent: row.node.path == model.currentDirectory,
                            onTap: { handleTap(row) }
                        )
                        .id(row.id)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)
            .onChange(of: model.currentDirectory) { path in
                guard let path else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(path, anchor: .center)
                }
            }
        }
    }

    // MARK: Actions

    private func handleTap(_ row: FileRow) {
        guard !row.isTruncationNotice else { return }

        if row.node.isDirectory {
            model.toggle(row.node)
            return
        }

        FileOpener.prompt(
            for: row.node.url,
            in: selectedTab?.window
        ) { surface(for: selectedTab) }
    }

    private func surface(for tab: SidebarTabModel?) -> Ghostty.SurfaceView? {
        guard let controller = tab?.window.windowController as? BaseTerminalController
        else { return nil }
        return controller.focusedSurface ?? controller.surfaceTree.root?.leftmostLeaf()
    }

    /// Recomputes the root from the selected terminal, then points the
    /// highlight at wherever that terminal currently is.
    private func syncRoot() {
        let tab = selectedTab

        var groupRoot: String?
        if let tab,
           let group = store.resolveGroup(surfaceId: tab.surfaceId, pwd: tab.pwd),
           case .project(let root) = group.kind {
            groupRoot = root
        }

        model.setRoot(WorkspaceRootResolver.resolve(
            mode: model.rootMode,
            groupRoot: groupRoot,
            repoRoot: tab?.repoRoot,
            pwd: tab?.pwd
        ))
        model.reveal(tab?.pwd)
    }
}

/// One row of the tree.
private struct FileExplorerRow: View {
    let row: FileRow
    let isExpanded: Bool
    let isCurrent: Bool
    let onTap: () -> Void

    @ObservedObject private var palette: ThemePalette = .shared
    @ObservedObject private var icons: FileIconProvider = .shared
    @State private var isHovered = false

    private var accent: Color { palette.accent ?? .accentColor }

    var body: some View {
        if row.isTruncationNotice {
            notice
        } else {
            content
        }
    }

    private var notice: some View {
        Text(row.node.name)
            .font(palette.font(size: 10))
            .foregroundStyle(.tertiary)
            .padding(.leading, indent + 18)
            .padding(.vertical, 3)
    }

    private var content: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                disclosure
                FileIconView(icon: icon)
                Text(row.node.name)
                    .font(palette.font(size: 11, weight: isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, indent)
            .padding(.trailing, 6)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(background)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .contextMenu { menu }
        .help(row.node.path)
    }

    @ViewBuilder
    private var disclosure: some View {
        if row.node.isDirectory {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 10)
        } else {
            Color.clear.frame(width: 10, height: 1)
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([row.node.url])
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(row.node.path, forType: .string)
        }
    }

    private var icon: FileIcon {
        row.node.isDirectory
            ? icons.icon(forFolder: row.node.name, expanded: isExpanded)
            : icons.icon(forFile: row.node.name)
    }

    private var background: Color {
        if isCurrent { return accent.opacity(0.28) }
        return isHovered ? accent.opacity(0.12) : .clear
    }

    private var indent: CGFloat {
        CGFloat(row.depth) * 12
    }
}
