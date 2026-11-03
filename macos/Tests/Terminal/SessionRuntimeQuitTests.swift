import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct SessionRuntimeQuitTests {
    private func descriptor(local: Bool) throws -> SessionRuntimeDescriptor {
        .init(connection: local ? nil : try GitSSHConnection(destination: "quit-fixture"),
              revision: "quit-fixture-unavailable", policy: .init(), localWorkingDirectory: local ? "/tmp" : nil)
    }

    private func inline(_ local: UUID, descriptor: SessionRuntimeDescriptor) -> SessionRuntimeInlineSession {
        .init(descriptor: descriptor, pane: UUID(), connectionID: "quit-fixture",
              socket: URL(fileURLWithPath: "/tmp/quit-fixture.sock"),
              helperPID: 0, bootID: UUID(), localPane: local)
    }

    @Test func localAndSSHPreferencesAreIndependentAndPersist() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let settings = OhMyGhosttySettings(fileURL: url)
        #expect(settings.runtimeQuitPolicy == .init())
        for local in [false, true] {
            for ssh in [false, true] {
                settings.keepLocalSessionsOnQuit = local
                settings.keepSSHSessionsOnQuit = ssh
                let restored = OhMyGhosttySettings(fileURL: url)
                #expect(restored.runtimeQuitPolicy == .init(keepLocal: local, keepSSH: ssh))
            }
        }
        let english = SettingsSearchCatalog.entries(strings: SettingsStrings(language: .english))
        let chinese = SettingsSearchCatalog.entries(strings: SettingsStrings(language: .simplifiedChinese))
        #expect(english.contains { $0.prefixes.contains("sessions.keep") && $0.keywords.contains("quit") })
        #expect(chinese.contains { $0.prefixes.contains("sessions.keep") && $0.keywords.contains("退出") })
        let host = NSHostingView(rootView: SessionRuntimeSettingsView(
            settings: settings, strings: SettingsStrings(language: .simplifiedChinese))
            .padding(20).frame(width: 620).background(Color(nsColor: .windowBackgroundColor)))
        host.frame = .init(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/omg-quit-policy-settings.png"))
    }

    @Test func allQuitPoliciesTargetOnlyOwnedSessionsAndPreserveInlineSSHIdentity() throws {
        let local = try descriptor(local: true)
        let remote = try descriptor(local: false)
        let localPane = UUID(), directRemote = UUID(), carrier = UUID()
        let viewer = inline(carrier, descriptor: remote)
        let sessions = [
            SessionRuntimeQuitSession(pane: localPane, descriptor: local, workingDirectory: "/tmp/current"),
            SessionRuntimeQuitSession(pane: directRemote, descriptor: remote),
            SessionRuntimeQuitSession(pane: carrier, descriptor: local, inline: viewer)
        ]
        for keepLocal in [false, true] {
            for keepSSH in [false, true] {
                let plan = SessionRuntimeQuitPlan(sessions: sessions, policy: .init(keepLocal: keepLocal, keepSSH: keepSSH))
                var expected = Set<UUID>()
                if !keepLocal { expected.formUnion([localPane, carrier]) }
                if !keepSSH { expected.formUnion([directRemote, viewer.pane]) }
                #expect(Set(plan.requests.map(\.pane)) == expected)
                #expect(plan.requests.allSatisfy { $0.descriptor == local || $0.descriptor == remote })
                if !keepLocal && keepSSH {
                    let replacement = try #require(plan.replacements[carrier])
                    #expect(replacement.pane == viewer.pane)
                    #expect(replacement.descriptor == remote)
                    #expect(!replacement.create)
                }
                if !keepLocal {
                    let replacement = try #require(plan.replacements[localPane])
                    #expect(replacement.pane != localPane && replacement.create)
                    #expect(replacement.descriptor.initialWorkingDirectory == "/tmp/current")
                }
                if !keepSSH {
                    #expect(plan.replacements[directRemote]?.create == true)
                    #expect(plan.sockets[viewer.pane] == viewer.socket)
                }
                if keepLocal && keepSSH { #expect(plan.isEmpty) }
            }
        }
    }

    @Test func retainedRemoteOutlivesAnOrdinaryLocalCarrier() throws {
        let local = UUID()
        let remote = try descriptor(local: false)
        let viewer = inline(local, descriptor: remote)
        let plan = SessionRuntimeQuitPlan(sessions: [.init(pane: local, descriptor: nil, inline: viewer)], policy: .init())
        #expect(plan.requests.isEmpty)
        #expect(plan.replacements[local]?.pane == viewer.pane)
        #expect(plan.replacements[local]?.create == false)
    }

    @Test func checkpointReplacesClosedIdentityAndUpdatesFocus() throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let controller = try fixture.tab()
        let surface = try #require(controller.surfaceTree.first)
        surface.runtimeDescriptor = try descriptor(local: true)
        controller.focusedSurface = surface
        var state = TerminalWorkspaceSessionState(controller)
        let originalID = surface.id
        let plan = SessionRuntimeQuitPlan(sessions: [.init(surface)], policy: .init(keepLocal: false))
        state.prepareRuntimeQuit(plan.replacements)
        let newID = try #require(plan.replacements[originalID]?.pane)
        #expect(state.paneIDs == [newID])
        #expect(state.focusedSurface == newID.uuidString)
        let decoded = try JSONDecoder().decode(TerminalWorkspaceSessionState.self, from: JSONEncoder().encode(state))
        #expect(decoded.surfaceTree.root?.panes.first?.runtimeCreateOnRestore == true)
        #expect(TerminalWorkspaceSessionState(controller).surfaceTree.root?.panes.first?.runtimeCreateOnRestore == nil)
        #expect(surface.id == originalID)
    }

    @Test func closeHelpersFinishRemoteBeforeLocalAndOnlyAcknowledgedRequestsDisappear() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("pending.json")
        let queue = SessionRuntimeCloseQueue(url: url)
        let local = SessionRuntimeCloseRequest(pane: UUID(), descriptor: try descriptor(local: true))
        let remote = SessionRuntimeCloseRequest(pane: UUID(), descriptor: try descriptor(local: false))
        try queue.enqueue([local, remote])
        var order: [Bool] = []
        var processes: [Process] = []
        await queue.finishForQuit(timeout: .milliseconds(100)) { request in
            if request.descriptor.isLocal { #expect(processes.allSatisfy { !$0.isRunning }) }
            order.append(request.descriptor.isLocal)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", request == remote ? "exit 0" : "exit 1"]
            try process.run()
            processes.append(process)
            return process
        }
        #expect(order.first == false)
        #expect(order.dropFirst().allSatisfy { $0 })
        #expect(queue.requests == [local])
        #expect(SessionRuntimeCloseQueue(url: url).requests == [local])
    }

    @Test func closeDeadlineLeavesDurableIntentAndStopsItsHelper() async throws {
        let queue = SessionRuntimeCloseQueue(url: nil)
        let request = SessionRuntimeCloseRequest(pane: UUID(), descriptor: try descriptor(local: false))
        try queue.enqueue([request])
        var helper: Process?
        let clock = ContinuousClock()
        let start = clock.now
        await queue.finishForQuit(timeout: .milliseconds(50)) { _ in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["30"]
            try process.run()
            helper = process
            return process
        }
        #expect(start.duration(to: clock.now) < .seconds(1))
        #expect(queue.requests == [request])
        try await waitForAppKit { helper?.isRunning == false }
    }

    @Test func manyClosesBoundControlProcessesAndDrainEveryRequest() async throws {
        let queue = SessionRuntimeCloseQueue(url: nil)
        let local = try descriptor(local: true)
        try queue.enqueue((0..<40).map { _ in .init(pane: UUID(), descriptor: local) })
        var helpers: [Process] = []
        var peak = 0
        await queue.finishForQuit { _ in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["0.03"]
            try process.run()
            helpers.append(process)
            peak = max(peak, helpers.filter(\.isRunning).count)
            return process
        }
        #expect(helpers.count == 40)
        #expect(peak <= 16)
        #expect(queue.requests.isEmpty)
    }

    @Test func quitCopyReflectsBothSettingsWhileWindowCloseKeepsItsContract() throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let controller = try fixture.tab()
        let surface = try #require(controller.surfaceTree.first)
        surface.runtimeDescriptor = try descriptor(local: true)
        surface.runtimeInlineSession = inline(surface.id, descriptor: try descriptor(local: false))
        let strings = SettingsStrings(language: .simplifiedChinese)
        let copy = SessionRuntimeCloseCopy(surfaces: [surface], quitPolicy: .init(keepLocal: false, keepSSH: true))
        #expect(copy.quitMessage(multipleWindows: false, strings: strings).contains("本地会话会被结束"))
        #expect(copy.quitMessage(multipleWindows: false, strings: strings).contains("SSH 会话会在远端继续"))
        #expect(copy.windowMessage(allWindows: false, strings: strings).contains("持久会话会在后台继续"))
    }

    @Test func rewrittenQuitCheckpointIsCompleteAndCancellationRestoresLiveIdentity() throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let controller = try fixture.tab()
        let surface = try #require(controller.surfaceTree.first)
        surface.runtimeDescriptor = try descriptor(local: true)
        fixture.sessions.start(fixture.app)
        fixture.sessions.capture()
        fixture.sessions.prepareToQuit()
        let plan = SessionRuntimeQuitPlan(sessions: [.init(surface)], policy: .init(keepLocal: false))
        try fixture.sessions.prepareRuntimeQuit(plan.replacements)
        let url = fixture.directory.appendingPathComponent("state.json")
        func snapshot() throws -> TerminalWorkspaceSessionStore.Snapshot {
            try JSONDecoder().decode(TerminalWorkspaceSessionStore.Snapshot.self, from: Data(contentsOf: url))
        }
        let saved = try snapshot()
        #expect(saved.isComplete)
        let state = try JSONDecoder().decode(TerminalWorkspaceSessionState.self, from: #require(saved.tabs.first?.state))
        #expect(state.paneIDs != [surface.id])
        fixture.sessions.cancelQuit()
        fixture.sessions.flush()
        let restored = try snapshot()
        #expect(restored.isComplete)
        let live = try JSONDecoder().decode(TerminalWorkspaceSessionState.self, from: #require(restored.tabs.first?.state))
        #expect(live.paneIDs == [surface.id])
        #expect(live.surfaceTree.root?.panes.first?.runtimeCreateOnRestore == nil)
    }
}
