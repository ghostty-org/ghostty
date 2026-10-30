import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct InspectorPaneDeckTests {
    @Test func switchingVisitedPanesRetainsNativeViewsAndBoundsTheCacheToItsTab() async throws {
        let registry = InspectorRegistry()
        let context = InspectorPaneContext(tabID: UUID(), surfaceID: UUID(), title: "Test", workingDirectory: "/repo")
        let commits = (0..<500).map { index in
            GitHistoryCommit(id: .init("commit-\(index)"), parentIDs: index < 499 ? [.init("commit-\(index + 1)")] : [],
                authorName: "Test", authorEmail: "test@example.com", authoredAt: Date(timeIntervalSince1970: 0), subject: "Commit \(index)", refDecorations: [])
        }
        let repo = GitRepositoryIdentity(worktreePath: "/repo", gitDirPath: "/repo/.git", commonGitDirPath: "/repo/.git")
        let values: [String: InspectorPaneContent] = [
            "files": .fileTree(.init(rootName: "repo", rootPath: "/repo", nodes: (0..<500).map {
                .init(id: "/repo/file-\($0)", name: "file-\($0)", isDirectory: false, icon: .init(systemImage: "doc", tint: .secondary),
                    isExpanded: false, isLoading: false, children: nil)
            })),
            "git": .git(.init(repository: repo, branch: "main", status: .ready(repository: repo, branch: "main", headCommitID: nil),
                history: .init(commits: commits))),
            "agent": .agentHistory(.init(sessions: [], selectedSessionID: nil, transcript: nil, isLoadingSessions: false, isLoadingTranscript: false)),
            "info": .info(.init(status: nil, fields: [], portForwards: .init(hostAlias: "test", items: []))),
        ]
        let container = InspectorPaneDeck.Container(frame: .init(x: 0, y: 0, width: 340, height: 650))
        let window = NSWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = container; window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        func show(_ id: String, tab: UUID? = nil) {
            container.show(AnyView(InspectorPaneContentView(content: values[id]!, paneID: id, context: context,
                dividerColor: .gray, registry: registry)), paneID: id, tabID: tab ?? context.tabID, availableIDs: Set(values.keys))
        }
        for id in ["files", "git", "agent", "info"] { show(id); try await Task.sleep(for: .milliseconds(70)) }
        let originals = container.hosts
        func findTable(_ view: NSView) -> GitHoverTableView? {
            (view as? GitHoverTableView) ?? view.subviews.lazy.compactMap(findTable).first
        }
        let history = try #require(originals["git"].flatMap(findTable))
        var durations: [Double] = []
        for _ in 0..<5 {
            for id in ["files", "agent", "git", "info"] {
                let start = Date()
                show(id); container.layoutSubtreeIfNeeded()
                durations.append(Date().timeIntervalSince(start) * 1000)
                #expect(container.hosts[id] === originals[id])
                #expect(container.hosts.values.filter { !$0.isHidden }.count == 1)
            }
        }
        #expect(container.hosts.count == 4)
        #expect(container.hosts["git"].flatMap(findTable) === history)
        print("Inspector cached switching: median=\(durations.sorted()[durations.count / 2])ms max=\(durations.max() ?? 0)ms")
        show("info", tab: UUID())
        #expect(container.hosts.count == 1)
        #expect(container.hosts["info"] !== originals["info"])
    }
}
