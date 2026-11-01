import AppKit
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct TerminalWorkspaceRefactorTests {
    @MainActor final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = TerminalWorkspaceStore(fileURL: nil)
        let sessions: TerminalWorkspaceSessionStore
        let coordinator: TerminalWorkspaceCoordinator
        let app: Ghostty.App
        var controllers: [TerminalController] = []

        init() throws {
            app = try #require(NSApp.delegate as? AppDelegate).ghostty
            sessions = TerminalWorkspaceSessionStore(url: directory.appendingPathComponent("state.json"), testing: true, workspaces: store)
            coordinator = TerminalWorkspaceCoordinator(store: store, sessions: sessions)
            coordinator.finishRestoring()
        }

        func tab(workspace: UUID? = nil, parent: TerminalController? = nil) throws -> TerminalController {
            var config = Ghostty.SurfaceConfiguration()
            config.command = "/bin/sleep 60"
            let controller = TerminalController(app, withBaseConfig: config, parent: parent?.window,
                tabLayout: .vertical, workspaceID: workspace, workspaceCoordinator: coordinator)
            controllers.append(controller)
            let window = try #require(controller.window)
            if let parentWindow = parent?.window {
                try #require(parentWindow.addTabbedWindowSafely(window, ordered: .above))
                controller.finishWorkspaceTabAttachment()
                parent?.refreshWorkspaceTabs()
            }
            return controller
        }

        func close() {
            coordinator.prepareToQuit()
            let all = controllers + coordinator.liveControllers
            for controller in all { controller.cancelWorkspacePendingPresentation(); controller.window?.close() }
            sessions.flush()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test func stateCommandsPreserveOwnershipAndSelectionAcrossLongSequences() throws {
        var state = TerminalWorkspaceState()
        let other = UUID(), host = UUID(), secondHost = UUID()
        state.workspaces.append(.init(id: other, name: "Work", symbol: "house", color: "blue"))
        let tabs = (0..<20).map { _ in UUID() }
        let firstGroup = UUID(), secondGroup = UUID()
        for (index, tab) in tabs.enumerated() {
            state.register(tab, owner: .init(window: index < 10 ? host : secondHost,
                workspace: state.defaultID, group: index < 10 ? firstGroup : secondGroup))
        }
        for index in 0..<200 {
            let tab = tabs[index % tabs.count]
            let target = state.owner(of: tab)?.workspace == other ? state.defaultID : other
            let moved = state.move(tab, to: target)
            #expect(moved)
            state.select(target, in: try #require(state.owner(of: tab)).window)
            #expect(state.validationErrors.isEmpty)
        }
        let deleted = state.deleteWorkspace(other)
        #expect(deleted)
        #expect(state.validationErrors.isEmpty)
        #expect(Set(state.windows?[host]?.groups[state.defaultID]?.tabs ?? []) == Set(tabs.prefix(10)))
        #expect(Set(state.windows?[secondHost]?.groups[state.defaultID]?.tabs ?? []) == Set(tabs.suffix(10)))
    }

    @Test func undoMakesClosedIdentityCheckpointableAgain() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let original = try fixture.tab()
        let undo = try #require(original.undoState)
        fixture.sessions.start(fixture.app)
        original.closeTabImmediately(registerRedo: false)
        let restored = TerminalController(fixture.app, with: undo)
        fixture.controllers.append(restored)
        try #require(restored.isAvailableForWorkspace)
        fixture.sessions.capture()
        fixture.sessions.flush()
        let saved = try JSONDecoder().decode(TerminalWorkspaceSessionStore.Snapshot.self,
            from: Data(contentsOf: fixture.directory.appendingPathComponent("state.json")))
        #expect(saved.tabs.contains { $0.id == restored.tabSessionID })
        #expect(saved.catalog?.owner(of: restored.tabSessionID) != nil)
        #expect(saved.catalog?.validationErrors.isEmpty == true)
    }

    @Test func deletingWorkspaceKeepsOtherHostsVisibleAndPreservesAllPanes() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let work = try #require(fixture.store.create(name: "Work", symbol: "house", color: "blue"))
        let first = try fixture.tab(workspace: work)
        let second = try fixture.tab(workspace: work)
        let secondTab = try fixture.tab(workspace: work, parent: second)
        first.window?.makeKeyAndOrderFront(nil)
        second.window?.makeKeyAndOrderFront(nil)
        let fallback = try #require(fixture.coordinator.switchWorkspace(to: fixture.store.defaultID, from: second))
        let surfaces = [first, second, secondTab, fallback].flatMap { Array($0.surfaceTree) }
        try #require(fallback.window?.isVisible == true)
        first.window?.makeKeyAndOrderFront(nil)
        try #require(fixture.coordinator.deleteWorkspace(work))
        #expect(first.window?.isVisible == true)
        #expect(fallback.window?.isVisible == true)
        #expect(!fallback.workspacePresentationIsParked)
        #expect(Set(fallback.tabControllers.map(\.tabSessionID)) == Set([fallback, second, secondTab].map(\.tabSessionID)))
        #expect(zip(surfaces, [first, second, secondTab, fallback].flatMap { Array($0.surfaceTree) }).allSatisfy { $0 === $1 })
        #expect(fixture.store.snapshot.validationErrors.isEmpty)
    }

    @Test func failedDeletePreflightDoesNotMoveAnyTab() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let work = try #require(fixture.store.create(name: "Work", symbol: "house", color: "blue"))
        let first = try fixture.tab(workspace: work)
        let second = try fixture.tab(workspace: work)
        first.window?.makeKeyAndOrderFront(nil)
        second.window?.makeKeyAndOrderFront(nil)
        let before = fixture.store.snapshot
        second.window?.tabbingMode = .disallowed
        defer { second.window?.tabbingMode = .preferred }
        #expect(!fixture.coordinator.deleteWorkspace(work))
        #expect(fixture.store.snapshot == before)
        #expect(first.workspaceID == work && second.workspaceID == work)
        #expect(first.window?.isVisible == true && second.window?.isVisible == true)
    }

    @Test func failedSwitchRollsBackNativeOrderAndDurableGraph() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let work = try #require(fixture.store.create(name: "Work", symbol: "house", color: "blue"))
        let first = try fixture.tab()
        let second = try fixture.tab(parent: first)
        first.window?.makeKeyAndOrderFront(nil)
        fixture.coordinator.didActivate(first)
        let before = fixture.store.snapshot
        let windows = try [first, second].map { try #require($0.window) }
        fixture.coordinator.native.show = { _ in false }
        #expect(fixture.coordinator.switchWorkspace(to: work, from: first) == nil)
        #expect(fixture.store.snapshot == before)
        #expect(first.window?.tabGroup?.windows == windows)
        #expect(first.window?.tabGroup?.selectedWindow === first.window)
        #expect(first.window?.isVisible == true)
        #expect(fixture.coordinator.controllers(in: work).isEmpty)
        #expect(fixture.coordinator.operationError != nil)
    }

    @Test func sharedPreferencesDoNotOverwriteUnrelatedFields() throws {
        let store = TerminalWorkspaceStore(fileURL: nil)
        let first = VerticalTabWindowLayoutState(isSidebarVisible: true)
        let second = VerticalTabWindowLayoutState(isSidebarVisible: true)
        first.bindWorkspace(store.defaultID, store: store)
        second.bindWorkspace(store.defaultID, store: store)
        first.setSidebarVisible(false)
        #expect(!second.isSidebarVisible)
        second.setInspectorVisible(true)
        #expect(first.isInspectorVisible)
        #expect(!store.presentation(for: store.defaultID).sidebarVisible)
        first.updateSidebarWidth(300, availableWidth: 1000, persist: true)
        #expect(second.sidebarWidth == 300)
    }

    @Test func unchangedCheckpointDoesNotWriteAndIncludesCatalog() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        _ = try fixture.tab()
        fixture.sessions.start(fixture.app)
        fixture.sessions.capture()
        let writes = fixture.sessions.writeCount
        for _ in 0..<10 { fixture.sessions.capture() }
        #expect(fixture.sessions.writeCount == writes)
        let url = fixture.directory.appendingPathComponent("state.json")
        let saved = try JSONDecoder().decode(TerminalWorkspaceSessionStore.Snapshot.self, from: Data(contentsOf: url))
        #expect(saved.version == 2)
        #expect(saved.catalog?.validationErrors.isEmpty == true)
        #expect(saved.tabs.count == 1)
        #expect(saved.generation != nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func legacyUnknownWorkspaceMigratesBeforeCreatingSurfaces() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let original = try fixture.tab()
        let state = try JSONEncoder().encode(TerminalWorkspaceSessionState(original))
        let tabID = UUID(), hostID = UUID()
        let snapshot = TerminalWorkspaceSessionStore.Snapshot(tabs: [
            .init(id: tabID, workspace: UUID(), state: state, group: UUID(), window: hostID)
        ])
        let url = fixture.directory.appendingPathComponent("legacy.json")
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url)
        let store = TerminalWorkspaceStore(fileURL: nil)
        let sessions = TerminalWorkspaceSessionStore(url: url, testing: true, workspaces: store)
        let count = TerminalController.all.count
        sessions.prepare()
        #expect(sessions.ownsRestoration)
        #expect(store.snapshot.owner(of: tabID)?.workspace == store.defaultID)
        #expect(store.snapshot.validationErrors.isEmpty)
        #expect(TerminalController.all.count == count)
    }

    @Test func emptyLegacyCheckpointDoesNotClaimRestoration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("state.json")
        try JSONEncoder().encode(TerminalWorkspaceSessionStore.Snapshot()).write(to: url)
        let sessions = TerminalWorkspaceSessionStore(url: url, testing: true, workspaces: TerminalWorkspaceStore(fileURL: nil))
        sessions.prepare()
        #expect(!sessions.ownsRestoration)
    }

    @Test func explicitEmptyGenerationPreservesItsWindowAndWorkspacePreferences() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let work = try #require(fixture.store.create(name: "Empty work", symbol: "briefcase", color: "blue"))
        let controller = try fixture.tab(workspace: work)
        fixture.sessions.start(fixture.app)
        controller.closeTabImmediately(registerRedo: false)
        fixture.sessions.capture()
        fixture.sessions.flush()
        let url = fixture.directory.appendingPathComponent("state.json")
        let expected = try JSONDecoder().decode(TerminalWorkspaceSessionStore.Snapshot.self, from: Data(contentsOf: url))
        try #require(expected.isComplete)
        #expect(expected.tabs.isEmpty)
        let store = TerminalWorkspaceStore(fileURL: nil)
        let sessions = TerminalWorkspaceSessionStore(url: url, testing: true, workspaces: store)
        sessions.prepare()
        #expect(sessions.ownsRestoration)
        #expect(store.snapshot == expected.catalog)
        #expect(store.snapshot.windows?[controller.windowSessionID]?.currentWorkspace == work)
    }

    @Test func malformedPayloadCannotReplaceThePreviousValidGeneration() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let controller = try fixture.tab()
        fixture.sessions.start(fixture.app)
        controller.titleOverride = "Valid backup"
        fixture.sessions.capture()
        let url = fixture.directory.appendingPathComponent("state.json")
        let backup = url.appendingPathExtension("previous")
        let previous = try Data(contentsOf: backup)
        var broken = try JSONDecoder().decode(TerminalWorkspaceSessionStore.Snapshot.self, from: Data(contentsOf: url))
        broken.tabs[0].state = Data("invalid terminal".utf8)
        #expect(!broken.isComplete)
        try JSONEncoder().encode(broken).write(to: url)
        controller.titleOverride = "Valid latest"
        fixture.sessions.capture()
        #expect(try Data(contentsOf: backup) == previous)
        let saved = try JSONDecoder().decode(TerminalWorkspaceSessionStore.Snapshot.self, from: Data(contentsOf: url))
        #expect(saved.isComplete)
    }

    @Test func damagedLatestCheckpointFallsBackToPreviousGeneration() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let controller = try fixture.tab()
        fixture.sessions.start(fixture.app)
        controller.titleOverride = "First generation"
        fixture.sessions.capture()
        controller.titleOverride = "Second generation"
        fixture.sessions.capture()
        let url = fixture.directory.appendingPathComponent("state.json")
        try Data("broken".utf8).write(to: url)
        let store = TerminalWorkspaceStore(fileURL: nil)
        let sessions = TerminalWorkspaceSessionStore(url: url, testing: true, workspaces: store)
        sessions.prepare()
        #expect(sessions.ownsRestoration)
        #expect(store.snapshot.owner(of: controller.tabSessionID) != nil)
    }
}
