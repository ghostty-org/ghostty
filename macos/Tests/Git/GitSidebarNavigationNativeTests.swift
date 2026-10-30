import AppKit
import Testing
@testable import Ghostty

@MainActor
struct GitSidebarNavigationNativeTests {
    @Test func segmentControlSelectsRepositorySections() throws {
        var selected: InspectorGitContent.ActiveTab = .history
        let coordinator = GitSidebarNavigation.Coordinator { selected = $0 }
        let control = NSSegmentedControl(
            labels: InspectorGitContent.ActiveTab.allCases.map { $0.rawValue },
            trackingMode: .selectOne,
            target: coordinator,
            action: #selector(GitSidebarNavigation.Coordinator.activate(_:))
        )

        let history = try #require(InspectorGitContent.ActiveTab.allCases.firstIndex(of: .history))
        let branches = try #require(InspectorGitContent.ActiveTab.allCases.firstIndex(of: .branches))
        control.selectedSegment = history
        coordinator.activate(control)
        #expect(selected == .history)

        control.selectedSegment = branches
        coordinator.activate(control)
        #expect(selected == .branches)

        control.selectedSegment = -1
        coordinator.activate(control)
        #expect(selected == .branches)
    }
}
