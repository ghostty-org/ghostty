import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct SettingsLayoutTests {
    @Test func settingsUseWideWindowAndAgentRowsFitNarrowAndWideForms() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "SettingsLayoutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: home)
            defaults.removePersistentDomain(forName: suite)
        }
        let settings = OhMyGhosttySettings(fileURL: home.appendingPathComponent("settings.json"))
        settings.language = .simplifiedChinese
        var snapshot = AgentIntegrationSnapshot()
        for agent in SupportedAgent.allCases {
            snapshot.hooks[agent] = .current
            snapshot.cli[agent] = .init(version: "1.2.3", path: "/usr/local/bin/" + agent.rawValue)
        }
        snapshot.hooks[.claude] = .updateAvailable
        snapshot.cli[.codex] = .init(version: "1.2.3", latest: "1.3.0", package: "example", path: "/usr/local/bin/codex")
        let manager = AgentIntegrationManager(defaults: defaults, snapshots: ["local": snapshot], connectionTargets: { [] })
        for width in [CGFloat(450), 1_000] {
            let root = Form {
                AgentIntegrationSettingsView(strings: .init(language: .simplifiedChinese), settings: settings,
                                             manager: manager, refreshOnAppear: false)
            }
            .formStyle(.grouped).environment(\.colorScheme, .dark)
            let host = NSHostingView(rootView: root)
            let window = makeWindow(host, width: width)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            try capture(host, name: "agents-\(Int(width))")
            #expect(host.bounds.width == width)
        }
        let host = NSHostingView(rootView: SettingsView(settings: settings, initialSelection: .appearance)
            .environment(\.colorScheme, .dark))
        let window = makeWindow(host, width: 1_200)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let scrollViews = descendants(of: NSScrollView.self, in: host)
        #expect(scrollViews.contains { $0.frame.width > 900 })
        try capture(host, name: "appearance-wide")
    }

    private func makeWindow(_ content: NSView, width: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 850),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        content.setFrameSize(NSSize(width: width, height: 850))
        return window
    }

    private func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(of: type, in: $0) }
    }

    private func capture(_ view: NSView, name: String) throws {
        let directory = URL(fileURLWithPath: "/tmp/omg-settings-layout")
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
