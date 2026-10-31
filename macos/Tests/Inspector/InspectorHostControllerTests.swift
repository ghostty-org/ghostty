import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct InspectorHostControllerTests {
    @Test(arguments: [BuiltInFilesInspectorProvider.paneID, BuiltInGitInspectorProvider.paneID])
    func titleChangesDoNotRestartLocationDrivenProviders(pane: String) throws {
        let registry = InspectorRegistry()
        var events: [InspectorPaneLifecycleEvent] = []
        try registry.registerCorePane(.init(id: pane, title: "Test", systemImage: "doc",
            source: .coreFeature("test"), preferredWidth: 320, minimumWidth: 176),
            content: { _ in .fields([]) }, lifecycle: { events.append($0) })
        let tab = UUID(), surface = UUID()
        for index in 0..<20 {
            registry.presentationDidChange(to: pane, context: .init(tabID: tab, surfaceID: surface,
                title: "Title \(index)", workingDirectory: "/repo"))
        }
        #expect(events.count == 1)
        registry.presentationDidChange(to: pane, context: .init(tabID: tab, surfaceID: surface,
            title: "Title", workingDirectory: "/other"))
        #expect(events.count == 3)
    }

    @Test func inactiveNativeTabsDoNotPresentOrLoadInspectorProviders() async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let first = try fixture.tab()
        for _ in 0..<7 { _ = try fixture.tab(parent: first) }
        let state = VerticalTabWindowLayoutState(isSidebarVisible: false, isInspectorVisible: true)
        let registry = InspectorRegistry()
        let paneID = BuiltInGitInspectorProvider.paneID
        var presented: Set<UUID> = []
        try registry.registerCorePane(.init(id: paneID, title: "Test", systemImage: "doc",
            source: .coreFeature("test"), preferredWidth: 320, minimumWidth: 176),
            content: { _ in .fields([]) }, lifecycle: { event in
                switch event {
                case .appeared(let context): presented.insert(context.tabID)
                case .disappeared(let context): presented.remove(context.tabID)
                }
            })
        let hosts = fixture.controllers.map { terminal in
            let host = InspectorHostController(controller: terminal, layoutState: state, registry: registry)
            host.configure(isPresented: true, backgroundColor: .clear, backgroundOpacity: 0, environment: EnvironmentValues())
            host.view.frame = .init(x: 0, y: 0, width: 320, height: 400)
            terminal.window?.contentView?.addSubview(host.view)
            return host
        }
        defer { hosts.forEach { $0.stop(); $0.view.removeFromSuperview() } }
        for terminal in [first, fixture.controllers[5], first] {
            terminal.window?.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(100))
            let previouslyEligible = hosts.filter { $0.view.window != nil && !$0.view.isHiddenOrHasHiddenAncestor }.count
            print("Inspector visibility: attached=\(hosts.count), previous-rule=\(previouslyEligible), active=\(presented.count)")
            #expect(presented == [terminal.tabSessionID])
            #expect(hosts.filter { !$0.deck.hosts.isEmpty }.count <= 2)
        }
    }

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
        var contentReads = 0
        try registry.registerCorePane(.init(id: paneID, title: "Test", systemImage: "doc",
            source: .coreFeature("test"), preferredWidth: 320, minimumWidth: 176),
            content: { _ in contentReads += 1; return .fields([]) }, lifecycle: { events.append($0) })
        try registry.registerPluginPane(.init(id: "other", title: "Other", systemImage: "doc",
            source: .plugin("test"), preferredWidth: 320, minimumWidth: 176))
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
        window.orderFront(nil)
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
        let readsBeforeUnrelatedChanges = contentReads
        for index in 0..<20 {
            let content = InspectorPaneContent.fields([.init(id: "value", label: "Value", value: "\(index)")])
            try registry.updatePluginContent(paneID: "other", pluginID: "test", tabID: terminal.tabSessionID, content: content)
            try registry.updateCoreContent(paneID: paneID, featureID: "test", tabID: UUID(), content: content)
        }
        try await Task.sleep(for: .milliseconds(60))
        #expect(contentReads == readsBeforeUnrelatedChanges)
        try registry.updateCoreContent(paneID: paneID, featureID: "test", tabID: terminal.tabSessionID, content: .fields([]))
        try await Task.sleep(for: .milliseconds(60))
        #expect(contentReads == readsBeforeUnrelatedChanges + 1)
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
