import AppKit
import Foundation
import Testing
@testable import Ghostty

/// Files pane toolbar (#60): create in a folder, Locate Current File and
/// Collapse/Expand All, all through the plugin-shaped action boundary.
@MainActor
struct FilesInspectorToolbarTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-files-toolbar-\(UUID().uuidString)", isDirectory: true)
        let deep = root.appendingPathComponent("Sources/App/Views", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Docs"), withIntermediateDirectories: true)
        try "view".write(to: deep.appendingPathComponent("Main.swift"), atomically: true, encoding: .utf8)
        // Sibling files keep the listing from compacting Sources/App/Views.
        try "pkg".write(to: root.appendingPathComponent("Sources/Package.swift"), atomically: true, encoding: .utf8)
        try "app".write(to: root.appendingPathComponent("Sources/App/App.swift"), atomically: true, encoding: .utf8)
        try "readme".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        return root
    }

    private func tree(
        _ registry: InspectorRegistry,
        _ context: InspectorPaneContext,
        until condition: (InspectorFileTree) -> Bool
    ) async throws -> InspectorFileTree? {
        for _ in 0..<80 {
            if case .fileTree(let tree) = registry.content(for: BuiltInFilesInspectorProvider.paneID, context: context),
               condition(tree) { return tree }
            try await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    private func node(_ path: String, in nodes: [InspectorFileNode]) -> InspectorFileNode? {
        for node in nodes {
            if node.id == path { return node }
            if let match = self.node(path, in: node.children ?? []) { return match }
        }
        return nil
    }

    private final class DocumentBox { var path: String? }

    private func setUp(
        root: URL,
        currentDocument: DocumentBox = .init()
    ) throws -> (InspectorRegistry, BuiltInFilesInspectorProvider, InspectorPaneContext) {
        let registry = InspectorRegistry()
        let provider = BuiltInFilesInspectorProvider(
            registry: registry,
            currentDocumentPath: { _, _ in currentDocument.path },
            openFile: { _, _, _ in }
        )
        try provider.register()
        let context = InspectorPaneContext(tabID: UUID(), surfaceID: UUID(), title: "Files", workingDirectory: root.path)
        registry.presentationDidChange(to: BuiltInFilesInspectorProvider.paneID, context: context)
        return (registry, provider, context)
    }

    @Test func ancestorDirectoriesStopBelowTheRoot() {
        #expect(BuiltInFilesInspectorProvider.ancestorDirectories(of: "/r/a/b/c.txt", root: "/r") == ["/r/a", "/r/a/b"])
        #expect(BuiltInFilesInspectorProvider.ancestorDirectories(of: "/r/c.txt", root: "/r").isEmpty)
        #expect(BuiltInFilesInspectorProvider.ancestorDirectories(of: "/other/c.txt", root: "/r").isEmpty)
        #expect(BuiltInFilesInspectorProvider.ancestorDirectories(of: "/a/b.txt", root: "/") == ["/a"])
    }

    @Test func treePathMapsEitherRootSpellingIntoNodeIDs() {
        #expect(BuiltInFilesInspectorProvider.treePath("/var/r/a.txt", rootPath: "/var/r", nodeRoot: "/private/var/r")
            == "/private/var/r/a.txt")
        #expect(BuiltInFilesInspectorProvider.treePath("/private/var/r/a.txt", rootPath: "/var/r", nodeRoot: "/private/var/r")
            == "/private/var/r/a.txt")
        #expect(BuiltInFilesInspectorProvider.treePath("/elsewhere/a.txt", rootPath: "/var/r", nodeRoot: "/var/r") == nil)
        let icon = InspectorFileIcon(systemImage: "doc", tint: .secondary)
        let nodes = ["/p/r/a/b/c", "/p/r/x.txt"].map {
            InspectorFileNode(id: $0, name: "n", isDirectory: false, icon: icon, isExpanded: false, isLoading: false, children: nil)
        }
        #expect(BuiltInFilesInspectorProvider.nodeRoot(of: .init(rootName: "r", rootPath: "/r", nodes: nodes)) == "/p/r")
    }

    @Test func expansionWalkIsBoundedByCountAndDepth() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let filesystem = LocalWorkspaceFilesystem(workingDirectory: root.path)
        let all = await BuiltInFilesInspectorProvider.directoriesForExpansion(root: root.path, filesystem: filesystem)
        #expect(Set(all.map { ($0 as NSString).lastPathComponent }) == ["Docs", "Sources", "App", "Views"])
        let limited = await BuiltInFilesInspectorProvider.directoriesForExpansion(
            root: root.path, filesystem: filesystem, limit: 2)
        #expect(limited.count == 2)
        let shallow = await BuiltInFilesInspectorProvider.directoriesForExpansion(
            root: root.path, filesystem: filesystem, depthLimit: 1)
        #expect(Set(shallow.map { ($0 as NSString).lastPathComponent }) == ["Docs", "Sources"])
    }

    @Test func locateCurrentFileExpandsAncestorsAndRevealsTheDocument() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let box = DocumentBox()
        let (registry, provider, context) = try setUp(root: root, currentDocument: box)
        defer { withExtendedLifetime(provider) {} }
        let base = BuiltInFilesInspectorProvider.nodeRoot(
            of: try #require(try await tree(registry, context) { !$0.nodes.isEmpty }))
        let document = base + "/Sources/App/Views/Main.swift"
        box.path = document

        registry.performAction(paneID: BuiltInFilesInspectorProvider.paneID,
                               action: .init(context: context, kind: .revealCurrentFile))
        let revealed = try #require(try await tree(registry, context) { $0.reveal?.path == document })
        #expect(node(base + "/Sources", in: revealed.nodes)?.isExpanded == true)
        #expect(node(base + "/Sources/App/Views", in: revealed.nodes)?.isExpanded == true)
        #expect(node(document, in: revealed.nodes) != nil)
        let firstToken = try #require(revealed.reveal?.token)

        // Locating again re-applies the reveal with a fresh token.
        registry.performAction(paneID: BuiltInFilesInspectorProvider.paneID,
                               action: .init(context: context, kind: .revealCurrentFile))
        #expect(try await tree(registry, context) { ($0.reveal?.token ?? 0) > firstToken } != nil)
    }

    @Test func createInSelectedFolderExpandsItAndRevealsTheNewItem() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (registry, provider, context) = try setUp(root: root)
        defer { withExtendedLifetime(provider) {} }
        let base = BuiltInFilesInspectorProvider.nodeRoot(
            of: try #require(try await tree(registry, context) { !$0.nodes.isEmpty }))
        let docs = base + "/Docs"

        registry.performAction(paneID: BuiltInFilesInspectorProvider.paneID,
                               action: .init(context: context, kind: .createFile(name: "guide.md", parent: docs)))
        let created = (docs as NSString).appendingPathComponent("guide.md")
        let tree = try #require(try await tree(registry, context) { $0.reveal?.path == created })
        #expect(FileManager.default.fileExists(atPath: created))
        #expect(node(docs, in: tree.nodes)?.isExpanded == true)

        registry.performAction(paneID: BuiltInFilesInspectorProvider.paneID,
                               action: .init(context: context, kind: .createFolder(name: "Nested", parent: docs)))
        let folder = (docs as NSString).appendingPathComponent("Nested")
        #expect(try await self.tree(registry, context) { $0.reveal?.path == folder } != nil)

        // Unknown parents are rejected instead of writing outside the tree.
        registry.performAction(paneID: BuiltInFilesInspectorProvider.paneID,
                               action: .init(context: context, kind: .createFile(name: "x.txt", parent: "/tmp/elsewhere")))
        try await Task.sleep(for: .milliseconds(150))
        #expect(!FileManager.default.fileExists(atPath: "/tmp/elsewhere/x.txt"))
    }

    @Test func expandAllThenCollapseAll() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (registry, provider, context) = try setUp(root: root)
        defer { withExtendedLifetime(provider) {} }
        let base = BuiltInFilesInspectorProvider.nodeRoot(
            of: try #require(try await tree(registry, context) { !$0.nodes.isEmpty }))
        let views = base + "/Sources/App/Views"

        registry.performAction(paneID: BuiltInFilesInspectorProvider.paneID,
                               action: .init(context: context, kind: .expandAll))
        let expanded = try #require(try await tree(registry, context) { self.node(views, in: $0.nodes)?.isExpanded == true })
        #expect(node(base + "/Docs", in: expanded.nodes)?.isExpanded == true)
        #expect(node((views as NSString).appendingPathComponent("Main.swift"), in: expanded.nodes) != nil)

        registry.performAction(paneID: BuiltInFilesInspectorProvider.paneID,
                               action: .init(context: context, kind: .collapseAll))
        let collapsed = try #require(try await tree(registry, context) { tree in
            tree.nodes.allSatisfy { !$0.isExpanded }
        })
        #expect(node(base + "/Sources", in: collapsed.nodes)?.isExpanded == false)
    }

    @Test func toolbarCreatesNextToTheSelectionAndRevealSelectsTheRow() throws {
        let controller = InspectorFileTreeController()
        var actions: [InspectorPaneActionKind] = []
        let icon = InspectorFileIcon(systemImage: "doc", tint: .secondary)
        let file = InspectorFileNode(id: "/r/a/file.txt", name: "file.txt", isDirectory: false, icon: icon,
                                     isExpanded: false, isLoading: false, children: nil)
        let folder = InspectorFileNode(id: "/r/a", name: "a", isDirectory: true, icon: icon,
                                       isExpanded: true, isLoading: false, children: [file])
        var tree = InspectorFileTree(rootName: "r", rootPath: "/r", nodes: [folder])
        controller.update(tree, isLight: false) { actions.append($0) }

        controller.newFile()
        #expect(actions.last == .promptCreateItem(directory: false, parent: nil))

        tree.reveal = .init(path: "/r/a/file.txt", token: 1)
        controller.update(tree, isLight: false) { actions.append($0) }
        #expect((controller.outline.item(atRow: controller.outline.selectedRow) as? InspectorFileTreeController.Item)?
            .node.id == "/r/a/file.txt")
        controller.newFolder()
        #expect(actions.last == .promptCreateItem(directory: true, parent: "/r/a"))

        controller.locateCurrentFile()
        controller.collapseAll()
        controller.expandAll()
        #expect(actions.suffix(3) == [.revealCurrentFile, .collapseAll, .expandAll])
    }
}
