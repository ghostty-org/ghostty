import AppKit
import Foundation
import Testing
@testable import Ghostty

struct MenuShortcutManagerTests {
    @Test(.bug("https://github.com/ghostty-org/ghostty/issues/779", id: 779))
    func unbindShouldDiscardDefault() async throws {
        let config = try TemporaryConfig("keybind = super+d=unbind")

        let menu = NSMenu()
        let item = NSMenuItem(title: "Split Right", action: #selector(BaseTerminalController.splitRight(_:)), keyEquivalent: "d")
        item.keyEquivalentModifierMask = .command
        menu.addItem(item)

        let manager = await Ghostty.MenuShortcutManager(menu)
        await manager.resetRegisteredGhosttyActions()
        await manager.register(action: "new_split:right", menuItem: item)

        await manager.updateShortcut(in: menu, config: config)

        #expect(item.keyEquivalent.isEmpty)
        #expect(item.keyEquivalentModifierMask.isEmpty)

        try config.reload("")

        await manager.resetRegisteredGhosttyActions()
        await manager.register(action: "new_split:right", menuItem: item)

        await manager.updateShortcut(in: menu, config: config)

        #expect(item.keyEquivalent == "d")
        #expect(item.keyEquivalentModifierMask == .command)
    }

    @Test(.bug("https://github.com/ghostty-org/ghostty/issues/11396", id: 11396))
    func overrideDefault() async throws {
        let config = try TemporaryConfig("keybind=super+h=goto_split:left")

        let hideItem = NSMenuItem(title: "Hide Ghostty", action: "hide:", keyEquivalent: "h")
        hideItem.keyEquivalentModifierMask = .command

        let goToLeftItem = NSMenuItem(title: "Select Split Left", action: "splitMoveFocusLeft:", keyEquivalent: "")

        let menu = NSMenu()
        [hideItem, goToLeftItem].forEach(menu.addItem)

        let manager = await Ghostty.MenuShortcutManager(menu)
        await manager.resetRegisteredGhosttyActions()

        await manager.register(action: "dummy", menuItem: hideItem)
        await manager.register(action: "goto_split:left", menuItem: goToLeftItem)

        await manager.updateShortcut(in: menu, config: config)

        #expect(hideItem.keyEquivalent.isEmpty)
        #expect(hideItem.keyEquivalentModifierMask.isEmpty)

        #expect(goToLeftItem.keyEquivalent == "h")
        #expect(goToLeftItem.keyEquivalentModifierMask == .command)
    }

    @Test
    func unreferencedItemShouldBeResetIfUnbound() async throws {
        let config = try TemporaryConfig("keybind=super+h=goto_split:left")

        let hideItem = NSMenuItem(title: "Hide Ghostty", action: "hide:", keyEquivalent: "h")
        hideItem.keyEquivalentModifierMask = .command

        let goToLeftItem = NSMenuItem(title: "Select Split Left", action: "splitMoveFocusLeft:", keyEquivalent: "")

        let menu = NSMenu()
        [hideItem, goToLeftItem].forEach(menu.addItem)

        let manager = await Ghostty.MenuShortcutManager(menu)

        await manager.resetRegisteredGhosttyActions()
        await manager.register(action: "goto_split:left", menuItem: goToLeftItem)

        await manager.updateShortcut(in: menu, config: config)

        // Even though hideItem is not register, it should still be cleared out
        #expect(hideItem.keyEquivalent.isEmpty)
        #expect(hideItem.keyEquivalentModifierMask.isEmpty)

        #expect(goToLeftItem.keyEquivalent == "h")
        #expect(goToLeftItem.keyEquivalentModifierMask == .command)

        try config.reload("""
            keybind=super+h=unbind
            keybind=super+l=goto_split:left
            """)
        await manager.resetRegisteredGhosttyActions()
        await manager.register(action: "goto_split:left", menuItem: goToLeftItem)

        await manager.updateShortcut(in: menu, config: config)

        #expect(hideItem.keyEquivalent.isEmpty)
        #expect(hideItem.keyEquivalentModifierMask.isEmpty)

        #expect(goToLeftItem.keyEquivalent == "l")
        #expect(goToLeftItem.keyEquivalentModifierMask == .command)
    }
}
