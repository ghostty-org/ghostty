import AppKit
import Foundation
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct TerminalApplicationTerminationTests {
    private struct RefreshTimeout: Error {}

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RefreshTimeout()
    }

    private func labels(in view: NSView) -> [String] {
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap { labels(in: $0) }
    }

    @Test func pendingQuitCanBeCancelledAndDoesNotFreezeAnotherCoordinator() async throws {
        let firstFixture = try TerminalWorkspaceRefactorTests.Fixture()
        let secondFixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { firstFixture.close(); secondFixture.close() }
        let first = try firstFixture.tab()
        first.tabLayoutState.setSidebarVisible(true)
        first.showWindow(nil)
        firstFixture.sessions.start(firstFixture.app)
        try await waitUntil { first.tabLayoutState.sidebarHost.liveView != nil }
        let firstHost = try #require(first.tabLayoutState.sidebarHost.liveView as? NativeTabSidebarHostingView)

        firstFixture.sessions.prepareToQuit()
        #expect(!firstFixture.coordinator.isTerminating)
        first.titleOverride = "Still reviewing quit"
        try await waitUntil { labels(in: firstHost).contains("Still reviewing quit") }
        firstFixture.sessions.cancelQuit()
        #expect(!firstFixture.coordinator.isTerminating)

        let work = try #require(firstFixture.store.create(name: "After cancel", symbol: "briefcase", color: "blue"))
        let switched = try #require(firstFixture.coordinator.switchWorkspace(to: work, from: first))
        firstFixture.controllers.append(switched)
        #expect(switched.workspaceID == work)

        let other = try secondFixture.tab()
        let otherSecond = try secondFixture.tab(parent: other)
        other.tabLayoutState.setSidebarVisible(true)
        other.showWindow(nil)
        secondFixture.coordinator.didActivate(other)
        try await waitUntil { other.tabLayoutState.sidebarHost.liveView != nil }
        let otherHost = try #require(other.tabLayoutState.sidebarHost.liveView as? NativeTabSidebarHostingView)
        let otherGroup = try #require(other.window?.tabGroup)
        TerminalWorkspacePresentation.begin()
        otherGroup.selectedWindow = otherSecond.window
        TerminalWorkspacePresentation.end()
        other.titleOverride = "Independent coordinator"
        firstFixture.sessions.prepareToQuit()
        firstFixture.coordinator.commitTermination()
        firstFixture.coordinator.commitTermination()
        firstFixture.coordinator.cancelQuit()
        #expect(firstFixture.coordinator.isTerminating)
        #expect(!secondFixture.coordinator.isTerminating)
        try await waitUntil {
            other.tabLayoutState.tabSnapshot.selectedID == ObjectIdentifier(otherSecond)
        }
        try await waitUntil { labels(in: otherHost).contains("Independent coordinator") }
        #expect(other.window?.contentView != nil)
    }

    @Test func confirmedTerminationClosesBackgroundTabsWithoutChangingSelectionOrCheckpoint() throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        let otherFixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close(); otherFixture.close() }

        let first = try fixture.tab()
        first.showWindow(nil)
        let second = try fixture.tab(parent: first)
        let selected = try fixture.tab(parent: second)
        let selectedWindow = try #require(selected.window)
        selectedWindow.makeKeyAndOrderFront(nil)
        fixture.coordinator.didActivate(selected)
        let windows = try [first, second, selected].map { try #require($0.window) }
        let group = try #require(selectedWindow.tabGroup)
        #expect(group.selectedWindow === selectedWindow)

        let other = try otherFixture.tab()
        other.showWindow(nil)
        let otherSelected = try otherFixture.tab(parent: other)
        let otherSelectedWindow = try #require(otherSelected.window)
        otherSelectedWindow.makeKeyAndOrderFront(nil)
        let otherWindows = try [other, otherSelected].map { try #require($0.window) }
        let otherGroup = try #require(otherSelectedWindow.tabGroup)
        let otherCatalog = otherFixture.store.snapshot

        // Make the first coordinator's selected tab key after preparing the
        // independent group. The second group's selection must remain intact.
        selectedWindow.makeKeyAndOrderFront(nil)
        fixture.sessions.start(fixture.app)
        fixture.sessions.capture()
        fixture.sessions.flush()
        let checkpointURL = fixture.directory.appendingPathComponent("state.json")
        let catalog = fixture.store.snapshot

        fixture.sessions.prepareToQuit()
        let checkpoint = try Data(contentsOf: checkpointURL)
        fixture.coordinator.closeBackgroundTabsForTermination()
        #expect(!fixture.coordinator.isTerminating)
        #expect(group.windows.count == windows.count)
        #expect(group.selectedWindow === selectedWindow)
        #expect(windows.allSatisfy { $0.contentView != nil })

        let keyWindow = NSApp.keyWindow
        fixture.coordinator.commitTermination()
        fixture.coordinator.closeBackgroundTabsForTermination()

        #expect(windows.filter { $0 !== selectedWindow }.allSatisfy { $0.contentView == nil })
        #expect(selected.window === selectedWindow)
        #expect(selectedWindow.contentView != nil)
        #expect(NSApp.keyWindow === keyWindow)
        #expect(group.selectedWindow === selectedWindow)
        #expect(fixture.store.snapshot == catalog)
        let savedCheckpoint = try Data(contentsOf: checkpointURL)
        #expect(savedCheckpoint == checkpoint)

        #expect(Set(otherGroup.windows.map(ObjectIdentifier.init)) ==
                Set(otherWindows.map(ObjectIdentifier.init)))
        #expect(otherGroup.selectedWindow === otherSelectedWindow)
        #expect(otherWindows.allSatisfy { $0.contentView != nil })
        #expect(otherFixture.store.snapshot == otherCatalog)
    }

    @Test(.tags(.interactiveDesktop))
    func confirmedTerminationKeepsSelectedTabDuringRealSixtyTabFullscreenTeardown() async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }

        let first = try fixture.tab()
        first.showWindow(nil)
        first.tabLayoutState.setSidebarVisible(true)
        var tabs = [first]
        for _ in 1..<60 { tabs.append(try fixture.tab(parent: tabs.last)) }

        let selected = try #require(tabs.last)
        let selectedWindow = try #require(selected.window)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        selectedWindow.makeKeyAndOrderFront(nil)
        selectedWindow.orderFrontRegardless()
        fixture.coordinator.didActivate(selected)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        try String(ProcessInfo.processInfo.processIdentifier).write(
            toFile: "/tmp/omg-fullscreen-test.pid", atomically: true, encoding: .utf8
        )
        for _ in 0..<200 {
            if NSApp.isActive && selectedWindow.isKeyWindow { break }
            if NSApp.isActive { selectedWindow.makeKeyAndOrderFront(nil) }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(NSApp.isActive && selectedWindow.isKeyWindow, "Requires an unlocked foreground desktop")
        let group = try #require(selectedWindow.tabGroup)
        #expect(group.windows.count == 60)
        #expect(group.selectedWindow === selectedWindow)

        var didEnterFullscreen = false
        let enterObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didEnterFullScreenNotification, object: selectedWindow, queue: .main
        ) { _ in MainActor.assumeIsolated { didEnterFullscreen = true } }
        defer { NotificationCenter.default.removeObserver(enterObserver) }
        selected.toggleFullscreen(mode: .native)
        for _ in 0..<200 {
            if didEnterFullscreen && selectedWindow.styleMask.contains(.fullScreen) &&
                fixture.coordinator.native.transitioningWindows.isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(didEnterFullscreen && selectedWindow.styleMask.contains(.fullScreen) &&
                     fixture.coordinator.native.transitioningWindows.isEmpty,
                     "Requires a completed real native fullscreen transition")

        let windows = try tabs.map { try #require($0.window) }
        let backgroundWindows = windows.filter { $0 !== selectedWindow }
        let backgroundIDs = Set(backgroundWindows.map(ObjectIdentifier.init))
        var promotedKeyEvents: [ObjectIdentifier] = []
        var promotedFullscreenEvents: [ObjectIdentifier] = []
        let keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow,
                      backgroundIDs.contains(ObjectIdentifier(window)) else { return }
                promotedKeyEvents.append(ObjectIdentifier(window))
            }
        }
        let fullscreenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didEnterFullScreenNotification, object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow,
                      backgroundIDs.contains(ObjectIdentifier(window)) else { return }
                promotedFullscreenEvents.append(ObjectIdentifier(window))
            }
        }
        defer {
            NotificationCenter.default.removeObserver(keyObserver)
            NotificationCenter.default.removeObserver(fullscreenObserver)
        }

        fixture.sessions.start(fixture.app)
        fixture.sessions.capture()
        fixture.sessions.flush()
        let checkpointURL = fixture.directory.appendingPathComponent("state.json")
        let catalog = fixture.store.snapshot
        fixture.sessions.prepareToQuit()
        let checkpoint = try Data(contentsOf: checkpointURL)
        fixture.coordinator.commitTermination()
        let clock = ContinuousClock()
        let started = clock.now
        fixture.coordinator.closeBackgroundTabsForTermination()
        let closeDuration = started.duration(to: clock.now)

        for _ in 0..<100 {
            if backgroundWindows.allSatisfy({ $0.contentView == nil }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(250))

        #expect(backgroundWindows.allSatisfy { $0.contentView == nil })
        #expect(promotedKeyEvents.isEmpty)
        #expect(promotedFullscreenEvents.isEmpty)
        #expect(selected.window === selectedWindow)
        #expect(selectedWindow.contentView != nil)
        #expect(selectedWindow.isKeyWindow)
        #expect(selectedWindow.isOnActiveSpace)
        #expect(selectedWindow.styleMask.contains(.fullScreen))
        #expect(selected.fullscreenStyle?.isFullscreen == true)
        #expect(group.selectedWindow === selectedWindow)
        #expect(group.windows.count == 1)
        #expect(fixture.store.snapshot == catalog)
        let savedCheckpoint = try Data(contentsOf: checkpointURL)
        #expect(savedCheckpoint == checkpoint)
        print("TERMINATION_FULLSCREEN_TABS tabs=\(windows.count) background_close_duration=\(closeDuration)")

        var didExitFullscreen = false
        let exitObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: selectedWindow, queue: .main
        ) { _ in MainActor.assumeIsolated { didExitFullscreen = true } }
        defer { NotificationCenter.default.removeObserver(exitObserver) }
        selected.toggleFullscreen(mode: .native)
        for _ in 0..<200 {
            if didExitFullscreen && !selectedWindow.styleMask.contains(.fullScreen) &&
                fixture.coordinator.native.transitioningWindows.isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(didExitFullscreen && !selectedWindow.styleMask.contains(.fullScreen) &&
                fixture.coordinator.native.transitioningWindows.isEmpty,
                "The desktop fixture must finish the native fullscreen exit")
    }

    @Test func confirmedTerminationClosesSixtyTabsWithoutSidebarHandoffAndKeepsCheckpoint() async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let personal = fixture.store.defaultID
        let first = try fixture.tab()
        first.tabLayoutState.setSidebarVisible(true)
        first.showWindow(nil)
        var tabs = [first]
        for _ in 1..<60 { tabs.append(try fixture.tab(parent: tabs.last)) }
        let selected = try #require(tabs.last)
        selected.window?.makeKeyAndOrderFront(nil)
        fixture.coordinator.didActivate(selected)
        let work = try #require(fixture.store.create(name: "Parked on quit", symbol: "briefcase", color: "blue"))
        let parked = try #require(fixture.coordinator.switchWorkspace(to: work, from: selected))
        fixture.controllers.append(parked)
        try #require(fixture.coordinator.switchWorkspace(to: personal, from: parked) === selected)
        fixture.sessions.start(fixture.app)
        try await waitUntil { selected.tabLayoutState.sidebarHost.liveView?.window === selected.window }
        let sidebarHost = selected.tabLayoutState.sidebarHost
        let host = try #require(sidebarHost.liveView as? NativeTabSidebarHostingView)
        let identities = Set(fixture.controllers.map(\.tabSessionID))

        fixture.sessions.prepareToQuit()
        let catalog = fixture.store.snapshot
        let revision = fixture.coordinator.revision
        let refreshCount = host.sidebar.refreshCount
        let mountCount = sidebarHost.mountCount
        selected.titleOverride = "Queued update before termination"
        fixture.coordinator.commitTermination()

        // Close the selected tab first: ordinary close would hand its sidebar
        // to a successor and query a native tab group that AppKit is dismantling.
        let closing = [selected] + fixture.controllers.filter { $0 !== selected }
        let clock = ContinuousClock()
        let started = clock.now
        for controller in closing { controller.window?.close() }
        let duration = started.duration(to: clock.now)
        try await Task.sleep(for: .milliseconds(40))
        fixture.sessions.capture()
        fixture.sessions.flush()

        #expect(closing.allSatisfy { $0.window?.contentView == nil })
        #expect(fixture.coordinator.liveControllers.isEmpty)
        #expect(fixture.coordinator.parked.isEmpty)
        #expect(fixture.coordinator.revision == revision)
        #expect(fixture.store.snapshot == catalog)
        #expect(sidebarHost.mountCount == mountCount)
        #expect(host.sidebar.refreshCount == refreshCount)
        #expect(host.window == nil)

        let saved = try JSONDecoder().decode(
            TerminalWorkspaceSessionStore.Snapshot.self,
            from: Data(contentsOf: fixture.directory.appendingPathComponent("state.json"))
        )
        #expect(Set(saved.tabs.map(\.id)) == identities)
        #expect(saved.catalog == catalog)
        #expect(saved.catalog?.validationErrors.isEmpty == true)
        print("TERMINATION_TABS_BENCHMARK tabs=\(closing.count) close_duration=\(duration)")
    }
}
