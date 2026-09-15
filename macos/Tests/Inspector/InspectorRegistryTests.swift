import Foundation
import Testing
@testable import Ghostty

@MainActor
struct InspectorRegistryTests {
    @Test(arguments: ["builtin.git", "custom.title-pane"])
    func titleChangesOnlyRestartTitleDependentPanes(paneID: String) throws {
        let registry = InspectorRegistry()
        var events: [InspectorPaneLifecycleEvent] = []
        try registry.registerCorePane(
            paneDescriptor(id: paneID, source: .coreFeature("test")),
            content: { _ in .fields([]) }, lifecycle: { events.append($0) }
        )
        let tabID = UUID(), surfaceID = UUID()
        var session = PaneSessionContext(workingDirectory: "/repo", terminalTitle: "first")
        func context() -> InspectorPaneContext {
            .init(tabID: tabID, surfaceID: surfaceID, title: session.presentationTitle,
                  workingDirectory: session.workingDirectory, session: session)
        }
        let initial = context()
        registry.presentationDidChange(to: paneID, context: initial)
        for index in 0..<100 {
            session.updateLocalMetadata(workingDirectory: "/repo", terminalTitle: "title \(index)")
            registry.presentationDidChange(to: paneID, context: context())
        }
        #expect(events.count == (paneID == "builtin.git" ? 1 : 201))
        let latest = context()
        session.updateLocalMetadata(workingDirectory: "/other", terminalTitle: "title 99")
        let moved = context()
        registry.presentationDidChange(to: paneID, context: moved)
        #expect(Array(events.suffix(2)) == [.disappeared(latest), .appeared(moved)])
        registry.presentationDidChange(to: nil, context: moved)
        #expect(events.last == .disappeared(moved))
    }

    @Test func closedTabsReleaseSnapshotsAndRejectLateResults() throws {
        let registry = InspectorRegistry()
        let descriptor = paneDescriptor(id: "cache", source: .plugin("owner"))
        var actions = 0
        try registry.registerPluginPane(descriptor, action: { _ in actions += 1 })
        let first = InspectorPaneContext(tabID: UUID(), surfaceID: nil, title: "first", workingDirectory: nil)
        let second = InspectorPaneContext(tabID: UUID(), surfaceID: nil, title: "second", workingDirectory: nil)
        let content = InspectorPaneContent.empty(title: "data", message: String(repeating: "large transcript ", count: 10000))
        for context in [first, second] {
            try registry.updatePluginContent(paneID: "cache", pluginID: "owner", tabID: context.tabID, content: content)
        }
        registry.closeTab(first.tabID)
        #expect(registry.isTabClosed(first.tabID))
        #expect(registry.content(for: "cache", context: first) != content)
        #expect(registry.content(for: "cache", context: second) == content)
        registry.presentationDidChange(to: "cache", context: first)
        registry.performAction(paneID: "cache", action: .init(context: first, kind: .refresh))
        #expect(actions == 0)
        try registry.updatePluginContent(paneID: "cache", pluginID: "owner", tabID: first.tabID, content: content)
        #expect(registry.isTabClosed(first.tabID))
        #expect(registry.content(for: "cache", context: first) != content)
        registry.openTab(first.tabID)
        try registry.updatePluginContent(paneID: "cache", pluginID: "owner", tabID: first.tabID, content: content)
        #expect(registry.content(for: "cache", context: first) == content)
    }

    @Test func inspectorToggleOwnsAFixedTrailingSlot() {
        #expect(InspectorTitlebarLayout.pluginWidth(
            totalWidth: TerminalTitlebarMetrics.inspectorCollapsedWidth
        ) == 0)
        #expect(InspectorTitlebarLayout.pluginWidth(totalWidth: 300) == 256)
    }

    @Test func pluginBarUsesStableOverflowBuckets() {
        let descriptors = [
            paneDescriptor(id: "files", source: .coreFeature("files"), title: "Files"),
            paneDescriptor(id: "git", source: .coreFeature("git"), title: "Git"),
            paneDescriptor(id: "ssh", source: .coreFeature("ssh"), title: "SSH"),
            paneDescriptor(id: "info", source: .coreFeature("info"), title: "Info"),
        ]

        let wide = InspectorPluginBarLayout.resolve(
            descriptors: descriptors,
            selectedID: "files",
            availableWidth: 240
        )
        #expect(wide.visibleIDs == ["files", "git", "ssh", "info"])
        #expect(wide.overflowIDs.isEmpty)

        let medium = InspectorPluginBarLayout.resolve(
            descriptors: descriptors,
            selectedID: "files",
            availableWidth: 120
        )
        #expect(medium.visibleIDs == ["files"])
        #expect(medium.overflowIDs == ["git", "ssh", "info"])

        let selectedOverflow = InspectorPluginBarLayout.resolve(
            descriptors: descriptors,
            selectedID: "git",
            availableWidth: 100
        )
        #expect(selectedOverflow.visibleIDs == ["files"])
        #expect(selectedOverflow.overflowIDs.contains("git"))

        #expect(medium == InspectorPluginBarLayout.resolve(
            descriptors: descriptors,
            selectedID: "files",
            availableWidth: 127
        ))
    }

    @Test func inspectorContentSharesLeadingBaseline() {
        let activeTitlebarContent = InspectorContentMetrics.titlebarLeadingInset(
            firstItemHasTitle: true
        ) + TerminalTitlebarControlStyle.horizontalLabelPadding
        let iconOnlyTitlebarContent = InspectorContentMetrics.titlebarLeadingInset(
            firstItemHasTitle: false
        ) + TerminalTitlebarControlStyle.iconHorizontalPadding
        let rootTreeContent = InspectorContentMetrics.treeOuterInset +
            InspectorContentMetrics.treeRowLeadingInset

        #expect(activeTitlebarContent == InspectorContentMetrics.leadingInset)
        #expect(iconOnlyTitlebarContent == InspectorContentMetrics.leadingInset)
        #expect(rootTreeContent == InspectorContentMetrics.leadingInset)
    }

    @Test func inspectorPresentationPersistsVisibilityWidthAndPane() throws {
        let suite = "InspectorPresentationStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = InspectorPresentationStore(defaults: defaults)

        store.setVisible(true)
        store.setWidth(412)
        store.selectPane("builtin.files")

        let restored = InspectorPresentationStore(defaults: defaults)
        #expect(restored.snapshot == .init(
            isVisible: true,
            width: 412,
            selectedPaneID: "builtin.files"
        ))
        let state = VerticalTabWindowLayoutState(
            isSidebarVisible: false,
            inspectorPresentation: restored
        )
        #expect(state.isInspectorVisible)
        #expect(state.inspectorWidth == 412)
        #expect(state.selectedInspectorPaneID == "builtin.files")
    }

    @Test func emptyRegistryDoesNotMutateWindowLayoutState() throws {
        let suite = "InspectorEmptyRegistryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = InspectorRegistry()
        let state = VerticalTabWindowLayoutState(
            isSidebarVisible: false,
            inspectorPresentation: InspectorPresentationStore(defaults: defaults)
        )

        state.setInspectorVisible(true)

        #expect(registry.isEmpty)
        #expect(state.isInspectorVisible)
        #expect(state.selectedInspectorPaneID == nil)
    }

    @Test func corePaneUsesTypedContentAndLifecycle() throws {
        let registry = InspectorRegistry()
        let descriptor = paneDescriptor(
            id: "core.session",
            source: .coreFeature("session")
        )
        var events: [InspectorPaneLifecycleEvent] = []
        try registry.registerCorePane(
            descriptor,
            content: { context in
                .fields([
                    .init(id: "title", label: "Title", value: context.title),
                ])
            },
            lifecycle: { events.append($0) }
        )
        let context = InspectorPaneContext(
            tabID: UUID(),
            surfaceID: UUID(),
            title: "Shell",
            workingDirectory: "/tmp"
        )

        #expect(registry.entries.map(\.id) == ["core.session"])
        #expect(registry.content(for: descriptor.id, context: context) == .fields([
            .init(id: "title", label: "Title", value: "Shell"),
        ]))

        let updatedContext = InspectorPaneContext(
            tabID: context.tabID,
            surfaceID: context.surfaceID,
            title: "Updated Shell",
            workingDirectory: "/var/tmp"
        )
        registry.presentationDidChange(to: descriptor.id, context: context)
        registry.presentationDidChange(to: descriptor.id, context: updatedContext)
        registry.presentationDidChange(to: nil, context: updatedContext)
        #expect(events == [
            .appeared(context),
            .disappeared(context),
            .appeared(updatedContext),
            .disappeared(updatedContext),
        ])
    }

    @Test func paneSessionChangesReachInspectorLifecycle() throws {
        let registry = InspectorRegistry()
        let descriptor = paneDescriptor(
            id: "core.session-lifecycle",
            source: .coreFeature("session")
        )
        var events: [InspectorPaneLifecycleEvent] = []
        try registry.registerCorePane(
            descriptor,
            content: { _ in .fields([]) },
            lifecycle: { events.append($0) }
        )

        var session = PaneSessionContext(
            workingDirectory: "/Users/test/code",
            terminalTitle: "code"
        )
        let local = InspectorPaneContext(
            tabID: UUID(),
            surfaceID: UUID(),
            title: session.presentationTitle,
            workingDirectory: session.workingDirectory,
            session: session
        )
        session.apply(
            .init(
                action: .start,
                id: "omg-ssh-1",
                metadata: "type=remote;targethost=cloud;cwd=/tmp"
            ),
            currentWorkingDirectory: "/tmp",
            currentTerminalTitle: "remote"
        )
        let remote = InspectorPaneContext(
            tabID: local.tabID,
            surfaceID: local.surfaceID,
            title: session.presentationTitle,
            workingDirectory: session.workingDirectory,
            session: session
        )

        registry.presentationDidChange(to: descriptor.id, context: local)
        registry.presentationDidChange(to: descriptor.id, context: remote)
        #expect(events == [
            .appeared(local),
            .disappeared(local),
            .appeared(remote),
        ])
    }

    @Test func pluginPaneIsDataOnlyAndOwnerScoped() throws {
        let registry = InspectorRegistry()
        let descriptor = paneDescriptor(
            id: "plugin.agent.context",
            source: .plugin("agent")
        )
        try registry.registerPluginPane(descriptor)
        let content = InspectorPaneContent.list([
            .init(id: "task", title: "Running", subtitle: "Tests", systemImage: "bolt"),
        ])

        try registry.updatePluginContent(
            paneID: descriptor.id,
            pluginID: "agent",
            content: content
        )
        let context = InspectorPaneContext(
            tabID: UUID(),
            surfaceID: nil,
            title: "Terminal",
            workingDirectory: nil
        )
        #expect(registry.content(for: descriptor.id, context: context) == content)
        #expect(throws: InspectorRegistry.RegistryError.ownerMismatch) {
            try registry.updatePluginContent(
                paneID: descriptor.id,
                pluginID: "other",
                content: content
            )
        }

        registry.disconnectPlugin("agent")
        #expect(registry.isEmpty)
    }

    @Test func builtInFilesProviderUsesPluginDataBoundary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let secondRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: secondRoot)
        }
        let sources = root.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(
            at: sources,
            withIntermediateDirectories: true
        )
        try "print(\"demo\")".write(
            to: sources.appendingPathComponent("main.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "demo".write(
            to: root.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try "{}".write(
            to: root.appendingPathComponent("package.json"),
            atomically: true,
            encoding: .utf8
        )

        let registry = InspectorRegistry()
        let provider = BuiltInFilesInspectorProvider(
            registry: registry,
            openFile: { _, _, _ in }
        )
        try provider.register()
        let context = InspectorPaneContext(
            tabID: UUID(),
            surfaceID: UUID(),
            title: "Demo",
            workingDirectory: root.path
        )
        registry.presentationDidChange(
            to: BuiltInFilesInspectorProvider.paneID,
            context: context
        )

        var content: InspectorPaneContent?
        for _ in 0..<20 {
            content = registry.content(
                for: BuiltInFilesInspectorProvider.paneID,
                context: context
            )
            if case .fileTree = content { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard case .fileTree(let initialTree) = content else {
            Issue.record("Expected a typed Files tree")
            return
        }
        #expect(initialTree.rootName == root.lastPathComponent)
        #expect(initialTree.nodes.map(\.name) == ["Sources", "package.json", "README.md"])
        #expect(initialTree.nodes[0].isDirectory)
        #expect(initialTree.nodes[0].children == nil)
        #expect(initialTree.nodes[1].icon.systemImage == "shippingbox")

        let titleOnlyContext = InspectorPaneContext(
            tabID: context.tabID,
            surfaceID: context.surfaceID,
            title: "Renamed Demo",
            workingDirectory: context.workingDirectory
        )
        registry.presentationDidChange(
            to: BuiltInFilesInspectorProvider.paneID,
            context: titleOnlyContext
        )
        guard case .fileTree(let titleUpdatedTree) = registry.content(
            for: BuiltInFilesInspectorProvider.paneID,
            context: titleOnlyContext
        ) else {
            Issue.record("Title-only context changes must keep the mounted tree")
            return
        }
        #expect(titleUpdatedTree == initialTree)

        registry.performAction(
            paneID: BuiltInFilesInspectorProvider.paneID,
            action: .init(
                context: context,
                kind: .toggleNode(id: initialTree.nodes[0].id, expanded: true)
            )
        )
        guard case .fileTree(let immediateTree) = registry.content(
            for: BuiltInFilesInspectorProvider.paneID,
            context: context
        ) else {
            Issue.record("Disclosure must keep the existing tree mounted")
            return
        }
        #expect(immediateTree.rootPath == initialTree.rootPath)
        #expect(immediateTree.nodes.map(\.id) == initialTree.nodes.map(\.id))
        #expect(immediateTree.nodes[0].isExpanded)
        #expect(immediateTree.nodes[0].isLoading)
        #expect(immediateTree.nodes[1] == initialTree.nodes[1])
        for _ in 0..<20 {
            content = registry.content(
                for: BuiltInFilesInspectorProvider.paneID,
                context: context
            )
            if case .fileTree(let tree) = content,
               tree.nodes.first?.children?.first?.name == "main.swift" { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard case .fileTree(let expandedTree) = content else {
            Issue.record("Expected an expanded Files tree")
            return
        }
        #expect(expandedTree.nodes[0].isExpanded)
        #expect(expandedTree.nodes[0].children?.map(\.name) == ["main.swift"])
        #expect(expandedTree.nodes[0].children?.first?.icon.systemImage == "swift")

        registry.performAction(
            paneID: BuiltInFilesInspectorProvider.paneID,
            action: .init(context: context, kind: .collapseAll)
        )
        for _ in 0..<20 {
            content = registry.content(
                for: BuiltInFilesInspectorProvider.paneID,
                context: context
            )
            if case .fileTree(let tree) = content,
               tree.nodes.first?.isExpanded == false { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard case .fileTree(let collapsedTree) = content else {
            Issue.record("Expected collapsed Files tree")
            return
        }
        #expect(!collapsedTree.nodes[0].isExpanded)
        #expect(collapsedTree.nodes[0].children?.map(\.name) == ["main.swift"])

        registry.performAction(
            paneID: BuiltInFilesInspectorProvider.paneID,
            action: .init(context: context, kind: .createFile(name: "created.json"))
        )
        for _ in 0..<20 where !FileManager.default.fileExists(
            atPath: root.appendingPathComponent("created.json").path
        ) {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("created.json").path
        ))
        registry.performAction(
            paneID: BuiltInFilesInspectorProvider.paneID,
            action: .init(context: context, kind: .createFolder(name: "Created Folder"))
        )
        for _ in 0..<20 where !FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Created Folder").path
        ) {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Created Folder").path
        ))
        try "external".write(
            to: root.appendingPathComponent("external.toml"),
            atomically: true,
            encoding: .utf8
        )
        registry.performAction(
            paneID: BuiltInFilesInspectorProvider.paneID,
            action: .init(context: context, kind: .refresh)
        )
        for _ in 0..<20 {
            content = registry.content(
                for: BuiltInFilesInspectorProvider.paneID,
                context: context
            )
            if case .fileTree(let tree) = content,
               tree.nodes.contains(where: { $0.name == "external.toml" }) { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard case .fileTree(let refreshedTree) = content else {
            Issue.record("Expected refreshed Files tree")
            return
        }
        #expect(refreshedTree.nodes.contains(where: { $0.name == "external.toml" }))

        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        try "second".write(
            to: secondRoot.appendingPathComponent("second.py"),
            atomically: true,
            encoding: .utf8
        )
        let secondContext = InspectorPaneContext(
            tabID: UUID(),
            surfaceID: UUID(),
            title: "Second",
            workingDirectory: secondRoot.path
        )
        registry.presentationDidChange(
            to: BuiltInFilesInspectorProvider.paneID,
            context: secondContext
        )
        var secondContent: InspectorPaneContent?
        for _ in 0..<20 {
            secondContent = registry.content(
                for: BuiltInFilesInspectorProvider.paneID,
                context: secondContext
            )
            if case .fileTree = secondContent { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard case .fileTree(let secondTree) = secondContent else {
            Issue.record("Expected tab-scoped Files content")
            return
        }
        #expect(secondTree.rootPath == secondRoot.path)
        #expect(secondTree.nodes.map(\.name) == ["second.py"])
        guard case .fileTree(let retainedFirstTree) = registry.content(
            for: BuiltInFilesInspectorProvider.paneID,
            context: context
        ) else {
            Issue.record("Expected first tab Files content to remain isolated")
            return
        }
        #expect(retainedFirstTree.rootPath == root.path)

        let movedContext = InspectorPaneContext(
            tabID: context.tabID,
            surfaceID: context.surfaceID,
            title: context.title,
            workingDirectory: secondRoot.path
        )
        registry.presentationDidChange(
            to: BuiltInFilesInspectorProvider.paneID,
            context: movedContext
        )
        guard case .fileTree(let transitioningTree) = registry.content(
            for: BuiltInFilesInspectorProvider.paneID,
            context: movedContext
        ) else {
            Issue.record("Local cwd changes should keep existing Files content while loading")
            return
        }
        #expect(transitioningTree.rootPath == root.path)
        var movedContent: InspectorPaneContent?
        for _ in 0..<20 {
            movedContent = registry.content(
                for: BuiltInFilesInspectorProvider.paneID,
                context: movedContext
            )
            if case .fileTree(let tree) = movedContent,
               tree.rootPath == secondRoot.path { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard case .fileTree(let movedTree) = movedContent else {
            Issue.record("Expected cwd-driven Files refresh")
            return
        }
        #expect(movedTree.rootPath == secondRoot.path)
        #expect(registry.descriptor(id: BuiltInFilesInspectorProvider.paneID)?.source ==
            .plugin(BuiltInFilesInspectorProvider.pluginID))

        registry.disconnectPlugin(BuiltInFilesInspectorProvider.pluginID)
        #expect(registry.isEmpty)
    }

    @Test func builtInFilesOpenFileActionCallsInjectedHandler() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = root.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(
            at: sources,
            withIntermediateDirectories: true
        )
        let readme = root.appendingPathComponent("README.md")
        try "demo".write(to: readme, atomically: true, encoding: .utf8)

        let registry = InspectorRegistry()
        var openedPaths: [String] = []
        var openedContexts: [InspectorPaneContext] = []
        var openedDestinations: [EditorOpenDestination] = []
        let provider = BuiltInFilesInspectorProvider(
            registry: registry,
            openFile: { path, context, destination in
                openedPaths.append(path)
                openedContexts.append(context)
                openedDestinations.append(destination)
            }
        )
        try provider.register()
        let context = InspectorPaneContext(
            tabID: UUID(),
            surfaceID: UUID(),
            title: "Files",
            workingDirectory: root.path
        )
        registry.presentationDidChange(
            to: BuiltInFilesInspectorProvider.paneID,
            context: context
        )

        var content: InspectorPaneContent?
        for _ in 0..<20 {
            content = registry.content(
                for: BuiltInFilesInspectorProvider.paneID,
                context: context
            )
            if case .fileTree = content { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard case .fileTree(let tree) = content,
              let directory = tree.nodes.first(where: { $0.name == "Sources" }),
              let file = tree.nodes.first(where: { $0.name == "README.md" }) else {
            Issue.record("Expected Files tree with directory and file nodes")
            return
        }

        registry.performAction(
            paneID: BuiltInFilesInspectorProvider.paneID,
            action: .init(context: context, kind: .openFile(path: directory.id))
        )
        registry.performAction(
            paneID: BuiltInFilesInspectorProvider.paneID,
            action: .init(context: context, kind: .openFile(path: "\(root.path)/missing.md"))
        )
        #expect(openedPaths.isEmpty)

        registry.performAction(
            paneID: BuiltInFilesInspectorProvider.paneID,
            action: .init(context: context, kind: .openFile(path: file.id))
        )

        #expect(openedPaths == [file.id])
        #expect(openedContexts == [context])
        #expect(openedDestinations == [.currentPane])
        registry.performAction(
            paneID: BuiltInFilesInspectorProvider.paneID,
            action: .init(context: context, kind: .openFile(path: file.id, destination: .splitRight))
        )
        #expect(openedDestinations == [.currentPane, .splitRight])
    }

    @Test func repeatedDeepExpansionRemainsBoundedAndResponsive() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var directory = root
        var directoryIDs: [String] = []
        for depth in 0..<12 {
            directory = directory.appendingPathComponent("level-\(depth)")
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            directoryIDs.append(directory.resolvingSymlinksInPath().path)
            for index in 0..<30 {
                try "{}".write(
                    to: directory.appendingPathComponent("file-\(index).json"),
                    atomically: true,
                    encoding: .utf8
                )
            }
        }

        let registry = InspectorRegistry()
        let provider = BuiltInFilesInspectorProvider(
            registry: registry,
            openFile: { _, _, _ in }
        )
        try provider.register()
        let context = InspectorPaneContext(
            tabID: UUID(),
            surfaceID: UUID(),
            title: "Stress",
            workingDirectory: root.path
        )
        registry.presentationDidChange(
            to: BuiltInFilesInspectorProvider.paneID,
            context: context
        )

        let clock = ContinuousClock()
        let start = clock.now
        for id in directoryIDs {
            registry.performAction(
                paneID: BuiltInFilesInspectorProvider.paneID,
                action: .init(
                    context: context,
                    kind: .toggleNode(id: id, expanded: true)
                )
            )
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(500))
        #expect(start.duration(to: clock.now) < .seconds(2))

        let content = registry.content(
            for: BuiltInFilesInspectorProvider.paneID,
            context: context
        )
        guard case .fileTree(let tree) = content else {
            Issue.record("Expected a stress-test Files tree")
            return
        }
        #expect(tree.nodes.count == 1)
        #expect(countNodes(tree.nodes) <= 500)

        for _ in 0..<40 {
            registry.performAction(
                paneID: BuiltInFilesInspectorProvider.paneID,
                action: .init(context: context, kind: .refresh)
            )
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(registry.content(
            for: BuiltInFilesInspectorProvider.paneID,
            context: context
        ) != nil)
    }

    @Test func canceledRemoteMutationCannotRestoreStaleFilesContext() async throws {
        let rootA = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let rootB = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        try "current".write(
            to: rootB.appendingPathComponent("current.txt"),
            atomically: true,
            encoding: .utf8
        )

        let gate = FilesMutationGate()
        let delayed = DelayedWorkspaceFilesystem(
            descriptor: LocalWorkspaceFilesystem(
                workingDirectory: rootA.path
            ).descriptor,
            gate: gate,
            counter: FilesListCounter()
        )
        let registry = InspectorRegistry()
        let provider = BuiltInFilesInspectorProvider(
            registry: registry,
            filesystemFactory: { context -> any WorkspaceFilesystem in
                if context.workingDirectory == rootA.path { return delayed }
                return LocalWorkspaceFilesystem(
                    workingDirectory: context.workingDirectory ?? "/"
                )
            },
            openFile: { _, _, _ in }
        )
        try provider.register()
        let tabID = UUID()
        let contextA = InspectorPaneContext(
            tabID: tabID,
            surfaceID: UUID(),
            title: "A",
            workingDirectory: rootA.path
        )
        let contextB = InspectorPaneContext(
            tabID: tabID,
            surfaceID: contextA.surfaceID,
            title: "B",
            workingDirectory: rootB.path
        )
        registry.presentationDidChange(
            to: BuiltInFilesInspectorProvider.paneID,
            context: contextA
        )
        try await Task.sleep(for: .milliseconds(50))
        registry.performAction(
            paneID: BuiltInFilesInspectorProvider.paneID,
            action: .init(
                context: contextA,
                kind: .createFile(name: "stale.txt")
            )
        )
        for _ in 0..<20 {
            if await gate.started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await gate.started)

        registry.presentationDidChange(
            to: BuiltInFilesInspectorProvider.paneID,
            context: contextB
        )
        var currentTree: InspectorFileTree?
        for _ in 0..<40 {
            if case .fileTree(let tree) = registry.content(
                for: BuiltInFilesInspectorProvider.paneID,
                context: contextB
            ), tree.rootPath == rootB.path {
                currentTree = tree
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        await gate.resume()
        try await Task.sleep(for: .milliseconds(200))

        guard case .fileTree(let finalTree) = registry.content(
            for: BuiltInFilesInspectorProvider.paneID,
            context: contextB
        ) else {
            Issue.record("Expected current Files context after stale mutation completion")
            return
        }
        #expect(currentTree?.nodes.map(\.name) == ["current.txt"])
        #expect(finalTree.rootPath == rootB.path)
        #expect(finalTree.nodes.map(\.name) == ["current.txt"])
    }

    @Test func disappearingPaneCancelsOwnedMutationWork() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let gate = FilesMutationGate()
        let counter = FilesListCounter()
        let filesystem = DelayedWorkspaceFilesystem(
            descriptor: LocalWorkspaceFilesystem(
                workingDirectory: root.path
            ).descriptor,
            gate: gate,
            counter: counter
        )
        let registry = InspectorRegistry()
        let provider = BuiltInFilesInspectorProvider(
            registry: registry,
            filesystemFactory: { _ in filesystem },
            openFile: { _, _, _ in }
        )
        try provider.register()
        let context = InspectorPaneContext(
            tabID: UUID(),
            surfaceID: UUID(),
            title: "Files",
            workingDirectory: root.path
        )
        registry.presentationDidChange(
            to: BuiltInFilesInspectorProvider.paneID,
            context: context
        )
        for _ in 0..<20 {
            if await counter.value == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        registry.performAction(
            paneID: BuiltInFilesInspectorProvider.paneID,
            action: .init(
                context: context,
                kind: .createFile(name: "stale.txt")
            )
        )
        for _ in 0..<20 {
            if await gate.started { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        registry.presentationDidChange(to: nil, context: context)
        await gate.resume()
        try await Task.sleep(for: .milliseconds(200))
        #expect(await counter.value == 1)
    }

    @Test func sameRemotePathWithNewConnectionReloadsFiles() async throws {
        let counter = FilesListCounter()
        let filesystem = CountingWorkspaceFilesystem(
            descriptor: .init(
                kind: .ssh,
                id: "ssh:cloud",
                displayName: "cloud",
                workingDirectory: "/remote/project"
            ),
            counter: counter
        )
        let registry = InspectorRegistry()
        let provider = BuiltInFilesInspectorProvider(
            registry: registry,
            filesystemFactory: { _ in filesystem },
            openFile: { _, _, _ in }
        )
        try provider.register()
        let tabID = UUID()
        let surfaceID = UUID()

        func readySession(_ connectionID: String) -> PaneSessionContext {
            var session = PaneSessionContext(
                workingDirectory: "/Users/test/code",
                terminalTitle: "code"
            )
            session.apply(
                .init(
                    action: .start,
                    id: connectionID,
                    metadata: "type=remote;targethost=cloud;cwd=/remote/project"
                ),
                currentWorkingDirectory: "/remote/project",
                currentTerminalTitle: "remote"
            )
            return session
        }

        for (index, connectionID) in ["omg-ssh-a", "omg-ssh-b"].enumerated() {
            let session = readySession(connectionID)
            let context = InspectorPaneContext(
                tabID: tabID,
                surfaceID: surfaceID,
                title: session.presentationTitle,
                workingDirectory: session.workingDirectory,
                workspace: filesystem.descriptor,
                session: session
            )
            registry.presentationDidChange(
                to: BuiltInFilesInspectorProvider.paneID,
                context: context
            )
            for _ in 0..<40 {
                if case .fileTree(let tree) = registry.content(
                    for: BuiltInFilesInspectorProvider.paneID,
                    context: context
                ), tree.nodes.map(\.name) == ["generation-\(index + 1).txt"] {
                    break
                }
                try await Task.sleep(for: .milliseconds(25))
            }
        }

        #expect(await counter.value == 2)
    }

    @Test func descriptorsAndWidthsAreValidated() throws {
        let registry = InspectorRegistry()
        let descriptor = paneDescriptor(id: "valid.pane", source: .coreFeature("core"))
        try registry.registerCorePane(descriptor) { _ in
            .empty(title: "Empty", message: "No content")
        }
        #expect(throws: InspectorRegistry.RegistryError.duplicatePaneID) {
            try registry.registerCorePane(descriptor) { _ in
                .empty(title: "Empty", message: "No content")
            }
        }

        let invalid = InspectorPaneDescriptor(
            id: "invalid pane",
            title: "Invalid",
            systemImage: "sidebar.trailing",
            source: .coreFeature("core"),
            preferredWidth: 100,
            minimumWidth: 100
        )
        #expect(throws: InspectorRegistry.RegistryError.invalidDescriptor) {
            try registry.registerCorePane(invalid) { _ in
                .empty(title: "Empty", message: "No content")
            }
        }

        let state = VerticalTabWindowLayoutState(isSidebarVisible: true)
        state.updateInspectorWidth(900, availableWidth: 800, persist: true)
        #expect(state.inspectorWidth == 400)
        #expect(state.committedInspectorWidth == 400)
        state.updateInspectorWidth(100, availableWidth: 800, persist: true)
        #expect(state.inspectorWidth == RightInspectorMetrics.minimumWidth)
    }

    private func countNodes(_ nodes: [InspectorFileNode]) -> Int {
        nodes.reduce(0) { count, node in
            count + 1 + countNodes(node.children ?? [])
        }
    }

    private func paneDescriptor(
        id: String,
        source: InspectorPaneDescriptor.Source,
        title: String = "Context"
    ) -> InspectorPaneDescriptor {
        .init(
            id: id,
            title: title,
            systemImage: "sidebar.trailing",
            source: source,
            preferredWidth: 320,
            minimumWidth: 220
        )
    }
}

private actor FilesMutationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false

    func suspend() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private struct DelayedWorkspaceFilesystem: WorkspaceFilesystem {
    let descriptor: WorkspaceDescriptor
    let gate: FilesMutationGate
    let counter: FilesListCounter

    func listDirectory(at path: String) async throws -> [WorkspaceFileEntry] {
        _ = await counter.increment()
        return []
    }

    func createFile(named name: String, in directory: String) async throws {
        await gate.suspend()
    }

    func createDirectory(named name: String, in directory: String) async throws {
        await gate.suspend()
    }
}

private actor FilesListCounter {
    private(set) var value = 0

    func increment() -> Int {
        value += 1
        return value
    }
}

private struct CountingWorkspaceFilesystem: WorkspaceFilesystem {
    let descriptor: WorkspaceDescriptor
    let counter: FilesListCounter

    func listDirectory(at path: String) async throws -> [WorkspaceFileEntry] {
        let generation = await counter.increment()
        return [.init(
            path: "\(path)/generation-\(generation).txt",
            name: "generation-\(generation).txt",
            isDirectory: false
        )]
    }

    func createFile(named name: String, in directory: String) async throws {}

    func createDirectory(named name: String, in directory: String) async throws {}
}
