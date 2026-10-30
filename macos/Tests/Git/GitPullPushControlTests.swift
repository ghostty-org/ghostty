import AppKit
import Testing
@testable import Ghostty

@MainActor
struct GitPullPushControlTests {
    @Test func nativeMenuPreservesAvailabilityAndOpenedRepositoryAction() throws {
        let control = GitPullPushControl.Control(frame: .zero)
        var actions: [InspectorGitAction] = []
        let original = GitPullPushControl(
            isBusy: false,
            canPull: true,
            canPush: false,
            canPushTo: true,
            canMerge: false,
            behindCount: 3,
            aheadCount: 0
        ) { actions.append($0) }
        control.configure(original)
        let menu = control.makeMenu()
        #expect(!menu.autoenablesItems)
        #expect(menu.items.count == 5)
        #expect(menu.items[0].isEnabled)
        #expect(menu.items[0].title.contains("3"))
        #expect(!menu.items[1].isEnabled)
        #expect(menu.items[2].isSeparatorItem)
        #expect(menu.items[3].isEnabled)
        #expect(!menu.items[4].isEnabled)

        control.configure(GitPullPushControl(
            isBusy: false,
            canPull: true,
            canPush: true,
            canPushTo: true,
            canMerge: true,
            behindCount: 0,
            aheadCount: 5
        ) { _ in Issue.record("An open menu must keep the action context it was created with.") })

        let item = try #require(menu.items.first)
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        #expect(actions == [.pull])
    }
}
