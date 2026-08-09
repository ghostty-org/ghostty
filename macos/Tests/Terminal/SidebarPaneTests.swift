import Foundation
@testable import Ghostty
import Testing

/// Which panels the sidebar offers, and when it shows a tab bar at all.
///
/// The settings that drive this live in `UserDefaults` rather than
/// `GuiConfigStore` on purpose: an unknown key in `gui-settings` makes the
/// Ghostty core raise a "Configuration Errors" popup, so Phantom-only
/// preferences must never go there.
///
/// `.serialized` is load-bearing, not tidiness: these cases all write the
/// same two global `UserDefaults` keys, and run in parallel they set each
/// other's state out from under themselves.
@Suite(.serialized)
struct SidebarPaneTests {
    /// Wrapped in a saved/restored snapshot: these read the real user
    /// defaults, and a test must not leave the user's panels switched off
    /// behind it.
    private func withPanes(files: Bool?, git: Bool?, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let savedFiles = defaults.object(forKey: "SidebarShowFilesPane")
        let savedGit = defaults.object(forKey: "SidebarShowGitPane")
        defer {
            defaults.set(savedFiles, forKey: "SidebarShowFilesPane")
            defaults.set(savedGit, forKey: "SidebarShowGitPane")
        }

        defaults.set(files, forKey: "SidebarShowFilesPane")
        defaults.set(git, forKey: "SidebarShowGitPane")
        body()
    }

    /// Absent keys mean a fresh install, which gets everything.
    @Test func panesDefaultToEnabled() {
        withPanes(files: nil, git: nil) {
            #expect(SidebarPane.enabled == SidebarPane.allCases)
            #expect(SidebarPane.showsTabBar)
        }
    }

    @Test func aDisabledPaneDropsOutOfTheTabOrder() {
        withPanes(files: false, git: true) {
            #expect(SidebarPane.enabled == [.terminals, .git])
            #expect(SidebarPane.showsTabBar)
        }
    }

    /// With both extras off there is nothing to switch between, so the bar
    /// hides and the sidebar goes back to being the plain terminal list it
    /// started as.
    @Test func turningEveryExtraOffHidesTheTabBar() {
        withPanes(files: false, git: false) {
            #expect(SidebarPane.enabled == [.terminals])
            #expect(!SidebarPane.showsTabBar)
        }
    }

    /// Terminals is the sidebar's reason to exist; the settings UI must
    /// never offer a switch for it.
    @Test func terminalsCannotBeHidden() {
        withPanes(files: false, git: false) {
            #expect(SidebarPane.terminals.isEnabled)
            #expect(!SidebarPane.terminals.canBeHidden)
            #expect(SidebarPane.terminals.defaultsKey == nil)
        }
    }

    @Test func everyHideablePaneHasItsOwnDefaultsKey() {
        let keys = SidebarPane.allCases.compactMap(\.defaultsKey)
        #expect(keys.count == SidebarPane.allCases.filter(\.canBeHidden).count)
        #expect(Set(keys).count == keys.count)
    }

    /// Git ships its own artwork instead of an SF Symbol, so the tab bar
    /// has to go through `SidebarPaneIcon` rather than reading `symbol`
    /// directly — a nil here is the contract that keeps it honest.
    @Test func gitIsTheOnlyPaneWithoutASymbol() {
        #expect(SidebarPane.git.symbol == nil)
        #expect(SidebarPane.terminals.symbol != nil)
        #expect(SidebarPane.files.symbol != nil)
    }
}
