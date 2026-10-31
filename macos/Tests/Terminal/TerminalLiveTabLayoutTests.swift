import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct TerminalLiveTabLayoutTests {
    @Test func tabChromeSettlesAfterCreationAndRepeatedDirectionChanges() async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let source = try fixture.tab()
        source.showWindow(nil)
        let second = try fixture.tab(parent: source)
        let window = try #require(source.window as? TerminalWindow)
        let other = try #require(second.window as? TerminalWindow)
        for mode in [Ghostty.Config.MacOSTabLayout.horizontal, .vertical, .horizontal, .vertical] {
            fixture.coordinator.requestTabLayout(mode, from: source)
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(200))
            #expect(window.nativeTabStripIsVisible == (mode == .horizontal))
            other.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(200))
            #expect(other.nativeTabStripIsVisible == (mode == .horizontal))
        }
        let chrome = try #require(other.omgTabChrome)
        try await Task.sleep(for: .milliseconds(300))
        let refreshes = chrome.refreshCount
        let toggles = chrome.visibilityChangeCount
        var cpuStart = timespec()
        clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &cpuStart)
        try await Task.sleep(for: .milliseconds(300))
        var cpuEnd = timespec()
        clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &cpuEnd)
        let cpuSeconds = Double(cpuEnd.tv_sec - cpuStart.tv_sec) + Double(cpuEnd.tv_nsec - cpuStart.tv_nsec) / 1_000_000_000
        print("Tab chrome idle: \(chrome.refreshCount - refreshes) refreshes, \(chrome.visibilityChangeCount - toggles) toggles, \(cpuSeconds)s CPU / 0.3s")
        #expect(chrome.refreshCount - refreshes < 5)
        #expect(chrome.visibilityChangeCount == toggles)
        #expect(other.titlebarSeparatorStyle == .none)
    }

    @Test func splitPreviewKeepsItsWidthInAnActualPopover() async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let source = try fixture.tab()
        let actions = NativeActionPopoverController(entries: (0..<4).map { index in
            .action("Pane \(index)", symbol: "terminal") {}
        })
        let panel = NativeTabPanePreviewController(controller: source, actions: actions)
        let anchor = NSView(frame: .init(x: 0, y: 0, width: 26, height: 26))
        let window = NSWindow(contentRect: .init(x: 200, y: 200, width: 400, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(anchor)
        window.orderFront(nil)
        let popover = NSPopover()
        defer { popover.close(); window.close() }
        popover.animates = false
        popover.contentViewController = panel
        popover.contentSize = panel.preferredContentSize
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
        try await Task.sleep(for: .milliseconds(150))
        panel.view.layoutSubtreeIfNeeded()
        #expect(abs(panel.view.bounds.width - 320) < 1)
        #expect(panel.view.bounds.height < 410)
        #expect(panel.surface.diagram?.bounds.width == 320)
        #expect(panel.surface.scroll?.documentView?.bounds.width ?? 0 > 280)
        #expect(panel.surface.scroll?.documentView?.bounds.height ?? 0 > 100)
        if let image = NSImage(data: panel.view.dataWithPDF(inside: panel.view.bounds)),
           let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: "/tmp/omg-fixed-pane-preview.png"))
        }
    }

    @Test func horizontalTabsUseNativeAgentStatusAndSharedPresentation() async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let source = try fixture.tab()
        source.showWindow(nil)
        fixture.coordinator.requestTabLayout(.horizontal, from: source)
        let activities = try #require(NSApp.delegate as? AppDelegate).tabActivities
        defer { activities.removeSession(source.tabSessionID) }
        let window = try #require(source.window as? TerminalWindow)
        let accessory = try #require(window.tab.accessoryView as? NSStackView)
        let badge = try #require(accessory.arrangedSubviews.compactMap { $0 as? NSImageView }.first)
        for (index, state) in [PluginSessionStatus.State.running, .waiting, .completed, .failed].enumerated() {
            #expect(activities.set(.init(sessionID: source.tabSessionID, revision: UInt64(index + 1),
                status: .init(agent: "codex", title: nil, state: state, icon: .init(kind: .systemSymbol, name: "terminal")),
                ttlMilliseconds: nil), pluginID: "test.layout", sessionExists: { $0 == source.tabSessionID }) == nil)
            try await Task.sleep(for: .milliseconds(50))
            #expect(badge.isHidden == (state == .running))
            if state != .running { #expect(badge.image != nil) }
            let value = try #require(TerminalTabPresentationResolver.resolve(source, index: 1, selected: true, activities: activities))
            #expect(window.tab.title == (value.remoteBreadcrumb?.title ?? value.title))
            #expect(window.tab.toolTip.contains("codex"))
        }
    }

    @Test func changingLayoutKeepsWindowsSurfacesAndParkedWorkspaceModes() async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let first = try fixture.tab()
        let second = try fixture.tab(parent: first)
        first.showWindow(nil)
        let other = try #require(fixture.coordinator.createWorkspace(name: "Other", symbol: "briefcase", color: "blue", from: first))
        let controllers = [first, second, other]
        let windows = try controllers.map { try #require($0.window) }
        let surfaces = controllers.map { Array($0.surfaceTree).map(ObjectIdentifier.init) }
        let host = first.windowSessionID
        for mode in [Ghostty.Config.MacOSTabLayout.horizontal, .vertical, .horizontal] {
            fixture.coordinator.requestTabLayout(mode, from: other)
            try await Task.sleep(for: .milliseconds(100))
            for (index, controller) in controllers.enumerated() {
                #expect(controller.tabLayout == mode)
                #expect(controller.window === windows[index])
                #expect(Array(controller.surfaceTree).map(ObjectIdentifier.init) == surfaces[index])
                #expect(controller.windowSessionID == host)
            }
            #expect(fixture.store.snapshot.windows?[host]?.currentWorkspace == other.workspaceID)
            #expect(fixture.store.snapshot.windows?[host]?.tabLayout == mode.rawValue)
        }
        #expect(other.horizontalWorkspaceInTitlebar)
        let window = try #require(other.window as? TerminalWindow)
        func containsWorkspace(_ view: NSView) -> Bool {
            view is TerminalWorkspaceHeaderButton || view.subviews.contains(where: containsWorkspace)
        }
        let workspaceAccessory = try #require(window.titlebarAccessoryViewControllers.first { containsWorkspace($0.view) })
        #expect(workspaceAccessory.view.frame.width > 30)
        #expect(window.inspectorTitlebarPresentation.navigationInPane)
        #expect(window.inspectorControlsWidth == TerminalTitlebarMetrics.inspectorCollapsedWidth)
        let accessory = try #require(window.tab.accessoryView as? NSStackView)
        #expect(accessory.arrangedSubviews.contains { $0 is NativeTabIconView && !$0.isHidden })
        var newConfig = Ghostty.SurfaceConfiguration()
        newConfig.command = "/bin/sleep 60"
        let added = try #require(TerminalController.newTab(fixture.app, from: window, withBaseConfig: newConfig))
        fixture.controllers.append(added)
        #expect(added.tabLayout == .horizontal)
        let addedWindow = try #require(added.window)
        #expect(ObjectIdentifier(type(of: addedWindow)) == ObjectIdentifier(type(of: window)))
    }

    @Test func originallyHorizontalWindowCanUseTheNativeVerticalSidebar() async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let controller = TerminalController(fixture.app, withBaseConfig: config, tabLayout: .horizontal,
                                            workspaceCoordinator: fixture.coordinator)
        fixture.controllers.append(controller)
        let window = try #require(controller.window)
        let content = window.contentView
        controller.showWindow(nil)
        fixture.coordinator.requestTabLayout(.vertical, from: controller)
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.supportsSidebar)
        #expect(controller.sidebarIsShowing)
        #expect(controller.window === window && window.contentView === content)
        #expect((window as? TerminalWindow)?.nativeTabStripIsVisible == false)
        #expect(!controller.horizontalWorkspaceInTitlebar)
        fixture.coordinator.requestTabLayout(.horizontal, from: controller)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!controller.supportsSidebar)
        #expect(controller.horizontalWorkspaceInTitlebar)
        #expect(controller.window === window && window.contentView === content)
        #expect(window.tabGroup?.isTabBarVisible == true)
    }

    @Test func latestLayoutRequestWaitsForNativeFullscreenCompletion() async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let source = try fixture.tab()
        let window = try #require(source.window)
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        fixture.coordinator.requestTabLayout(.horizontal, from: source)
        #expect(source.tabLayout == .vertical)
        fixture.coordinator.requestTabLayout(.vertical, from: source)
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        try await Task.sleep(for: .milliseconds(50))
        #expect(source.tabLayout == .vertical)
    }

    @Test(arguments: [VerticalTabDropPolicy.Placement.before, .after])
    func joiningAnotherNativeGroupAdoptsItsHostDirection(placement: VerticalTabDropPolicy.Placement) async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let target = try fixture.tab()
        let source = try fixture.tab()
        target.showWindow(nil)
        fixture.coordinator.requestTabLayout(.horizontal, from: target)
        #expect(source.tabLayout == .vertical)
        #expect(target.attachNativeTab(source, relativeTo: target, placement: placement))
        try await Task.sleep(for: .milliseconds(50))
        #expect(source.windowSessionID == target.windowSessionID)
        #expect(source.tabLayout == .horizontal)
    }

    @Test func settingChangesOnlyTheLastMainHostAndPersistsItsDirection() async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let source = try fixture.tab()
        let independent = try fixture.tab()
        let settings = OhMyGhosttySettings.shared
        let saved = settings.tabLayout
        defer { settings.tabLayout = saved }
        source.windowDidBecomeMain(Notification(name: NSWindow.didBecomeMainNotification, object: source.window))
        settings.tabLayout = .vertical
        settings.tabLayout = .horizontal
        try await Task.sleep(for: .milliseconds(100))
        #expect(source.tabLayout == .horizontal)
        #expect(independent.tabLayout == .vertical)
        let encoded = try JSONEncoder().encode(fixture.store.snapshot)
        let decoded = try JSONDecoder().decode(TerminalWorkspaceState.self, from: encoded)
        #expect(decoded.windows?[source.windowSessionID]?.tabLayout == "horizontal")
        #expect(fixture.coordinator.tabLayout(in: source.windowSessionID, fallback: .vertical) == .horizontal)
    }
}
