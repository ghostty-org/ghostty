import AppKit
import Combine
import SwiftUI
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct TerminalWorkspacePresentationTests {
    @Test func hostedWorkspaceButtonPresentsAfterStateChange() async throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let coordinator = TerminalWorkspaceCoordinator(store: TerminalWorkspaceStore(fileURL: nil))
        coordinator.finishRestoring()
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let controller = TerminalController(app, withBaseConfig: config, workspaceCoordinator: coordinator)
        let window = try #require(controller.window)
        let host = NSHostingView(rootView: TerminalWorkspaceButton(controller: controller).frame(width: 240, height: 40))
        window.contentView = host
        window.setContentSize(.init(width: 240, height: 100))
        window.makeKeyAndOrderFront(nil)
        defer { controller.workspacePopover.close(); window.delegate = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        controller.workspaceSwitcherIsPresented = true
        try await Task.sleep(for: .milliseconds(150))
        #expect(controller.workspacePopover.isShown)
        #expect(controller.workspacePopover.contentView?.accessibilityIdentifier() == "workspace.picker")
        #expect(controller.workspacePopover.contentController is TerminalWorkspacePickerController)
        let creations = controller.workspacePopover.contentCreationCount
        coordinator.store.update(id: coordinator.store.defaultID, name: "Renamed", symbol: "house", color: "blue")
        host.layoutSubtreeIfNeeded()
        #expect(controller.workspacePopover.isShown)
        #expect(controller.workspacePopover.contentCreationCount == creations)
    }

    @Test(.tags(.interactiveDesktop))
    func clickingWorkspaceButtonOpensItsNativePopover() async throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let coordinator = TerminalWorkspaceCoordinator(store: TerminalWorkspaceStore(fileURL: nil))
        coordinator.finishRestoring()
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let controller = TerminalController(app, withBaseConfig: config, workspaceCoordinator: coordinator)
        let window = try #require(controller.window)
        let host = NSHostingView(rootView: TerminalWorkspaceButton(controller: controller).fixedSize())
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { controller.workspacePopover.close(); window.delegate = nil; window.close() }
        for _ in 0..<50 {
            if NSApp.isActive && window.isKeyWindow { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(NSApp.isActive && window.isKeyWindow, "Requires an unlocked foreground test window")
        host.layoutSubtreeIfNeeded()
        let point = host.convert(NSPoint(x: host.bounds.midX, y: host.bounds.midY), to: nil)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.01, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        NSApp.postEvent(up, atStart: true)
        NSApp.sendEvent(down)
        if let queued = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
            NSApp.sendEvent(queued)
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.workspaceSwitcherIsPresented)
        #expect(controller.workspacePopover.isShown)
        #expect(controller.workspacePopover.contentCreationCount == 1)
    }

    @Test func keyboardCanPresentWithoutAWorkspaceButtonAnchor() async throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let coordinator = TerminalWorkspaceCoordinator(store: TerminalWorkspaceStore(fileURL: nil))
        coordinator.finishRestoring()
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let controller = TerminalController(app, withBaseConfig: config, workspaceCoordinator: coordinator)
        let window = try #require(controller.window)
        window.contentView = NSView(frame: .init(x: 0, y: 0, width: 500, height: 300))
        window.makeKeyAndOrderFront(nil)
        defer { controller.workspacePopover.close(); window.delegate = nil; window.close() }
        controller.workspaceSwitcherIsPresented = true
        #expect(controller.workspacePopover.isShown)
        controller.workspaceSwitcherIsPresented = false
        try await Task.sleep(for: .milliseconds(50))
        #expect(!controller.workspacePopover.isShown)
    }

    @Test func quickInputChangesDoNotPublishSidebarOrInspectorGeometry() throws {
        let store = TerminalWorkspaceStore(fileURL: nil)
        let layout = VerticalTabWindowLayoutState(isSidebarVisible: true)
        layout.bindWorkspace(store.defaultID, store: store)
        var geometryChanges = 0
        let observation = layout.objectWillChange.sink { geometryChanges += 1 }
        defer { observation.cancel() }
        let composer = store.quickInputPresentation(for: store.defaultID)
        composer.setPresented(true)
        composer.togglePinned()
        composer.setHeight(300)
        #expect(geometryChanges == 0)
        #expect(layout.isSidebarVisible)
    }

    @Test func collapsedVerticalSidebarDoesNotCreateAReplacementWorkspaceHeader() async throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let coordinator = TerminalWorkspaceCoordinator(store: TerminalWorkspaceStore(fileURL: nil))
        coordinator.finishRestoring()
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let controller = TerminalController(app, withBaseConfig: config, tabLayout: .vertical, workspaceCoordinator: coordinator)
        let window = try #require(controller.window)
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        controller.setSidebarVisible(false)
        try await Task.sleep(for: .milliseconds(100))
        window.contentView?.layoutSubtreeIfNeeded()
        let content = try #require(window.contentView)
        func workspaceLabels(_ view: NSView) -> [String] {
            let label = view.accessibilityLabel().map { [$0] } ?? []
            return label.filter { $0.hasPrefix("Workspace:") || $0.hasPrefix("工作区：") } + view.subviews.flatMap(workspaceLabels)
        }
        #expect(workspaceLabels(content).isEmpty)
        #expect(controller.tabLayoutState.sidebarHost.liveView == nil)
    }

    @Test func ordinaryQuickInputDoesNotCoverPaneWithAnOldFrame() async throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let store = TerminalWorkspaceStore(fileURL: nil)
        let coordinator = TerminalWorkspaceCoordinator(store: store)
        coordinator.finishRestoring()
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let controller = TerminalController(app, withBaseConfig: config, workspaceCoordinator: coordinator)
        let window = try #require(controller.window)
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        let surface = try #require(controller.focusedSurface)
        let parent = try #require(surface.superview)
        let overlays = parent.subviews.filter { $0 is NSImageView }.count
        window.makeFirstResponder(surface)
        let focused = surface.focused
        controller.toggleQuickInput()
        #expect(controller.quickInputModel.isPresented)
        #expect(parent.subviews.filter { $0 is NSImageView }.count == overlays)
        // The terminal must not be resigned before the composer can take over.
        #expect(surface.focused == focused)
    }

    @Test func rebindingSameWorkspaceDoesNotRepublishComposerState() {
        let store = TerminalWorkspaceStore(fileURL: nil)
        let presentation = store.quickInputPresentation(for: store.defaultID)
        let model = AgentQuickInputModel(globalPresentation: presentation)
        model.bindGlobalTarget { UUID() }
        var changes = 0
        let observer = model.objectWillChange.sink { changes += 1 }
        defer { observer.cancel() }
        model.bindPresentation(presentation)
        #expect(changes == 0)
    }

    @Test func firstWorkspaceShellHasKnownDirectoryBeforeItsFirstTitleEvent() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let store = TerminalWorkspaceStore(fileURL: nil)
        let coordinator = TerminalWorkspaceCoordinator(store: store)
        coordinator.finishRestoring()
        let workspace = try #require(store.create(name: "New", symbol: "house", color: "blue"))
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let source = TerminalController(app, withBaseConfig: config, workspaceCoordinator: coordinator)
        source.window?.makeKeyAndOrderFront(nil)
        defer { for controller in coordinator.liveControllers { controller.window?.close() } }
        let target = try #require(coordinator.switchWorkspace(to: workspace, from: source))
        let pane = try #require(target.surfaceTree.first)
        let context = try #require(target.paneSessionContext(for: pane))
        #expect(context.workingDirectory != nil)
        #expect(context.presentationTitle != "Terminal")
    }

    @Test func switchingExistingWorkspacesDoesNotPublishFallbackTitle() async throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let store = TerminalWorkspaceStore(fileURL: nil)
        let coordinator = TerminalWorkspaceCoordinator(store: store)
        coordinator.finishRestoring()
        let otherID = try #require(store.create(name: "Other", symbol: "house", color: "blue"))
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        config.workingDirectory = "/tmp"
        let source = TerminalController(app, withBaseConfig: config, workspaceCoordinator: coordinator)
        let target = TerminalController(app, withBaseConfig: config, workspaceID: otherID,
            windowSessionID: source.windowSessionID, workspaceCoordinator: coordinator)
        _ = source.window
        _ = target.window
        defer { for controller in [source, target] { controller.window?.close() } }
        let surface = try #require(target.surfaceTree.first)
        surface.setTitle("stable workspace title")
        try await Task.sleep(for: .milliseconds(100))
        var titles: [String] = []
        let observation = target.tabLayoutState.tabPresentation.$tabSnapshot.sink { snapshot in
            titles += snapshot.controllers.compactMap { tab in
                tab.paneSessionContext(for: tab.focusedSurface ?? tab.surfaceTree.first)?.presentationTitle
            }
        }
        defer { observation.cancel() }
        source.window?.makeKeyAndOrderFront(nil)
        try #require(coordinator.switchWorkspace(to: otherID, from: source) === target)
        try #require(coordinator.switchWorkspace(to: store.defaultID, from: target) === source)
        try #require(coordinator.switchWorkspace(to: otherID, from: source) === target)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!titles.contains("Terminal"))
        #expect(surface.title == "stable workspace title")
    }
}
