import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct GitChangesSynchronizationTests {
    private struct LiveChanges: View {
        @ObservedObject var registry: InspectorRegistry
        let context: InspectorPaneContext
        @State private var content: InspectorGitContent?
        var body: some View {
            Group {
                if let content {
                    InspectorGitView(content: content) { action in
                        registry.performAction(paneID: BuiltInGitInspectorProvider.paneID,
                            action: .init(context: context, kind: action))
                    }
                }
            }
            .onAppear(perform: refresh)
            .onReceive(registry.contentChanges) { change in
                if change.affects(paneID: BuiltInGitInspectorProvider.paneID, tabID: context.tabID) { refresh() }
            }
        }
        private func refresh() {
            if case .git(let value) = registry.content(for: BuiltInGitInspectorProvider.paneID, context: context) {
                content = value
            } else {
                content = nil
            }
        }
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { find(type, in: $0) }
    }

    @Test(arguments: GitCollectionMode.allCases)
    func realCheckboxStagesAndUnstagesWithoutLeavingChanges(mode: GitCollectionMode) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("git-changes-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await LocalGitExecutor().execute(arguments: ["init", "-b", "main"], workingDirectory: root.path)
        try #require(result.isSuccess)
        try Data("foo\n".utf8).write(to: root.appendingPathComponent("foo.cpp"))
        let registry = InspectorRegistry()
        let provider = BuiltInGitInspectorProvider(registry: registry)
        try provider.register()
        let context = InspectorPaneContext(tabID: UUID(), surfaceID: UUID(), title: "Test", workingDirectory: root.path)
        registry.presentationDidChange(to: BuiltInGitInspectorProvider.paneID, context: context)
        defer { registry.presentationDidChange(to: nil, context: context) }
        func content() -> InspectorGitContent? {
            guard case .git(let value) = registry.content(for: BuiltInGitInspectorProvider.paneID, context: context) else { return nil }
            return value
        }
        func waitFor(_ predicate: (InspectorGitContent) -> Bool) async throws {
            for _ in 0..<120 {
                if let value = content(), predicate(value) { return }
                try await Task.sleep(for: .milliseconds(25))
            }
            throw NSError(domain: "ChangesStateTimeout", code: 1)
        }
        try await waitFor { $0.workingTree.unstaged.count == 1 }
        registry.performAction(paneID: BuiltInGitInspectorProvider.paneID,
            action: .init(context: context, kind: .gitAction(.selectTab(.changes))))
        let suite = "git-changes-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(mode.rawValue, forKey: "git.changes.viewMode")
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = NSHostingView(rootView: LiveChanges(registry: registry, context: context).defaultAppStorage(defaults))
        host.sizingOptions = []
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 320, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(100))
        let table = try #require(find(GitCollectionTableView.self, in: host).first)
        let coordinator = try #require(table.target as? GitCollectionView.Coordinator)
        func checkbox(_ section: GitChangeSection) throws -> GitStageCheckbox {
            let index = try #require(coordinator.rows.firstIndex { $0.id == section.rowID(path: "foo.cpp") })
            let cell = try #require(table.view(atColumn: 0, row: index, makeIfNecessary: true) as? GitCollectionCell)
            return cell.checkbox
        }
        let unchecked = try checkbox(.unstaged)
        #expect(unchecked.state == .off)
        unchecked.performClick(nil)
        try await waitFor { $0.operation == nil && $0.workingTree.staged.count == 1 && $0.workingTree.unstaged.isEmpty }
        try await Task.sleep(for: .milliseconds(80))
        let checked = try checkbox(.staged)
        #expect(checked.state == .on, "Successful Stage must update the current checkbox, not only the Git model")
        checked.performClick(nil)
        try await waitFor { $0.operation == nil && $0.workingTree.staged.isEmpty && $0.workingTree.unstaged.count == 1 }
        try await Task.sleep(for: .milliseconds(80))
        #expect(try checkbox(.unstaged).state == .off)
        #expect(content()?.activeTab == .changes)
    }
}
