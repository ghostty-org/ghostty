import AppKit
import SwiftUI

extension Ghostty {
    /// The manager that's responsible for updating shortcuts of Ghostty's app menu
    @MainActor
    class MenuShortcutManager {
        /// Ghostty action indexed by the action of their belonging menu item
        private var ghosttyActionsBySelector: [Selector: String] = [:]
        /// Ghostty menu action indexed by their normalized shortcut. This avoids traversing
        /// the entire menu tree on every key equivalent event.
        ///
        /// If multiple action map to the same shortcut, the most recent one wins.
        private var configuredShortcuts: [MenuShortcutKey: Selector] = [:]
        /// Original shortcut configured in xib indexed by their action
        private var originalMenuShortcutByAction: [Selector: MenuShortcutKey] = [:]

        /// Save initial/default keyboard shortcut of every menu item recursively in this menu
        ///
        /// - Important: This should only be called once per app launch
        init(_ menu: NSMenu?) {
            saveOriginalMenuItemShortcutsRecursively(in: menu)
        }

        /// Reset our shortcut index since we're about to rebuild all menu bindings.
        func resetRegisteredGhosttyActions() {
            ghosttyActionsBySelector.removeAll(keepingCapacity: true)
        }

        /// Registers a single menu shortcut for the given action. The action string is the same
        /// action string used for the Ghostty configuration.
        func register(action ghosttyAction: String?, menuItem: NSMenuItem?) {
            guard let selector = menuItem?.action else {
                return
            }
            ghosttyActionsBySelector[selector] = ghosttyAction
        }

        /// Map the keyboard shortcut of every menu item (including submenu's) in this menu based on previously register action
        func updateShortcut(in menu: NSMenu?, config: Ghostty.Config) {
            /// Reset our shortcut index since we're about to rebuild all menu bindings.
            configuredShortcuts.removeAll()

            updateShortcutRecursively(in: menu, config: config)

            checkConflictsRecursively(in: menu)
        }
    }
}

extension Ghostty.MenuShortcutManager {
    /// Attempts to perform a menu key equivalent only for menu items that represent
    /// Ghostty keybind actions. This is important because it lets our surface dispatch
    /// bindings through the menu so they flash but also lets our surface override macOS built-ins
    /// like Cmd+H.
    func performGhosttyBindingMenuKeyEquivalent(with event: NSEvent) -> Bool {
        // Convert this event into the same normalized lookup key we use when
        // syncing menu shortcuts from configuration.
        guard let key = MenuShortcutKey(event: event) else {
            return false
        }

        // If we don't have an entry for this key combo, no Ghostty-owned
        // menu shortcut exists for this event.
        guard let action = configuredShortcuts[key] else {
            return false
        }

        guard let item = NSApp.mainMenu?.findItem(with: action) else {
            return false
        }

        guard let parentMenu = item.menu else {
            return false
        }

        // Keep enablement state fresh in case menu validation hasn't run yet.
        parentMenu.update()
        guard item.isEnabled else {
            return false
        }

        let index = parentMenu.index(of: item)
        guard index >= 0 else {
            return false
        }

        parentMenu.performActionForItem(at: index)
        return true
    }
}

// MARK: - Recursively process all of the menu items

private extension Ghostty.MenuShortcutManager {
    /// Save initial/default keyboard shortcut of every menu item recursively in this menu
    ///
    /// - Important: This should only be called once per app launch
    func saveOriginalMenuItemShortcutsRecursively(in menu: NSMenu?) {
        guard let menu else {
            return
        }
        for item in menu.items {
            if let action = item.action, let shortcut = MenuShortcutKey(keyEquivalent: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask) {
                originalMenuShortcutByAction[action] = shortcut
            }
            saveOriginalMenuItemShortcutsRecursively(in: item.submenu)
        }
    }

    /// Map the keyboard shortcut of every menu item recursively in this menu based on previously register action
    func updateShortcutRecursively(in menu: NSMenu?, config: Ghostty.Config) {
        guard let menu else {
            return
        }

        for item in menu.items {
            updateItemShortcut(item: item, config: config)
            updateShortcutRecursively(in: item.submenu, config: config)
        }
        menu.update()
    }

    /// Shortcuts in Ghostty configuration should have higher priority than default shortcuts
    ///
    /// We run this to do a final check for every menu item
    func checkConflictsRecursively(in menu: NSMenu?) {
        guard let menu else {
            return
        }

        for item in menu.items {
            checkConflicts(item: item)
            checkConflictsRecursively(in: item.submenu)
        }
        menu.update()
    }
}

// MARK: - Process a single menu item

private extension Ghostty.MenuShortcutManager {
    /// Update shortcuts in the following order
    ///
    /// 1. Ghostty configuration
    /// 2. Xib
    /// 3. Remove unbound defined in Ghostty configuration
    /// 4. Check conflicts between xib and Ghostty configuration
    func updateItemShortcut(item: NSMenuItem, config: Ghostty.Config) {
        guard let selector = item.action else {
            return
        }

        if let action = ghosttyActionsBySelector[selector],
            syncMenuShortcutFrom(config, action: action, menuItem: item) {
            // Overrode by Ghostty configuration
            return
        }

        // Restore to the original shortcut first,
        // so we can then use the original one to check whether it's unbound
        restoreMenuItemShortcut(item: item)

        if let key = MenuShortcutKey(item), config.isKeyboardShortcutUnbound(key: key) {
            // This is unbind by the user
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        // Restored to the original shortcut
    }

    /// Syncs a single menu shortcut for the given action. The action string is the same
    /// action string used for the Ghostty configuration.
    func syncMenuShortcutFrom(_ config: Ghostty.Config, action: String, menuItem menu: NSMenuItem) -> Bool {

        guard let shortcut = config.keyboardShortcut(for: action) else {
            return false
        }

        // Build a direct lookup for key-equivalent dispatch so we don't need to
        // linearly walk the full menu hierarchy at event time.
        guard let key = MenuShortcutKey(shortcut) else {
            return false
        }

        menu.keyEquivalent = key.keyEquivalent
        menu.keyEquivalentModifierMask = key.modifierFlags

        // Later registrations intentionally override earlier ones for the same key.
        configuredShortcuts[key] = menu.action
        return true
    }

    /// Restore the shortcut of the item to the original one registered when first launched
    func restoreMenuItemShortcut(item: NSMenuItem) {
        guard
            let action = item.action,
            let key = originalMenuShortcutByAction[action]
        else {
            return
        }
        item.keyEquivalent = key.keyEquivalent
        item.keyEquivalentModifierMask = key.modifierFlags
    }

    func checkConflicts(item: NSMenuItem) {
        guard
            let key = MenuShortcutKey(item),
            // There should be an existing shortcut first
            let existed = configuredShortcuts[key],
            // Then we check if the action is the same
            existed != item.action
        else {
            return
        }
        // User configured shortcut has conflicts with default one,
        // clear the default one
        item.keyEquivalent = ""
        item.keyEquivalentModifierMask = []
    }
}

extension Ghostty.MenuShortcutManager {
    /// Hashable key for a menu shortcut match, normalized for quick lookup.
    struct MenuShortcutKey: Hashable {
        private static let shortcutModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]

        let keyEquivalent: String
        private let modifiersRawValue: UInt

        var modifierFlags: NSEvent.ModifierFlags {
            NSEvent.ModifierFlags(rawValue: modifiersRawValue)
        }

        init?(keyEquivalent: String, modifiers: NSEvent.ModifierFlags) {
            let normalized = keyEquivalent.lowercased()
            guard !normalized.isEmpty else { return nil }
            var mods = modifiers.intersection(Self.shortcutModifiers)
            if
                keyEquivalent.lowercased() != keyEquivalent.uppercased(),
                normalized.uppercased() == keyEquivalent {
                // If key equivalent is case sensitive and
                // it's originally uppercased, then we need to add `shift` to the modifiers
                mods.insert(.shift)
            }
            self.keyEquivalent = normalized
            self.modifiersRawValue = mods.rawValue
        }

        init?(event: NSEvent) {
            guard let keyEquivalent = event.charactersIgnoringModifiers else { return nil }
            self.init(keyEquivalent: keyEquivalent, modifiers: event.modifierFlags)
        }

        /// Create from a `NSMenuItem`
        ///
        /// - Important: This will check whether the `keyEquivalent` is uppercased by `.shift` modifier.
        init?(_ menuItem: NSMenuItem) {
            self.init(
                keyEquivalent: menuItem.keyEquivalent,
                modifiers: menuItem.keyEquivalentModifierMask,
            )
        }

        /// Create from a swiftUI `KeyboardShortcut`
        init?(_ shortcut: KeyboardShortcut) {
            let keyEquivalent = shortcut.key.character.description
            let modifierMask = NSEvent.ModifierFlags(swiftUIFlags: shortcut.modifiers)
            self.init(keyEquivalent: keyEquivalent, modifiers: modifierMask)
        }

        var swiftUIShortcut: KeyboardShortcut? {
            guard let character = keyEquivalent.first else { return nil }
            return KeyboardShortcut(
                KeyEquivalent(character),
                modifiers: .init(nsFlags: modifierFlags)
            )
        }
    }
}

private extension NSMenu {
    /// Expensive operation, but it will be deleted later
    func findItem(with action: Selector) -> NSMenuItem? {
        for item in items {
            if item.action == action {
                return item
            }
            if let item = item.submenu?.findItem(with: action) {
                return item
            }
        }
        return nil
    }
}

private extension Ghostty.Config {
    func isKeyboardShortcutUnbound(key: Ghostty.MenuShortcutManager.MenuShortcutKey) -> Bool {
        guard let swiftUIShortcut = key.swiftUIShortcut else {
            return false
        }
        return isKeyboardShortcutUnbound(swiftUIShortcut)
    }
}
