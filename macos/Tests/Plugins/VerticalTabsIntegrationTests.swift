import AppKit
import Combine
import SwiftUI
import Testing
@testable import Ghostty
@testable import GhosttyKit

@MainActor
struct VerticalTabsIntegrationTests {
    @Test func terminalTitlesDoNotInvalidateWholeController() async throws {
        let appDelegate = try #require(NSApp.delegate as? AppDelegate)
        var configuration = Ghostty.SurfaceConfiguration()
        configuration.command = "sleep 30"
        let controller = TerminalController(appDelegate.ghostty, withBaseConfig: configuration)
        let window = try #require(controller.window)
        defer { window.delegate = nil; window.close() }
        let surface = try #require(controller.focusedSurface ?? controller.surfaceTree.first)
        try await Task.sleep(for: .milliseconds(200))
        var publications = 0
        var surfacePublications = 0
        var titles: [String] = []
        let observer = controller.objectWillChange.sink { publications += 1 }
        let surfaceObserver = surface.objectWillChange.sink { surfacePublications += 1 }
        let titleObserver = surface.$title.dropFirst().sink { titles.append($0) }
        defer { observer.cancel(); surfaceObserver.cancel(); titleObserver.cancel() }
        for index in 0..<10 {
            surface.setTitle("CPU title test \(index)")
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(controller.paneSessionContext(for: surface)?.local.terminalTitle == "CPU title test 9")
        #expect(publications == 0)
        #expect(surfacePublications == 0)
        #expect(titles == (0..<10).map { "CPU title test \($0)" })
        surface.pwd = "/tmp/omg-title-location-test"
        #expect(controller.paneSessionContext(for: surface)?.workingDirectory == "/tmp/omg-title-location-test")
        #expect(publications > 0)
    }

    private let hoverScreenshotPath = "/tmp/oh-my-ghostty-vertical-tabs-hover.png"
    private let hiddenScreenshotPath = "/tmp/oh-my-ghostty-vertical-tabs-hidden.png"
    private let lightScreenshotPath = "/tmp/oh-my-ghostty-vertical-tabs-light.png"
    private let groupsScreenshotPath = "/tmp/oh-my-ghostty-vertical-tabs-groups.png"
    private let horizontalScreenshotPath = "/tmp/oh-my-ghostty-horizontal-tabs.png"
    private let transparencyVerticalScreenshotPath =
        "/tmp/oh-my-ghostty-transparency-vertical.png"
    private let transparencyHorizontalScreenshotPath =
        "/tmp/oh-my-ghostty-transparency-horizontal.png"
    private let settingsScreenshotPath = "/tmp/oh-my-ghostty-settings-tabs.png"
    private let appearanceSettingsScreenshotPath =
        "/tmp/oh-my-ghostty-settings-appearance.png"
    private let appearanceSettingsLightScreenshotPath =
        "/tmp/oh-my-ghostty-settings-appearance-light.png"
    private let reorderScreenshotPath = "/tmp/oh-my-ghostty-vertical-tabs-reordered.png"
    private let inspectorScreenshotPath = "/tmp/oh-my-ghostty-inspector-files.png"
    private let reopenedInspectorScreenshotPath =
        "/tmp/oh-my-ghostty-inspector-files-reopened.png"

    @Test func remoteSessionMetadataDoesNotAddScrollDispatchJank() async throws {
        let appDelegate = try #require(NSApp.delegate as? AppDelegate)
        var configuration = Ghostty.SurfaceConfiguration()
        configuration.command = "seq 1 30000; sleep 30"
        let controller = TerminalController(
            appDelegate.ghostty,
            withBaseConfig: configuration
        )
        let window = try #require(controller.window)
        defer {
            window.delegate = nil
            window.close()
        }
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .seconds(2))
        let surface = try #require(controller.focusedSurface ?? controller.surfaceTree.first)
        let up = try #require(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: 8,
            wheel2: 0,
            wheel3: 0
        ).flatMap(NSEvent.init(cgEvent:)))
        let down = try #require(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: -8,
            wheel2: 0,
            wheel3: 0
        ).flatMap(NSEvent.init(cgEvent:)))

        func measure() async -> Duration {
            let clock = ContinuousClock()
            let start = clock.now
            for index in 0..<800 {
                surface.scrollWheel(with: index % 400 < 200 ? up : down)
                if index.isMultiple(of: 40) { await Task.yield() }
            }
            surface.displayIfNeeded()
            await Task.yield()
            return start.duration(to: clock.now)
        }

        let local = await measure()
        surface.contextSignal = .init(
            action: .start,
            id: "omg-ssh-scroll-benchmark",
            metadata: "type=remote;targethost=cloud;cwdhex=2f746d70"
        )
        try await Task.sleep(for: .milliseconds(100))
        let remote = await measure()
        surface.contextSignal = .init(
            action: .start,
            id: "omg-agent-pi-99999",
            metadata: "type=app;omg_agent=pi;omg_scope=remote;omg_state=working"
        )
        try await Task.sleep(for: .milliseconds(100))
        let remotePi = await measure()

        print("Scroll dispatch: local=\(local), remote=\(remote), remote-pi=\(remotePi)")
        let tolerance = local * 4 + .milliseconds(20)
        #expect(remote < tolerance)
        #expect(remotePi < tolerance)
    }

    @Test func appKitTabGroupDrivesVerticalTabsWithoutRecreatingSurfaces() async throws {
        let inspectorPresentation = InspectorPresentationStore.shared
        let previousInspectorPresentation = inspectorPresentation.snapshot
        inspectorPresentation.replace(with: .init())
        defer {
            inspectorPresentation.replace(with: previousInspectorPresentation)
        }

        let settingsURL = OhMyGhosttySettings.fileURL
        let previousSettings = try? Data(contentsOf: settingsURL)
        defer {
            if let previousSettings {
                try? previousSettings.write(to: settingsURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: settingsURL)
            }
            OhMyGhosttySettings.shared.reloadFromDisk()
        }
        let settings = OhMyGhosttySettings.shared
        settings.language = .english
        settings.tabLayout = .vertical
        settings.defaultSidebarWidth = 240
        settings.sidebarVisible = true
        settings.groupingMode = .none
        settings.orderingMode = .manual
        settings.showShortcutLabels = true
        settings.rememberSidebarWidth = true
        settings.openQuickInputOnAgentStart = false
        settings.openQuickInputOnAgentComplete = false
        settings.resetAppearance()

        let appDelegate = try #require(NSApp.delegate as? AppDelegate)
        let configURL = URL(fileURLWithPath: "/tmp/Ghostty/testing_config.ghostty")
        let previousConfig = try? Data(contentsOf: configURL)
        defer {
            if let previousConfig {
                try? previousConfig.write(to: configURL)
            } else {
                try? FileManager.default.removeItem(at: configURL)
            }
            appDelegate.ghostty.reloadConfig()
        }
        try await applyConfig(
            "macos-tab-layout = vertical\nbackground = #282c34\nforeground = #f0f0f0\n",
            at: configURL,
            app: appDelegate.ghostty
        )

        let titles = [
            "project-a",
            "project-b",
            "project-c",
            "quant-research",
            "maka-agent",
            "infra-tools",
            "research-notes",
            "oh-my-ghostty",
        ]
        var controllers: [TerminalController] = []

        let first = TerminalController(
            appDelegate.ghostty,
            withBaseConfig: configuration(title: titles[0])
        )
        first.titleOverride = titles[0]
        controllers.append(first)
        let initialWindow = try #require(first.window as? VerticalTabsTerminalWindow)
        first.showWindow(nil)
        try await settle([first])
        initialWindow.contentView?.superview?.layoutSubtreeIfNeeded()
        #expect(initialWindow.sidebarToggleIsInstalled)
        #expect(initialWindow.inspectorToggleIsInstalled)
        #expect(
            initialWindow.titlebarControlsWidth ==
                TerminalTitlebarMetrics.leftAccessoryWidth
        )
        #expect(
            initialWindow.inspectorControlsWidth ==
                TerminalTitlebarMetrics.inspectorCollapsedWidth
        )

        for title in titles.dropFirst() {
            let parent = try #require(controllers.last?.window)
            let controller = try #require(TerminalController.newTab(
                appDelegate.ghostty,
                from: parent,
                withBaseConfig: configuration(title: title)
            ))
            controller.titleOverride = title
            controllers.append(controller)
        }

        defer {
            for controller in controllers {
                controller.window?.delegate = nil
                controller.window?.close()
            }
        }

        try await settle(controllers)

        let eighth = controllers[7]
        let initialDividerColor = NSColor(eighth.sidebarDividerColor)
        let expectedInitialDividerColor = NSColor(
            appDelegate.ghostty.config.splitDividerColor(
                for: eighth.terminalBackgroundColor
            )
        )
        #expect(initialDividerColor.distance(to: expectedInitialDividerColor) < 0.001)
        #expect(initialDividerColor.alphaComponent == 1)
        #expect(controllers.allSatisfy { $0.sidebarIsShowing })
        settings.defaultSidebarWidth = 300
        try await Task.sleep(for: .milliseconds(100))
        #expect(controllers.allSatisfy { abs($0.sidebarWidth - 300) < 0.001 })
        settings.sidebarVisible = false
        try await Task.sleep(for: .milliseconds(100))
        #expect(controllers.allSatisfy { !$0.sidebarIsShowing })
        settings.sidebarVisible = true
        try await Task.sleep(for: .milliseconds(100))
        #expect(controllers.allSatisfy { $0.sidebarIsShowing })
        eighth.setSidebarVisible(false)
        settings.tabIconSize = 17
        try await Task.sleep(for: .milliseconds(100))
        #expect(controllers.allSatisfy { !$0.sidebarIsShowing })
        eighth.setSidebarVisible(true)
        try await Task.sleep(for: .milliseconds(300))

        eighth.setTabGroupingMode(.none)
        eighth.setTabOrderingMode(.manual)
        let tabGroup = try #require(eighth.window?.tabGroup)
        #expect(tabGroup.windows.count == 8)
        #expect(eighth.tabControllers.count == 8)
        #expect(controllers.allSatisfy { controller in
            (controller.window as? VerticalTabsTerminalWindow)?.nativeTabBarIsSuppressed == true
        })
        #expect(controllers.compactMap {
            ($0.window as? VerticalTabsTerminalWindow)?.nativeTabBarRejectionCount
        }.reduce(0, +) > 0)

        tabGroup.selectedWindow = initialWindow
        try await Task.sleep(for: .milliseconds(150))
        initialWindow.contentView?.superview?.layoutSubtreeIfNeeded()
        #expect(initialWindow.titlebarControlsWidth ==
            TerminalTitlebarMetrics.leftAccessoryWidth)
        #expect(initialWindow.inspectorControlsWidth ==
            TerminalTitlebarMetrics.inspectorCollapsedWidth)

        let eighthWindow = try #require(eighth.window)
        tabGroup.selectedWindow = eighthWindow
        try await Task.sleep(for: .milliseconds(150))
        let alignedWindow = try #require(eighth.window as? VerticalTabsTerminalWindow)
        alignedWindow.contentView?.superview?.layoutSubtreeIfNeeded()
        let controlsCenterY = try #require(alignedWindow.titlebarControlsCenterY)
        let inspectorCenterY = try #require(alignedWindow.inspectorControlsCenterY)
        let trafficLightsCenterY = try #require(alignedWindow.trafficLightsCenterY)
        #expect(abs(controlsCenterY - trafficLightsCenterY) < 0.5)
        #expect(abs(inspectorCenterY - trafficLightsCenterY) < 0.5)
        let titlebarHeight = try #require(alignedWindow.titlebarContainer?.bounds.height)
        #expect(abs((alignedWindow.titlebarControlsHeight ?? 0) - titlebarHeight) < 0.5)
        #expect(abs((alignedWindow.inspectorControlsHeight ?? 0) - titlebarHeight) < 0.5)
        #expect(alignedWindow.inspectorToggleIsInstalled)
        let alignedContentView = try #require(alignedWindow.contentView)

        let surfaceIDs = controllers.map { $0.surfaceTree.first?.id }
        #expect(Set(controllers.map(\.tabSessionID)).count == controllers.count)
        let mockStatus = MockAgentStatusAdapter(store: appDelegate.tabActivities)
        #expect(mockStatus.report(
            sessionID: controllers[0].tabSessionID,
            state: .working,
            message: "Running tests"
        ) == nil)
        #expect(appDelegate.tabActivities.activity(
            for: controllers[0].tabSessionID
        )?.state == .working)
        #expect(appDelegate.tabActivities.activity(
            for: controllers[1].tabSessionID
        ) == nil)
        #expect(mockStatus.report(sessionID: controllers[0].tabSessionID, state: .done) == nil)
        #expect(appDelegate.tabActivities.activity(
            for: controllers[0].tabSessionID
        )?.state == .done)
        #expect(mockStatus.report(
            sessionID: controllers[0].tabSessionID,
            state: .needsAttention
        ) == nil)
        #expect(appDelegate.tabActivities.activity(
            for: controllers[0].tabSessionID
        )?.state == .needsAttention)
        #expect(mockStatus.report(sessionID: controllers[0].tabSessionID, state: .idle) == nil)

        let initialSurfaceSizes = controllers.map(surfaceSize)
        #expect(initialSurfaceSizes.allSatisfy { $0 != nil })
        #expect(!appDelegate.inspectorRegistry.isEmpty)
        let inspectorMenuItem = try #require(menuItem(
            withAction: #selector(AppDelegate.toggleInspector(_:)),
            in: NSApp.mainMenu
        ))
        #expect(inspectorMenuItem.keyEquivalent == "i")
        #expect(inspectorMenuItem.keyEquivalentModifierMask.contains([.command, .shift]))
        #expect(NSApp.sendAction(
            inspectorMenuItem.action!,
            to: inspectorMenuItem.target,
            from: inspectorMenuItem
        ))
        let terminalWindow = try #require(eighth.window as? TerminalWindow)
        for _ in 0..<20 where
            !eighth.tabLayoutState.isInspectorVisible ||
                !terminalWindow.inspectorTitlebarPresentation.isVisible ||
                eighth.tabLayoutState.selectedInspectorPaneID == nil ||
                (terminalWindow.inspectorToggleWidthConstraint?.constant ?? 0) <=
                    TerminalTitlebarMetrics.inspectorCollapsedWidth {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(eighth.tabLayoutState.isInspectorVisible)
        #expect(eighth.tabLayoutState.selectedInspectorPaneID ==
            BuiltInFilesInspectorProvider.paneID)
        #expect(
            (terminalWindow.inspectorToggleWidthConstraint?.constant ?? 0) >
                TerminalTitlebarMetrics.inspectorCollapsedWidth
        )
        eighth.updateInspectorWidth(380, persist: true)
        #expect(eighth.tabLayoutState.inspectorWidth == 380)
        #expect(inspectorPresentation.snapshot.width == 380)
        let presentedInspectorWidth = TerminalShellStyle.presentedInspectorWidth(
            preferred: 380,
            totalWidth: alignedContentView.bounds.width,
            leadingWidth: eighth.tabLayoutState.sidebarWidth +
                TerminalShellStyle.dividerWidth
        )
        let expectedAccessoryWidth = presentedInspectorWidth
        for _ in 0..<20 where abs(
            (terminalWindow.inspectorToggleWidthConstraint?.constant ?? 0) -
                expectedAccessoryWidth
        ) >= 0.5 {
            try await Task.sleep(for: .milliseconds(50))
        }
        alignedContentView.superview?.layoutSubtreeIfNeeded()
        #expect(abs(
            (terminalWindow.inspectorToggleWidthConstraint?.constant ?? 0) -
                expectedAccessoryWidth
        ) < 0.5)
        #expect(abs(
            (terminalWindow.inspectorControlsWidth ?? 0) -
                expectedAccessoryWidth
        ) < 0.5)
        #expect(controllers.map { $0.surfaceTree.first?.id } == surfaceIDs)

        let inspectorSurface = try #require(eighth.focusedSurface ?? eighth.surfaceTree.first)
        inspectorSurface.contextSignal = .init(
            action: .start,
            id: "omg-agent-codex",
            metadata: "type=app;omg_agent=codex;omg_scope=local;" +
                "omg_state=working;omg_conversation=019f-first"
        )
        for _ in 0..<20 where eighth.agentActivity(for: inspectorSurface) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(eighth.agentActivity(for: inspectorSurface)?.source == "codex")
        #expect(eighth.agentActivity(for: inspectorSurface)?.state == .working)
        #expect(eighth.agentResumeDescriptor(
            for: inspectorSurface
        )?.conversationID?.rawValue == "019f-first")
        inspectorSurface.contextSignal = .init(
            action: .start,
            id: "omg-agent-codex",
            metadata: "type=app;omg_agent=codex;omg_scope=local;" +
                "omg_state=done;omg_conversation=019f-rotated"
        )
        for _ in 0..<20
        where eighth.agentActivity(for: inspectorSurface)?.state != .done {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(eighth.agentActivity(for: inspectorSurface)?.state == .done)
        eighth.updateAgentTitleActivity("Codex ⠋ working", for: inspectorSurface.id)
        #expect(eighth.agentActivity(for: inspectorSurface)?.state == .done)
        #expect(eighth.agentResumeDescriptor(
            for: inspectorSurface
        )?.conversationID?.rawValue == "019f-rotated")

        let completionInputs = try terminalCompletionInputs()
        try terminalScrollInput()(inspectorSurface)
        #expect(eighth.agentActivity(for: inspectorSurface)?.state == .done)
        for input in completionInputs {
            input(inspectorSurface)
            #expect(eighth.agentActivity(for: inspectorSurface)?.state == .idle)
            inspectorSurface.contextSignal = .init(
                action: .start,
                id: "omg-agent-codex",
                metadata: "type=app;omg_agent=codex;omg_scope=local;" +
                    "omg_state=done;omg_conversation=019f-rotated"
            )
            #expect(eighth.agentActivity(for: inspectorSurface)?.state == .done)
        }
        eighth.markTabActivated()
        #expect(eighth.agentActivity(for: inspectorSurface)?.state == .done)
        #expect(eighth.agentActivity(for: inspectorSurface)?.icon?.name == "AgentOpenAI")

        inspectorSurface.contextSignal = .init(
            action: .start,
            id: "omg-agent-codex",
            metadata: "type=app;omg_agent=codex;omg_scope=local;" +
                "omg_state=working;omg_conversation=019f-rotated"
        )
        #expect(eighth.agentActivity(for: inspectorSurface)?.state == .working)
        inspectorSurface.contextSignal = .init(
            action: .end,
            id: "omg-agent-codex",
            metadata: "type=app;omg_agent=codex;omg_scope=local"
        )
        for _ in 0..<20
        where eighth.agentActivity(for: inspectorSurface)?.state != .error {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(eighth.agentActivity(for: inspectorSurface)?.state == .error)
        eighth.markTabActivated()
        #expect(eighth.agentActivity(for: inspectorSurface)?.state == .error)
        completionInputs[0](inspectorSurface)
        #expect(eighth.agentActivity(for: inspectorSurface) == nil)
        #expect(eighth.agentResumeDescriptor(for: inspectorSurface) == nil)

        let inspectorContext = InspectorPaneContext(
            tabID: eighth.tabSessionID,
            surfaceID: inspectorSurface.id,
            title: eighth.titleOverride ?? inspectorSurface.title,
            workingDirectory: inspectorSurface.pwd
        )
        var inspectorContent: InspectorPaneContent?
        for _ in 0..<30 {
            inspectorContent = appDelegate.inspectorRegistry.content(
                for: BuiltInFilesInspectorProvider.paneID,
                context: inspectorContext
            )
            if case .fileTree = inspectorContent { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard case .fileTree(let initialInspectorTree) = inspectorContent,
              let sourcesNode = initialInspectorTree.nodes.first(where: {
                  $0.name == "Sources"
              }) else {
            Issue.record("Expected cwd-driven Files tree")
            return
        }
        #expect(initialInspectorTree.rootName == URL(
            fileURLWithPath: inspectorContext.workingDirectory ?? ""
        ).lastPathComponent)
        appDelegate.inspectorRegistry.performAction(
            paneID: BuiltInFilesInspectorProvider.paneID,
            action: .init(
                context: inspectorContext,
                kind: .toggleNode(id: sourcesNode.id, expanded: true)
            )
        )
        for _ in 0..<30 {
            inspectorContent = appDelegate.inspectorRegistry.content(
                for: BuiltInFilesInspectorProvider.paneID,
                context: inspectorContext
            )
            if case .fileTree(let tree) = inspectorContent,
               tree.nodes.first(where: { $0.name == "Sources" })?
                .children?.contains(where: { $0.name == "main.swift" }) == true {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard case .fileTree(let expandedInspectorTree) = inspectorContent else {
            Issue.record("Expected expanded cwd-driven Files tree")
            return
        }
        #expect(expandedInspectorTree.nodes.first(where: {
            $0.name == "Sources"
        })?.children?.contains(where: { $0.name == "main.swift" }) == true)
        try await Task.sleep(for: .milliseconds(500))
        try capture(window: try #require(eighth.window), path: inspectorScreenshotPath)

        let switchedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: switchedRoot) }
        try FileManager.default.createDirectory(at: switchedRoot, withIntermediateDirectories: true)
        try "{}".write(
            to: switchedRoot.appendingPathComponent("switched.json"),
            atomically: true,
            encoding: .utf8
        )
        let originalPWD = inspectorSurface.pwd
        var focusedContextChangeObserved = false
        let focusedContextObservation = eighth.objectWillChange.sink {
            focusedContextChangeObserved = true
        }
        inspectorSurface.pwd = switchedRoot.path
        #expect(focusedContextChangeObserved)
        withExtendedLifetime(focusedContextObservation) {}
        let switchedContext = InspectorPaneContext(
            tabID: eighth.tabSessionID,
            surfaceID: inspectorSurface.id,
            title: eighth.titleOverride ?? inspectorSurface.title,
            workingDirectory: switchedRoot.path
        )
        var switchedContent: InspectorPaneContent?
        for _ in 0..<30 {
            switchedContent = appDelegate.inspectorRegistry.content(
                for: BuiltInFilesInspectorProvider.paneID,
                context: switchedContext
            )
            if case .fileTree(let tree) = switchedContent,
               tree.nodes.contains(where: { $0.name == "switched.json" }) {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard case .fileTree(let switchedTree) = switchedContent else {
            Issue.record("Expected Files tree to follow terminal cwd")
            return
        }
        #expect(switchedTree.rootName == switchedRoot.lastPathComponent)
        #expect(switchedTree.nodes.map(\.name) == ["switched.json"])
        inspectorSurface.pwd = originalPWD
        try await Task.sleep(for: .milliseconds(100))
        let expandedInspectorAccessoryWidth = try #require(
            terminalWindow.inspectorToggleWidthConstraint?.constant
        )
        #expect(
            expandedInspectorAccessoryWidth >
                TerminalTitlebarMetrics.inspectorCollapsedWidth
        )
        eighth.toggleInspectorPane()
        #expect(!eighth.tabLayoutState.isInspectorVisible)
        #expect(!terminalWindow.inspectorTitlebarPresentation.isVisible)
        #expect(
            terminalWindow.inspectorToggleWidthConstraint?.constant ==
                expandedInspectorAccessoryWidth
        )
        for _ in 0..<20 where
            eighth.tabLayoutState.isInspectorVisible ||
                terminalWindow.inspectorTitlebarPresentation.isVisible ||
                terminalWindow.inspectorToggleWidthConstraint?.constant !=
                    TerminalTitlebarMetrics.inspectorCollapsedWidth ||
                controllers.map(surfaceSize) != initialSurfaceSizes {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!eighth.tabLayoutState.isInspectorVisible)
        #expect(
            terminalWindow.inspectorToggleWidthConstraint?.constant ==
                TerminalTitlebarMetrics.inspectorCollapsedWidth
        )
        terminalWindow.contentView?.superview?.layoutSubtreeIfNeeded()
        #expect(
            terminalWindow.inspectorControlsWidth ==
                TerminalTitlebarMetrics.inspectorCollapsedWidth
        )
        let collapsedInspectorCenterY = try #require(
            terminalWindow.inspectorControlsCenterY
        )
        let collapsedTrafficCenterY = try #require(alignedWindow.trafficLightsCenterY)
        #expect(abs(collapsedInspectorCenterY - collapsedTrafficCenterY) < 0.5)
        #expect(controllers.map { $0.surfaceTree.first?.id } == surfaceIDs)
        #expect(controllers.map(surfaceSize) == initialSurfaceSizes)

        eighth.toggleInspectorPane()
        for _ in 0..<20 where
            !eighth.tabLayoutState.isInspectorVisible ||
                !terminalWindow.inspectorTitlebarPresentation.isVisible ||
                (terminalWindow.inspectorControlsWidth ?? 0) <=
                    TerminalTitlebarMetrics.inspectorCollapsedWidth {
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(250))
        let reopenedAccessoryWidth = try #require(terminalWindow.inspectorControlsWidth)
        let reopenedPluginWidth = InspectorTitlebarLayout.pluginWidth(
            totalWidth: reopenedAccessoryWidth
        )
        let reopenedLayout = InspectorPluginBarLayout.resolve(
            descriptors: appDelegate.inspectorRegistry.entries.map(\.descriptor),
            selectedID: eighth.tabLayoutState.selectedInspectorPaneID,
            availableWidth: reopenedPluginWidth
        )
        #expect(eighth.tabLayoutState.isInspectorVisible)
        #expect(terminalWindow.inspectorTitlebarPresentation.isVisible)
        #expect(terminalWindow.inspectorTitlebarPresentation.width ==
            reopenedAccessoryWidth)
        #expect(reopenedPluginWidth > 0)
        #expect(reopenedLayout.visibleIDs.contains(BuiltInFilesInspectorProvider.paneID))
        try capture(
            window: try #require(eighth.window),
            path: reopenedInspectorScreenshotPath
        )

        eighth.toggleInspectorPane()
        for _ in 0..<20 where
            eighth.tabLayoutState.isInspectorVisible ||
                terminalWindow.inspectorTitlebarPresentation.isVisible ||
                terminalWindow.inspectorControlsWidth !=
                    TerminalTitlebarMetrics.inspectorCollapsedWidth {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!eighth.tabLayoutState.isInspectorVisible)
        #expect(!terminalWindow.inspectorTitlebarPresentation.isVisible)
        #expect(terminalWindow.inspectorTitlebarPresentation.width ==
            TerminalTitlebarMetrics.inspectorCollapsedWidth)
        try await Task.sleep(for: .milliseconds(250))
        #expect(controllers.map(surfaceSize) == initialSurfaceSizes)

        let expectedFrameSize = try #require(eighth.window).frame.size
        let switchOrder = [0, 4, 1, 7, 2, 5]
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<10 {
            for index in switchOrder {
                let target = controllers[index]
                eighth.selectVerticalTab(target)
                #expect(tabGroup.selectedWindow === target.window)
                #expect(target.window?.frame.size == expectedFrameSize)
                #expect((target.window as? VerticalTabsTerminalWindow)?.nativeTabBarIsSuppressed == true)
            }
        }
        let switchDuration = start.duration(to: clock.now)
        print("Vertical tabs: 60 switches in \(switchDuration)")
        #expect(switchDuration < .seconds(2))
        #expect(controllers.map { $0.surfaceTree.first?.id } == surfaceIDs)
        #expect(controllers.map(surfaceSize) == initialSurfaceSizes)

        let firstSurface = try #require(controllers[0].focusedSurface?.surfaceModel)
        let actionStart = clock.now
        for _ in 0..<10 {
            for index in switchOrder {
                #expect(firstSurface.perform(action: "goto_tab:\(index + 1)"))
                for _ in 0..<50
                where tabGroup.selectedWindow !== controllers[index].window {
                    try await Task.sleep(for: .milliseconds(1))
                }
                #expect(tabGroup.selectedWindow === controllers[index].window)
            }
        }
        let actionDuration = actionStart.duration(to: clock.now)
        print("Goto-tab actions: 60 switches in \(actionDuration)")
        #expect(actionDuration < .seconds(2))

        for index in 1...8 {
            let configured = appDelegate.ghostty.config.keyboardShortcut(for: "goto_tab:\(index)")
            #expect(controllers[index - 1].tabShortcutLabel(for: index) == configured.map { "\($0)" })
            #expect(controllers[index - 1].tabShortcutLabel(for: index)?.contains("⌘") == true)
        }
        #expect(eighth.tabShortcutLabel(for: 10) == nil)

        eighth.selectVerticalTab(controllers[2])
        eighth.setSidebarVisible(true)
        #expect(eighth.reorderTab(controllers[3], toInsertionIndex: 1))
        #expect(tabGroup.windows.compactMap(\.windowController).map(ObjectIdentifier.init) == [
            controllers[0], controllers[3], controllers[1], controllers[2],
            controllers[4], controllers[5], controllers[6], controllers[7],
        ].map(ObjectIdentifier.init))
        #expect(tabGroup.selectedWindow === controllers[2].window)
        #expect(controllers.map { $0.surfaceTree.first?.id } == surfaceIDs)
        try await Task.sleep(for: .milliseconds(100))
        try capture(window: try #require(controllers[2].window), path: reorderScreenshotPath)
        #expect(firstSurface.perform(action: "goto_tab:2"))
        try await Task.sleep(for: .milliseconds(40))
        #expect(tabGroup.selectedWindow === controllers[3].window)
        #expect(firstSurface.perform(action: "goto_tab:3"))
        try await Task.sleep(for: .milliseconds(40))
        #expect(tabGroup.selectedWindow === controllers[1].window)

        eighth.selectVerticalTab(controllers[2])
        #expect(eighth.reorderTab(controllers[2], toInsertionIndex: 0))
        #expect(tabGroup.selectedWindow === controllers[2].window)
        #expect(tabGroup.windows.first === controllers[2].window)
        #expect(controllers[2].tabShortcutLabel(for: 1)?.contains("1") == true)
        #expect(controllers.map { $0.surfaceTree.first?.id } == surfaceIDs)
        for candidate in tabGroup.windows.compactMap({
            $0.windowController as? TerminalController
        }) {
            let restorable = TerminalRestorableState(from: candidate)
            #expect(restorable.tabSessionID == candidate.tabSessionID)
            #expect(restorable.tabCreatedAt == candidate.tabCreatedAt)
        }

        eighth.setTabOrderingMode(.created)
        #expect(tabGroup.windows.compactMap(\.windowController).map(ObjectIdentifier.init) ==
            controllers.map(ObjectIdentifier.init))
        eighth.beginManualTabDrag()
        #expect(eighth.tabLayoutState.orderingMode == .manual)

        for index in [1, 5, 2, 8, 3, 6] {
            #expect(firstSurface.perform(action: "goto_tab:\(index)"))
            try await Task.sleep(for: .milliseconds(40))
            #expect(tabGroup.selectedWindow === controllers[index - 1].window)
            #expect((tabGroup.selectedWindow as? VerticalTabsTerminalWindow)?.nativeTabBarIsSuppressed == true)
        }

        let organizer = GhosttyTabOrganizationModel()
        let ungrouped = organizer.groups(
            tabs: eighth.tabControllers,
            grouping: .none,
            ordering: .manual
        )
        #expect(ungrouped.count == 1)
        #expect(ungrouped[0].tabs.map(\.actualIndex) == Array(1...8))

        eighth.setTabOrderingMode(.created)
        eighth.setTabGroupingMode(.project)
        let projectGroups = organizer.groups(
            tabs: eighth.tabControllers,
            grouping: .project,
            ordering: .manual
        )
        #expect(projectGroups.count == 3)
        #expect(projectGroups.map { $0.tabs.count } == [2, 3, 3])
        let collapsedGroup = projectGroups[0]
        let activeGroup = projectGroups[2]
        eighth.tabLayoutState.toggleGroup(collapsedGroup.id)
        eighth.tabLayoutState.toggleGroup(activeGroup.id)
        #expect(eighth.tabLayoutState.collapsedGroupIDs.contains(collapsedGroup.id))
        #expect(eighth.tabLayoutState.collapsedGroupIDs.contains(activeGroup.id))
        #expect(controllers.map { $0.surfaceTree.first?.id } == surfaceIDs)

        let dateGroups = organizer.groups(
            tabs: controllers,
            grouping: .date,
            ordering: .created
        )
        #expect(dateGroups.count == 1)
        #expect(dateGroups[0].title == "Today")

        eighth.setTabOrderingMode(.recentlyUsed)
        for index in 0..<40 {
            let target = controllers[index.isMultiple(of: 2) ? 0 : 1]
            eighth.selectVerticalTab(target)
            await Task.yield()
            #expect(tabGroup.selectedWindow === target.window)
        }
        eighth.selectVerticalTab(controllers[2])
        controllers[2].markTabActivated()
        for _ in 0..<50 where tabGroup.windows.first !== controllers[2].window {
            try await Task.sleep(for: .milliseconds(2))
        }
        let recent = organizer.groups(
            tabs: eighth.tabControllers,
            grouping: .none,
            ordering: .manual
        )
        #expect(recent[0].tabs.first?.controller === controllers[2])
        #expect(recent[0].tabs.first?.actualIndex == 1)
        #expect(controllers[2].tabShortcutLabel(for: 1)?.contains("1") == true)

        let restoredOrganization = VerticalTabWindowLayoutState(isSidebarVisible: true)
        #expect(restoredOrganization.groupingMode == .project)
        #expect(restoredOrganization.orderingMode == .recentlyUsed)

        settings.groupingMode = .date
        settings.orderingMode = .manual
        try await Task.sleep(for: .milliseconds(50))
        #expect(eighth.tabLayoutState.groupingMode == .date)
        #expect(eighth.tabLayoutState.orderingMode == .manual)
        settings.groupingMode = .project
        settings.orderingMode = .recentlyUsed
        try await Task.sleep(for: .milliseconds(50))
        #expect(eighth.tabLayoutState.groupingMode == .project)
        #expect(eighth.tabLayoutState.orderingMode == .recentlyUsed)

        eighth.selectVerticalTab(eighth)
        eighth.setSidebarVisible(true)
        #expect(controllers.allSatisfy { $0.sidebarIsShowing })
        let contentViewID = ObjectIdentifier(try #require(eighth.window?.contentView))
        let surfaceObjectIDs = controllers.compactMap { controller in
            controller.surfaceTree.first.map(ObjectIdentifier.init)
        }

        eighth.updateSidebarWidth(100, persist: false)
        try await Task.sleep(for: .milliseconds(30))
        #expect(controllers.allSatisfy {
            $0.sidebarWidth == VerticalTabSidebarMetrics.minimumWidth
        })
        eighth.updateSidebarWidth(1_000, persist: false)
        try await Task.sleep(for: .milliseconds(30))
        #expect(controllers.allSatisfy {
            $0.sidebarWidth <= VerticalTabSidebarMetrics.maximumWidth
        })

        let resizeCount = eighth.tabLayoutState.appliedResizeCount
        for step in 0..<300 {
            eighth.updateSidebarWidth(CGFloat(180 + (step % 171)), persist: false)
        }
        try await Task.sleep(for: .milliseconds(80))
        #expect(eighth.tabLayoutState.appliedResizeCount - resizeCount <= 5)

        let hiddenSurfaceSizes = controllers.dropLast().map(surfaceSize)
        var startWidth = eighth.sidebarWidth
        for targetWidth in [CGFloat(220), 350, 180, 300] {
            for tick in 1...150 {
                let progress = CGFloat(tick) / 150
                eighth.updateSidebarWidth(
                    startWidth + (targetWidth - startWidth) * progress,
                    persist: false
                )
                try await Task.sleep(for: .milliseconds(8))
            }
            try await Task.sleep(for: .milliseconds(30))
            try capture(
                window: try #require(eighth.window),
                path: "/tmp/oh-my-ghostty-resize-\(Int(targetWidth)).png"
            )
            startWidth = targetWidth
        }
        #expect(controllers.dropLast().map(surfaceSize) == hiddenSurfaceSizes)

        eighth.updateSidebarWidth(340, persist: true)
        #expect(controllers.allSatisfy { $0.sidebarWidth == 340 })
        #expect(VerticalTabSidebarMetrics.persistedWidth != 340)
        #expect(ObjectIdentifier(try #require(eighth.window?.contentView)) == contentViewID)
        #expect(controllers.compactMap { $0.surfaceTree.first.map(ObjectIdentifier.init) } == surfaceObjectIDs)
        #expect(controllers.map { $0.surfaceTree.first?.id } == surfaceIDs)
        try await Task.sleep(for: .milliseconds(300))
        #expect(VerticalTabSidebarMetrics.persistedWidth == 340)
        let resizedSurfaceSizes = controllers.map(surfaceSize)
        for index in switchOrder {
            eighth.selectVerticalTab(controllers[index])
            #expect(controllers.allSatisfy { $0.sidebarWidth == 340 })
        }
        #expect(controllers.map(surfaceSize) == resizedSurfaceSizes)

        eighth.setSidebarVisible(true)
        eighth.toggleSidebar(nil)
        #expect(controllers.allSatisfy { !$0.sidebarIsShowing })
        eighth.toggleSidebar(nil)
        #expect(controllers.allSatisfy { $0.sidebarIsShowing })

        let restoredController = TerminalController(
            appDelegate.ghostty,
            withBaseConfig: configuration(title: "restored-width")
        )
        #expect(restoredController.tabLayout == .vertical)
        #expect(restoredController.sidebarWidth == 340)
        #expect(mockStatus.report(
            sessionID: restoredController.tabSessionID,
            state: .working
        ) == nil)
        #expect(appDelegate.tabActivities.activity(
            for: restoredController.tabSessionID
        )?.state == .working)
        restoredController.windowWillClose(.init(
            name: NSWindow.willCloseNotification,
            object: restoredController.window
        ))
        #expect(appDelegate.tabActivities.activity(
            for: restoredController.tabSessionID
        ) == nil)
        restoredController.window?.delegate = nil
        restoredController.window?.close()

        eighth.setTabGroupingMode(.project)
        eighth.setTabOrderingMode(.created)
        #expect(mockStatus.report(
            sessionID: eighth.tabSessionID,
            state: .working,
            message: "Mock agent is working"
        ) == nil)
        try await Task.sleep(for: .milliseconds(300))
        try capture(window: try #require(eighth.window), path: groupsScreenshotPath)
        #expect(mockStatus.report(sessionID: eighth.tabSessionID, state: .idle) == nil)

        eighth.setTabGroupingMode(.none)
        eighth.setTabOrderingMode(.manual)
        eighth.setVerticalTabHovered(controllers[2], hovered: true)
        try await Task.sleep(for: .milliseconds(1_200))
        try capture(window: try #require(eighth.window), path: hoverScreenshotPath)

        eighth.setSidebarVisible(false)
        #expect(controllers.allSatisfy { !$0.sidebarIsShowing })
        #expect(controllers.allSatisfy { $0.sidebarWidth == 340 })
        #expect((eighth.window as? VerticalTabsTerminalWindow)?.sidebarToggleIsInstalled == true)
        #expect(controllers.map { $0.surfaceTree.first?.id } == surfaceIDs)
        try await Task.sleep(for: .milliseconds(1_200))
        try capture(window: try #require(eighth.window), path: hiddenScreenshotPath)

        eighth.setSidebarVisible(true)
        #expect(controllers.allSatisfy { $0.sidebarIsShowing })
        #expect(controllers.allSatisfy { $0.sidebarWidth == 340 })
        try await Task.sleep(for: .milliseconds(1_200))
        let rapidToggleSurfaceSizes = controllers.map(surfaceSize)
        let rapidToggleInspectorVisible = eighth.tabLayoutState.isInspectorVisible

        for _ in 0..<4 {
            eighth.setSidebarVisible(false)
            try await Task.sleep(for: .milliseconds(40))
            eighth.setSidebarVisible(true)
            try await Task.sleep(for: .milliseconds(40))
            eighth.toggleInspectorPane()
            try await Task.sleep(for: .milliseconds(40))
            eighth.toggleInspectorPane()
            try await Task.sleep(for: .milliseconds(40))
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(eighth.sidebarIsShowing)
        #expect(eighth.tabLayoutState.isInspectorVisible == rapidToggleInspectorVisible)
        #expect(controllers.map(surfaceSize) == rapidToggleSurfaceSizes)

        try await applyConfig(
            "macos-tab-layout = vertical\nbackground = #f3f3f3\nforeground = #202020\n",
            at: configURL,
            app: appDelegate.ghostty
        )
        for _ in 0..<20 where !NSColor(eighth.terminalBackgroundColor).isLightColor {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(NSColor(eighth.terminalBackgroundColor).isLightColor)
        let lightDividerColor = NSColor(eighth.sidebarDividerColor)
        let expectedLightDividerColor = NSColor(
            appDelegate.ghostty.config.splitDividerColor(
                for: eighth.terminalBackgroundColor
            )
        )
        #expect(lightDividerColor.distance(to: expectedLightDividerColor) < 0.001)
        #expect(lightDividerColor.alphaComponent == 1)
        #expect(lightDividerColor.luminance > initialDividerColor.luminance)
        try capture(window: try #require(eighth.window), path: lightScreenshotPath)

        try await applyConfig(
            """
            macos-tab-layout = vertical
            macos-titlebar-style = transparent
            background = #161821
            foreground = #c6d0f5
            background-opacity = 0.58
            background-blur = 20
            """,
            at: configURL,
            app: appDelegate.ghostty
        )
        for _ in 0..<20 where abs(eighth.terminalBackgroundOpacity - 0.58) > 0.001 {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(abs(eighth.terminalBackgroundOpacity - 0.58) < 0.001)
        let transparentDividerColor = NSColor(eighth.sidebarDividerColor)
        let expectedTransparentDividerColor = NSColor(
            appDelegate.ghostty.config.splitDividerColor(
                for: eighth.terminalBackgroundColor
            )
        )
        #expect(transparentDividerColor.distance(to: expectedTransparentDividerColor) < 0.001)
        #expect(transparentDividerColor.alphaComponent == 1)
        #expect(transparentDividerColor.distance(to: lightDividerColor) > 0.1)
        // The Sidebar is AppKit/SwiftUI content and cacheDisplay returns its
        // composited alpha reliably. CAMetalLayer may expose a stale opaque
        // drawable while offscreen or under load, so terminal alpha is asserted
        // through the live renderer-derived property above instead of a flaky
        // bitmap sample.
        let sidebarAlpha = try await settledScreenshotAlpha(
            window: try #require(eighth.window),
            path: transparencyVerticalScreenshotPath,
            points: [CGPoint(x: 0.1, y: 0.5)],
            target: 0.58
        )
        #expect(sidebarAlpha.allSatisfy { abs($0 - 0.58) < 0.01 })

        let appearanceSurface = try #require(eighth.focusedSurface)
        let initialCellSize = appearanceSurface.cellSize

        settings.fontSizeOverride = 19
        settings.backgroundOpacityOverride = 0.42
        settings.windowThemeOverride = .dark
        for _ in 0..<30 where
            abs(eighth.terminalBackgroundOpacity - 0.42) > 0.001 ||
                appearanceSurface.cellSize == initialCellSize ||
                eighth.window?.effectiveAppearance.isDark != true {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(abs(eighth.terminalBackgroundOpacity - 0.42) < 0.001)
        #expect(appearanceSurface.cellSize != initialCellSize)
        #expect(eighth.window?.effectiveAppearance.isDark == true)

        settings.windowThemeOverride = .light
        for _ in 0..<20 where eighth.window?.effectiveAppearance.isDark != false {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(eighth.window?.effectiveAppearance.isDark == false)

        settings.windowThemeOverride = .system
        for _ in 0..<20 where eighth.window?.appearance != nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(eighth.window?.appearance == nil)

        settings.fontSizeOverride = nil
        settings.backgroundOpacityOverride = nil
        settings.windowThemeOverride = nil
        try await Task.sleep(for: .milliseconds(300))

        eighth.newVerticalTab()
        try await Task.sleep(for: .milliseconds(300))
        eighth.refreshTabState()
        let ninth = try #require(eighth.tabControllers.last)
        controllers.append(ninth)
        #expect(tabGroup.windows.count == 9)
        #expect(ninth.sidebarWidth == 340)
        #expect((ninth.window as? VerticalTabsTerminalWindow)?.nativeTabBarIsSuppressed == true)
        eighth.closeVerticalTab(ninth)
        try await Task.sleep(for: .milliseconds(200))
        #expect(tabGroup.windows.count == 8)

        eighth.closeVerticalTab(controllers[1])
        try await Task.sleep(for: .milliseconds(200))
        #expect(tabGroup.windows.count == 7)

        settings.tabLayout = .horizontal
        try await applyConfig(
            """
            macos-tab-layout = horizontal
            macos-titlebar-style = transparent
            background = #161821
            foreground = #c6d0f5
            background-opacity = 0.58
            background-blur = 20
            """,
            at: configURL,
            app: appDelegate.ghostty
        )
        let horizontalFirst = TerminalController(
            appDelegate.ghostty,
            withBaseConfig: configuration(title: "horizontal-a")
        )
        horizontalFirst.titleOverride = "horizontal-a"
        let horizontalWindow = try #require(horizontalFirst.window)
        let horizontalSecond = try #require(TerminalController.newTab(
            appDelegate.ghostty,
            from: horizontalWindow,
            withBaseConfig: configuration(title: "horizontal-b")
        ))
        horizontalSecond.titleOverride = "horizontal-b"
        let horizontalThird = try #require(TerminalController.newTab(
            appDelegate.ghostty,
            from: horizontalSecond.window,
            withBaseConfig: configuration(title: "horizontal-c")
        ))
        horizontalThird.titleOverride = "horizontal-c"
        let horizontalControllers = [horizontalFirst, horizontalSecond, horizontalThird]
        defer {
            for controller in horizontalControllers {
                controller.window?.delegate = nil
                controller.window?.close()
            }
        }
        try await settle(horizontalControllers)
        let nativeWindow = try #require(horizontalThird.window as? TerminalWindow)
        #expect(horizontalThird.tabLayout == .horizontal)
        #expect(!(nativeWindow is VerticalTabsTerminalWindow))
        #expect(horizontalThird.window?.tabGroup?.windows.count == 3)
        #expect(nativeWindow.tabBarView != nil || nativeWindow.titlebarAccessoryViewControllers.contains {
            nativeWindow.isTabBar($0)
        })
        #expect(nativeWindow.inspectorToggleIsInstalled)
        horizontalThird.toggleInspectorPane()
        try await Task.sleep(for: .milliseconds(200))
        #expect(horizontalControllers.allSatisfy { $0.tabLayoutState.isInspectorVisible })
        #expect(horizontalThird.tabLayoutState.inspectorWidth == 380)
        #expect(nativeWindow.tabBarView != nil || nativeWindow.titlebarAccessoryViewControllers.contains {
            nativeWindow.isTabBar($0)
        })
        horizontalThird.toggleInspectorPane()
        #expect(horizontalControllers.allSatisfy {
            abs($0.terminalBackgroundOpacity - 0.58) < 0.001
        })
        try capture(window: nativeWindow, path: horizontalScreenshotPath)
        try capture(window: nativeWindow, path: transparencyHorizontalScreenshotPath)

        settings.tabLayout = .vertical
        settings.groupingMode = .project
        settings.orderingMode = .manual
        let settingsItem = try #require(menuItem(withKeyEquivalent: ",", in: NSApp.mainMenu))
        #expect(settingsItem.action == #selector(AppDelegate.openSettings(_:)))
        #expect(NSApp.sendAction(settingsItem.action!, to: settingsItem.target, from: settingsItem))
        try await Task.sleep(for: .milliseconds(300))
        let expectedSettingsTitle = SettingsStrings(language: settings.language).windowTitle
        let settingsWindow = try #require(NSApp.windows.first { $0.title == expectedSettingsTitle })
        #expect(settingsWindow.isVisible)
        try capture(window: settingsWindow, path: settingsScreenshotPath)
        settingsWindow.close()

        let appearanceSettingsController = OhMyGhosttySettingsWindowController(
            settings: settings,
            initialSelection: .appearance
        )
        let appearanceSettingsWindow = try #require(appearanceSettingsController.window)
        appearanceSettingsWindow.setContentSize(NSSize(width: 820, height: 640))
        appearanceSettingsWindow.makeKeyAndOrderFront(nil)

        settings.windowThemeOverride = .light
        try await Task.sleep(for: .milliseconds(300))
        #expect(appearanceSettingsWindow.effectiveAppearance.isDark == false)
        try capture(
            window: appearanceSettingsWindow,
            path: appearanceSettingsLightScreenshotPath
        )

        settings.windowThemeOverride = .dark
        try await Task.sleep(for: .milliseconds(300))
        #expect(appearanceSettingsWindow.effectiveAppearance.isDark)
        try capture(
            window: appearanceSettingsWindow,
            path: appearanceSettingsScreenshotPath
        )

        settings.windowThemeOverride = .system
        try await Task.sleep(for: .milliseconds(100))
        #expect(appearanceSettingsWindow.appearance == nil)
        settings.windowThemeOverride = nil
        appearanceSettingsWindow.close()
    }

    private func terminalCompletionInputs() throws -> [(Ghostty.SurfaceView) -> Void] {
        let mouse = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        let key = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ))
        return [
            { $0.mouseDown(with: mouse) },
            { $0.keyDown(with: key) },
        ]
    }

    private func terminalScrollInput() throws -> (Ghostty.SurfaceView) -> Void {
        let scroll = try #require(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: 1,
            wheel2: 0,
            wheel3: 0
        ).flatMap(NSEvent.init(cgEvent:)))
        return { $0.scrollWheel(with: scroll) }
    }

    private func menuItem(withAction action: Selector, in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        for item in menu.items {
            if item.action == action { return item }
            if let nested = menuItem(withAction: action, in: item.submenu) {
                return nested
            }
        }
        return nil
    }

    private func menuItem(withKeyEquivalent key: String, in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        for item in menu.items {
            if item.keyEquivalent == key { return item }
            if let nested = menuItem(withKeyEquivalent: key, in: item.submenu) {
                return nested
            }
        }
        return nil
    }

    private func applyConfig(
        _ text: String,
        at url: URL,
        app: Ghostty.App
    ) async throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
        app.reloadConfig()
        try await Task.sleep(for: .milliseconds(200))
    }

    private func surfaceSize(_ controller: TerminalController) -> String? {
        guard let size = controller.focusedSurface?.surfaceSize else { return nil }
        return "\(size.columns)x\(size.rows)"
    }

    private func configuration(title: String) -> Ghostty.SurfaceConfiguration {
        let project = switch title {
        case "project-a", "project-b": "project-a"
        case "project-c", "quant-research", "maka-agent": "oh-my-ghostty"
        case "infra-tools", "research-notes", "oh-my-ghostty": "quant-research-platform"
        default: "horizontal-tabs"
        }
        let projectDirectory = "/tmp/oh-my-ghostty-tabs/projects/\(project)"
        let directory = if title == "project-a" || title == "project-b" {
            "\(projectDirectory)/shared"
        } else {
            "\(projectDirectory)/\(title)"
        }
        try? FileManager.default.createDirectory(
            atPath: "\(projectDirectory)/.git",
            withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            atPath: "\(directory)/Sources",
            withIntermediateDirectories: true
        )
        try? "demo".write(
            toFile: "\(directory)/README.md",
            atomically: true,
            encoding: .utf8
        )
        try? "print(\"demo\")".write(
            toFile: "\(directory)/Sources/main.swift",
            atomically: true,
            encoding: .utf8
        )
        var configuration = Ghostty.SurfaceConfiguration()
        configuration.workingDirectory = directory
        configuration.environmentVariables["TAB_MARKER"] = title
        return configuration
    }

    private func settle(_ controllers: [TerminalController]) async throws {
        try await Task.sleep(for: .milliseconds(500))
        for controller in controllers {
            controller.refreshTabState()
        }
        try await Task.sleep(for: .milliseconds(150))
    }

    /// Captures and measures screenshot alpha repeatedly until it settles on
    /// the expected composited value. The terminal's Metal layer may need a few
    /// frames to present a new background-opacity, so a single-shot capture can
    /// observe a stale opaque frame when the window is occluded or mid-reload.
    private func settledScreenshotAlpha(
        window: NSWindow,
        path: String,
        points: [CGPoint],
        target: CGFloat
    ) async throws -> [CGFloat] {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(100))
        var alpha: [CGFloat] = []
        for _ in 0..<30 {
            try capture(window: window, path: path)
            alpha = try screenshotAlpha(at: points, path: path)
            if alpha.allSatisfy({ abs($0 - target) < 0.01 }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        return alpha
    }

    private func screenshotAlpha(at points: [CGPoint], path: String) throws -> [CGFloat] {

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let image = try #require(NSBitmapImageRep(data: data))
        return try points.map { point in
            let x = Int(CGFloat(image.pixelsWide - 1) * point.x)
            let y = Int(CGFloat(image.pixelsHigh - 1) * point.y)
            return try #require(image.colorAt(x: x, y: y)?.alphaComponent)
        }
    }

    private func capture(window: NSWindow, path: String) throws {
        let view = try #require(window.contentView?.superview)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let representation = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: representation)
        let data = try #require(representation.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path))
    }
}
