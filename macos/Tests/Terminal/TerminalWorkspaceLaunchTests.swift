import AppKit
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct TerminalWorkspaceLaunchTests {
    @Test func checkpointCapturesForegroundChangesWithoutChangingTheWorkspaceGraph() throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let first = try fixture.tab()
        first.showWindow(nil)
        let second = try fixture.tab()
        second.showWindow(nil)
        fixture.sessions.start(fixture.app)
        fixture.sessions.capture(foreground: first.window)
        fixture.sessions.flush()
        let url = fixture.directory.appendingPathComponent("state.json")
        let firstSnapshot = try JSONDecoder().decode(TerminalWorkspaceSessionStore.Snapshot.self,
                                                    from: Data(contentsOf: url))
        #expect(firstSnapshot.foregroundTab == first.tabSessionID)
        let catalog = fixture.store.snapshot
        let writes = fixture.sessions.writeCount

        fixture.sessions.capture(foreground: second.window)
        fixture.sessions.flush()

        let secondSnapshot = try JSONDecoder().decode(TerminalWorkspaceSessionStore.Snapshot.self,
                                                     from: Data(contentsOf: url))
        #expect(secondSnapshot.foregroundTab == second.tabSessionID)
        #expect(fixture.store.snapshot == catalog)
        #expect(fixture.sessions.writeCount == writes + 1)
    }

    @Test(arguments: [false, true])
    func checkpointLaunchRestoresForegroundSelectionWithoutAppKitWindowCallbacks(legacy: Bool) async throws {
        let previousMode = OhMyGhosttySettings.shared.startupMode
        OhMyGhosttySettings.shared.startupMode = .restoreSessions
        defer { OhMyGhosttySettings.shared.startupMode = previousMode }
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let first = try fixture.tab()
        first.showWindow(nil)
        let selected = try fixture.tab(parent: first)
        selected.window?.makeKeyAndOrderFront(nil)
        fixture.coordinator.didActivate(selected)
        let other = try fixture.tab()
        other.showWindow(nil)
        fixture.sessions.start(fixture.app)
        fixture.sessions.capture(foreground: selected.window)
        fixture.sessions.flush()
        let selectedID = selected.tabSessionID
        let firstID = first.tabSessionID
        let otherID = other.tabSessionID
        let panes = Set(fixture.controllers.flatMap { $0.surfaceTree.map(\.id) })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let checkpoint = directory.appendingPathComponent("state.json")
        try FileManager.default.copyItem(at: fixture.directory.appendingPathComponent("state.json"), to: checkpoint)
        if legacy {
            var snapshot = try JSONDecoder().decode(TerminalWorkspaceSessionStore.Snapshot.self,
                                                   from: Data(contentsOf: checkpoint))
            snapshot.foregroundTab = nil
            try JSONEncoder().encode(snapshot).write(to: checkpoint)
        }
        fixture.close()

        let store = TerminalWorkspaceStore(fileURL: nil)
        var restoredCoordinator: TerminalWorkspaceCoordinator?
        var completed = 0
        let selection = TerminalTabSelectionRestoration(finishRestoring: {
            completed += 1
            restoredCoordinator?.finishRestoring()
        })
        if legacy {
            let archive = TerminalTabSelectionRestoration(captureSnapshot: {
                .init(groups: [], foreground: selectedID)
            })
            let coder = NSKeyedArchiver(requiringSecureCoding: true)
            archive.encode(into: coder)
            coder.finishEncoding()
            let decoder = try NSKeyedUnarchiver(forReadingFrom: coder.encodedData)
            selection.decode(from: decoder)
            decoder.finishDecoding()
        }
        let sessions = TerminalWorkspaceSessionStore(url: checkpoint, testing: true, workspaces: store,
                                                    selectionRestoration: selection)
        let coordinator = TerminalWorkspaceCoordinator(store: store, sessions: sessions)
        restoredCoordinator = coordinator
        defer { restoredCoordinator = nil }
        sessions.prepare()
        sessions.start(fixture.app)
        let restored = coordinator.liveControllers
        defer {
            sessions.prepareToQuit()
            coordinator.commitTermination()
            coordinator.closeBackgroundTabsForTermination()
            for controller in restored { controller.window?.close() }
            sessions.flush()
        }
        let target = try #require(restored.first { $0.tabSessionID == selectedID })
        let targetWindow = try #require(target.window)
        let group = try #require(targetWindow.tabGroup)
        let firstWindow = try #require(restored.first { $0.tabSessionID == firstID }?.window)
        let otherWindow = try #require(restored.first { $0.tabSessionID == otherID }?.window)
        TerminalWorkspacePresentation.begin()
        group.selectedWindow = firstWindow
        otherWindow.makeKeyAndOrderFront(nil)
        TerminalWorkspacePresentation.end()

        // The checkpoint's controllers never entered registerRestored through
        // AppKit. A later system selection snapshot must not displace them.
        let stale = TerminalTabSelectionRestoration(captureSnapshot: {
            .init(groups: [.init(members: [firstID, selectedID], selected: firstID)], foreground: otherID)
        })
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        stale.encode(into: coder)
        coder.finishEncoding()
        let decoder = try NSKeyedUnarchiver(forReadingFrom: coder.encodedData)
        selection.decode(from: decoder)
        decoder.finishDecoding()
        selection.finishLaunching()
        for _ in 0..<100 {
            if completed > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(completed == 1)
        #expect(group.selectedWindow === targetWindow)
        #expect(targetWindow.isVisible)
        #expect(target.tabLayoutState.tabSnapshot.selectedID == ObjectIdentifier(target))
        #expect(Set(target.tabLayoutState.tabSnapshot.controllers.map(\.tabSessionID)) == [firstID, selectedID])
        #expect(Set(restored.flatMap { $0.surfaceTree.map(\.id) }) == panes)
        #expect(store.group(window: target.windowSessionID, workspace: target.workspaceID)?.selected == selectedID)
        for _ in 0..<100 {
            if let host = target.tabLayoutState.sidebarHost.liveView as? NativeTabSidebarHostingView,
               host.window === targetWindow,
               host.sidebar.list.nodes.values.filter({ $0.tab != nil }).count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let host = try #require(target.tabLayoutState.sidebarHost.liveView as? NativeTabSidebarHostingView)
        #expect(host.window === targetWindow)
        #expect(host.sidebar.configuration.controller === target)
        #expect(host.sidebar.configuration.layoutState === target.tabLayoutState)
        #expect(Set(host.sidebar.list.nodes.values.compactMap { $0.tab?.controller.tabSessionID }) ==
                [firstID, selectedID])
    }

    @Test func nativeSelectionOfAParkedTabActivatesItsWorkspaceAndExactTab() async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let first = try fixture.tab()
        first.showWindow(nil)
        let target = try fixture.tab(parent: first)
        fixture.coordinator.didActivate(first)
        let other = try #require(fixture.store.create(name: "Other", symbol: "house", color: "blue"))
        let outgoing = try #require(fixture.coordinator.switchWorkspace(to: other, from: first))
        fixture.controllers.append(outgoing)
        let targetWindow = try #require(target.window)
        let group = try #require(targetWindow.tabGroup)
        let surfaces = fixture.controllers.map { Array($0.surfaceTree).map(ObjectIdentifier.init) }

        TerminalWorkspacePresentation.begin()
        group.selectedWindow = targetWindow
        TerminalWorkspacePresentation.end()
        try #require(target.workspacePresentationIsParked)
        for _ in 0..<100 {
            if !target.workspacePresentationIsParked { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!target.workspacePresentationIsParked)
        #expect(outgoing.workspacePresentationIsParked)
        #expect(group.selectedWindow === targetWindow)
        #expect(fixture.store.snapshot.windows?[target.windowSessionID]?.currentWorkspace == target.workspaceID)
        #expect(fixture.store.group(window: target.windowSessionID, workspace: target.workspaceID)?.selected == target.tabSessionID)
        #expect(target.tabLayoutState.tabSnapshot.selectedID == ObjectIdentifier(target))
        #expect(target.tabLayoutState.tabSnapshot.controllers.map(\.tabSessionID) == [first.tabSessionID, target.tabSessionID])
        #expect(fixture.controllers.map { Array($0.surfaceTree).map(ObjectIdentifier.init) } == surfaces)
    }

    @Test func dockReopenDoesNotTreatAParkedNativeTabAsAVisibleWorkspace() throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let first = try fixture.tab()
        first.showWindow(nil)
        let other = try #require(fixture.store.create(name: "Other", symbol: "house", color: "blue"))
        let current = try #require(fixture.coordinator.switchWorkspace(to: other, from: first))
        fixture.controllers.append(current)
        let currentWindow = try #require(current.window)
        let parkedWindow = try #require(first.window)
        let group = try #require(currentWindow.tabGroup)
        try #require(group.windows.contains(parkedWindow))
        let tabIDs = Set(fixture.coordinator.liveControllers.map(\.tabSessionID))

        // AppKit's Window/Dock menu can select a retained parked tab while the
        // committed workspace and its sidebar still belong to the current tab.
        TerminalWorkspacePresentation.begin()
        group.selectedWindow = parkedWindow
        TerminalWorkspacePresentation.end()
        try #require(parkedWindow.isVisible)
        try #require(first.workspacePresentationIsParked)

        let delegate = try #require(NSApp.delegate as? AppDelegate)
        let useAppKitDefault = delegate.handleReopen(hasVisibleWindows: true, coordinator: fixture.coordinator)

        #expect(!useAppKitDefault)
        #expect(group.selectedWindow === currentWindow)
        #expect(currentWindow.isVisible)
        #expect(!current.workspacePresentationIsParked)
        #expect(first.workspacePresentationIsParked)
        #expect(Set(fixture.coordinator.liveControllers.map(\.tabSessionID)) == tabIDs)
        #expect(fixture.store.snapshot.windows?[current.windowSessionID]?.currentWorkspace == other)
    }

    @Test func dockReopenKeepsAppKitBehaviorForAHealthyVisibleWorkspace() throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let selected = try fixture.tab()
        selected.showWindow(nil)
        fixture.coordinator.didActivate(selected)
        let catalog = fixture.store.snapshot
        let revision = fixture.coordinator.revision
        var presentations = 0
        let show = fixture.coordinator.native.show
        fixture.coordinator.native.show = { controller in
            presentations += 1
            return show(controller)
        }
        let delegate = try #require(NSApp.delegate as? AppDelegate)

        #expect(delegate.handleReopen(hasVisibleWindows: true, coordinator: fixture.coordinator))
        #expect(presentations == 0)
        #expect(fixture.coordinator.revision == revision)
        #expect(fixture.store.snapshot == catalog)
        #expect(selected.window?.isVisible == true)
    }

    @Test func finishingCheckpointRestoreKeepsParkedMembersInTheirRetainedGroup() throws {
        let previousMode = OhMyGhosttySettings.shared.startupMode
        OhMyGhosttySettings.shared.startupMode = .restoreSessions
        defer { OhMyGhosttySettings.shared.startupMode = previousMode }
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let first = try fixture.tab()
        first.showWindow(nil)
        _ = try fixture.tab(parent: first)
        fixture.coordinator.didActivate(first)
        let other = try #require(fixture.store.create(name: "Parked", symbol: "house", color: "blue"))
        let parked = try #require(fixture.coordinator.switchWorkspace(to: other, from: first))
        fixture.controllers.append(parked)
        _ = try fixture.tab(workspace: other, parent: parked)
        try #require(fixture.coordinator.switchWorkspace(to: first.workspaceID, from: parked) === first)
        fixture.sessions.start(fixture.app)
        fixture.sessions.capture()
        fixture.sessions.flush()

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let checkpoint = directory.appendingPathComponent("state.json")
        try FileManager.default.copyItem(at: fixture.directory.appendingPathComponent("state.json"), to: checkpoint)
        let selectedID = first.tabSessionID
        let expectedIDs = Set(fixture.controllers.map(\.tabSessionID))
        fixture.close()

        let store = TerminalWorkspaceStore(fileURL: nil)
        let sessions = TerminalWorkspaceSessionStore(url: checkpoint, testing: true, workspaces: store)
        let coordinator = TerminalWorkspaceCoordinator(store: store, sessions: sessions)
        sessions.prepare()
        try #require(sessions.ownsRestoration)
        sessions.start(fixture.app)
        let restored = coordinator.liveControllers
        defer {
            sessions.prepareToQuit()
            coordinator.commitTermination()
            coordinator.closeBackgroundTabsForTermination()
            for controller in restored { controller.window?.close() }
            sessions.flush()
        }
        let selected = try #require(restored.first { $0.tabSessionID == selectedID })
        let window = try #require(selected.window)
        let group = try #require(window.tabGroup)
        try #require(Set(restored.map(\.tabSessionID)) == expectedIDs)
        try #require(group.windows.count == 4)
        try #require(coordinator.usesRetainedNativeTabs(in: selected.windowSessionID))
        let membership = Set(group.windows.map(ObjectIdentifier.init))

        coordinator.finishRestoring()

        #expect(Set(group.windows.map(ObjectIdentifier.init)) == membership)
        #expect(group.selectedWindow === window)
        #expect(window.isVisible)
        #expect(store.snapshot.windows?[selected.windowSessionID]?.currentWorkspace == selected.workspaceID)
        #expect(restored.filter { $0.workspaceID == other }.allSatisfy { $0.workspacePresentationIsParked })
    }

    @Test func reopeningHiddenWindowsKeepsTheCurrentWorkspace() throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let first = TerminalController(fixture.app, withBaseConfig: config,
                                       tabLayout: .horizontal, workspaceCoordinator: fixture.coordinator)
        fixture.controllers.append(first)
        first.showWindow(nil)
        let other = try #require(fixture.store.create(name: "Current", symbol: "house", color: "blue"))
        let current = try #require(fixture.coordinator.switchWorkspace(to: other, from: first))
        fixture.controllers.append(current)
        try #require(current.window?.isVisible == true)
        try #require(first.workspacePresentationIsParked)
        current.window?.orderOut(nil)
        try #require(!fixture.coordinator.liveControllers.contains { $0.window?.isVisible == true })

        let delegate = try #require(NSApp.delegate as? AppDelegate)
        #expect(!delegate.handleReopen(hasVisibleWindows: false, coordinator: fixture.coordinator))

        #expect(fixture.store.snapshot.windows?[first.windowSessionID]?.currentWorkspace == other)
        #expect(current.window?.isVisible == true)
        #expect(first.workspacePresentationIsParked)
    }

    @Test func launchWithoutAppKitSnapshotFinishesTheInjectedRestorationOwner() {
        var completions = 0
        let restoration = TerminalTabSelectionRestoration(
            captureSnapshot: { .init(groups: [], foreground: nil) },
            finishRestoring: { completions += 1 }
        )
        restoration.finishLaunching()
        #expect(completions == 1)
    }

    @Test func workspacePresentationPreservesItsPreparedWindowFrame() throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let controller = try fixture.tab()
        let window = try #require(controller.window)
        let screen = try #require(window.screen ?? NSScreen.main).visibleFrame
        var frame = NSRect(x: screen.minX + 31, y: screen.minY + 47,
                           width: min(641, screen.width * 0.7), height: min(433, screen.height * 0.7))
        if let stored = UserDefaults.ghostty.array(forKey: "NSWindowLastPosition") as? [Double],
           stored.count >= 4, stored[2] == frame.width {
            frame.size.width -= 17
        }
        window.setFrame(frame, display: false)
        let expected = window.frame
        let transaction = TerminalWorkspacePresentationTransaction([controller])
        controller.showWindow(nil)
        transaction.publish {}
        #expect(window.frame == expected)
    }
}
