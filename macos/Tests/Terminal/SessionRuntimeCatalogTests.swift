import AppKit
import Foundation
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct SessionRuntimeCatalogTests {
    @MainActor
    @Test func corruptEndpointArchiveIsPreservedWhenRememberingAnEndpoint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("endpoints.json")
        let damaged = Data("{broken endpoint archive".utf8)
        try damaged.write(to: url)

        let catalog = SessionRuntimeCatalog(url: url)
        catalog.remember(try endpoint("saved-host"))

        #expect(catalog.endpoints.count == 1)
        #expect(catalog.persistenceError != nil)
        #expect(try Data(contentsOf: url) == damaged)
    }

    @MainActor
    @Test func testCatalogUsesOnlyItsInjectedMemoryScope() throws {
        let catalog = SessionRuntimeCatalog(url: nil)
        catalog.remember(try endpoint("memory-host"))

        #expect(catalog.endpoints.count == 1)
        #expect(catalog.endpoints.first?.descriptor.connection?.destination == "memory-host")
        #expect(catalog.persistenceError == nil)
    }

    @MainActor
    @Test func endpointArchivePreservesSSHRouteWithPrivatePermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("session-runtime/endpoints.json")
        let connection = try GitSSHConnection(
            destination: "route-host",
            options: ["-o", "ProxyCommand=ssh -W %h:%p jump-host", "-o", "ProxyJump=jump-host"],
            localWorkingDirectory: "/tmp"
        )
        var descriptor = SessionRuntimeDescriptor(
            connection: connection,
            revision: "catalog-test",
            policy: .init(),
            initialWorkingDirectory: "/tmp/launch-only"
        )
        let catalog = SessionRuntimeCatalog(url: url)
        catalog.remember(descriptor)
        descriptor.initialWorkingDirectory = nil

        let reopened = SessionRuntimeCatalog(url: url)
        let saved = try #require(reopened.endpoints.first)
        let directoryPermissions = try FileManager.default.attributesOfItem(
            atPath: url.deletingLastPathComponent().path
        )[.posixPermissions] as? NSNumber
        let filePermissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber

        #expect(saved.descriptor == descriptor)
        #expect(directoryPermissions?.intValue == 0o700)
        #expect(filePermissions?.intValue == 0o600)
    }

    @MainActor
    @Test func sessionLibraryStringsFollowTheConfiguredLanguage() throws {
        let english = SessionRuntimeLibraryStrings(language: .english)
        let chinese = SessionRuntimeLibraryStrings(language: .simplifiedChinese)
        let running = try session(id: UUID().uuidString, updatedAt: 2)
        let ended = try session(id: UUID().uuidString, updatedAt: 3, ended: "process_exited")

        #expect(english.windowTitle == "Session Library")
        #expect(english.openExisting == "Open Existing")
        #expect(running.statusLabel(using: english) == "Running")
        #expect(chinese.windowTitle == "会话库")
        #expect(chinese.openExisting == "打开现有会话")
        #expect(running.statusLabel(using: chinese) == "运行中")
        #expect(ended.statusLabel(using: chinese) == "已结束（进程已退出）")
    }

    @MainActor
    @Test func sessionProjectionRejectsListsAboveTheHostLimit() throws {
        let value: [String: Any] = [
            "id": UUID().uuidString,
            "generation": "0123456789abcdef0123456789abcdef",
            "created_at": 1,
            "updated_at": 1
        ]
        let data = try JSONSerialization.data(withJSONObject: Array(repeating: value, count: 2_049))

        #expect(throws: (any Error).self) {
            try SessionRuntimeCatalogSession.decodeList(data)
        }
    }

    @MainActor
    @Test func selectedEndpointOwnsResultsEvenWhenAnOlderQueryReturnsLate() async throws {
        let catalog = SessionRuntimeCatalog(url: nil)
        let first = try endpoint("first-host")
        let second = try endpoint("second-host")
        catalog.remember(first)
        catalog.remember(second)
        let firstID = first.identity
        let firstRecord = try session(id: UUID().uuidString, updatedAt: 1)
        let secondRecord = try session(id: UUID().uuidString, updatedAt: 2)
        let model = SessionRuntimeLibraryModel(
            catalog: catalog,
            closeQueue: SessionRuntimeCloseQueue(url: nil),
            loader: { descriptor in
                try? await Task.sleep(for: .milliseconds(descriptor.identity == firstID ? 80 : 10))
                return descriptor.identity == firstID ? [firstRecord] : [secondRecord]
            }
        )

        model.selectedEndpointID = first.identity
        model.selectedEndpointID = second.identity
        try await Task.sleep(for: .milliseconds(120))

        #expect(model.loadState == .loaded)
        #expect(model.sessions == [secondRecord])
    }

    @MainActor
    @Test func cancellingRefreshDoesNotPublishItsLateResult() async throws {
        let catalog = SessionRuntimeCatalog(url: nil)
        let descriptor = try endpoint("cancel-host")
        catalog.remember(descriptor)
        let record = try session(id: UUID().uuidString, updatedAt: 2)
        let model = SessionRuntimeLibraryModel(
            catalog: catalog,
            closeQueue: SessionRuntimeCloseQueue(url: nil),
            loader: { _ in
                try? await Task.sleep(for: .milliseconds(80))
                return [record]
            }
        )

        model.selectedEndpointID = descriptor.identity
        model.cancelRefresh()
        try await Task.sleep(for: .milliseconds(120))

        #expect(model.loadState == .idle)
        #expect(model.sessions.isEmpty)
    }

    @MainActor
    @Test func openingAnAlreadyVisibleUUIDFocusesItWithoutCreatingAnotherSurface() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let native = try #require(app.app)
        let paneID = UUID()
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let surface = Ghostty.SurfaceView(native, baseConfig: config, uuid: paneID)
        let controller = TerminalController(app, withSurfaceTree: .init(view: surface))
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let descriptor = try endpoint("already-open-host")
        let session = try session(id: paneID.uuidString, updatedAt: 2)

        let opened = try SessionRuntimeLibrary.openExisting(
            session,
            descriptor: descriptor,
            from: controller.window,
            controllers: [controller]
        )

        #expect(opened == nil)
        #expect(controller.surfaceTree.count == 1)
        #expect(controller.surfaceTree.first === surface)
        #expect(controller.focusedSurface === surface)
    }

    @MainActor
    @Test func openingAparkedUUIDSwitchesBackToItsWorkspace() async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let source = try fixture.tab()
        let workID = try #require(fixture.store.create(name: "Parked session", symbol: "briefcase", color: "blue"))
        let target = try #require(fixture.coordinator.switchWorkspace(to: workID, from: source))
        fixture.controllers.append(target)
        let surface = try #require(target.surfaceTree.first)
        let descriptor = try endpoint("parked-session-host")
        let session = try session(id: surface.id.uuidString, updatedAt: 2)
        _ = try #require(fixture.coordinator.switchWorkspace(to: source.workspaceID, from: target))
        #expect(target.workspacePresentationIsParked)

        let opened = try SessionRuntimeLibrary.openExisting(
            session,
            descriptor: descriptor,
            from: source.window,
            controllers: [source]
        )

        #expect(opened == nil)
        for _ in 0..<20 where target.workspacePresentationIsParked {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!target.workspacePresentationIsParked)
        #expect(target.window?.isVisible == true)
        #expect(target.focusedSurface === surface)
        #expect(target.surfaceTree.first === surface)
    }

    @MainActor
    @Test func endedSessionCannotBeAttachedAsANewShell() throws {
        let descriptor = try endpoint("ended-host")
        let session = try session(id: UUID().uuidString, updatedAt: 2, ended: "process_exited")

        #expect(!session.isAttachable)
        #expect(throws: (any Error).self) {
            try SessionRuntimeLibrary.openExisting(session, descriptor: descriptor, controllers: [])
        }
    }

    @MainActor
    @Test func endingASessionCreatesDurableCloseIntent() async throws {
        let catalog = SessionRuntimeCatalog(url: nil)
        let descriptor = try endpoint("close-host")
        catalog.remember(descriptor)
        let queue = SessionRuntimeCloseQueue(url: nil)
        let record = try session(id: UUID().uuidString, updatedAt: 2)
        let model = SessionRuntimeLibraryModel(
            catalog: catalog,
            closeQueue: queue,
            loader: { _ in [record] }
        )
        model.selectedEndpointID = descriptor.identity
        for _ in 0..<20 where model.loadState != .loaded {
            try await Task.sleep(for: .milliseconds(10))
        }
        model.selectSession(record)

        try model.end(record)

        #expect(queue.requests.count == 1)
        #expect(queue.requests.first?.pane == record.paneID)
        #expect(queue.requests.first?.descriptor == descriptor)
    }

    @MainActor
    @Test func refreshClearsOldRowsAndDisablesOldCloseIntent() async throws {
        let catalog = SessionRuntimeCatalog(url: nil)
        let descriptor = try endpoint("stale-close-host")
        catalog.remember(descriptor)
        let queue = SessionRuntimeCloseQueue(url: nil)
        let record = try session(id: UUID().uuidString, updatedAt: 2)
        let model = SessionRuntimeLibraryModel(
            catalog: catalog,
            closeQueue: queue,
            loader: { _ in
                try? await Task.sleep(for: .milliseconds(80))
                return [record]
            }
        )
        model.selectedEndpointID = descriptor.identity
        for _ in 0..<20 where model.loadState != .loaded {
            try await Task.sleep(for: .milliseconds(10))
        }
        model.selectSession(record)

        model.refresh()
        #expect(model.sessions.isEmpty)
        #expect(model.selectedSessionID == nil)
        try model.end(record)
        #expect(queue.requests.isEmpty)
    }

    private func endpoint(_ destination: String) throws -> SessionRuntimeDescriptor {
        SessionRuntimeDescriptor(
            connection: try GitSSHConnection(destination: destination),
            revision: "catalog-test",
            policy: .init()
        )
    }

    private func session(id: String, updatedAt: UInt64, ended: String? = nil) throws -> SessionRuntimeCatalogSession {
        let json: [String: Any] = [
            "id": id,
            "generation": "0123456789abcdef0123456789abcdef",
            "created_at": 1,
            "updated_at": updatedAt,
            "pid": 123,
            "ended": ended.map { $0 as Any } ?? NSNull(),
            "resume": [
                "agent": "codex",
                "conversation_id": "test-conversation",
                "cwd": "/tmp"
            ],
            "cwd": "/tmp",
            "policy": [
                "detached_ttl_seconds": 259200,
                "expires_at": NSNull(),
                "close_on_agent_done": false,
                "agent_done_grace_seconds": 60,
                "terminate_grace_seconds": 5,
                "host_idle_seconds": 300,
                "record_retention_seconds": 604800
            ] as [String: Any]
        ]
        return try #require(SessionRuntimeCatalogSession.decodeList(
            JSONSerialization.data(withJSONObject: [json])
        ).first)
    }
}
