import AppKit
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct VerticalNativeTabSidebarTests {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @Test func remoteGroupingSeparatesConnectionsWithTheSameDirectory() throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let controllers = try [fixture.tab(), fixture.tab()]
        for (index, controller) in controllers.enumerated() {
            let surface = try #require(controller.surfaceTree.first)
            var context = PaneSessionContext(workingDirectory: "/tmp", terminalTitle: "Local")
            context.apply(.init(action: .start, id: "omg-ssh-\(index)",
                                metadata: "type=remote;targethost=cloud-\(index);cwd=/remote/project"),
                          currentWorkingDirectory: "/remote/project", currentTerminalTitle: "Remote")
            controller.restorePaneSessionState(.init(context: context, activity: nil, resumeDescriptor: nil,
                resumeContextID: nil, reducer: nil, typedHookContextID: nil, observedForegroundProcessID: nil,
                detectedAgent: nil, screenSignature: nil, screenStableTicks: nil, quickInputState: nil), for: surface.id)
        }
        let groups = GhosttyTabOrganizationModel().groups(tabs: controllers, grouping: .project, ordering: .manual)
        #expect(groups.count == 2)
        #expect(groups[0].id != groups[1].id)
        #expect(groups.allSatisfy { $0.id.hasPrefix("remote:") })
        #expect(groups[0].title == "cloud-0 · project")
    }

    @Test func completeSidebarHasNoHostingViewsAndKeepsControllerAcrossUpdates() async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let first = try fixture.tab()
        let second = try fixture.tab(parent: first)
        first.tabLayoutState.updateTabs([first, second], selectedID: ObjectIdentifier(first))
        let status = try #require(NSApp.delegate as? AppDelegate).tabActivities
        let config = NativeTabSidebarConfiguration(controller: first, layoutState: first.tabLayoutState,
                                                   statusStore: status, backgroundColor: .black)
        let host = NativeTabSidebarHostingView(configuration: config)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 250, height: 320),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        let outline = host.sidebar.list.outline
        let reloads = host.sidebar.list.reloadCount
        #expect(outline.numberOfRows == 2)
        let secondNode = try #require(outline.item(atRow: 1) as? NativeTabNode)
        let targetRect = outline.rect(ofRow: 1)
        let before = host.sidebar.list.insertionProposal(item: secondNode, index: NSOutlineViewDropOnItemIndex,
                                                        point: .init(x: 50, y: targetRect.minY + 1))
        let after = host.sidebar.list.insertionProposal(item: secondNode, index: NSOutlineViewDropOnItemIndex,
                                                       point: .init(x: 50, y: targetRect.maxY - 1))
        #expect(before.0 == nil && before.1 == 1)
        #expect(after.0 == nil && after.1 == 2)
        for row in 0..<outline.numberOfRows { _ = outline.view(atColumn: 0, row: row, makeIfNecessary: true) }
        #expect(!descendants(host).contains { String(describing: type(of: $0)).contains("HostingView") && $0 !== host })
        #expect(descendants(host).contains { $0 is TerminalWorkspaceHeaderButton })
        #expect(descendants(host).contains { $0 is NativeTabIconView })
        // AppKit paints native selection inside mouse tracking, before deferred
        // activation. The glyph must change in that same synchronous update.
        outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let cell = try #require(outline.view(atColumn: 0, row: 1, makeIfNecessary: true))
        let icon = try #require(descendants(cell).compactMap { $0 as? NativeTabIconView }.first)
        let mark = try #require(icon.subviews.compactMap { $0 as? NSImageView }.first)
        #expect(mark.contentTintColor == OMGNativeTheme.resolve(for: icon).accent)
        first.tabLayoutState.updateTabs([first, second], selectedID: ObjectIdentifier(second))
        host.configure(.init(controller: second, layoutState: first.tabLayoutState,
                             statusStore: status, backgroundColor: .black))
        try await Task.sleep(for: .milliseconds(30))
        #expect(host.sidebar.list.outline === outline)
        #expect(host.sidebar.list.reloadCount == reloads)
        #expect(outline.selectedRow == 1)
        host.layoutSubtreeIfNeeded()
        for child in descendants(host) { child.needsDisplay = true }
        window.displayIfNeeded()
        let labels = descendants(host).compactMap { $0 as? NSTextField }.filter { !$0.stringValue.isEmpty }
        #expect(labels.count >= 5)
        #expect(labels.allSatisfy { $0.bounds.width > 0 && !$0.isHiddenOrHasHiddenAncestor })
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/tmp/omg-native-complete-sidebar.png"))
        let pdf = host.dataWithPDF(inside: host.bounds)
        if let image = NSImage(data: pdf), let tiff = image.tiffRepresentation,
           let rendered = NSBitmapImageRep(data: tiff), let png = rendered.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: "/tmp/omg-native-complete-sidebar-print.png"))
        }
    }

    @Test func crossWindowMovePreservesTheWholeSplitTreeAndNativeSelection() throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let target = try fixture.tab()
        let source = try fixture.tab()
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let surface = try #require(source.surfaceTree.first)
        _ = try #require(source.newSplit(at: surface, direction: .right, baseConfig: config))
        let original = Array(source.surfaceTree)
        let icon = NativeTabIconView(frame: .init(x: 0, y: 0, width: 26, height: 26))
        icon.configure(controller: source, icon: .systemSymbol("terminal"), selected: true, activity: nil)
        icon.layoutSubtreeIfNeeded()
        let marks = icon.subviews.compactMap { $0 as? NSImageView }
        #expect(marks.count == 2)
        #expect(marks.allSatisfy { icon.bounds.contains($0.frame) && $0.image != nil })
        #expect(!descendants(icon).contains { String(describing: type(of: $0)).contains("HostingView") })
        let oldWindow = try #require(source.window)
        let selected = try #require(target.window)
        #expect(!source.sharesNativeTabGroup(with: target))
        #expect(target.attachNativeTab(source, relativeTo: target, placement: .before))
        let group = try #require(selected.tabGroup)
        #expect(group.windows.first === oldWindow)
        #expect(group.selectedWindow === selected)
        #expect(source.window === oldWindow)
        #expect(Array(source.surfaceTree).map(ObjectIdentifier.init) == original.map(ObjectIdentifier.init))
        #expect(fixture.store.snapshot.validationErrors.isEmpty)
        #expect(!target.attachNativeTab(source, relativeTo: target, placement: .after))
    }

    @Test func crossWorkspaceNativeDropIsRejectedBeforeMutatingWindows() throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let other = try #require(fixture.store.create(name: "Other", symbol: "briefcase", color: "blue"))
        let target = try fixture.tab()
        let source = try fixture.tab(workspace: other)
        let before = source.window?.tabGroup
        #expect(!target.attachNativeTab(source, relativeTo: target, placement: .after))
        #expect(source.window?.tabGroup === before)
        #expect(source.workspaceID == other)
    }
}
