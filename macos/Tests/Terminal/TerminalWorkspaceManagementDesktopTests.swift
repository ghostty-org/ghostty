import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@Suite(.tags(.interactiveDesktop), .serialized) @MainActor
struct TerminalWorkspaceManagementDesktopTests {
    @Test(arguments: [FullscreenMode.native, .nonNative])
    func createWorkspaceFromFullscreenPopover(mode: FullscreenMode) async throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let store = TerminalWorkspaceStore(fileURL: nil)
        let coordinator = TerminalWorkspaceCoordinator(store: store)
        coordinator.finishRestoring()
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let source = TerminalController(app, withBaseConfig: config, tabLayout: .vertical, workspaceCoordinator: coordinator)
        let window = try #require(source.window)
        defer { for controller in coordinator.liveControllers { controller.window?.close() } }
        source.showWindow(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        for _ in 0..<100 {
            if NSApp.isActive && window.isKeyWindow { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(NSApp.isActive && window.isKeyWindow, "Requires unlocked foreground desktop")
        var entered = false
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification,
            object: window, queue: .main) { _ in MainActor.assumeIsolated { entered = true } }
        defer { NotificationCenter.default.removeObserver(observer) }
        source.toggleFullscreen(mode: mode)
        for _ in 0..<200 {
            if mode == .native ? entered : source.fullscreenStyle?.isFullscreen == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(source.fullscreenStyle?.isFullscreen == true)
        try await Task.sleep(for: .milliseconds(100))
        source.workspaceSwitcherIsPresented = true
        try #require(source.workspacePopover.isShown)
        let content = try #require(source.workspacePopover.contentView)
        try await Task.sleep(for: .milliseconds(100))
        try click(content, at: NSPoint(x: content.bounds.width - 35, y: 21))
        try await Task.sleep(for: .milliseconds(100))
        func fields(_ view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
        }
        let field = try #require(fields(content).first { $0.isEditable })
        content.window?.makeFirstResponder(field)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("Fullscreen created via popover", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(100))
        try click(content, at: NSPoint(x: content.bounds.width - 55, y: content.bounds.height - 28))
        try await Task.sleep(for: .milliseconds(500))
        let created = try #require(store.workspaces.first { $0.name == "Fullscreen created via popover" })
        let target = try #require(coordinator.controllers(in: created.id).first,
            "Created label must have a presented terminal; transition=\(coordinator.native.transitioningWindows), error=\(coordinator.operationError ?? "none")")
        #expect(!source.workspacePopover.isShown)
        #expect(target.window?.isKeyWindow == true)
        #expect(target.fullscreenStyle?.isFullscreen == true)
        #expect(target.windowSessionID == source.windowSessionID)
        #expect(store.snapshot.windows?[source.windowSessionID]?.currentWorkspace == created.id)
        target.toggleFullscreen(mode: mode)
        try await Task.sleep(for: .seconds(2))
    }

    @Test(arguments: [FullscreenMode.native, .nonNative])
    func restoredWorkspaceSwitchesUsingKeyboardInFullscreen(mode: FullscreenMode) async throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        let store = TerminalWorkspaceStore(fileURL: nil)
        let sessions = TerminalWorkspaceSessionStore(url: url, testing: true, workspaces: store)
        let coordinator = TerminalWorkspaceCoordinator(store: store, sessions: sessions)
        coordinator.finishRestoring()
        let other = try #require(store.create(name: "Restored destination", symbol: "house", color: "blue"))
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let first = TerminalController(app, withBaseConfig: config, workspaceCoordinator: coordinator)
        first.window?.makeKeyAndOrderFront(nil)
        sessions.start(app)
        let second = try #require(coordinator.switchWorkspace(to: other, from: first))
        _ = try #require(TerminalController.newTab(app, from: second.window!, withBaseConfig: config))
        try await Task.sleep(for: .milliseconds(100))
        second.window?.makeKeyAndOrderFront(nil)
        coordinator.didActivate(second)
        try #require(coordinator.switchWorkspace(to: store.defaultID, from: second) === first)
        store.transaction { state in
            state.windows?[first.windowSessionID]?.fullscreen = mode != .native
            state.windows?[first.windowSessionID]?.fullscreenMode = mode == .native ? nil : mode
        }
        sessions.capture()
        sessions.flush()
        coordinator.prepareToQuit()
        for controller in coordinator.liveControllers { controller.window?.close() }
        let restoredStore = TerminalWorkspaceStore(fileURL: nil)
        let restoredSessions = TerminalWorkspaceSessionStore(url: url, testing: true, workspaces: restoredStore)
        let restored = TerminalWorkspaceCoordinator(store: restoredStore, sessions: restoredSessions)
        restoredSessions.prepare()
        restoredSessions.start(app)
        restored.finishRestoring()
        defer { for controller in restored.liveControllers { controller.window?.close() } }
        let source = try #require(restored.controllers(in: restoredStore.defaultID).first)
        let target = try #require(restored.controllers(in: other).first)
        let window = try #require(source.window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<100 {
            if NSApp.isActive && window.isKeyWindow { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(NSApp.isActive && window.isKeyWindow)
        var entered = false
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification,
            object: window, queue: .main) { _ in MainActor.assumeIsolated { entered = true } }
        defer { NotificationCenter.default.removeObserver(observer) }
        if mode == .native {
            let fullscreenKey = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .command],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
            NSApp.sendEvent(fullscreenKey)
        } else if source.fullscreenStyle?.isFullscreen != true { source.toggleFullscreen(mode: mode) }
        for _ in 0..<200 {
            if mode == .native ? (entered || (source.fullscreenStyle?.isFullscreen == true && restored.native.transitioningWindows.isEmpty)) : source.fullscreenStyle?.isFullscreen == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(source.fullscreenStyle?.isFullscreen == true && restored.native.transitioningWindows.isEmpty,
            "The fullscreen shortcut must complete before workspace switching is exercised")
        try await Task.sleep(for: .milliseconds(100))
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .command],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "2", charactersIgnoringModifiers: "2", isARepeat: false, keyCode: 19))
        NSApp.sendEvent(key)
        try await Task.sleep(for: .milliseconds(300))
        #expect(restoredStore.snapshot.windows?[source.windowSessionID]?.currentWorkspace == other)
        #expect(target.window?.isKeyWindow == true)
        #expect(target.fullscreenStyle?.isFullscreen == true)
        #expect(source.window?.isVisible == false)
        #expect(target.window?.tabGroup?.selectedWindow === target.window || mode != .native)
        #expect(target.tabLayoutState.sidebarHost.liveView?.window === target.window)
        for index in 0..<8 {
            let current = index.isMultiple(of: 2) ? target : source
            let digit = index.isMultiple(of: 2) ? "1" : "2"
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .command],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: current.window!.windowNumber, context: nil,
                characters: digit, charactersIgnoringModifiers: digit, isARepeat: false, keyCode: digit == "1" ? 18 : 19))
            NSApp.sendEvent(event)
            try await Task.sleep(for: .milliseconds(150))
            let expected = index.isMultiple(of: 2) ? source : target
            #expect(expected.window?.isKeyWindow == true)
            #expect(expected.fullscreenStyle?.isFullscreen == true)
        }
        target.toggleFullscreen(mode: mode)
        try await Task.sleep(for: .seconds(2))
    }

    @Test func nativeFullscreenWorkspaceRoundTripsRecordAppKitSettling() async throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let store = TerminalWorkspaceStore(fileURL: nil)
        let native = TerminalWorkspaceNativeAdapter()
        let coordinator = TerminalWorkspaceCoordinator(store: store, native: native)
        coordinator.finishRestoring()
        let workspaceB = try #require(store.create(name: "Fullscreen B", symbol: "house", color: "blue"))
        let workspaceC = try #require(store.create(name: "Fullscreen C", symbol: "briefcase", color: "mint"))
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let first = TerminalController(app, withBaseConfig: config, tabLayout: .vertical, workspaceCoordinator: coordinator)
        var controllers = [first]
        defer {
            for controller in controllers { controller.window?.delegate = nil; controller.window?.close() }
        }
        first.titleOverride = "A-1"
        first.showWindow(nil)
        for index in 2...3 {
            let parent = try #require(controllers.last?.window)
            let next = try #require(TerminalController.newTab(app, from: parent, withBaseConfig: config))
            next.titleOverride = "A-\(index)"
            controllers.append(next)
        }
        try await Task.sleep(for: .milliseconds(150))
        let aWindows = try controllers.map { try #require($0.window) }
        let selectedA = try #require(first.window?.tabGroup?.selectedWindow?.windowController as? TerminalController)
        coordinator.didActivate(selectedA)

        let start = ProcessInfo.processInfo.systemUptime
        func trace(_ tag: String, _ details: String = "") {
            print(String(format: "WORKSPACE_FULLSCREEN_TRACE t=%.6f tag=%@ transitionCount=%d %@",
                         ProcessInfo.processInfo.systemUptime - start, tag,
                         native.transitioningWindows.count, details))
        }
        func windowState(_ window: NSWindow?) -> String {
            guard let window else { return "window=nil" }
            return "window=\(window.windowNumber) visible=\(window.isVisible) " +
                "activeSpace=\(window.isOnActiveSpace) key=\(window.isKeyWindow) " +
                "styleFull=\(window.styleMask.contains(.fullScreen))"
        }
        func poll(_ interval: Duration, until condition: () -> Bool) async -> Bool {
            for _ in 0..<200 {
                if condition() { return true }
                try? await Task.sleep(for: interval)
            }
            return condition()
        }

        var didEnterCount = 0
        var didExitCount = 0
        let names: [(Notification.Name, String)] = [
            (NSWindow.willEnterFullScreenNotification, "willEnter"),
            (NSWindow.didEnterFullScreenNotification, "didEnter"),
            (NSWindow.willExitFullScreenNotification, "willExit"),
            (NSWindow.didExitFullScreenNotification, "didExit"),
        ]
        let observers = names.map { item -> NSObjectProtocol in
            let (name, tag) = item
            return NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated {
                    guard let window = note.object as? NSWindow,
                          let controller = window.windowController as? TerminalController,
                          controller.workspaceCoordinator === coordinator else { return }
                    if tag == "didEnter" { didEnterCount += 1 }
                    if tag == "didExit" { didExitCount += 1 }
                    trace("notification.\(tag)", windowState(window))
                }
            }
        }
        defer { observers.forEach(NotificationCenter.default.removeObserver) }

        var attachCalls = 0
        var showCalls = 0
        let originalAttach = native.attach
        native.attach = { anchor, member, ordering in
            attachCalls += 1
            trace("native.attach.enter", "call=\(attachCalls) order=\(ordering) anchor={\(windowState(anchor))} member={\(windowState(member))}")
            let succeeded = originalAttach(anchor, member, ordering)
            trace("native.attach.return", "call=\(attachCalls) result=\(succeeded) anchor={\(windowState(anchor))} member={\(windowState(member))}")
            return succeeded
        }
        let originalShow = native.show
        native.show = { controller in
            showCalls += 1
            trace("native.show.enter", "call=\(showCalls) \(windowState(controller.window))")
            let succeeded = originalShow(controller)
            trace("native.show.return", "call=\(showCalls) result=\(succeeded) \(windowState(controller.window))")
            return succeeded
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        selectedA.window?.makeKeyAndOrderFront(nil)
        selectedA.window?.orderFrontRegardless()
        let foregroundReady = await poll(.milliseconds(50)) { NSApp.isActive && selectedA.window?.isKeyWindow == true }
        try #require(foregroundReady, "Requires an unlocked foreground desktop and the selected A tab as key window")

        var contents: [UUID: NSView] = [:]
        var surfaces: [UUID: NSView] = [:]
        func remember(_ controller: TerminalController) throws {
            let id = controller.tabSessionID
            if contents[id] == nil {
                contents[id] = try #require(controller.window?.contentView)
                surfaces[id] = controller.focusedSurface ?? controller.surfaceTree.first
            }
        }
        for controller in controllers { try remember(controller) }

        let enterCountBefore = didEnterCount
        trace("fullscreen.enter.request", windowState(selectedA.window))
        selectedA.toggleFullscreen(mode: .native)
        let entered = await poll(.milliseconds(50)) {
            didEnterCount > enterCountBefore && selectedA.window?.styleMask.contains(.fullScreen) == true &&
                native.transitioningWindows.isEmpty
        }
        try #require(entered, "Requires a completed real native fullscreen Space transition")
        try #require(NSApp.isActive && selectedA.window?.isKeyWindow == true)
        #expect(selectedA.window?.isOnActiveSpace == true)
        trace("fullscreen.enter.settled", windowState(selectedA.window))

        func waitForStableFullscreen(_ controller: TerminalController, _ label: String) async throws {
            let settled = await poll(.milliseconds(25)) {
                let window = controller.window
                let surface = controller.focusedSurface ?? controller.surfaceTree.first
                return NSApp.isActive && window?.isVisible == true && window?.isOnActiveSpace == true &&
                    window?.isKeyWindow == true && window?.styleMask.contains(.fullScreen) == true &&
                    controller.fullscreenStyle?.isFullscreen == true &&
                    window?.tabGroup?.selectedWindow === window &&
                    native.transitioningWindows.isEmpty && surface?.window === window &&
                    window?.firstResponder === surface
            }
            #expect(settled, "\(label) must settle into the active native fullscreen Space")
            let window = try #require(controller.window)
            let surface = try #require(controller.focusedSurface ?? controller.surfaceTree.first)
            trace("switch.\(label).settled", windowState(window))
            #expect(NSApp.isActive && window.isVisible && window.isOnActiveSpace && window.isKeyWindow,
                    "\(label) must be visible, active in its Space, and key")
            #expect(window.styleMask.contains(.fullScreen) && controller.fullscreenStyle?.isFullscreen == true,
                    "\(label) must remain in native fullscreen")
            #expect(window.tabGroup?.selectedWindow === window, "\(label) must be the selected native tab")
            #expect(native.transitioningWindows.isEmpty, "\(label) must settle after fullscreen transitions")
            #expect(surface.window === window && window.firstResponder === surface,
                    "\(label) must retain its terminal content and responder")
        }

        func switchAndWait(_ label: String, _ workspace: UUID,
                           _ source: TerminalController) async throws -> TerminalController {
            let attachBefore = attachCalls
            let showBefore = showCalls
            trace("switch.\(label).begin", "from={\(windowState(source.window))}")
            let target = try #require(coordinator.switchWorkspace(to: workspace, from: source),
                "\(label) failed: \(coordinator.operationError ?? "no operation error")")
            if !controllers.contains(where: { $0 === target }) { controllers.append(target) }
            trace("switch.\(label).return",
                  "attachDelta=\(attachCalls - attachBefore) showDelta=\(showCalls - showBefore) " +
                    "target={\(windowState(target.window))}")
            try await waitForStableFullscreen(target, label)
            try remember(target)
            return target
        }

        let targetB = try await switchAndWait("A-to-B", workspaceB, selectedA)
        let targetC = try await switchAndWait("B-to-C", workspaceC, targetB)
        let returnedA = try await switchAndWait("C-to-A", store.defaultID, targetC)
        #expect(returnedA === selectedA)

        // Query native group membership only for behavioral assertions; diagnostic
        // event logging intentionally never touches NSWindow.tabGroup.
        let returnedAWindow = try #require(returnedA.window)
        let returnedAGroup = try #require(returnedAWindow.tabGroup)
        #expect(Set(returnedAGroup.windows.map { ObjectIdentifier($0) }) ==
                Set(aWindows.map { ObjectIdentifier($0) }))
        #expect(returnedAGroup.selectedWindow === returnedAWindow && returnedAWindow.isVisible)
        #expect(!returnedAGroup.windows.contains(where: { $0 === targetB.window || $0 === targetC.window }))
        #expect(targetB.window?.isVisible == false && targetC.window?.isVisible == false)
        for controller in controllers {
            let id = controller.tabSessionID
            #expect(controller.window?.contentView === contents[id])
            #expect((controller.focusedSurface ?? controller.surfaceTree.first) === surfaces[id])
        }
        trace("switch.sequence.counts", "attachCalls=\(attachCalls) showCalls=\(showCalls)")

        let exitCountBefore = didExitCount
        trace("fullscreen.exit.request", windowState(returnedA.window))
        returnedA.toggleFullscreen(mode: .native)
        let exited = await poll(.milliseconds(50)) {
            didExitCount > exitCountBefore &&
                returnedA.window?.styleMask.contains(.fullScreen) == false &&
                native.transitioningWindows.isEmpty
        }
        try #require(exited, "The diagnostic must finish by completing the native fullscreen exit")
        trace("fullscreen.exit.settled", windowState(returnedA.window))
    }

    @Test func closePersonalWindowThenSwitchAndEnterFullscreen() async throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        let store = TerminalWorkspaceStore(fileURL: nil)
        let sessions = TerminalWorkspaceSessionStore(url: url, testing: true, workspaces: store)
        let runtime = TerminalWorkspaceCoordinator(store: store, sessions: sessions)
        runtime.finishRestoring()
        let other = try #require(store.create(name: "Independent", symbol: "house", color: "blue"))
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let personal = TerminalController(app, withBaseConfig: config, workspaceCoordinator: runtime)
        let work = TerminalController(app, withBaseConfig: config, workspaceID: other, workspaceCoordinator: runtime)
        personal.window?.makeKeyAndOrderFront(nil)
        work.window?.makeKeyAndOrderFront(nil)
        sessions.start(app)
        sessions.prepareToQuit()
        personal.window?.close(); work.window?.close()
        let restoredStore = TerminalWorkspaceStore(fileURL: nil)
        let restoredSessions = TerminalWorkspaceSessionStore(url: url, testing: true, workspaces: restoredStore)
        let restored = TerminalWorkspaceCoordinator(store: restoredStore, sessions: restoredSessions)
        restoredSessions.prepare(); restoredSessions.start(app); restored.finishRestoring()
        defer { for controller in restored.liveControllers { controller.window?.close() } }
        let closed = try #require(restored.controllers(in: restoredStore.defaultID).first)
        let source = try #require(restored.controllers(in: other).first)
        closed.closeWindowImmediately()
        let target = try #require(restored.switchWorkspace(to: restoredStore.defaultID, from: source))
        #expect(target !== closed)
        let window = try #require(target.window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<100 {
            if NSApp.isActive && window.isKeyWindow { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(NSApp.isActive && window.isKeyWindow)
        var entered = false
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification,
            object: window, queue: .main) { _ in MainActor.assumeIsolated { entered = true } }
        defer { NotificationCenter.default.removeObserver(observer) }
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .command],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        NSApp.sendEvent(key)
        for _ in 0..<200 {
            if entered { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(entered)
        #expect(window.isKeyWindow)
        #expect(restoredStore.snapshot.validationErrors.isEmpty)
        window.toggleFullScreen(nil)
        try await Task.sleep(for: .seconds(2))
    }

    private func click(_ view: NSView, at point: NSPoint) throws {
        let window = try #require(view.window)
        let location = view.convert(point, to: nil)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime + 0.01, windowNumber: window.windowNumber, context: nil,
            eventNumber: 2, clickCount: 1, pressure: 0))
        NSApp.postEvent(up, atStart: true)
        NSApp.sendEvent(down)
        if let event = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
    }
}
