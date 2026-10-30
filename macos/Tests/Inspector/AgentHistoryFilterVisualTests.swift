import AppKit
import Testing
@testable import Ghostty

@MainActor
struct AgentHistoryFilterVisualTests {
    @Test func nativeFilterRestoresCompactRowsChipsAndSideBySideOrganization() throws {
        let sessions = sessionsByAgent()
        var filter = AgentHistoryFilterState()
        filter.directory = .currentTree
        filter.time = .quarter
        filter.grouping = .agent
        let agents = Array(SupportedAgent.allCases.prefix(9))
        let controller = AgentHistoryFilterController()
        var published: [AgentHistoryFilterState] = []
        controller.onChange = { published.append($0); filter = $0 }
        controller.update(sessions: sessions, agents: agents,
                          filter: filter, strings: .init(language: .simplifiedChinese),
                          currentDirectory: "/repo/project")

        let size = controller.preferredContentSize
        #expect(size.width == 320)
        #expect(size.height >= 340 && size.height <= 480)
        controller.view.frame = NSRect(origin: .zero, size: size)
        controller.view.layoutSubtreeIfNeeded()

        let allAgents = try #require(controller.choiceButtonForTesting(.agent, ""))
        #expect(allAgents.frame.height == 24)
        #expect(try #require(controller.choiceButtonForTesting(.time, "month")).frame.height == 22)
        #expect((allAgents.accessibilityLabel() as? String)?.contains("12") == true)
        let claude = try #require(controller.agentButtonForTesting(.claude))
        #expect((claude.accessibilityLabel() as? String)?.contains("8") == true)
        let asset = try #require(NSImage(named: SupportedAgent.claude.assetName))
        let icon = try #require(find(NSImageView.self, in: claude).first { $0.image === asset })
        #expect(icon.frame.width == 14 && icon.imageScaling == .scaleProportionallyUpOrDown)
        let scroll = try #require(controller.filterControlsForTesting[.agent] as? NSScrollView)
        let document = try #require(scroll.documentView)
        #expect(document.isFlipped)
        #expect(document.frame.height > scroll.contentSize.height)
        let firstAgent = try #require(controller.agentButtonForTesting(agents[0]))
        #expect(scroll.documentVisibleRect.intersects(firstAgent.frame))
        #expect(controller.directoryHintForTesting.stringValue == "project")
        #expect(!controller.directoryHintForTesting.isHidden)

        let directory = try #require(controller.choiceButtonForTesting(.directory, "currentTree"))
        directory.performClick(nil)
        #expect(published.last?.directory == .currentTree)
        controller.update(sessions: sessions, agents: agents, filter: filter,
                          strings: .init(language: .simplifiedChinese), currentDirectory: "/repo/project")
        let ordering = try #require(controller.choiceButtonForTesting(.ordering, "title"))
        ordering.performClick(nil)
        #expect(published.last?.ordering == .title)
        controller.update(sessions: sessions, agents: agents, filter: filter,
                          strings: .init(language: .simplifiedChinese), currentDirectory: "/repo/project")
        #expect(controller.resetControlForTesting.isEnabled)

        if FileManager.default.fileExists(atPath: "/tmp/omg-native-visual-review") {
            try render(controller, appearance: .aqua, to: "/tmp/omg-agent-filter-light.png")
            try render(controller, appearance: .darkAqua, to: "/tmp/omg-agent-filter-dark.png")
        }
    }

    @Test func missingCurrentDirectoryDisablesOnlyThatChip() throws {
        let controller = AgentHistoryFilterController()
        controller.update(sessions: sessionsByAgent(), agents: [.claude],
                          filter: .init(), strings: .init(language: .simplifiedChinese),
                          currentDirectory: nil)
        let any = try #require(controller.choiceButtonForTesting(.directory, "any"))
        let current = try #require(controller.choiceButtonForTesting(.directory, "currentTree"))
        #expect(any.isEnabled)
        #expect(!current.isEnabled)
        var state = AgentHistoryFilterState()
        controller.onChange = { state = $0 }
        controller.apply("claude", to: .agent)
        #expect(state.agent == .claude)
    }

    private func sessionsByAgent() -> [AgentHistorySession] {
        let agents: [(SupportedAgent, Int)] = [(.claude, 8), (.pi, 4)]
        return agents.flatMap { agent, count in
            (0..<count).map { index in
                AgentHistorySession(
                    agent: agent,
                    conversationID: AgentConversationID("\(agent.rawValue)-filter-\(index)")!,
                    title: "\(agent.displayName) \(index)",
                    workingDirectory: "/repo/project",
                    updatedAt: Date(),
                    sourcePath: "/tmp/\(agent.rawValue)-\(index).jsonl",
                    isActive: false
                )
            }
        }
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { find(type, in: $0) }
    }

    private func render(_ controller: AgentHistoryFilterController, appearance: NSAppearance.Name,
                        to path: String) throws {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: controller.preferredContentSize),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentViewController = controller
        controller.configurePopoverAppearance(
            window.appearance ?? NSApp.effectiveAppearance,
            background: appearance == .darkAqua
                ? NSColor(calibratedWhite: 0.15, alpha: 1)
                : NSColor(calibratedWhite: 0.96, alpha: 1)
        )
        window.makeKeyAndOrderFront(nil)
        defer { window.contentViewController = nil; window.close() }
        controller.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path))
    }
}
