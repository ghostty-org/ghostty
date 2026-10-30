import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct GitHistoryScopeSegmentsTests {
    private struct Host: View {
        let select: (GitHistoryScope) -> Void
        var body: some View {
            GitHistoryScopeSegments(selectedID: "scope:allBranches", select: select)
        }
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { find(type, in: $0) }
    }

    @Test func nativeSegmentsSelectScope() async throws {
        var selected: GitHistoryScope?
        let host = NSHostingView(rootView: Host { selected = $0 })
        host.sizingOptions = []
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 260, height: 50),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(60))
        host.layoutSubtreeIfNeeded()

        let control = try #require(find(NSSegmentedControl.self, in: host).first)
        #expect(control.segmentCount == GitHistoryScope.allCases.count)
        control.selectedSegment = 0
        #expect(NSApp.sendAction(try #require(control.action), to: control.target, from: control))
        #expect(selected == .currentBranch)
    }
}
