import AppKit
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct TerminalWorkspaceSwitchSchedulingTests {
    @Test func keyboardBurstPresentsOnlyTheLatestWorkspace() async throws {
        let fixture = try TerminalWorkspaceManagementTests.Fixture()
        defer { fixture.close() }
        let source = fixture.controller
        let window = try #require(source.window)
        let first = try #require(fixture.store.create(name: "First", symbol: "house", color: "blue"))
        let latest = try #require(fixture.store.create(name: "Latest", symbol: "briefcase", color: "mint"))
        var shown: [UUID] = []
        let show = fixture.coordinator.native.show
        fixture.coordinator.native.show = { controller in
            shown.append(controller.workspaceID)
            return show(controller)
        }
        for (digit, keyCode) in [("2", UInt16(19)), ("3", UInt16(20))] {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.control, .command],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: digit, charactersIgnoringModifiers: digit,
                isARepeat: false, keyCode: keyCode
            ))
            #expect(fixture.coordinator.handle(event, in: source))
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(shown == [latest], "Queued input must not present every intermediate workspace")
        #expect(fixture.store.snapshot.windows?[source.windowSessionID]?.currentWorkspace == latest)
        #expect(fixture.coordinator.controllers(in: first).isEmpty)
    }

    @Test func requestReceivedInsideNativeApplyRunsAfterTheCurrentTransaction() async throws {
        let fixture = try TerminalWorkspaceManagementTests.Fixture()
        defer { fixture.close() }
        let source = fixture.controller
        let first = try #require(fixture.store.create(name: "First", symbol: "house", color: "blue"))
        let latest = try #require(fixture.store.create(name: "Latest", symbol: "briefcase", color: "mint"))
        var outcome: TerminalWorkspaceCoordinator.SwitchOutcome?
        let show = fixture.coordinator.native.show
        fixture.coordinator.native.show = { controller in
            if controller.workspaceID == first {
                fixture.coordinator.requestWorkspaceSwitch(to: latest, from: source) { outcome = $0 }
            }
            return show(controller)
        }
        _ = try #require(fixture.coordinator.switchWorkspace(to: first, from: source))
        try await Task.sleep(for: .milliseconds(100))
        #expect(outcome == .committed)
        #expect(fixture.store.snapshot.windows?[source.windowSessionID]?.currentWorkspace == latest)
        #expect(fixture.coordinator.operationError == nil)
    }

    @Test func switchingOtherWorkspacesDoesNotReparkAnUnchangedHiddenGroup() throws {
        let fixture = try TerminalWorkspaceManagementTests.Fixture()
        defer { fixture.close() }
        let source = fixture.controller
        let parkedID = try #require(fixture.store.create(name: "Parked", symbol: "house", color: "blue"))
        let latest = try #require(fixture.store.create(name: "Latest", symbol: "briefcase", color: "mint"))
        let parked = try #require(fixture.coordinator.switchWorkspace(to: parkedID, from: source))
        _ = try #require(fixture.coordinator.switchWorkspace(to: source.workspaceID, from: parked))
        try #require(parked.workspacePresentationIsParked && parked.window?.isVisible == false)
        let generation = parked.workspacePresentationGeneration
        _ = try #require(fixture.coordinator.switchWorkspace(to: latest, from: source))
        #expect(parked.workspacePresentationGeneration == generation)
        #expect(parked.window?.isVisible == false)
    }

    @Test func closingATransitionWindowDoesNotLeaveItsHostQueueWaitingForever() async throws {
        let fixture = try TerminalWorkspaceManagementTests.Fixture()
        defer { fixture.close() }
        let source = fixture.controller
        let window = try #require(source.window)
        var completed = false
        fixture.coordinator.native.transitionCompleted = { host in
            #expect(host == source.windowSessionID)
            completed = true
        }
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        #expect(!completed)
        try await Task.sleep(for: .milliseconds(20))
        #expect(completed)
        #expect(fixture.coordinator.native.transitioningWindows.isEmpty)
    }

    @Test func delayedPickerDismissalCannotReplaceANewerKeyboardIntent() async throws {
        let fixture = try TerminalWorkspaceManagementTests.Fixture()
        defer { fixture.close() }
        let source = fixture.controller
        let stale = try #require(fixture.store.create(name: "Picker", symbol: "house", color: "blue"))
        let latest = try #require(fixture.store.create(name: "Keyboard", symbol: "briefcase", color: "mint"))
        fixture.model.activate(stale)
        let dismissed = try #require(fixture.deferred)
        var outcome: TerminalWorkspaceCoordinator.SwitchOutcome?
        fixture.coordinator.requestWorkspaceSwitch(to: latest, from: source) { outcome = $0 }
        // The old popover finishes closing after the newer shortcut arrived.
        dismissed()
        try await Task.sleep(for: .milliseconds(100))
        #expect(outcome == .committed)
        #expect(!fixture.model.isPerforming)
        #expect(fixture.store.snapshot.windows?[source.windowSessionID]?.currentWorkspace == latest)
        #expect(fixture.coordinator.controllers(in: stale).isEmpty)
    }

    @Test func closingThePickerOwnerCancelsItsPendingDismissalWithoutBlockingSiblingTabs() async throws {
        let fixture = try TerminalWorkspaceManagementTests.Fixture()
        defer { fixture.close() }
        let source = fixture.controller
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let window = try #require(source.window)
        let sibling = try #require(TerminalController.newTab(source.ghostty, from: window,
                                                             withBaseConfig: config))
        let stale = try #require(fixture.store.create(name: "Picker", symbol: "house", color: "blue"))
        let latest = try #require(fixture.store.create(name: "Sibling", symbol: "briefcase", color: "mint"))
        fixture.model.activate(stale)
        let dismissed = try #require(fixture.deferred)
        source.closeTabImmediately()
        #expect(!fixture.model.isPerforming)
        dismissed()
        var outcome: TerminalWorkspaceCoordinator.SwitchOutcome?
        fixture.coordinator.requestWorkspaceSwitch(to: latest, from: sibling) { outcome = $0 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(outcome == .committed)
        #expect(fixture.store.snapshot.windows?[sibling.windowSessionID]?.currentWorkspace == latest)
        #expect(fixture.coordinator.controllers(in: stale).isEmpty)
    }

    @Test func supersededCompletionCanSubmitANewerIntentWithoutItBeingOverwritten() async throws {
        let fixture = try TerminalWorkspaceManagementTests.Fixture()
        defer { fixture.close() }
        let source = fixture.controller
        let first = try #require(fixture.store.create(name: "First", symbol: "house", color: "blue"))
        let second = try #require(fixture.store.create(name: "Second", symbol: "house", color: "blue"))
        let latest = try #require(fixture.store.create(name: "Latest", symbol: "briefcase", color: "mint"))
        fixture.coordinator.requestWorkspaceSwitch(to: first, from: source) { outcome in
            if outcome == .superseded {
                fixture.coordinator.requestWorkspaceSwitch(to: latest, from: source) { _ in }
            }
        }
        fixture.coordinator.requestWorkspaceSwitch(to: second, from: source) { _ in }
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.store.snapshot.windows?[source.windowSessionID]?.currentWorkspace == latest)
        #expect(fixture.coordinator.controllers(in: first).isEmpty)
        #expect(fixture.coordinator.controllers(in: second).isEmpty)
    }

    @Test func rollbackCancelsADismissalOwnedByTheFailedTemporaryWindow() async throws {
        let fixture = try TerminalWorkspaceManagementTests.Fixture()
        defer { fixture.close() }
        let source = fixture.controller
        let failing = try #require(fixture.store.create(name: "Failing", symbol: "house", color: "blue"))
        let latest = try #require(fixture.store.create(name: "Latest", symbol: "briefcase", color: "mint"))
        var cancelled: TerminalWorkspaceCoordinator.SwitchOutcome?
        let show = fixture.coordinator.native.show
        fixture.coordinator.native.show = { controller in
            _ = fixture.coordinator.prepareWorkspaceSwitch(to: latest, from: controller) { cancelled = $0 }
            return false
        }
        #expect(fixture.coordinator.switchWorkspace(to: failing, from: source) == nil)
        #expect(cancelled == .superseded)
        fixture.coordinator.native.show = show
        var completed: TerminalWorkspaceCoordinator.SwitchOutcome?
        fixture.coordinator.requestWorkspaceSwitch(to: latest, from: source) { completed = $0 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(completed == .committed)
        #expect(fixture.store.snapshot.windows?[source.windowSessionID]?.currentWorkspace == latest)
    }

    @Test func lateNativeActivationCannotCancelANewerExplicitSwitch() async throws {
        let fixture = try TerminalWorkspaceManagementTests.Fixture()
        defer { fixture.close() }
        let source = fixture.controller
        let oldID = try #require(fixture.store.create(name: "Old", symbol: "house", color: "blue"))
        let latest = try #require(fixture.store.create(name: "Latest", symbol: "briefcase", color: "mint"))
        let old = try #require(fixture.coordinator.switchWorkspace(to: oldID, from: source))
        _ = try #require(fixture.coordinator.switchWorkspace(to: source.workspaceID, from: old))
        var outcome: TerminalWorkspaceCoordinator.SwitchOutcome?
        let ready = try #require(fixture.coordinator.prepareWorkspaceSwitch(to: latest, from: source) { outcome = $0 })
        old.window?.orderFront(nil)
        fixture.coordinator.didActivate(old)
        ready()
        try await Task.sleep(for: .milliseconds(100))
        #expect(outcome == .committed)
        #expect(fixture.store.snapshot.windows?[source.windowSessionID]?.currentWorkspace == latest)
        #expect(old.window?.isVisible == false)
    }

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
