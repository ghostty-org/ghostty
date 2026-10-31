import AppKit
import Combine
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct TerminalWorkspaceIntegrationTests {
    @Test func workspacePopoverSurvivesAnchorUpdatesAndExecutesActionOnceAfterClosing() async throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let controller = TerminalController(app, withBaseConfig: config)
        let window = try #require(controller.window)
        defer { controller.workspacePopover.close(); window.delegate = nil; window.close() }
        let anchor = NSView(frame: .init(x: 20, y: 20, width: 180, height: 30))
        window.contentView?.addSubview(anchor)
        window.makeKeyAndOrderFront(nil)
        controller.workspaceSwitcherIsPresented = true
        let presentation = controller.workspacePopover
        presentation.update(anchor: anchor)
        try #require(presentation.isShown)
        let count = presentation.contentCreationCount
        for _ in 0..<20 { presentation.update(anchor: anchor) }
        #expect(presentation.isShown)
        #expect(presentation.contentCreationCount == count)
        var calls = 0
        presentation.close {
            #expect(!presentation.isShown)
            calls += 1
        }
        #expect(calls == 0)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!controller.workspaceSwitcherIsPresented)
        #expect(calls == 1)
        presentation.close()
        #expect(calls == 1)
    }

    @Test func sidebarRegisteredDuringWorkspaceHandoffMountsOnLaterLayout() throws {
        let delegate = try #require(NSApp.delegate as? AppDelegate)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let controller = TerminalController(delegate.ghostty, withBaseConfig: config, tabLayout: .vertical)
        let window = try #require(controller.window)
        defer { window.delegate = nil; window.close() }
        controller.tabLayoutState = VerticalTabWindowLayoutState(isSidebarVisible: true)
        let host = controller.tabLayoutState.sidebarHost
        let container = VerticalTabSidebarContainer(frame: .init(x: 0, y: 0, width: 240, height: 400))
        window.contentView = container
        controller.tabLayoutState.updateTabs([controller], selectedID: ObjectIdentifier(controller))
        TerminalWorkspacePresentation.begin()
        container.configure(controller: controller, owner: host,
            content: NativeTabSidebarConfiguration(controller: controller, layoutState: controller.tabLayoutState,
                statusStore: delegate.tabActivities, backgroundColor: .black))
        #expect(host.liveView == nil)
        TerminalWorkspacePresentation.end()
        container.layout()
        #expect(host.liveView?.superview === container)
        #expect(host.liveView?.window === window)
    }

    @Test func deletingInactiveLiveWorkspacePreservesItsSurface() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let store = TerminalWorkspaceStore(fileURL: nil)
        let id = try #require(store.create(name: "Delete live", symbol: "house", color: "blue"))
        let coordinator = TerminalWorkspaceCoordinator(store: store)
        coordinator.finishRestoring()
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let controller = TerminalController(app, withBaseConfig: config, workspaceID: id, workspaceCoordinator: coordinator)
        controller.window?.makeKeyAndOrderFront(nil)
        let active = TerminalController(app, withBaseConfig: config, workspaceID: store.defaultID, workspaceCoordinator: coordinator)
        active.window?.makeKeyAndOrderFront(nil)
        let surface = try #require(controller.surfaceTree.first)
        defer {
            for tab in [controller, active] { tab.window?.delegate = nil; tab.window?.close() }
        }
        #expect(coordinator.deleteWorkspace(id, from: active))
        #expect(controller.workspaceID == store.defaultID)
        #expect(controller.surfaceTree.first === surface)
        #expect(controller.window?.contentView != nil)
        #expect(controller.window?.isVisible == true)
        #expect(!controller.workspacePresentationIsParked)
    }

    @Test func sessionSnapshotSurvivesStoreRecreationAndExplicitTabDeletion() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("sessions.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let controller = TerminalController(app, withBaseConfig: config)
        _ = controller.window
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let store = TerminalWorkspaceSessionStore(url: url, testing: true)
        store.start(app)
        store.capture()
        let snapshot = try JSONDecoder().decode(TerminalWorkspaceSessionStore.Snapshot.self, from: Data(contentsOf: url))
        #expect(snapshot.tabs.contains { $0.id == controller.tabSessionID })
        let recreated = TerminalWorkspaceSessionStore(url: url, testing: true)
        recreated.prepare()
        #expect(recreated.ownsRestoration)
        store.forget(controller)
        store.capture()
        let deleted = try JSONDecoder().decode(TerminalWorkspaceSessionStore.Snapshot.self, from: Data(contentsOf: url))
        #expect(!deleted.tabs.contains { $0.id == controller.tabSessionID })
    }

    @Test func switchingToAClosedWorkspaceNeverReusesItsEmptyWindow() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let store = TerminalWorkspaceStore(fileURL: nil)
        let sourceID = try #require(store.create(name: "Open", symbol: "house", color: "blue"))
        let closedID = try #require(store.create(name: "Closed", symbol: "house", color: "blue"))
        let coordinator = TerminalWorkspaceCoordinator(store: store)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let source = TerminalController(app, withBaseConfig: config, tabLayout: .vertical,
            workspaceID: sourceID, workspaceCoordinator: coordinator)
        let closed = TerminalController(app, withBaseConfig: config, tabLayout: .vertical,
            workspaceID: closedID, workspaceCoordinator: coordinator)
        let sourceWindow = try #require(source.window)
        let closedWindow = try #require(closed.window)
        var reopened: TerminalController?
        defer {
            for controller in [source, closed] + [reopened].compactMap({ $0 }) {
                controller.window?.delegate = nil
                controller.window?.close()
            }
        }
        sourceWindow.makeKeyAndOrderFront(nil)
        closed.closeWindowImmediately()
        // Undo and AppKit can retain this controller after its content view is
        // cleared. A still-live surface tree is not proof of a usable window.
        #expect(!closed.surfaceTree.isEmpty)
        #expect(closedWindow.contentView == nil)
        #expect(!coordinator.controllers(in: closedID).contains { $0 === closed })
        reopened = try #require(coordinator.switchWorkspace(to: closedID, from: source))
        #expect(reopened !== closed)
        #expect(reopened?.workspaceID == closedID)
        #expect(reopened?.window?.contentView != nil)
        #expect(reopened?.window?.isVisible == true)
        #expect(sourceWindow.isVisible == false)
    }

    @Test(arguments: [1, 3])
    func closedWorkspaceRestoresSavedTabsIntoCurrentWindow(tabCount: Int) async throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let native = try #require(app.app)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TerminalWorkspaceStore(fileURL: nil)
        let sessions = TerminalWorkspaceSessionStore(url: directory.appendingPathComponent("sessions.json"), testing: true, workspaces: store)
        let sourceID = try #require(store.create(name: "Open", symbol: "house", color: "blue"))
        let closedID = try #require(store.create(name: "Closed", symbol: "house", color: "blue"))
        let coordinator = TerminalWorkspaceCoordinator(store: store, sessions: sessions)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let source = TerminalController(app, withBaseConfig: config, tabLayout: .vertical,
            workspaceID: sourceID, workspaceCoordinator: coordinator)
        let original = (0..<tabCount).map { _ in TerminalController(app, withBaseConfig: config, tabLayout: .vertical,
            workspaceID: closedID, windowSessionID: source.windowSessionID, workspaceCoordinator: coordinator) }
        let extraPane = Ghostty.SurfaceView(native, baseConfig: config)
        let firstPane = try #require(original[0].surfaceTree.first)
        original[0].surfaceTree = .init(root: .split(.init(direction: .horizontal, ratio: 0.4,
            left: .leaf(view: firstPane), right: .leaf(view: extraPane))), zoomed: nil)
        original[0].focusedSurface = extraPane
        let ids = original.map(\.tabSessionID)
        let paneIDs = original.flatMap { $0.surfaceTree.map(\.id) }
        var restored: [TerminalController] = []
        defer {
            for controller in [source] + original + restored {
                controller.window?.delegate = nil
                controller.window?.close()
            }
        }
        for (index, controller) in original.enumerated() {
            controller.titleOverride = "Saved \(index)"
            _ = controller.window
        }
        let firstWindow = try #require(original[0].window)
        let sourceWindow = try #require(source.window)
        for index in 1..<tabCount {
            #expect(original[index - 1].window!.addTabbedWindowSafely(original[index].window!, ordered: .above))
        }
        let selected = try #require(original.last)
        firstWindow.tabGroup?.selectedWindow = selected.window
        original[0].refreshWorkspaceTabs()
        store.selectWorkspace(closedID, in: source.windowSessionID, frame: nil, fullscreen: false)
        coordinator.finishRestoring()
        selected.window?.makeKeyAndOrderFront(nil)
        coordinator.didActivate(selected)
        // Capture the intended group before the real close path clears its views.
        sessions.start(app)
        selected.closeWindowImmediately()
        // Delayed lifecycle callbacks and periodic captures must not replace the
        // saved group with the retained, already torn-down single-tab windows.
        for controller in original { controller.titleOverride = "Closed controller" }
        sessions.capture()
        sourceWindow.makeKeyAndOrderFront(nil)
        let target = try #require(coordinator.switchWorkspace(to: closedID, from: source))
        restored = coordinator.controllers(in: closedID)
        #expect(restored.count == tabCount)
        #expect(original.allSatisfy { old in restored.allSatisfy { $0 !== old } })
        #expect(target.tabSessionID == selected.tabSessionID)
        #expect(target.tabControllers.map(\.tabSessionID) == ids)
        #expect(Set(restored.flatMap { $0.surfaceTree.map(\.id) }) == Set(paneIDs))
        #expect(restored.first(where: { $0.tabSessionID == ids[0] })?.surfaceTree.isSplit == true)
        #expect(restored.allSatisfy { $0.window?.contentView != nil && $0.titleOverride?.hasPrefix("Saved ") == true })
        #expect(target.window?.tabGroup?.selectedWindow === target.window)
        #expect(target.window?.isVisible == true)
        #expect(!sourceWindow.isVisible)
        try await Task.sleep(for: .milliseconds(150))
        #expect(coordinator.switchWorkspace(to: sourceID, from: target) === source)
        #expect(coordinator.switchWorkspace(to: closedID, from: source) === target)
        #expect(target.tabControllers.map(\.tabSessionID) == ids)
    }

    @Test func explicitTabRemovalIsNotRestoredWhenReopeningWorkspace() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TerminalWorkspaceStore(fileURL: nil)
        let sessions = TerminalWorkspaceSessionStore(url: directory.appendingPathComponent("sessions.json"), testing: true, workspaces: store)
        let sourceID = try #require(store.create(name: "Open", symbol: "house", color: "blue"))
        let closedID = try #require(store.create(name: "Deleted", symbol: "house", color: "blue"))
        let coordinator = TerminalWorkspaceCoordinator(store: store, sessions: sessions)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let source = TerminalController(app, withBaseConfig: config, workspaceID: sourceID, workspaceCoordinator: coordinator)
        let deleted = TerminalController(app, withBaseConfig: config, workspaceID: closedID, workspaceCoordinator: coordinator)
        _ = source.window
        _ = deleted.window
        var fresh: TerminalController?
        defer {
            for controller in [source, deleted] + [fresh].compactMap({ $0 }) {
                controller.window?.delegate = nil
                controller.window?.close()
            }
        }
        sessions.start(app)
        sessions.forget(deleted)
        deleted.closeTabImmediately(registerRedo: false)
        sessions.capture()
        fresh = try #require(coordinator.switchWorkspace(to: closedID, from: source))
        #expect(fresh?.tabSessionID != deleted.tabSessionID)
        #expect(fresh?.workspaceID == closedID)
        #expect(fresh?.window?.contentView != nil)
    }

    @Test func sessionSnapshotPreservesEveryTabAndSplitIdentity() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let nativeApp = try #require(app.app)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("sessions.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let views = (0..<4).map { _ in Ghostty.SurfaceView(nativeApp, baseConfig: config) }
        let split = SplitTree<Ghostty.SurfaceView>(root: .split(.init(
            direction: .horizontal, ratio: 0.4,
            left: .leaf(view: views[0]), right: .split(.init(
                direction: .vertical, ratio: 0.6,
                left: .leaf(view: views[1]), right: .leaf(view: views[2])
            ))
        )), zoomed: nil)
        let first = TerminalController(app, withSurfaceTree: split)
        let second = TerminalController(app, withSurfaceTree: .init(view: views[3]))
        let firstWindow = try #require(first.window)
        let secondWindow = try #require(second.window)
        defer {
            for controller in [first, second] {
                controller.window?.delegate = nil
                controller.window?.close()
            }
        }
        #expect(firstWindow.addTabbedWindowSafely(secondWindow, ordered: .above))
        first.focusedSurface = views[2]
        let store = TerminalWorkspaceSessionStore(url: url, testing: true)
        store.start(app)
        store.capture()
        let snapshot = try JSONDecoder().decode(TerminalWorkspaceSessionStore.Snapshot.self, from: Data(contentsOf: url))
        let expected = [first.tabSessionID, second.tabSessionID]
        let tabs = snapshot.tabs.filter { expected.contains($0.id) }
        #expect(tabs.count == 2)
        for tab in tabs {
            let restored = try JSONDecoder().decode(TerminalRestorableState.self, from: tab.state)
            let ids = restored.surfaceTree.map(\.id)
            if tab.id == first.tabSessionID {
                #expect(ids == Array(views.prefix(3)).map(\.id))
                #expect(restored.focusedSurface == views[2].id.uuidString)
                #expect(restored.surfaceTree.isSplit)
            } else {
                #expect(ids == [views[3].id])
            }
        }
    }

    @Test func startupRestoresAllTabsAndSplitsFromTheSessionCatalog() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let nativeApp = try #require(app.app)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("sessions.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let panes = (0..<3).map { _ in Ghostty.SurfaceView(nativeApp, baseConfig: config) }
        let firstID = UUID()
        let secondID = UUID()
        let tabIDs = Set([firstID, secondID])
        let workspace = TerminalWorkspace.defaultID
        let trees: [SplitTree<Ghostty.SurfaceView>] = [
            .init(root: .split(.init(direction: .vertical, ratio: 0.35,
                left: .leaf(view: panes[0]), right: .leaf(view: panes[1]))), zoomed: nil),
            .init(view: panes[2]),
        ]
        var encoded = TerminalWorkspaceSessionStore.Snapshot()
        for (id, tree) in zip([firstID, secondID], trees) {
            let state = TerminalRestorableState.InternalState(
                focusedSurface: tree.first?.id.uuidString, surfaceTree: tree,
                effectiveFullscreenMode: nil, tabColor: nil, titleOverride: nil,
                tabSessionID: id.uuidString, tabCreatedAt: Date()
            )
            encoded.tabs.append(.init(id: id, workspace: workspace,
                state: try JSONEncoder().encode(state)))
        }
        #expect(TerminalController.all.allSatisfy { !tabIDs.contains($0.tabSessionID) })
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(encoded).write(to: url)
        let store = TerminalWorkspaceSessionStore(url: url, testing: true)
        store.prepare()
        #expect(store.ownsRestoration)
        store.start(app)
        let restored = TerminalController.all.filter { tabIDs.contains($0.tabSessionID) }
        defer {
            for controller in restored {
                controller.window?.delegate = nil
                controller.window?.close()
            }
        }
        #expect(restored.count == 2)
        #expect(Set(restored.flatMap { $0.surfaceTree.map(\.id) }) == Set(panes.map(\.id)))
        let restoredSplit = try #require(restored.first { $0.tabSessionID == firstID })
        #expect(restoredSplit.surfaceTree.isSplit)
        #expect(restoredSplit.window?.tabGroup?.windows.count == 2)
        let savedAgain = try JSONDecoder().decode(TerminalWorkspaceSessionStore.Snapshot.self, from: Data(contentsOf: url))
        #expect(Set(savedAgain.tabs.map(\.id)).isSuperset(of: tabIDs))
    }

    @Test func startupPreservesSavedManualTabOrderAfterPresentation() async throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let nativeApp = try #require(app.app)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("sessions.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let ids = (0..<4).map { _ in UUID() }
        var snapshot = TerminalWorkspaceSessionStore.Snapshot()
        for (index, id) in ids.enumerated() {
            let view = Ghostty.SurfaceView(nativeApp, baseConfig: config)
            let state = TerminalRestorableState.InternalState(
                focusedSurface: view.id.uuidString, surfaceTree: SplitTree(view: view),
                effectiveFullscreenMode: nil, tabColor: nil, titleOverride: "Order \(index)",
                tabSessionID: id.uuidString, tabCreatedAt: Date(timeIntervalSince1970: Double(4 - index))
            )
            snapshot.tabs.append(.init(id: id, workspace: TerminalWorkspace.defaultID,
                state: try JSONEncoder().encode(state)))
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url)
        let store = TerminalWorkspaceSessionStore(url: url, testing: true)
        store.prepare()
        store.start(app)
        let restored = TerminalController.all.filter { ids.contains($0.tabSessionID) }
        defer {
            for controller in restored {
                controller.window?.delegate = nil
                controller.window?.close()
            }
        }
        let first = try #require(restored.first { $0.tabSessionID == ids[0] })
        let group = try #require(first.window?.tabGroup)
        func nativeOrder() -> [UUID] {
            group.windows.compactMap { ($0.windowController as? TerminalController)?.tabSessionID }
        }
        #expect(nativeOrder() == ids)
        try await Task.sleep(for: .milliseconds(250))
        #expect(nativeOrder() == ids)
        #expect(first.tabControllers.map(\.tabSessionID) == ids)
        store.capture()
        let captured = try JSONDecoder().decode(TerminalWorkspaceSessionStore.Snapshot.self, from: Data(contentsOf: url))
        #expect(captured.tabs.filter { ids.contains($0.id) }.map(\.id) == ids)
    }

    @Test func quitKeepsManualOrderAndCancelResumesLayoutChanges() throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.sessions.cancelQuit(); fixture.close() }
        let app = fixture.app
        let url = fixture.directory.appendingPathComponent("state.json")
        let controllers = try (0..<4).map { _ in try fixture.tab() }
        let windows = try controllers.map { try #require($0.window) }
        for index in 1..<windows.count {
            #expect(windows[index - 1].addTabbedWindowSafely(windows[index], ordered: .above))
        }
        let group = try #require(windows[0].tabGroup)
        // An explicit drag order must survive, independently of creation time.
        let manual = [windows[2], windows[0], windows[3], windows[1]]
        func reorder(_ order: [NSWindow]) {
            for (index, window) in order.enumerated() where group.windows[index] !== window {
                group.removeWindow(window)
                group.insertWindow(window, at: index)
            }
        }
        reorder(manual)
        controllers[0].refreshWorkspaceTabs()
        let ids = Set(controllers.map(\.tabSessionID))
        func savedOrder() throws -> [UUID] {
            let snapshot = try JSONDecoder().decode(TerminalWorkspaceSessionStore.Snapshot.self, from: Data(contentsOf: url))
            return snapshot.tabs.filter { ids.contains($0.id) }.map(\.id)
        }
        let expected = manual.compactMap { ($0.windowController as? TerminalController)?.tabSessionID }
        let store = fixture.sessions
        store.start(app)
        store.prepareToQuit()
        #expect(try savedOrder() == expected)
        let beforeTeardown = try Data(contentsOf: url)
        // AppKit changes the live group order as it closes tab windows. Timer,
        // window-close, explicit-close and termination callbacks must freeze it.
        reorder(Array(manual.reversed()))
        store.capture()
        store.forget(controllers[0])
        store.prepareToQuit()
        #expect(try Data(contentsOf: url) == beforeTeardown)
        #expect(try savedOrder() == expected)

        store.cancelQuit()
        controllers[0].refreshWorkspaceTabs()
        store.capture()
        #expect(try savedOrder() == Array(expected.reversed()))
        store.forget(controllers[0])
        #expect(try savedOrder() == Array(expected.reversed()).filter { $0 != controllers[0].tabSessionID })
        store.prepareToQuit()
        reorder(manual)
        store.capture()
        #expect(try savedOrder() == Array(expected.reversed()).filter { $0 != controllers[0].tabSessionID })
    }

    @Test func sessionCatalogPreservesSeparateWindowsInOneWorkspace() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sessions.json")
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let first = TerminalController(app, withBaseConfig: config)
        let second = TerminalController(app, withBaseConfig: config)
        let ids = Set([first.tabSessionID, second.tabSessionID])
        _ = first.window
        _ = second.window
        let store = TerminalWorkspaceSessionStore(url: url, testing: true)
        store.start(app)
        let saved = try JSONDecoder().decode(TerminalWorkspaceSessionStore.Snapshot.self, from: Data(contentsOf: url))
        let tabs = saved.tabs.filter { ids.contains($0.id) }
        #expect(tabs.count == 2)
        #expect(tabs[0].group != tabs[1].group)
        for controller in [first, second] {
            controller.window?.delegate = nil
            controller.window?.close()
        }
        let restoredStore = TerminalWorkspaceSessionStore(url: url, testing: true)
        restoredStore.prepare()
        restoredStore.start(app)
        let restored = TerminalController.all.filter { ids.contains($0.tabSessionID) }
        defer {
            for controller in restored {
                controller.window?.delegate = nil
                controller.window?.close()
            }
        }
        #expect(restored.count == 2)
        for controller in restored {
            #expect((controller.window?.tabGroup?.windows.count ?? 1) == 1)
        }
    }

    @Test func recoveryExposesAnExistingWindowWhenEveryWindowIsHidden() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let store = TerminalWorkspaceStore(fileURL: nil)
        let coordinator = TerminalWorkspaceCoordinator(store: store)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let controller = TerminalController(app, withBaseConfig: config, workspaceCoordinator: coordinator)
        let window = try #require(controller.window)
        let previouslyVisible = TerminalController.all.filter { $0 !== controller && $0.window?.isVisible == true }
        defer {
            controller.window?.delegate = nil
            controller.window?.close()
            for other in previouslyVisible { other.window?.orderFront(nil) }
        }
        for other in previouslyVisible { other.window?.orderOut(nil) }
        window.orderOut(nil)
        coordinator.ensureVisibleWorkspace()
        #expect(TerminalController.all.contains { $0.window?.isVisible == true })
    }

    @Test func quittingFreezesParkedWorkspacePresentation() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let store = TerminalWorkspaceStore(fileURL: nil)
        let coordinator = TerminalWorkspaceCoordinator(store: store)
        coordinator.finishRestoring()
        let targetID = try #require(store.create(name: "Other", symbol: "house", color: "blue"))
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let source = TerminalController(app, withBaseConfig: config, workspaceCoordinator: coordinator)
        let target = TerminalController(app, withBaseConfig: config, workspaceID: targetID,
            windowSessionID: source.windowSessionID, workspaceCoordinator: coordinator)
        defer {
            for controller in [source, target] {
                controller.window?.delegate = nil
                controller.window?.close()
            }
        }
        _ = source.window
        target.window?.orderOut(nil)
        #expect(coordinator.switchWorkspace(to: targetID, from: source) === target)
        #expect(store.snapshot.hiddenTabs.contains(source.tabSessionID))
        coordinator.prepareToQuit()
        let snapshot = store.snapshot
        coordinator.didClose(source)
        coordinator.didActivate(source)
        coordinator.savePresentation()
        #expect(store.snapshot == snapshot)
        coordinator.cancelQuit()
        coordinator.didClose(source)
        #expect(coordinator.parked[source.tabSessionID] == nil)
        // Closing a window retains its logical group for restoration.
        #expect(store.group(window: source.windowSessionID, workspace: source.workspaceID)?.tabs.contains(source.tabSessionID) == true)
    }

    @Test func restartPreservesEachWindowsCurrentWorkspaceAndParkedSelection() async throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalogURL = directory.appendingPathComponent("catalog.json")
        let sessionsURL = directory.appendingPathComponent("sessions.json")
        let store = TerminalWorkspaceStore(fileURL: catalogURL)
        let one = try #require(store.create(name: "One", symbol: "house", color: "blue"))
        let two = try #require(store.create(name: "Two", symbol: "house", color: "blue"))
        let sessions = TerminalWorkspaceSessionStore(url: sessionsURL, testing: true, workspaces: store)
        let coordinator = TerminalWorkspaceCoordinator(store: store, sessions: sessions)
        coordinator.finishRestoring()
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let a = TerminalController(app, withBaseConfig: config, workspaceID: one, workspaceCoordinator: coordinator)
        let b = TerminalController(app, withBaseConfig: config, workspaceID: one, workspaceCoordinator: coordinator)
        let aID = a.tabSessionID, bID = b.tabSessionID
        let aHost = a.windowSessionID, bHost = b.windowSessionID
        _ = a.window
        b.window?.makeKeyAndOrderFront(nil)
        coordinator.didActivate(b)
        a.window?.makeKeyAndOrderFront(nil)
        coordinator.didActivate(a)
        sessions.start(app)
        let bTwo = try #require(coordinator.switchWorkspace(to: two, from: b))
        let bTwoID = bTwo.tabSessionID
        sessions.prepareToQuit()
        store.flush()
        for controller in [a, b, bTwo] { controller.window?.close() }
        let restoredStore = TerminalWorkspaceStore(fileURL: catalogURL)
        let restoredSessions = TerminalWorkspaceSessionStore(url: sessionsURL, testing: true, workspaces: restoredStore)
        let restoredCoordinator = TerminalWorkspaceCoordinator(store: restoredStore, sessions: restoredSessions)
        restoredSessions.prepare()
        restoredSessions.start(app)
        restoredCoordinator.finishRestoring()
        let ids = Set([aID, bID, bTwoID])
        let restored = TerminalController.all.filter { ids.contains($0.tabSessionID) && $0.isAvailableForWorkspace }
        defer {
            for controller in restored { controller.window?.delegate = nil; controller.window?.close() }
        }
        #expect(restored.count == 3)
        let restoredA = try #require(restored.first { $0.tabSessionID == aID })
        let restoredB = try #require(restored.first { $0.tabSessionID == bID })
        let restoredBTwo = try #require(restored.first { $0.tabSessionID == bTwoID })
        #expect(restoredA.windowSessionID == aHost)
        #expect(restoredB.windowSessionID == bHost)
        #expect(restoredBTwo.windowSessionID == bHost)
        #expect(restoredA.window?.isVisible == true)
        #expect(restoredBTwo.window?.isVisible == true)
        #expect(restoredCoordinator.parked[bID] === restoredB)
        #expect(restoredStore.snapshot.windows?[aHost]?.currentWorkspace == one)
        #expect(restoredStore.snapshot.windows?[bHost]?.currentWorkspace == two)
        #expect(restoredCoordinator.switchWorkspace(to: one, from: restoredBTwo) === restoredB)
        #expect(restoredA.window?.isVisible == true)
        #expect(restoredB.window?.tabGroup !== restoredA.window?.tabGroup)
        try await Task.sleep(for: .milliseconds(100))
        #expect(restoredB.tabControllers.map(\.tabSessionID) == [bID])
    }

    @Test func newWindowInheritsWorkspaceButNotWindowOrGroupIdentity() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let store = TerminalWorkspaceStore.shared
        let workspace = try #require(store.create(name: "Window inheritance", symbol: "house", color: "blue"))
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let first = TerminalController(app, withBaseConfig: config, workspaceID: workspace)
        let second = TerminalController.newWindow(app, withBaseConfig: config, withParent: first.window)
        let native = try #require(app.app)
        let movedSurface = Ghostty.SurfaceView(native, baseConfig: config)
        let detached = TerminalController.newWindow(app, tree: .init(view: movedSurface), workspaceID: workspace)
        defer {
            for controller in [first, second, detached] { controller.cancelWorkspacePendingPresentation(); controller.window?.delegate = nil; controller.window?.close() }
        }
        #expect(detached.workspaceID == workspace)
        #expect(detached.windowSessionID != first.windowSessionID)
        #expect(detached.surfaceTree.first === movedSurface)
        #expect(second.workspaceID == workspace)
        #expect(second.windowSessionID != first.windowSessionID)
        #expect(second.workspaceGroupID != first.workspaceGroupID)
    }

    @Test func detachedNativeTabGetsItsOwnWindowIdentityAndUndoRestoresIt() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let coordinator = TerminalWorkspaceCoordinator(store: TerminalWorkspaceStore(fileURL: nil))
        coordinator.finishRestoring()
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let first = TerminalController(app, withBaseConfig: config, workspaceCoordinator: coordinator)
        let firstWindow = try #require(first.window)
        let second = TerminalController(app, withBaseConfig: config, parent: firstWindow)
        let secondWindow = try #require(second.window)
        defer {
            for controller in [first, second] { controller.window?.delegate = nil; controller.window?.close() }
        }
        #expect(firstWindow.addTabbedWindowSafely(secondWindow, ordered: .above))
        first.refreshWorkspaceTabs()
        let originalHost = first.windowSessionID
        let originalGroup = first.workspaceGroupID
        let snapshot = VerticalTabWindowGroupSnapshot(controller: second)
        // Production newTab clears its pending-parent marker after attachment.
        second.finishWorkspaceTabAttachment()
        firstWindow.tabGroup?.removeWindow(secondWindow)
        second.refreshWorkspaceTabs()
        #expect(second.windowSessionID != originalHost)
        #expect(second.workspaceGroupID != originalGroup)
        let restoration = try #require(snapshot.resolveRestoration(of: second, in: [first, second]))
        #expect(snapshot.restore(restoration))
        first.refreshWorkspaceTabs()
        #expect(second.windowSessionID == originalHost)
        #expect(second.workspaceGroupID == originalGroup)
        #expect(firstWindow.tabGroup?.windows == [firstWindow, secondWindow])
    }

    @Test func legacyWindowGroupsMigrateWithoutMerging() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TerminalWorkspaceStore(fileURL: nil)
        let url = directory.appendingPathComponent("sessions.json")
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let original = TerminalController(app, withBaseConfig: config)
        _ = original.window
        defer { original.window?.delegate = nil; original.window?.close() }
        let data = try JSONEncoder().encode(TerminalRestorableState(from: original))
        let other = TerminalController(app, withBaseConfig: config)
        _ = other.window
        defer { other.window?.delegate = nil; other.window?.close() }
        let otherData = try JSONEncoder().encode(TerminalRestorableState(from: other))
        let first = UUID(), second = UUID()
        let groupA = UUID(), groupB = UUID()
        var snapshot = TerminalWorkspaceSessionStore.Snapshot()
        snapshot.tabs = [.init(id: first, workspace: store.defaultID, state: data, group: groupA),
                         .init(id: second, workspace: store.defaultID, state: otherData, group: groupB)]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url)
        let sessions = TerminalWorkspaceSessionStore(url: url, testing: true, workspaces: store)
        sessions.prepare()
        #expect(store.group(window: groupA, workspace: store.defaultID)?.tabs == [first])
        #expect(store.group(window: groupB, workspace: store.defaultID)?.tabs == [second])
        #expect(store.snapshot.windows?.count == 2)
    }

    @Test func twoWindowsSwitchWorkspacesWithoutTakingEachOthersTabs() async throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let store = TerminalWorkspaceStore(fileURL: nil)
        let one = try #require(store.create(name: "One", symbol: "house", color: "blue"))
        let two = try #require(store.create(name: "Two", symbol: "house", color: "blue"))
        let coordinator = TerminalWorkspaceCoordinator(store: store)
        coordinator.finishRestoring()
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        var controllers: [TerminalController] = []
        func group(_ count: Int) throws -> [TerminalController] {
            let host = UUID(), group = UUID()
            let result = (0..<count).map { _ in TerminalController(app, withBaseConfig: config,
                tabLayout: .vertical, workspaceID: one, windowSessionID: host, workspaceGroupID: group,
                workspaceCoordinator: coordinator) }
            controllers += result
            for controller in result { _ = controller.window }
            for index in 1..<count { #expect(result[index - 1].window!.addTabbedWindowSafely(result[index].window!, ordered: .above)) }
            result[0].refreshWorkspaceTabs()
            result.last?.window?.makeKeyAndOrderFront(nil)
            return result
        }
        defer {
            for controller in controllers { controller.window?.delegate = nil; controller.window?.close() }
        }
        let a = try group(2), b = try group(3)
        let selectedA = a[1], selectedB = b[2]
        let aWindows = a.compactMap(\.window), bWindows = b.compactMap(\.window)
        let bHost = selectedB.windowSessionID
        let bGroup = selectedB.workspaceGroupID
        let originalSurfaces = b.flatMap { Array($0.surfaceTree) }
        coordinator.didActivate(selectedA)
        let bTwo = try #require(coordinator.switchWorkspace(to: two, from: selectedB))
        controllers.append(bTwo)
        #expect(bTwo.windowSessionID == bHost)
        #expect(selectedA.window?.isVisible == true)
        #expect(selectedA.window?.tabGroup?.windows == aWindows)
        #expect(coordinator.switchWorkspace(to: one, from: bTwo) === selectedB)
        #expect(selectedB.window?.tabGroup?.windows == bWindows)
        #expect(selectedB.workspaceGroupID == bGroup)
        #expect(zip(b.flatMap { Array($0.surfaceTree) }, originalSurfaces).allSatisfy { $0 === $1 })
        #expect(store.group(window: a[0].windowSessionID, workspace: one)?.selected == selectedA.tabSessionID)
        #expect(store.group(window: bHost, workspace: one)?.selected == selectedB.tabSessionID)

        let aTwo = try #require(coordinator.switchWorkspace(to: two, from: selectedA))
        controllers.append(aTwo)
        #expect(aTwo !== bTwo)
        #expect(aTwo.windowSessionID != bHost)
        #expect(coordinator.switchWorkspace(to: two, from: selectedB) === bTwo)
        #expect(aTwo.window?.isVisible == true)
        #expect(coordinator.switchWorkspace(to: one, from: aTwo) === selectedA)
        #expect(coordinator.switchWorkspace(to: one, from: bTwo) === selectedB)
        try await Task.sleep(for: .milliseconds(150))
        #expect(selectedA.window?.tabGroup?.windows == aWindows)
        #expect(selectedB.window?.tabGroup?.windows == bWindows)
        #expect(coordinator.previousWorkspaceID(in: selectedA) == two)
        #expect(coordinator.previousWorkspaceID(in: selectedB) == two)

        // Moving B's tab to workspace Two must not append it to A's Two group.
        #expect(coordinator.move(b[0], to: two))
        #expect(b[0].windowSessionID == bHost)
        #expect(b[0].workspaceGroupID == bTwo.workspaceGroupID)
        #expect(aTwo.surfaceTree.first != nil)
        #expect(aTwo.window?.tabGroup?.windows.contains(b[0].window!) != true)
        let nextB = try #require(b[1].window?.tabGroup?.selectedWindow?.windowController as? TerminalController)
        #expect(coordinator.switchWorkspace(to: two, from: nextB) === bTwo)
        #expect(bTwo.tabControllers.map(\.tabSessionID) == [bTwo.tabSessionID, b[0].tabSessionID])
    }

    @Test func switchingPublishesOnlyFinalMembershipAndSelection() async throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let store = TerminalWorkspaceStore(fileURL: nil)
        let destinationID = try #require(store.create(name: "Long", symbol: "house", color: "blue"))
        let sourceID = try #require(store.create(name: "Short", symbol: "house", color: "blue"))
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let restoredCoordinator = TerminalWorkspaceCoordinator(store: store)
        let source = TerminalController(app, withBaseConfig: config, tabLayout: .vertical,
            workspaceID: sourceID, workspaceCoordinator: restoredCoordinator)
        let targets = (0..<5).map { _ in TerminalController(app, withBaseConfig: config, tabLayout: .vertical,
            workspaceID: destinationID, windowSessionID: source.windowSessionID, workspaceCoordinator: restoredCoordinator) }
        let sourceWindow = try #require(source.window)
        let windows = try targets.map { controller -> NSWindow in
            return try #require(controller.window)
        }
        defer {
            for controller in [source] + targets {
                controller.window?.delegate = nil
                controller.window?.close()
            }
        }
        for index in 1..<windows.count { #expect(windows[index - 1].addTabbedWindowSafely(windows[index], ordered: .above)) }
        targets[0].refreshWorkspaceTabs()
        let destinationLayout = targets[0].tabLayoutState
        store.rememberGroup(window: source.windowSessionID, workspace: destinationID,
            group: .init(id: targets[0].workspaceGroupID, tabs: targets.map(\.tabSessionID), selected: targets[2].tabSessionID))
        store.selectWorkspace(sourceID, in: source.windowSessionID, frame: nil, fullscreen: nil)
        // Build the same parked catalog used by a restored long workspace.
        restoredCoordinator.finishRestoring()
        sourceWindow.makeKeyAndOrderFront(nil)
        var published: [([UUID], ObjectIdentifier?)] = []
        let observation = destinationLayout.tabPresentation.$tabSnapshot.dropFirst().sink { snapshot in
            published.append((snapshot.controllers.map(\.tabSessionID), snapshot.selectedID))
        }
        defer { observation.cancel() }
        let target = try #require(restoredCoordinator.switchWorkspace(to: destinationID, from: source))
        let expected = targets.map(\.tabSessionID)
        #expect(target === targets[2])
        #expect(target.tabControllers.map(\.tabSessionID) == expected)
        #expect(target.tabLayoutState === destinationLayout)
        #expect(source.tabLayoutState !== destinationLayout)
        try await Task.sleep(for: .milliseconds(150))
        #expect(published.allSatisfy { $0.0 == expected && $0.1 == ObjectIdentifier(target) })
        #expect(restoredCoordinator.switchWorkspace(to: source.workspaceID, from: target) === source)
        #expect(restoredCoordinator.switchWorkspace(to: destinationID, from: source) === target)
        #expect(target.tabLayoutState === destinationLayout)
        #expect(target.tabControllers.map(\.tabSessionID) == expected)
    }

    @Test func switchingRetainsSurfacesAndNativeTabMembership() async throws {
        let appDelegate = try #require(NSApp.delegate as? AppDelegate)
        let store = TerminalWorkspaceStore(fileURL: nil)
        let coordinator = TerminalWorkspaceCoordinator(store: store)
        let personal = try #require(store.create(name: "Test Personal", symbol: "house", color: "sage"))
        let work = try #require(store.create(name: "Work", symbol: "briefcase", color: "blue"))
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let first = TerminalController(appDelegate.ghostty, withBaseConfig: config, tabLayout: .vertical,
            workspaceID: personal, workspaceCoordinator: coordinator)
        let second = TerminalController(appDelegate.ghostty, withBaseConfig: config, tabLayout: .vertical,
            workspaceID: personal, workspaceCoordinator: coordinator)
        let target = TerminalController(appDelegate.ghostty, withBaseConfig: config, tabLayout: .vertical,
            workspaceID: work, windowSessionID: first.windowSessionID, workspaceCoordinator: coordinator)
        let firstWindow = try #require(first.window)
        let secondWindow = try #require(second.window)
        let targetWindow = try #require(target.window)
        defer {
            for controller in [first, second, target] {
                controller.window?.delegate = nil
                controller.window?.close()
            }
        }
        #expect(firstWindow.addTabbedWindowSafely(secondWindow, ordered: .above))
        first.refreshWorkspaceTabs()
        firstWindow.makeKeyAndOrderFront(nil)
        targetWindow.orderOut(nil)
        let firstSurface = try #require(first.surfaceTree.first)
        let secondSurface = try #require(second.surfaceTree.first)
        let targetSurface = try #require(target.surfaceTree.first)
        #expect(firstWindow.tabGroup?.windows.count == 2)
        try await Task.sleep(for: .milliseconds(100))

        #expect(coordinator.switchWorkspace(to: work, from: first) === target)
        #expect(coordinator.parked[first.tabSessionID] === first)
        #expect(coordinator.parked[second.tabSessionID] === second)
        #expect(first.surfaceTree.first === firstSurface)
        #expect(second.surfaceTree.first === secondSurface)
        #expect(target.surfaceTree.first === targetSurface)
        #expect(firstSurface.surface != nil)
        #expect(secondSurface.surface != nil)

        #expect(coordinator.switchWorkspace(to: personal, from: target) === first)
        #expect(firstWindow.tabGroup?.selectedWindow === firstWindow)
        #expect(firstWindow.tabGroup?.windows == [firstWindow, secondWindow])
        #expect(coordinator.parked[target.tabSessionID] === target)
        #expect(coordinator.parked[first.tabSessionID] == nil)
        #expect(first.surfaceTree.first === firstSurface)
        #expect(target.surfaceTree.first === targetSurface)

        // Moving a live tab into the parked target must keep both sessions,
        // leave the source's remaining tab selected, and restore target order.
        #expect(coordinator.move(second, to: work))
        #expect(second.workspaceID == work)
        #expect(second.surfaceTree.first === secondSurface)
        #expect(coordinator.switchWorkspace(to: work, from: first) === target)
        #expect(targetWindow.tabGroup?.windows == [targetWindow, secondWindow])
        #expect(first.surfaceTree.first === firstSurface)
        #expect(second.surfaceTree.first === secondSurface)
    }
}
