import AppKit
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct TerminalWorkspacePopoverSwitchTests {
    private enum ClickRoute: Equatable { case performClick, queuedPerformClick, childWindowClick, nativeFullscreenMouse }

    @Test func absentPopoverDoesNotDelayAKeyboardCommand() throws {
        let fixture = try TerminalWorkspaceManagementTests.Fixture()
        defer { fixture.close() }
        var completed = 0
        fixture.controller.workspacePopover.close { completed += 1 }
        #expect(completed == 1)
        #expect(fixture.controller.workspacePopover.contentController == nil)
        #expect(!fixture.controller.workspaceSwitcherIsPresented)
    }

    @Test func performClickRunsTheRealPopoverTargetAndCloseChain() async throws {
        try await exercisePopoverSwitch(route: .performClick)
    }

    @Test func actualPopoverCloseDrainsAQueuedWorkspaceSwitch() async throws {
        try await exercisePopoverSwitch(route: .queuedPerformClick)
    }

    @Test func transientChildWindowCannotStrandTheAcceptedWorkspaceSwitch() async throws {
        try await exercisePopoverSwitch(route: .childWindowClick)
    }

    @Test(.tags(.interactiveDesktop)) func nativeFullscreenMouseSelectionClosesAndSwitchesWithoutAnotherKey() async throws {
        try await exercisePopoverSwitch(route: .nativeFullscreenMouse)
    }

    private func exercisePopoverSwitch(route: ClickRoute) async throws {
        let fixture = try TerminalWorkspaceManagementTests.Fixture()
        defer {
            fixture.controller.workspacePopover.close()
            fixture.close()
        }
        let source = fixture.controller
        let sourceWorkspace = source.workspaceID
        let targetID = try #require(fixture.store.create(name: "Popover target", symbol: "house", color: "blue"))
        let window = try #require(source.window)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        if route == .nativeFullscreenMouse {
            var config = Ghostty.SurfaceConfiguration()
            config.command = "/bin/sleep 120"
            var parent = source
            for _ in 1..<40 {
                let parentWindow = try #require(parent.window)
                parent = try #require(TerminalController.newTab(source.ghostty, from: parentWindow,
                                                                withBaseConfig: config))
            }
            try await Task.sleep(for: .milliseconds(100))
            try #require(fixture.coordinator.controllers(in: sourceWorkspace).count == 40)
            window.tabGroup?.selectedWindow = window
            fixture.coordinator.didActivate(source)
        }

        func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { views(type, in: $0) }
        }
        func targetButton() -> NSButton? {
            guard let content = source.workspacePopover.contentView else { return nil }
            return views(NSButton.self, in: content).first {
                $0.accessibilityIdentifier() == "workspace.open.\(targetID)"
            }
        }
        func waitUntil(attempts: Int = 100, _ predicate: () -> Bool) async -> Bool {
            for _ in 0..<attempts {
                if predicate() { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return predicate()
        }
        func sendButtonMouseDown(_ button: NSButton) throws -> TimeInterval {
            let eventWindow = try #require(button.window)
            let point = button.convert(.init(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            let timestamp = ProcessInfo.processInfo.systemUptime
            let down = try #require(NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [], timestamp: timestamp,
                windowNumber: eventWindow.windowNumber, context: nil, eventNumber: 101, clickCount: 1, pressure: 1
            ))
            let up = try #require(NSEvent.mouseEvent(
                with: .leftMouseUp, location: point, modifierFlags: [], timestamp: timestamp + 0.01,
                windowNumber: eventWindow.windowNumber, context: nil, eventNumber: 102, clickCount: 1, pressure: 0
            ))
            let start = ProcessInfo.processInfo.systemUptime
            // The desktop prerequisite makes NSWindow firstMouse routing real.
            // Queue mouse-up first so the tracking loop cannot wait for input.
            NSApp.postEvent(up, atStart: true)
            NSApp.sendEvent(down)
            if let queued = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast,
                                             inMode: .default, dequeue: true) {
                NSApp.sendEvent(queued)
            }
            return ProcessInfo.processInfo.systemUptime - start
        }

        let native = fixture.coordinator.native
        if route == .nativeFullscreenMouse {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            try String(ProcessInfo.processInfo.processIdentifier).write(
                toFile: "/tmp/omg-workspace-popup-desktop.pid", atomically: true, encoding: .utf8
            )
            let foreground = await waitUntil(attempts: 1_500) {
                if NSApp.isActive { window.makeKeyAndOrderFront(nil) }
                return NSApp.isActive && window.isKeyWindow && window.isOnActiveSpace
            }
            try #require(foreground, "Requires the foreground test window on the active desktop")
            source.toggleFullscreen(mode: .native)
            let entered = await waitUntil(attempts: 1_000) {
                window.styleMask.contains(.fullScreen) && window.isOnActiveSpace && native.transitioningWindows.isEmpty
            }
            try #require(entered, "Requires a completed real native fullscreen transition")
        }

        try await Task.sleep(for: .milliseconds(100))
        source.workspaceSwitcherIsPresented = true
        let opened = await waitUntil { source.workspacePopover.isShown && targetButton() != nil }
        try #require(opened, "The test must open the actual WorkspacePopoverPresentation")
        try #require(source.workspacePopover.contentController is TerminalWorkspacePickerController)
        weak var picker = source.workspacePopover.contentController
        let button = try #require(targetButton())
        #expect(button.isEnabled)
        var transientChild: NSPanel?
        if route == .childWindowClick || route == .nativeFullscreenMouse {
            let owner = try #require(button.window)
            let child = NSPanel(contentRect: .init(x: owner.frame.maxX - 20, y: owner.frame.minY,
                                                  width: 20, height: 20),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            child.isReleasedWhenClosed = false
            child.ignoresMouseEvents = true
            owner.addChildWindow(child, ordered: .above)
            transientChild = child
            #expect(owner.childWindows?.contains(child) == true)
        }
        defer {
            if let transientChild {
                transientChild.parent?.removeChildWindow(transientChild)
                transientChild.close()
            }
        }

        let queued = route == .queuedPerformClick
        let windowID = source.windowSessionID
        if queued {
            // Only the scheduling gate is synthetic; the popover and button are live AppKit objects.
            NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
            #expect(native.transitioningWindows.contains(windowID))
        }

        let started: Bool
        switch route {
        case .performClick, .queuedPerformClick, .childWindowClick:
            button.performClick(nil)
            started = source.workspacePopover.isManagementActionPerforming
        case .nativeFullscreenMouse:
            let duration = try sendButtonMouseDown(button)
            #expect(duration < 2, "Pre-posted mouse-up must release AppKit's button tracking loop")
            started = source.workspacePopover.isManagementActionPerforming
        }
        #expect(started, "The real workspace row action must enter the picker model")

        let closeCompleted = await waitUntil {
            !source.workspacePopover.isShown && source.workspacePopover.contentController == nil
        }
        #expect(closeCompleted, "Popover close must release its pending action and tear down content")
        #expect(await waitUntil { picker == nil }, "Closing must release the original picker controller")
        #expect(!source.workspaceSwitcherIsPresented)

        if queued {
            #expect(fixture.store.snapshot.windows?[windowID]?.currentWorkspace == sourceWorkspace,
                    "The fullscreen transition must keep this prepared switch queued")
            source.workspaceSwitcherIsPresented = true
            let reopened = await waitUntil { source.workspacePopover.isShown && targetButton() != nil }
            try #require(reopened)
            let stillBusy = await waitUntil { source.workspacePopover.isManagementActionPerforming && targetButton()?.isEnabled == false }
            #expect(stillBusy, "The same picker session must stay busy while the switch is queued")
            NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        }

        let switched = await waitUntil {
            fixture.store.snapshot.windows?[windowID]?.currentWorkspace == targetID &&
                !source.workspacePopover.isShown && source.workspacePopover.contentController == nil &&
                native.transitioningWindows.isEmpty
        }
        #expect(switched, "The action released by popoverDidClose must switch to the selected workspace")
        #expect(!source.workspacePopover.isManagementActionPerforming)
        #expect(fixture.coordinator.native.transitioningWindows.isEmpty)
        #expect(fixture.coordinator.operationError == nil)
        let destination = try #require(fixture.coordinator.controllers(in: targetID).first)
        #expect(destination.window?.tabGroup?.selectedWindow === destination.window)
        if route == .nativeFullscreenMouse {
            #expect(destination.window?.isKeyWindow == true)
            #expect(destination.window?.isOnActiveSpace == true)
            #expect(destination.window?.styleMask.contains(.fullScreen) == true)
        }

        if route == .nativeFullscreenMouse {
            destination.workspaceSwitcherIsPresented = true
            let backOpened = await waitUntil { destination.workspacePopover.isShown }
            try #require(backOpened)
            let backContent = try #require(destination.workspacePopover.contentView)
            let backButton = try #require(views(NSButton.self, in: backContent).first {
                $0.accessibilityIdentifier() == "workspace.open.\(sourceWorkspace)"
            })
            _ = try sendButtonMouseDown(backButton)
            let returned = await waitUntil(attempts: 500) {
                fixture.store.snapshot.windows?[windowID]?.currentWorkspace == sourceWorkspace &&
                    !destination.workspacePopover.isShown && native.transitioningWindows.isEmpty
            }
            #expect(returned, "A mouse click must return to the 40-tab workspace without another key")
            #expect(window.isKeyWindow && window.isOnActiveSpace && window.styleMask.contains(.fullScreen))
            #expect(window.tabGroup?.windows.count == 41)
        } else {
            let returnedSource = try #require(
                fixture.coordinator.switchWorkspace(to: sourceWorkspace, from: destination)
            )
            #expect(returnedSource === source)
        }
        source.workspaceSwitcherIsPresented = true
        let reopened = await waitUntil { source.workspacePopover.isShown && targetButton() != nil }
        try #require(reopened)
        let modelReady = await waitUntil {
            !source.workspacePopover.isManagementActionPerforming && targetButton()?.isEnabled == true
        }
        #expect(modelReady, "The original picker session must be reusable after the switch commits")
        source.workspaceSwitcherIsPresented = false
        #expect(await waitUntil { !source.workspacePopover.isShown })
        #expect(source.workspacePopover.contentController == nil)
        if route == .nativeFullscreenMouse {
            source.toggleFullscreen(mode: .native)
            let exited = await waitUntil(attempts: 1_000) {
                !window.styleMask.contains(.fullScreen) && native.transitioningWindows.isEmpty
            }
            #expect(exited)
        }
    }
}
