import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct GitSidebarNavigationNativeTests {
    @Test func segmentControlSelectsRepositorySections() async throws {
        var selected: InspectorGitContent.ActiveTab = .history
        let host = NSHostingView(rootView: GitSidebarNavigation(selected: .history) { selected = $0 })
        host.sizingOptions = []
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 320, height: 28),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(60))
        host.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> GitPopoverSegments? {
            view as? GitPopoverSegments ?? view.subviews.compactMap(find).first
        }
        let segments = try #require(find(host))
        #expect(segments.buttonsForTesting.count == InspectorGitContent.ActiveTab.allCases.count)
        let branchIndex = try #require(InspectorGitContent.ActiveTab.allCases.firstIndex(of: .branches))
        segments.buttonsForTesting[branchIndex].performClick(nil)
        #expect(selected == .branches)
        #expect(segments.buttonsForTesting[branchIndex].state == .on)
        #expect(segments.bounds.width <= host.bounds.width)
        segments.layoutSubtreeIfNeeded()
        let last = try #require(segments.buttonsForTesting.last)
        #expect(abs(last.convert(last.bounds, to: segments).maxX - segments.bounds.maxX + 1) < 1)
    }
}
