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

    @MainActor @Test func physicalBackquoteUsesCurrentKeyboardLayout() throws {
        let config = try TemporaryConfig("keybind=super+backquote=toggle_quick_terminal")
        let expected = try #require(KeyboardLayout.character(for: 0x32, modifiers: .command))
        let item = NSMenuItem(title: "Quick Terminal", action: nil, keyEquivalent: "")
        let manager = Ghostty.MenuShortcutManager()

        manager.reset()
        manager.syncMenuShortcut(config, action: "toggle_quick_terminal", menuItem: item)

        #expect(item.keyEquivalent == String(expected))
        #expect(item.keyEquivalentModifierMask == .command)
        #expect(!item.allowsAutomaticKeyEquivalentLocalization)
        #expect(!item.allowsAutomaticKeyEquivalentMirroring)
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

    /// The full restore cycle: an unbound action loses its shortcut on sync, gets the
    /// xib default back on restore, and loses it again on re-sync.
    @Test func restoreAndReSyncRestorableItem() async throws {
        let config = try TemporaryConfig("keybind = super+c=unbind")

        let item = NSMenuItem(title: "Copy", action: "copy:", keyEquivalent: "c")
        item.keyEquivalentModifierMask = .command

        let manager = await Ghostty.MenuShortcutManager()
        await manager.saveRestorableMenuItem(item, action: "copy_to_clipboard")
        await manager.syncMenuShortcut(config, action: "copy_to_clipboard", menuItem: item)

        #expect(item.keyEquivalent.isEmpty)
        #expect(item.keyEquivalentModifierMask.isEmpty)

        // A non-terminal responder takes focus: the xib default comes back.
        await manager.restoreMenuShortcuts()
        #expect(item.keyEquivalent == "c")
        #expect(item.keyEquivalentModifierMask == .command)

        // A terminal surface regains focus: the config wins again.
        await manager.reSyncRestoredMenuShortcuts(config: config)
        #expect(item.keyEquivalent.isEmpty)
        #expect(item.keyEquivalentModifierMask.isEmpty)
    }

    /// Restoring more than once must not orphan restored shortcuts: a later re-sync
    /// still has to bring items back to their configured state.
    @Test func restoreIsIdempotent() async throws {
        let config = try TemporaryConfig("keybind = super+c=unbind")

        let item = NSMenuItem(title: "Copy", action: "copy:", keyEquivalent: "c")
        item.keyEquivalentModifierMask = .command

        let manager = await Ghostty.MenuShortcutManager()
        await manager.saveRestorableMenuItem(item, action: "copy_to_clipboard")
        await manager.syncMenuShortcut(config, action: "copy_to_clipboard", menuItem: item)

        await manager.restoreMenuShortcuts()
        await manager.restoreMenuShortcuts()

        await manager.reSyncRestoredMenuShortcuts(config: config)
        #expect(item.keyEquivalent.isEmpty)
        #expect(item.keyEquivalentModifierMask.isEmpty)
    }

    /// Restore must never overwrite a shortcut the user configured themselves, and
    /// re-sync must leave such items untouched.
    @Test func restoreKeepsConfiguredShortcut() async throws {
        let config = try TemporaryConfig("""
        keybind = super+c=unbind
        keybind = super+shift+c=copy_to_clipboard
        """)

        let item = NSMenuItem(title: "Copy", action: "copy:", keyEquivalent: "c")
        item.keyEquivalentModifierMask = .command

        let manager = await Ghostty.MenuShortcutManager()
        await manager.saveRestorableMenuItem(item, action: "copy_to_clipboard")
        await manager.syncMenuShortcut(config, action: "copy_to_clipboard", menuItem: item)

        #expect(item.keyEquivalent == "c")
        #expect(item.keyEquivalentModifierMask == [.command, .shift])

        await manager.restoreMenuShortcuts()
        #expect(item.keyEquivalent == "c")
        #expect(item.keyEquivalentModifierMask == [.command, .shift])

        await manager.reSyncRestoredMenuShortcuts(config: config)
        #expect(item.keyEquivalent == "c")
        #expect(item.keyEquivalentModifierMask == [.command, .shift])
    }

    /// Two items that share the same default shortcut are both restorable. The previous
    /// storage was keyed by shortcut, which silently dropped all but the last item.
    @Test func restorableItemsMayShareOriginalShortcut() async throws {
        let config = try TemporaryConfig("")

        let firstItem = NSMenuItem(title: "First", action: "first:", keyEquivalent: "z")
        firstItem.keyEquivalentModifierMask = .command

        let secondItem = NSMenuItem(title: "Second", action: "second:", keyEquivalent: "z")
        secondItem.keyEquivalentModifierMask = .command

        let manager = await Ghostty.MenuShortcutManager()
        await manager.saveRestorableMenuItem(firstItem, action: nil)
        await manager.saveRestorableMenuItem(secondItem, action: nil)

        // Items without a Ghostty action are always cleared on sync.
        await manager.syncMenuShortcut(config, action: nil, menuItem: firstItem)
        await manager.syncMenuShortcut(config, action: nil, menuItem: secondItem)
        #expect(firstItem.keyEquivalent.isEmpty)
        #expect(secondItem.keyEquivalent.isEmpty)

        await manager.restoreMenuShortcuts()
        #expect(firstItem.keyEquivalent == "z")
        #expect(firstItem.keyEquivalentModifierMask == .command)
        #expect(secondItem.keyEquivalent == "z")
        #expect(secondItem.keyEquivalentModifierMask == .command)
    }
}
