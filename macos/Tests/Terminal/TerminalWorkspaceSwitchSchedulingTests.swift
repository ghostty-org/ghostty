import AppKit
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct TerminalWorkspaceSwitchSchedulingTests {
    @Test func pickerWaitsForQueuedSwitchWithoutShowingAFailure() async throws {
        let fixture = try TerminalWorkspaceManagementTests.Fixture()
        defer { fixture.close() }
        let source = fixture.controller
        let target = try #require(fixture.store.create(name: "Target", symbol: "house", color: "blue"))
        let window = try #require(source.window)
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        fixture.model.activate(target)
        fixture.deferred?()
        #expect(fixture.model.isPerforming)
        #expect(fixture.model.error == nil)
        #expect(fixture.reopenCount == 0)
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!fixture.model.isPerforming)
        #expect(fixture.reopenCount == 0)
        #expect(fixture.store.snapshot.windows?[source.windowSessionID]?.currentWorkspace == target)
    }

    @Test func queuedFailureReturnsToTheManagementSession() async throws {
        let fixture = try TerminalWorkspaceManagementTests.Fixture()
        defer { fixture.close() }
        let target = try #require(fixture.store.create(name: "Target", symbol: "house", color: "blue"))
        let window = try #require(fixture.controller.window)
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        fixture.model.activate(target)
        fixture.deferred?()
        fixture.coordinator.native.show = { _ in false }
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!fixture.model.isPerforming)
        #expect(fixture.model.error != nil)
        #expect(fixture.reopenCount == 1)
    }

    @Test func latestQueuedTargetStillAppliesWhenTransitionFinishes() async throws {
        let fixture = try TerminalWorkspaceManagementTests.Fixture()
        defer { fixture.close() }
        let source = fixture.controller
        let window = try #require(source.window)
        let first = try #require(fixture.store.create(name: "First", symbol: "house", color: "blue"))
        let latest = try #require(fixture.store.create(name: "Latest", symbol: "briefcase", color: "mint"))
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        #expect(fixture.coordinator.switchWorkspace(to: first, from: source) == nil)
        #expect(fixture.coordinator.switchWorkspace(to: latest, from: source) == nil)
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.store.snapshot.windows?[source.windowSessionID]?.currentWorkspace == latest)
        #expect(fixture.coordinator.controllers(in: first).isEmpty)
        #expect(fixture.coordinator.controllers(in: latest).count == 1)
    }

    @Test func selectingCurrentWorkspaceCancelsOlderFullscreenRequest() async throws {
        let fixture = try TerminalWorkspaceManagementTests.Fixture()
        defer { fixture.close() }
        let source = fixture.controller
        let window = try #require(source.window)
        let original = source.workspaceID
        let destination = try #require(fixture.store.create(name: "Queued", symbol: "house", color: "blue"))
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        #expect(fixture.coordinator.switchWorkspace(to: destination, from: source) == nil)
        #expect(fixture.coordinator.switchWorkspace(to: original, from: source) === source)
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.store.snapshot.windows?[source.windowSessionID]?.currentWorkspace == original)
        #expect(fixture.coordinator.controllers(in: destination).isEmpty)
        #expect(fixture.coordinator.operationError == nil)
    }

    @Test func newRequestBeforeCompletionDrainSupersedesTheQueuedTarget() async throws {
        let fixture = try TerminalWorkspaceManagementTests.Fixture()
        defer { fixture.close() }
        let source = fixture.controller
        let window = try #require(source.window)
        let queued = try #require(fixture.store.create(name: "Queued", symbol: "house", color: "blue"))
        let latest = try #require(fixture.store.create(name: "Latest", symbol: "briefcase", color: "mint"))
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        #expect(fixture.coordinator.switchWorkspace(to: queued, from: source) == nil)
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        // The completion drain is queued, but this newer command arrives first.
        let target = try #require(fixture.coordinator.switchWorkspace(to: latest, from: source))
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.store.snapshot.windows?[target.windowSessionID]?.currentWorkspace == latest)
        #expect(fixture.coordinator.controllers(in: queued).isEmpty)
    }

    @Test func fullscreenFailureDoesNotDrainCommandsInsideTheNativeCallback() async throws {
        let fixture = try TerminalWorkspaceManagementTests.Fixture()
        defer { fixture.close() }
        let window = try #require(fixture.controller.window)
        var completed = false
        fixture.coordinator.native.transitionCompleted = { _ in completed = true }
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        fixture.coordinator.native.fullscreenTransitionFailed(in: fixture.controller.windowSessionID)
        #expect(!completed)
        try await Task.sleep(for: .milliseconds(20))
        #expect(completed)
    }

    @Test func failureCompletionWaitsForANewerNativeTransition() async throws {
        let fixture = try TerminalWorkspaceManagementTests.Fixture()
        defer { fixture.close() }
        let window = try #require(fixture.controller.window)
        var completed = false
        fixture.coordinator.native.transitionCompleted = { _ in completed = true }
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        fixture.coordinator.native.fullscreenTransitionFailed(in: fixture.controller.windowSessionID)
        NotificationCenter.default.post(name: NSWindow.willExitFullScreenNotification, object: window)
        try await Task.sleep(for: .milliseconds(20))
        #expect(!completed)
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
        try await Task.sleep(for: .milliseconds(20))
        #expect(completed)
    }
}
