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
