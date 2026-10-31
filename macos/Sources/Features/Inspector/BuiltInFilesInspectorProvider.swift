import AppKit
import Foundation
import OSLog
import UniformTypeIdentifiers

@MainActor
final class BuiltInFilesInspectorProvider {
    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "oh-my-ghostty",
        category: "files-inspector"
    )
    static let pluginID = "builtin.files"
    static let paneID = "builtin.files"
    typealias OpenFileHandler = @MainActor (String, InspectorPaneContext, EditorOpenDestination) -> Void

    private static let rootTaskID = "__root__"
    private static let loadingTaskID = "__loading__"
    private static let mutationTaskID = "__mutation__"

    private struct BrowserState {
        var context: InspectorPaneContext
        var rootPath: String
        var filesystem: any WorkspaceFilesystem
        var expanded: Set<String> = []
        var generation: UInt64 = 0
        var tree: InspectorFileTree?
    }

    private struct LoadKey: Hashable {
        let tabID: UUID
        let nodeID: String
    }

    private let registry: InspectorRegistry
    private let filesystemFactory: (InspectorPaneContext) -> any WorkspaceFilesystem
    private let openFile: OpenFileHandler
    private var states: [UUID: BrowserState] = [:]
    private var loadTasks: [LoadKey: Task<Void, Never>] = [:]

    init(
        registry: InspectorRegistry,
        filesystemFactory: @escaping (InspectorPaneContext) -> any WorkspaceFilesystem =
            WorkspaceFilesystemFactory.make,
        openFile: @escaping OpenFileHandler
    ) {
        self.registry = registry
        self.filesystemFactory = filesystemFactory
        self.openFile = openFile
    }

    func register() throws {
        let descriptor = InspectorPaneDescriptor(
            id: Self.paneID,
            title: "Files",
            systemImage: "folder",
            source: .plugin(Self.pluginID),
            preferredWidth: RightInspectorMetrics.defaultWidth,
            minimumWidth: 220
        )
        try registry.registerPluginPane(
            descriptor,
            lifecycle: { [weak self] event in self?.handle(event) },
            action: { [weak self] action in self?.handle(action) }
        )
    }

    func forgetTab(_ tabID: UUID) {
        cancelTasks(tabID: tabID)
        states.removeValue(forKey: tabID)
    }

    private func handle(_ event: InspectorPaneLifecycleEvent) {
        guard case .appeared(let context) = event else {
            if case .disappeared(let previousContext) = event {
                cancelTasks(tabID: previousContext.tabID)
                Self.logger.debug("Files pane disappeared tab=\(previousContext.tabID.uuidString, privacy: .public)")
            }
            return
        }
        Self.logger.debug("Files pane appeared tab=\(context.tabID.uuidString, privacy: .public) cwd=\(context.workingDirectory ?? "<none>", privacy: .public)")
        guard context.workingDirectory?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty == false else {
            cancelTasks(tabID: context.tabID)
            states.removeValue(forKey: context.tabID)
            publish(
                .empty(
                    title: "Files",
                    message: "The terminal has not reported a working directory."
                ),
                tabID: context.tabID
            )
            return
        }

        let previousState = states[context.tabID]
        var state = state(for: context)
        state.context = context
        states[context.tabID] = state
        if previousState?.rootPath == state.rootPath, state.tree != nil {
            Self.logger.debug("Files context updated without root reload tab=\(context.tabID.uuidString, privacy: .public)")
            return
        }
        if previousState?.rootPath != state.rootPath {
            Self.logger.debug("Files cwd changed tab=\(context.tabID.uuidString, privacy: .public) root=\(state.rootPath, privacy: .public)")
        }
        reloadRoot(
            context: context,
            reason: previousState == nil ? "appear" : "cwd"
        )
    }

    private func handle(_ action: InspectorPaneAction) {
        let context = action.context
        var state = state(for: context)
        switch action.kind {
        case .toggleNode(let id, let expanded):
            Self.logger.debug("Files disclosure tab=\(context.tabID.uuidString, privacy: .public) node=\(id, privacy: .public) expanded=\(expanded)")
            guard let tree = state.tree,
                  let node = Self.findNode(id: id, in: tree.nodes),
                  node.isDirectory else {
                Self.logger.error("Files disclosure ignored missing node=\(id, privacy: .public)")
                return
            }

            if expanded {
                state.expanded.insert(id)
                state.tree = Self.updatingTree(tree, nodeID: id) { current in
                    Self.copy(
                        current,
                        isExpanded: true,
                        isLoading: current.children == nil,
                        children: current.children
                    )
                }
                states[context.tabID] = state
                publishTree(for: context.tabID)
                if node.children == nil {
                    loadChildren(nodeID: id, context: context)
                }
            } else {
                state.expanded = Set(state.expanded.filter {
                    $0 != id && !$0.hasPrefix(id + "/")
                })
                cancelNodeTasks(tabID: context.tabID, pathPrefix: id)
                state.tree = Self.updatingTree(tree, nodeID: id) { current in
                    Self.copy(
                        current,
                        isExpanded: false,
                        isLoading: false,
                        children: current.children
                    )
                }
                states[context.tabID] = state
                publishTree(for: context.tabID)
            }

        case .openFile(let path, let destination):
            guard let tree = state.tree,
                  let node = Self.findNode(id: path, in: tree.nodes),
                  !node.isDirectory else {
                Self.logger.error("Files open ignored missing file=\(path, privacy: .public)")
                return
            }
            openFile(path, state.context, destination ?? OhMyGhosttySettings.shared.editorFileOpenDestination)

        case .copyFilePath(let path, let relative):
            guard let tree = state.tree, Self.findNode(id: path, in: tree.nodes) != nil else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                relative ? WorkspaceFileActions.relativePath(path, root: state.rootPath) : path,
                forType: .string
            )

        case .renameFile(let path):
            rename(path: path, context: context)

        case .openFileExternally(let path):
            openExternally(path: path, context: context)

        case .refresh:
            states[context.tabID] = state
            reloadRoot(context: context, reason: "manual-refresh")

        case .collapseAll:
            state.expanded.removeAll()
            cancelNodeTasks(tabID: context.tabID)
            if let tree = state.tree {
                state.tree = .init(
                    rootName: tree.rootName,
                    rootPath: tree.rootPath,
                    nodes: Self.collapsing(nodes: tree.nodes)
                )
            }
            states[context.tabID] = state
            publishTree(for: context.tabID)

        case .createFile(let name):
            create(name: name, directory: false, context: context)

        case .createFolder(let name):
            create(name: name, directory: true, context: context)

        case .createPortForward, .openPortForward, .copyPortForward,
             .removePortForward, .refreshAgentHistory, .setAgentHistoryTimeRange,
             .selectAgentHistorySession, .clearAgentHistorySelection,
             .resumeAgentHistorySession, .forkAgentHistorySession,
             .jumpToHistoryItem,
             .gitAction:
            break
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "File operation failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func rename(path: String, context: InspectorPaneContext) {
        let state = state(for: context)
        guard let tree = state.tree, let node = Self.findNode(id: path, in: tree.nodes) else { return }
        guard !EditorWorkspaceStore.shared.containsOpenDocument(path: path, descriptor: state.filesystem.descriptor) else {
            showError(WorkspaceFilesystemError.operationFailed(
                "Close this file and any open files inside this folder before renaming it."
            ))
            return
        }
        let alert = NSAlert()
        alert.messageText = "Rename \(node.name)"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: (node.id as NSString).lastPathComponent)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue
        do { _ = try WorkspaceFileActions.renamedPath(path, name: name) } catch {
            showError(error)
            return
        }
        guard name != (node.id as NSString).lastPathComponent else { return }
        guard !EditorWorkspaceStore.shared.containsOpenDocument(path: path, descriptor: state.filesystem.descriptor) else {
            showError(WorkspaceFilesystemError.operationFailed("Close this file and any open files inside this folder before renaming it."))
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await state.filesystem.renameItem(at: path, to: name)
                guard let current = states[context.tabID],
                      current.filesystem.descriptor == state.filesystem.descriptor,
                      current.context.session.state == state.context.session.state else { return }
                let newPath = try WorkspaceFileActions.renamedPath(path, name: name)
                states[context.tabID]?.expanded = Set(current.expanded.map { expanded in
                    if expanded == path { return newPath }
                    return expanded.hasPrefix(path + "/") ? newPath + expanded.dropFirst(path.count) : expanded
                })
                reloadRoot(context: current.context, reason: "rename")
            } catch {
                showError(error)
            }
        }
    }

    private func openExternally(path: String, context: InspectorPaneContext) {
        let state = state(for: context)
        guard let tree = state.tree, let node = Self.findNode(id: path, in: tree.nodes) else { return }
        let remote = state.filesystem.descriptor.kind == .ssh
        guard !remote || !node.isDirectory else {
            showError(WorkspaceFilesystemError.operationFailed("Open in… supports remote files, but not remote folders."))
            return
        }
        let panel = NSOpenPanel()
        panel.title = remote ? "Open a read-only downloaded copy in…" : "Open in…"
        panel.message = remote ? "Changes in the other app will not be uploaded to the server." : "Choose an application."
        panel.prompt = "Open"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let application = panel.url else { return }
        Task { [weak self] in
            do {
                let url = try await EditorFileOpening.externalURL(path: path, filesystem: state.filesystem)
                let configuration = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.open([url], withApplicationAt: application, configuration: configuration) { _, error in
                    guard let error else { return }
                    Task { @MainActor [weak self] in self?.showError(error) }
                }
            } catch {
                self?.showError(error)
            }
        }
    }

    private func state(for context: InspectorPaneContext) -> BrowserState {
        let filesystem = filesystemFactory(context)
        let rootPath = filesystem.descriptor.workingDirectory
        if var state = states[context.tabID], state.rootPath == rootPath,
           state.filesystem.descriptor == filesystem.descriptor,
           state.context.session.state == context.session.state {
            state.context = context
            return state
        }
        cancelTasks(tabID: context.tabID)
        return .init(
            context: context,
            rootPath: rootPath,
            filesystem: filesystem
        )
    }

    private func reloadRoot(context: InspectorPaneContext, reason: String) {
        var state = state(for: context)
        state.generation &+= 1
        states[context.tabID] = state
        let generation = state.generation
        let rootPath = state.rootPath
        let filesystem = state.filesystem
        let expanded = state.expanded
        let key = LoadKey(tabID: context.tabID, nodeID: Self.rootTaskID)

        cancelTasks(tabID: context.tabID)
        if state.tree == nil {
            let loadingKey = LoadKey(
                tabID: context.tabID,
                nodeID: Self.loadingTaskID
            )
            let loadingDelay = filesystem.descriptor.kind == .local ? 300 : 150
            loadTasks[loadingKey] = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(loadingDelay))
                guard !Task.isCancelled,
                      let self,
                      states[context.tabID]?.generation == generation,
                      states[context.tabID]?.tree == nil else { return }
                publish(
                    .empty(title: "Files", message: "Loading…"),
                    tabID: context.tabID
                )
                loadTasks.removeValue(forKey: loadingKey)
            }
        }
        let started = ContinuousClock.now
        Self.logger.debug("Files root refresh started tab=\(context.tabID.uuidString, privacy: .public) generation=\(generation) reason=\(reason, privacy: .public) root=\(rootPath, privacy: .public) expanded=\(expanded.count)")
        let diskTask = Task.detached(priority: .utility) {
            await Self.loadContent(
                rootPath: rootPath,
                filesystem: filesystem,
                expanded: expanded
            )
        }
        loadTasks[key] = Task { [weak self] in
            let content = await withTaskCancellationHandler(
                operation: { await diskTask.value },
                onCancel: { diskTask.cancel() }
            )
            guard !Task.isCancelled,
                  let self,
                  states[context.tabID]?.generation == generation else {
                Self.logger.debug("Files root refresh discarded tab=\(context.tabID.uuidString, privacy: .public) generation=\(generation)")
                return
            }
            let loadingKey = LoadKey(
                tabID: context.tabID,
                nodeID: Self.loadingTaskID
            )
            loadTasks.removeValue(forKey: loadingKey)?.cancel()
            if case .fileTree(let tree) = content {
                states[context.tabID]?.tree = tree
            }
            publish(content, tabID: context.tabID)
            loadTasks.removeValue(forKey: key)
            let elapsed = ContinuousClock.now - started
            Self.logger.debug("Files root refresh completed tab=\(context.tabID.uuidString, privacy: .public) generation=\(generation) elapsed=\(elapsed) summary=\(Self.summary(content), privacy: .public)")
        }
    }

    private func loadChildren(nodeID: String, context: InspectorPaneContext) {
        guard let state = states[context.tabID] else { return }
        let generation = state.generation
        let expanded = state.expanded
        let filesystem = state.filesystem
        let key = LoadKey(tabID: context.tabID, nodeID: nodeID)
        loadTasks[key]?.cancel()
        let started = ContinuousClock.now
        Self.logger.debug("Files subtree read started tab=\(context.tabID.uuidString, privacy: .public) node=\(nodeID, privacy: .public) generation=\(generation)")
        let diskTask = Task.detached(priority: .utility) {
            do {
                return try await Self.loadNodes(
                    at: nodeID,
                    filesystem: filesystem,
                    expanded: expanded,
                    depth: 0
                )
            } catch {
                return []
            }
        }
        loadTasks[key] = Task { [weak self] in
            let children = await withTaskCancellationHandler(
                operation: { await diskTask.value },
                onCancel: { diskTask.cancel() }
            )
            guard !Task.isCancelled,
                  let self,
                  var current = states[context.tabID],
                  current.generation == generation,
                  current.expanded.contains(nodeID),
                  let tree = current.tree else {
                Self.logger.debug("Files subtree read discarded tab=\(context.tabID.uuidString, privacy: .public) node=\(nodeID, privacy: .public)")
                return
            }
            current.tree = Self.updatingTree(tree, nodeID: nodeID) { node in
                Self.copy(
                    node,
                    isExpanded: true,
                    isLoading: false,
                    children: children
                )
            }
            states[context.tabID] = current
            publishTree(for: context.tabID)
            loadTasks.removeValue(forKey: key)
            let elapsed = ContinuousClock.now - started
            Self.logger.debug("Files subtree read completed tab=\(context.tabID.uuidString, privacy: .public) node=\(nodeID, privacy: .public) children=\(children.count) elapsed=\(elapsed)")
        }
    }

    private func publishTree(for tabID: UUID) {
        guard let tree = states[tabID]?.tree else { return }
        publish(.fileTree(tree), tabID: tabID)
    }

    private func publish(_ content: InspectorPaneContent, tabID: UUID) {
        do {
            try registry.updatePluginContent(
                paneID: Self.paneID,
                pluginID: Self.pluginID,
                tabID: tabID,
                content: content
            )
        } catch {
            Self.logger.error("Files state publish failed tab=\(tabID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func cancelTasks(tabID: UUID) {
        let keys = loadTasks.keys.filter { $0.tabID == tabID }
        for key in keys {
            loadTasks.removeValue(forKey: key)?.cancel()
        }
    }

    private func cancelNodeTasks(tabID: UUID, pathPrefix: String? = nil) {
        let keys = loadTasks.keys.filter { key in
            guard key.tabID == tabID, key.nodeID != Self.rootTaskID else { return false }
            guard let pathPrefix else { return true }
            return key.nodeID == pathPrefix || key.nodeID.hasPrefix(pathPrefix + "/")
        }
        for key in keys {
            loadTasks.removeValue(forKey: key)?.cancel()
        }
    }

    private func create(
        name: String,
        directory: Bool,
        context: InspectorPaneContext
    ) {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validChildName(normalized) else {
            Self.logger.error("Files create rejected invalid name=\(normalized, privacy: .public)")
            return
        }
        let state = state(for: context)
        states[context.tabID] = state
        let expectedDescriptor = state.filesystem.descriptor
        let expectedSessionState = context.session.state
        let previousMutationKeys = loadTasks.keys.filter {
            $0.tabID == context.tabID &&
                $0.nodeID.hasPrefix(Self.mutationTaskID + ":")
        }
        for previousKey in previousMutationKeys {
            loadTasks.removeValue(forKey: previousKey)?.cancel()
        }
        let key = LoadKey(
            tabID: context.tabID,
            nodeID: Self.mutationTaskID + ":" + UUID().uuidString
        )
        loadTasks[key] = Task { [weak self] in
            do {
                if directory {
                    try await state.filesystem.createDirectory(
                        named: normalized,
                        in: state.rootPath
                    )
                } else {
                    try await state.filesystem.createFile(
                        named: normalized,
                        in: state.rootPath
                    )
                }
            } catch {
                if !Task.isCancelled {
                    Self.logger.error("Files create failed error=\(error.localizedDescription, privacy: .public)")
                }
            }
            guard !Task.isCancelled,
                  let self,
                  let current = states[context.tabID],
                  current.filesystem.descriptor == expectedDescriptor,
                  current.context.session.state == expectedSessionState else {
                self?.loadTasks.removeValue(forKey: key)
                return
            }
            loadTasks.removeValue(forKey: key)
            reloadRoot(
                context: current.context,
                reason: directory ? "create-folder" : "create-file"
            )
        }
    }

    nonisolated private static func validChildName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." &&
            !name.contains("/") && !name.contains(":")
    }

    private static func loadContent(
        rootPath: String,
        filesystem: any WorkspaceFilesystem,
        expanded: Set<String>
    ) async -> InspectorPaneContent {
        let started = ContinuousClock.now
        do {
            let nodes = try await loadNodes(
                at: rootPath,
                filesystem: filesystem,
                expanded: expanded,
                depth: 0
            )
            let elapsed = ContinuousClock.now - started
            Self.logger.debug("Files root read completed root=\(rootPath, privacy: .public) nodes=\(nodes.count) elapsed=\(elapsed)")
            return .fileTree(.init(
                rootName: WorkspacePathPresentation.folderName(rootPath),
                rootPath: rootPath,
                nodes: nodes
            ))
        } catch {
            return .empty(
                title: "Files",
                message: "The current working directory is unavailable."
            )
        }
    }

    private static func loadNodes(
        at path: String,
        filesystem: any WorkspaceFilesystem,
        expanded: Set<String>,
        depth: Int
    ) async throws -> [InspectorFileNode] {
        guard depth < 24, !Task.isCancelled else { return [] }
        let started = ContinuousClock.now
        let entries = try await filesystem.listTreeDirectory(at: path)
        let boundedEntries = Array(entries.prefix(500))
        let elapsed = ContinuousClock.now - started
        Self.logger.debug("Files directory read path=\(path, privacy: .public) depth=\(depth) entries=\(boundedEntries.count) elapsed=\(elapsed)")

        var nodes: [InspectorFileNode] = []
        nodes.reserveCapacity(boundedEntries.count)
        for entry in boundedEntries where !Task.isCancelled {
            let isExpanded = entry.isDirectory && expanded.contains(entry.path)
            let children = isExpanded
                ? try await loadNodes(
                    at: entry.path,
                    filesystem: filesystem,
                    expanded: expanded,
                    depth: depth + 1
                )
                : nil
            nodes.append(.init(
                id: entry.path,
                name: entry.name,
                isDirectory: entry.isDirectory,
                icon: icon(for: entry.name, isDirectory: entry.isDirectory),
                isExpanded: isExpanded,
                isLoading: false,
                children: children
            ))
        }
        return nodes
    }

    nonisolated private static func findNode(
        id: String,
        in nodes: [InspectorFileNode]
    ) -> InspectorFileNode? {
        for node in nodes {
            if node.id == id { return node }
            if let match = findNode(id: id, in: node.children ?? []) { return match }
        }
        return nil
    }

    nonisolated private static func updatingTree(
        _ tree: InspectorFileTree,
        nodeID: String,
        transform: (InspectorFileNode) -> InspectorFileNode
    ) -> InspectorFileTree {
        .init(
            rootName: tree.rootName,
            rootPath: tree.rootPath,
            nodes: updating(nodes: tree.nodes, nodeID: nodeID, transform: transform)
        )
    }

    nonisolated private static func updating(
        nodes: [InspectorFileNode],
        nodeID: String,
        transform: (InspectorFileNode) -> InspectorFileNode
    ) -> [InspectorFileNode] {
        nodes.map { node in
            if node.id == nodeID { return transform(node) }
            guard let children = node.children else { return node }
            let updatedChildren = updating(
                nodes: children,
                nodeID: nodeID,
                transform: transform
            )
            guard updatedChildren != children else { return node }
            return copy(node, children: updatedChildren)
        }
    }

    nonisolated private static func collapsing(
        nodes: [InspectorFileNode]
    ) -> [InspectorFileNode] {
        nodes.map { node in
            copy(
                node,
                isExpanded: false,
                isLoading: false,
                children: node.children.map(collapsing(nodes:))
            )
        }
    }

    nonisolated private static func copy(
        _ node: InspectorFileNode,
        isExpanded: Bool? = nil,
        isLoading: Bool? = nil,
        children: [InspectorFileNode]? = nil
    ) -> InspectorFileNode {
        .init(
            id: node.id,
            name: node.name,
            isDirectory: node.isDirectory,
            icon: node.icon,
            isExpanded: isExpanded ?? node.isExpanded,
            isLoading: isLoading ?? node.isLoading,
            children: children ?? node.children
        )
    }

    nonisolated private static func summary(_ content: InspectorPaneContent) -> String {
        switch content {
        case .fileTree(let tree): "fileTree root=\(tree.rootPath) nodes=\(tree.nodes.count)"
        case .empty(let title, _): "empty title=\(title)"
        case .fields(let fields): "fields count=\(fields.count)"
        case .list(let items): "list count=\(items.count)"
        case .info(let info):
            "info host=\(info.portForwards.hostAlias) forwards=\(info.portForwards.items.count)"
        case .agentHistory(let history):
            "agentHistory sessions=\(history.sessions.count)"
        case .git(let git):
            "git repo=\(git.repository?.worktreePath ?? "<none>") tab=\(git.activeTab.rawValue)"
        }
    }

    nonisolated private static func icon(
        for name: String,
        isDirectory: Bool
    ) -> InspectorFileIcon {
        if isDirectory {
            return .init(systemImage: "folder", tint: .blue)
        }

        let lower = name.lowercased()
        let ext = URL(fileURLWithPath: lower).pathExtension
        if [".gitconfig", ".gitignore", ".gitattributes"].contains(lower) ||
            lower == "gitconfig" {
            return .init(systemImage: "point.3.connected.trianglepath.dotted", tint: .orange)
        }
        if [".zshrc", ".zprofile", ".bashrc", ".bash_profile", ".profile"].contains(lower) {
            return .init(systemImage: "terminal", tint: .green)
        }
        if ["package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock"].contains(lower) {
            return .init(systemImage: "shippingbox", tint: .red)
        }
        if ["cargo.toml", "cargo.lock"].contains(lower) {
            return .init(systemImage: "gearshape.2", tint: .orange)
        }

        switch ext {
        case "swift": return .init(systemImage: "swift", tint: .orange)
        case "js", "jsx": return .init(systemImage: "curlybraces", tint: .yellow)
        case "ts", "tsx": return .init(systemImage: "curlybraces", tint: .blue)
        case "json": return .init(systemImage: "curlybraces.square", tint: .yellow)
        case "py": return .init(systemImage: "chevron.left.forwardslash.chevron.right", tint: .yellow)
        case "rs": return .init(systemImage: "gearshape.2", tint: .orange)
        case "go": return .init(systemImage: "g.circle", tint: .blue)
        case "zig": return .init(systemImage: "bolt", tint: .orange)
        case "sh", "bash", "zsh", "fish": return .init(systemImage: "terminal", tint: .green)
        case "md", "markdown": return .init(systemImage: "doc.richtext", tint: .blue)
        case "yaml", "yml", "toml", "ini", "conf":
            return .init(systemImage: "gearshape.2", tint: .secondary)
        case "png", "jpg", "jpeg", "gif", "webp", "svg":
            return .init(systemImage: "photo", tint: .purple)
        case "pdf": return .init(systemImage: "doc.richtext", tint: .red)
        default: return .init(systemImage: "doc.text", tint: .secondary)
        }
    }
}
