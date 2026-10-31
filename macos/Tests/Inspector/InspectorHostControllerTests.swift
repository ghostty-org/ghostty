import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct InspectorHostControllerTests {
    @Test(arguments: [Ghostty.Config.MacOSTabLayout.vertical, .horizontal])
    func nativeOwnerCoalescesUpdatesAndStopsPresentationOnHideAndDetach(mode: Ghostty.Config.MacOSTabLayout) async throws {
        let app = try #require(NSApp.delegate as? AppDelegate)
        var configuration = Ghostty.SurfaceConfiguration()
        configuration.command = "sleep 30"
        let terminal = TerminalController(app.ghostty, withBaseConfig: configuration, tabLayout: mode)
        let terminalWindow = try #require(terminal.window)
        defer { terminalWindow.delegate = nil; terminalWindow.close() }
        let suite = "InspectorHostTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = VerticalTabWindowLayoutState(isSidebarVisible: false, isInspectorVisible: true,
            inspectorPresentation: InspectorPresentationStore(defaults: defaults))
        let registry = InspectorRegistry()
        var events: [InspectorPaneLifecycleEvent] = []
        // The spawned command can finish setting its title during this test.
        // Git's location-only lifecycle isolates attachment from that metadata.
        let paneID = BuiltInGitInspectorProvider.paneID
        try registry.registerCorePane(.init(id: paneID, title: "Test", systemImage: "doc",
            source: .coreFeature("test"), preferredWidth: 320, minimumWidth: 176),
            content: { _ in .fields([]) }, lifecycle: { events.append($0) })
        let host = InspectorHostController(controller: terminal, layoutState: state, registry: registry)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 320, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { host.stop(); window.contentView = nil; window.close() }
        func configure(_ visible: Bool) {
            host.configure(isPresented: visible, backgroundColor: .clear,
                           backgroundOpacity: 0, environment: EnvironmentValues())
        }
        configure(true)
        try await Task.sleep(for: .milliseconds(60))
        #expect(events.isEmpty)
        let ancestor = NSView(frame: window.contentLayoutRect)
        host.view.frame = ancestor.bounds
        ancestor.addSubview(host.view)
        window.contentView = ancestor
        try await Task.sleep(for: .milliseconds(60))
        #expect(events.count == 1)
        #expect(state.selectedInspectorPaneID == paneID)
        host.view.layoutSubtreeIfNeeded()
        host.viewDidLayout()
        let navigation = try #require(host.view.subviews.first { $0.accessibilityIdentifier() == "inspector.navigation" })
        #expect(navigation.isHidden == (mode == .vertical))
        if mode == .horizontal {
            #expect(host.deck.frame.maxY <= navigation.frame.minY)
            #expect(navigation.subviews.contains { ($0 as? NativeActionControl)?.title == "Test" })
        }
        let original = try #require(host.deck.hosts[paneID])
        for _ in 0..<10 { configure(true) }
        try await Task.sleep(for: .milliseconds(60))
        #expect(events.count == 1)
        configure(false)
        try await Task.sleep(for: .milliseconds(60))
        #expect(events.count == 2)
        configure(true)
        try await Task.sleep(for: .milliseconds(60))
        #expect(events.count == 3)
        #expect(host.deck.hosts[paneID] === original)
        ancestor.isHidden = true
        try await Task.sleep(for: .milliseconds(60))
        #expect(events.count == 4)
        ancestor.isHidden = false
        try await Task.sleep(for: .milliseconds(60))
        #expect(events.count == 5)
        window.contentView = nil
        try await Task.sleep(for: .milliseconds(60))
        #expect(events.count == 6)
        host.stop()
        configure(true)
        try await Task.sleep(for: .milliseconds(60))
        #expect(events.count == 6)
    }
}
