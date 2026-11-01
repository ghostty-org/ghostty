import AppKit
import IOSurface
import Testing
@testable import Ghostty

/// Requires a real fullscreen Space and the test application in the foreground.
@Suite(.tags(.interactiveDesktop))
@MainActor
struct VerticalTabFullscreenTests {
    @Test(arguments: [Ghostty.Config.MacOSTabLayout.vertical, .horizontal])
    func newTabsInNativeFullscreen(layout: Ghostty.Config.MacOSTabLayout) async throws {
        let app = try #require(NSApp.delegate as? AppDelegate)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let first = TerminalController(app.ghostty, withBaseConfig: config, tabLayout: layout)
        var controllers = [first]
        defer {
            for controller in controllers {
                controller.window?.delegate = nil
                controller.window?.close()
            }
        }
        let window = try #require(first.window)
        first.showWindow(nil)
        first.setSidebarVisible(true)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        try String(ProcessInfo.processInfo.processIdentifier).write(
            toFile: "/tmp/omg-fullscreen-test.pid", atomically: true, encoding: .utf8
        )
        for _ in 0..<200 {
            if NSApp.isActive && window.isKeyWindow { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(NSApp.isActive && window.isKeyWindow, "Requires foreground test app")
        window.toggleFullScreen(nil)
        try await Task.sleep(for: .seconds(2))
        try #require(window.styleMask.contains(.fullScreen))
        let fullscreenFrame = window.frame
        let contentSize = try #require(window.contentView?.bounds.size)

        for _ in 0..<3 {
            let parent = try #require(controllers.last?.window)
            let next = try #require(TerminalController.newTab(app.ghostty, from: parent, withBaseConfig: config))
            controllers.append(next)
            let incoming = try #require(next.window)
            let animation = incoming.animationBehavior
            // Exercise the presentation boundary synchronously: inspecting only
            // a later run-loop turn would miss a default-color/undersized frame.
            let shown = next.withNewTabPresentation(from: parent) {
                #expect(incoming.backgroundColor == parent.backgroundColor)
                #expect(incoming.animationBehavior == .none)
                #expect(CATransaction.disableActions())
                return next.showWindowSafely(nil)
            }
            #expect(shown)
            #expect(incoming.animationBehavior == animation)
            #expect(incoming.styleMask.contains(.fullScreen))
            // Horizontal tabs reserve the native tab strip on the first
            // insertion. Both members must agree on the resulting frame.
            #expect(incoming.frame == parent.frame)
            if layout == .vertical {
                #expect(incoming.frame == fullscreenFrame)
                #expect(incoming.contentView?.bounds.size == contentSize)
            }
            try expectPreparedFrame(next)
            if layout == .vertical {
                #expect(next.tabLayoutState.sidebarHost.liveView?.window === incoming)
                #expect((incoming as? VerticalTabsTerminalWindow)?.nativeTabBarIsSuppressed == true)
            }
            // Let the normal deferred newTab presentation run as well.
            try await Task.sleep(for: .milliseconds(100))
            #expect(incoming.tabGroup?.selectedWindow === incoming)
            #expect(incoming.frame == parent.frame)
        }

        let last = try #require(controllers.last)
        last.closeTabImmediately(registerRedo: false)
        try await Task.sleep(for: .milliseconds(100))
        let selected = try #require(window.tabGroup?.selectedWindow)
        #expect(selected.styleMask.contains(.fullScreen))
        if layout == .vertical { #expect(selected.frame == fullscreenFrame) }
        selected.toggleFullScreen(nil)
        try await Task.sleep(for: .seconds(2))
        #expect(!selected.styleMask.contains(.fullScreen))
        #expect(selected.contentLayoutRect.height < selected.frame.height)
    }

    @Test(arguments: [Ghostty.Config.MacOSTabLayout.vertical, .horizontal])
    func workspaceSwitchKeepsNativeFullscreenSpace(layout: Ghostty.Config.MacOSTabLayout) async throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let store = TerminalWorkspaceStore(fileURL: nil)
        let coordinator = TerminalWorkspaceCoordinator(store: store)
        coordinator.finishRestoring()
        let workspace = try #require(store.create(name: "Fullscreen test", symbol: "house", color: "blue"))
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let source = TerminalController(app, withBaseConfig: config, tabLayout: layout, workspaceCoordinator: coordinator)
        var controllers = [source]
        defer {
            for controller in controllers {
                controller.window?.delegate = nil
                controller.window?.close()
            }
        }
        let window = try #require(source.window)
        source.showWindow(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        try String(ProcessInfo.processInfo.processIdentifier).write(
            toFile: "/tmp/omg-fullscreen-test.pid", atomically: true, encoding: .utf8
        )
        for _ in 0..<100 {
            if NSApp.isActive && window.isKeyWindow { break }
            if NSApp.isActive { window.makeKeyAndOrderFront(nil) }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(NSApp.isActive && window.isKeyWindow,
                     "Requires foreground test app: active=\(NSApp.isActive), key=\(window.isKeyWindow), visible=\(window.isVisible)")
        var enteredFullscreen = false
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main
        ) { _ in MainActor.assumeIsolated { enteredFullscreen = true } }
        defer { NotificationCenter.default.removeObserver(observer) }
        source.toggleFullscreen(mode: .native)
        for _ in 0..<200 {
            if enteredFullscreen { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(enteredFullscreen && window.styleMask.contains(.fullScreen),
                     "Requires a desktop capable of completing the native fullscreen transition")
        let original = try #require(source.surfaceTree.first)
        let target = try #require(coordinator.switchWorkspace(to: workspace, from: source))
        controllers.append(target)
        try await Task.sleep(for: .milliseconds(250))
        let targetWindow = try #require(target.window)
        #expect(target.workspaceID == workspace)
        #expect(target.surfaceTree.first !== original)
        #expect(targetWindow.styleMask.contains(.fullScreen))
        #expect(targetWindow.isKeyWindow)
        #expect(target.workspaceTabWindows == [targetWindow])
        #expect(Set(targetWindow.tabGroup?.windows ?? []) ==
                Set(layout == .vertical ? [window, targetWindow] : [targetWindow]))
        #expect(targetWindow.tabGroup?.selectedWindow === targetWindow)
        #expect(source.workspacePresentationIsParked)
        if layout == .vertical { #expect(target.tabLayoutState.sidebarHost.liveView?.window === targetWindow) }
        #expect(target.tabControllers.map(\.tabSessionID) == [target.tabSessionID])
        let targetSurface = try #require(target.focusedSurface ?? target.surfaceTree.first)
        #expect(targetSurface.window === targetWindow)
        #expect(targetWindow.firstResponder === targetSurface)
        target.workspaceSwitcherIsPresented = true
        #expect(target.workspacePopover.isShown)
        target.workspaceSwitcherIsPresented = false
        try await Task.sleep(for: .milliseconds(50))
        #expect(!target.workspacePopover.isShown)
        #expect(coordinator.switchWorkspace(to: source.workspaceID, from: target) === source)
        try await Task.sleep(for: .milliseconds(250))
        #expect(window.styleMask.contains(.fullScreen))
        #expect(window.isKeyWindow)
        #expect(source.surfaceTree.first === original)
        if layout == .vertical { #expect(source.tabLayoutState.sidebarHost.liveView?.window === window) }
        #expect(window.firstResponder === original)

        // Multiple tabs and splits exercise the final native geometry, not just
        // one empty destination window. Each workspace keeps its own sidebar.
        try #require(coordinator.switchWorkspace(to: workspace, from: source) === target)
        let sibling = try #require(TerminalController.newTab(app, from: targetWindow, withBaseConfig: config))
        controllers.append(sibling)
        try await Task.sleep(for: .milliseconds(150))
        targetWindow.makeKeyAndOrderFront(nil)
        let extraPane = try #require(target.newSplit(at: targetSurface, direction: .right, baseConfig: config))
        target.tabLayoutState.setSidebarVisible(false)
        try await Task.sleep(for: .milliseconds(150))
        try #require(targetWindow.firstResponder === extraPane,
                     "The new pane must own actual keyboard focus before workspace switching")
        coordinator.didActivate(target)
        try #require(coordinator.switchWorkspace(to: source.workspaceID, from: target) === source)
        let sourceLayout = source.tabLayoutState
        for _ in 0..<6 {
            try #require(coordinator.switchWorkspace(to: workspace, from: source) === target)
            try #require(coordinator.switchWorkspace(to: source.workspaceID, from: target) === source)
        }
        try await Task.sleep(for: .milliseconds(250))
        #expect(source.tabLayoutState === sourceLayout)
        #expect(window.isKeyWindow && window.styleMask.contains(.fullScreen))
        #expect(window.firstResponder === original)
        #expect(target.surfaceTree.contains { $0 === extraPane })
        try expectPreparedFrame(source)
        try #require(coordinator.switchWorkspace(to: workspace, from: source) === target)
        try await Task.sleep(for: .milliseconds(250))
        #expect(target.workspaceTabWindows == [targetWindow, sibling.window!])
        #expect(Set(targetWindow.tabGroup?.windows ?? []) == Set(
            layout == .vertical ? [window, targetWindow, sibling.window!] : [targetWindow, sibling.window!]
        ))
        #expect(targetWindow.tabGroup?.selectedWindow === targetWindow)
        #expect(!target.sidebarIsShowing)
        #expect(targetWindow.firstResponder === extraPane)
        try expectPreparedFrame(target)
        // A collapsed sidebar has no replacement header. The keyboard command
        // still opens against the owning fullscreen content view.
        target.workspaceSwitcherIsPresented = true
        #expect(target.workspacePopover.isShown)
        target.workspaceSwitcherIsPresented = false
        try await Task.sleep(for: .milliseconds(50))
        targetWindow.makeFirstResponder(extraPane)
        let parent = try #require(extraPane.superview)
        let overlayCount = parent.subviews.filter { $0 is NSImageView }.count
        target.toggleQuickInput()
        #expect(parent.subviews.filter { $0 is NSImageView }.count == overlayCount)
        try await Task.sleep(for: .milliseconds(200))
        #expect(targetWindow.firstResponder is ComposerTextView)
        #expect(target.focusedSurface === extraPane)
        target.dismissQuickInput()
        try await Task.sleep(for: .milliseconds(200))
        #expect(targetWindow.firstResponder === extraPane)
        #expect(targetWindow.styleMask.contains(.fullScreen))

        // Moving the last source tab must create its replacement inside the
        // existing fullscreen stack before parking the moved tab.
        try #require(coordinator.switchWorkspace(to: source.workspaceID, from: target) === source)
        try #require(coordinator.move(source, to: workspace))
        let replacement = try #require(coordinator.controllers(in: store.defaultID).first)
        controllers.append(replacement)
        try await Task.sleep(for: .milliseconds(200))
        #expect(replacement.window?.styleMask.contains(.fullScreen) == true)
        #expect(replacement.window?.isKeyWindow == true)
        try #require(coordinator.deleteWorkspace(workspace))
        try await Task.sleep(for: .milliseconds(250))
        let selected = try #require(replacement.window?.tabGroup?.selectedWindow ?? replacement.window)
        #expect(selected.styleMask.contains(.fullScreen))
        #expect(selected.isKeyWindow)
        #expect(coordinator.store.snapshot.validationErrors.isEmpty)
        #expect(source.surfaceTree.first === original)
        selected.toggleFullScreen(nil)
        try await Task.sleep(for: .seconds(2))
    }

    private func expectPreparedFrame(_ controller: TerminalController) throws {
        let view = try #require(controller.surfaceTree.first)
        let layer = try #require(view.layer)
        let image = try #require(layer.contents as? IOSurface)
        #expect(image.width == Int((layer.bounds.width * layer.contentsScale).rounded(.down)))
        #expect(image.height == Int((layer.bounds.height * layer.contentsScale).rounded(.down)))
    }
}
