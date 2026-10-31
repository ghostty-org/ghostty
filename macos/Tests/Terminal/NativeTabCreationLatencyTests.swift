import AppKit
import Combine
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct NativeTabCreationLatencyTests {
    @Test func nativeGroupReconciliationDoesNotRepublishUnchangedWorkspaceIdentity() throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let first = try fixture.tab()
        let second = try fixture.tab(parent: first)
        first.refreshWorkspaceTabs()
        var publications = 0
        let observations = [first, second].map {
            $0.objectWillChange.sink { publications += 1 }
        }
        defer { observations.forEach { $0.cancel() } }
        for _ in 0..<20 { first.refreshWorkspaceTabs() }
        #expect(publications == 0)
        #expect(first.workspaceID == second.workspaceID)
        #expect(first.tabControllers.count == 2)
    }

    @Test func backgroundMembershipChangesDoNotInvalidateTerminalContent() throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let background = try fixture.tab()
        let first = try fixture.tab()
        let second = try fixture.tab()
        background.applyWorkspaceTabProjection([background, first], selected: first)
        var publications = 0
        let observation = background.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        background.applyWorkspaceTabProjection([background, first, second], selected: second)
        #expect(background.tabControllers.count == 3)
        #expect(background.selectedTabID == ObjectIdentifier(second))
        #expect(publications == 0)
        background.applyWorkspaceTabProjection([background, first, second], selected: background)
        #expect(publications == 1)
    }

    @Test func nativeNewTabActionSelectsConfiguredWindowBeforeReturning() async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 120"
        let first = TerminalController(fixture.app, withBaseConfig: config, tabLayout: .horizontal,
                                       workspaceCoordinator: fixture.coordinator)
        fixture.controllers.append(first)
        first.showWindow(nil)
        try await Task.sleep(for: .milliseconds(100))
        let parent = try #require(first.window)
        first.newWindowForTab(nil)
        let group = try #require(parent.tabGroup)
        let added = try #require(group.windows.first { $0 !== parent })
        #expect(group.selectedWindow === added)
        let accessory = try #require(added.tab.accessoryView)
        let icon = try #require(accessory.subviews.compactMap { $0 as? NativeTabIconView }.first)
        #expect(icon.subviews.compactMap { $0 as? NSImageView }.contains { $0.image != nil })
        let mark = try #require(icon.subviews.compactMap { $0 as? NSImageView }.first)
        #expect(mark.contentTintColor == OMGNativeTheme.resolve(for: icon).accent)
        try await Task.sleep(for: .milliseconds(100))
        #expect(group.windows.count == 2 && group.selectedWindow === added)
    }

    @Test(arguments: [Ghostty.Config.MacOSTabLayout.vertical, .horizontal])
    func creationAtFortyTabsKeepsNativeSelectionAndChrome(mode: Ghostty.Config.MacOSTabLayout) async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 120"
        let first = TerminalController(fixture.app, withBaseConfig: config, tabLayout: mode, workspaceCoordinator: fixture.coordinator)
        fixture.controllers.append(first)
        first.showWindow(nil)
        var creation: [Double] = []
        var presentation: [Double] = []
        for index in 1...40 {
            let start = Date()
            let next = try #require(TerminalController.newTab(fixture.app, from: fixture.controllers.last?.window, withBaseConfig: config))
            fixture.controllers.append(next)
            let created = Date()
            creation.append(created.timeIntervalSince(start) * 1_000)
            if mode == .horizontal {
                let accessory = try #require(next.window?.tab.accessoryView)
                let icon = try #require(accessory.subviews.compactMap { $0 as? NativeTabIconView }.first)
                #expect(icon.subviews.compactMap { $0 as? NSImageView }.contains { $0.image != nil })
                #expect(next.window?.tab.title?.isEmpty == false)
            }
            for _ in 0..<100 {
                if next.window?.tabGroup?.selectedWindow === next.window { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            presentation.append(Date().timeIntervalSince(start) * 1_000)
            #expect(next.window?.tabGroup?.selectedWindow === next.window)
            if index == 1 || index == 20 || index == 40 {
                print("TAB_LATENCY mode=\(mode) count=\(index + 1) create=\(creation.last!)ms selected=\(presentation.last!)ms")
            }
        }
        print("TAB_LATENCY mode=\(mode) maxCreate=\(creation.max()!)ms maxSelected=\(presentation.max()!)ms")
        if mode == .horizontal {
            let parent = try #require(fixture.controllers.last)
            let group = try #require(parent.window?.tabGroup)
            let before = group.windows.count
            let start = Date()
            parent.newWindowForTab(nil)
            let duration = Date().timeIntervalSince(start) * 1_000
            #expect(group.windows.count == before + 1)
            #expect(group.selectedWindow !== parent.window)
            print("TAB_NATIVE_PLUS count=\(group.windows.count) selectedBeforeReturn=\(duration)ms")
        }
    }
}
