import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct SessionRuntimePresentationTests {
    @Test func fastAttachmentNeverShowsAConnectingNotice() async throws {
        let presentation = SessionRuntimeRecoveryPresentation(delay: 0.05)
        presentation.update(.connecting(attempt: 0))
        #expect(presentation.state == nil)
        presentation.update(.ready)
        try await Task.sleep(for: .milliseconds(100))
        #expect(presentation.state == nil)
    }

    @Test func slowAttachmentShowsTheLatestStateAndCancelsWhenHidden() async throws {
        let presentation = SessionRuntimeRecoveryPresentation(delay: 0.02)
        presentation.update(.connecting(attempt: 0))
        presentation.update(.reconnecting(attempt: 2, retryInMilliseconds: 500))
        try await Task.sleep(for: .milliseconds(60))
        #expect(presentation.state == .reconnecting(attempt: 2, retryInMilliseconds: 500))
        presentation.update(.ready)
        #expect(presentation.state == nil)
        presentation.update(.connecting(attempt: 0))
        presentation.update(nil)
        try await Task.sleep(for: .milliseconds(60))
        #expect(presentation.state == nil)
    }

    @Test func actionableFailureIsImmediateAndExitDoesNotDuplicateTheTerminalExitNotice() {
        let presentation = SessionRuntimeRecoveryPresentation()
        presentation.update(.failed(message: "offline"))
        #expect(presentation.state == .failed(message: "offline"))
        presentation.update(.exited(exitCode: 0))
        #expect(presentation.state == nil)
    }

    private struct Probe: NSViewRepresentable {
        let view: NSView
        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    @Test func runtimeStatusDoesNotResizeTheTerminal() async throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let controller = TerminalController(app, withBaseConfig: config)
        defer { controller.window?.close() }
        let surface = try #require(controller.surfaceTree.first)
        surface.runtimeDescriptor = .init(connection: nil, revision: "test", policy: .init())
        surface.runtimeConnectionState = .ready
        let probe = NSView()
        let host = NSHostingView(rootView: EditorWorkspaceHost(controller: controller, surfaceView: surface) {
            Probe(view: probe)
        })
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 800, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(80))
        host.layoutSubtreeIfNeeded()
        let initial = probe.convert(probe.bounds, to: host)
        try #require(initial.height > 400)
        for state in [SessionRuntimeConnectionState.failed(message: "offline"), .ready,
                      .reconnecting(attempt: 1, retryInMilliseconds: 100), .ready] {
            surface.runtimeConnectionState = state
            try await Task.sleep(for: .milliseconds(80))
            host.layoutSubtreeIfNeeded()
            #expect(probe.convert(probe.bounds, to: host) == initial)
        }
    }
}
