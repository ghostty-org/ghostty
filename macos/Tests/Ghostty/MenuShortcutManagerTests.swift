import AppKit
import Foundation
import Testing
@testable import Ghostty

struct MenuShortcutManagerTests {
    @Test(.bug("https://github.com/ghostty-org/ghostty/issues/779", id: 779))
    func unbindShouldDiscardDefault() async throws {
        let config = try TemporaryConfig("keybind = super+d=unbind")

        let item = NSMenuItem(title: "Split Right", action: #selector(BaseTerminalController.splitRight(_:)), keyEquivalent: "d")
        item.keyEquivalentModifierMask = .command
        let manager = await Ghostty.MenuShortcutManager()
        await manager.reset()
        await manager.syncMenuShortcut(config, action: "new_split:right", menuItem: item)

        #expect(item.keyEquivalent.isEmpty)
        #expect(item.keyEquivalentModifierMask.isEmpty)

        try config.reload("")

        await manager.reset()
        await manager.syncMenuShortcut(config, action: "new_split:right", menuItem: item)

        #expect(item.keyEquivalent == "d")
        #expect(item.keyEquivalentModifierMask == .command)
    }

    @Test(.bug("https://github.com/ghostty-org/ghostty/issues/11396", id: 11396))
    func overrideDefault() async throws {
        let config = try TemporaryConfig("keybind=super+h=goto_split:left")

        let hideItem = NSMenuItem(title: "Hide Ghostty", action: "hide:", keyEquivalent: "h")
        hideItem.keyEquivalentModifierMask = .command

        let goToLeftItem = NSMenuItem(title: "Select Split Left", action: "splitMoveFocusLeft:", keyEquivalent: "")

        let manager = await Ghostty.MenuShortcutManager()
        await manager.reset()

        await manager.syncMenuShortcut(config, action: nil, menuItem: hideItem)
        await manager.syncMenuShortcut(config, action: "goto_split:left", menuItem: goToLeftItem)

        #expect(hideItem.keyEquivalent.isEmpty)
        #expect(hideItem.keyEquivalentModifierMask.isEmpty)

        #expect(goToLeftItem.keyEquivalent == "h")
        #expect(goToLeftItem.keyEquivalentModifierMask == .command)
    }

    @Test func disabledMenuKeyEquivalentsClearShortcut() async throws {
        let config = try TemporaryConfig("""
        macos-menu-key-equivalents = false
        keybind = super+n=new_window
        """)

        let item = NSMenuItem(title: "New Window", action: "newWindow:", keyEquivalent: "n")
        item.keyEquivalentModifierMask = .command

        let manager = await Ghostty.MenuShortcutManager()
        await manager.reset()
        await manager.syncMenuShortcut(config, action: "new_window", menuItem: item)

        #expect(item.keyEquivalent.isEmpty)
        #expect(item.keyEquivalentModifierMask.isEmpty)
    }

    @Test func disabledMenuKeyEquivalentsClearSystemShortcut() async throws {
        let menu = NSMenu()
        let hide = NSMenuItem(title: "Hide Ghostty", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.keyEquivalentModifierMask = .command
        menu.addItem(hide)

        let regular = NSMenuItem(title: "Other", action: "other:", keyEquivalent: "o")
        regular.keyEquivalentModifierMask = .command
        menu.addItem(regular)

        let manager = await Ghostty.MenuShortcutManager()
        await manager.syncSystemMenuKeyEquivalents(false, menu: menu)

        #expect(hide.keyEquivalent.isEmpty)
        #expect(hide.keyEquivalentModifierMask.isEmpty)
        #expect(regular.keyEquivalent == "o")
        #expect(regular.keyEquivalentModifierMask == .command)

        await manager.syncSystemMenuKeyEquivalents(true, menu: menu)

        #expect(hide.keyEquivalent == "h")
        #expect(hide.keyEquivalentModifierMask == .command)
    }

    @Test func disabledMenuKeyEquivalentsClearDynamicTabShortcuts() async throws {
        let menu = NSMenu()
        let next = NSMenuItem(title: "Show Next Tab", action: "selectNextTab:", keyEquivalent: "}")
        next.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(next)

        let manager = await Ghostty.MenuShortcutManager()
        await manager.syncSystemMenuKeyEquivalents(false, menu: menu)

        #expect(next.keyEquivalent.isEmpty)
        #expect(next.keyEquivalentModifierMask.isEmpty)
    }

    @Test func disabledMenuKeyEquivalentsClearMinimizeAllShortcut() async throws {
        let menu = NSMenu()
        let minimizeAll = NSMenuItem(
            title: "Minimize All",
            action: #selector(NSApplication.miniaturizeAll(_:)),
            keyEquivalent: "m")
        minimizeAll.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(minimizeAll)

        let manager = await Ghostty.MenuShortcutManager()
        await manager.syncSystemMenuKeyEquivalents(false, menu: menu)

        #expect(minimizeAll.keyEquivalent.isEmpty)
        #expect(minimizeAll.keyEquivalentModifierMask.isEmpty)
    }
}
