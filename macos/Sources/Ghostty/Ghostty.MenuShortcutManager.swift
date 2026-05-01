import AppKit
import SwiftUI

extension Ghostty {
    /// The manager that's responsible for updating shortcuts of Ghostty's app menu
    @MainActor
    class MenuShortcutManager {

        /// Ghostty menu items indexed by their normalized shortcut. This avoids traversing
        /// the entire menu tree on every key equivalent event.
        ///
        /// We store a weak reference so this cache can never be the owner of menu items.
        /// If multiple items map to the same shortcut, the most recent one wins.
        private var menuItemsByShortcut: [MenuShortcutKey: Weak<NSMenuItem>] = [:]

        /// Original shortcut configured in xib indexed by their action
        private var restorableMenuItemsByOriginalShortcut: [MenuShortcutKey: (Weak<NSMenuItem>, String?)] = [:]

        private var menuItemsRestored = [(Weak<NSMenuItem>, String?)]()

        func saveRestorableMenuItem(_ item: NSMenuItem?, action ghosttyAction: String?) {
            guard
                let item,
                let key = MenuShortcutKey(item)
            else {
                return
            }
            // Later registrations intentionally override earlier ones for the same key.
            restorableMenuItemsByOriginalShortcut[key] = (.init(item), ghosttyAction)
        }

        /// Restore shortcuts for the items that are registered
        ///
        /// - Important: the item is only restored when the current shortcut is empty
        func restoreMenuShortcuts() {
            menuItemsRestored.removeAll()
            for (key, item) in restorableMenuItemsByOriginalShortcut {
                if let menuItem = item.0.value, menuItem.keyEquivalent.isEmpty {
                    menuItem.keyEquivalent = key.keyEquivalent
                    menuItem.keyEquivalentModifierMask = key.modifierFlags
                    menuItemsRestored.append(item)
                }
            }
        }

        /// Re-sync shortcuts for the items that are restored
        func reSyncRestoredMenuShortcuts(config: Ghostty.Config) {
            for item in menuItemsRestored {
                if let menuItem = item.0.value {
                    syncMenuShortcut(config, action: item.1, menuItem: menuItem)
                }
            }
            menuItemsRestored.removeAll()
        }

        /// Reset our shortcut index since we're about to rebuild all menu bindings.
        func reset() {
            menuItemsByShortcut.removeAll(keepingCapacity: true)
        }

        /// Syncs a single menu shortcut for the given action. The action string is the same
        /// action string used for the Ghostty configuration.
        func syncMenuShortcut(_ config: Ghostty.Config, action: String?, menuItem: NSMenuItem?) {
            guard let menu = menuItem else { return }

            if !updateMenuShortcut(config, action: action, menuItem: menu) {
                menu.keyEquivalent = ""
                menu.keyEquivalentModifierMask = []
            }
        }

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
            guard let weakItem = menuItemsByShortcut[key] else {
                return false
            }

            // Weak references can be nil if a menu item was deallocated after sync.
            guard let item = weakItem.value else {
                menuItemsByShortcut.removeValue(forKey: key)
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
}

private extension Ghostty.MenuShortcutManager {
    /// Syncs a single menu shortcut for the given action. The action string is the same
    /// action string used for the Ghostty configuration.
    ///
    /// - Returns: Whether the menu item is updated and saved in ``menuItemsByShortcut``
    func updateMenuShortcut(_ config: Ghostty.Config, action: String?, menuItem menu: NSMenuItem) -> Bool {
        guard
            let action,
            let shortcut = config.keyboardShortcut(for: action),
            // Build a direct lookup for key-equivalent dispatch so we don't need to
            // linearly walk the full menu hierarchy at event time.
            let key = MenuShortcutKey(shortcut)
        else {
            return false
        }

        menu.keyEquivalent = key.keyEquivalent
        menu.keyEquivalentModifierMask = key.modifierFlags

        // Later registrations intentionally override earlier ones for the same key.
        menuItemsByShortcut[key] = .init(menu)
        return true
    }
}

extension Ghostty.MenuShortcutManager {
    /// Hashable key for a menu shortcut match, normalized for quick lookup.
    struct MenuShortcutKey: Hashable {
        private static let shortcutModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]

        let keyEquivalent: String
        // Make it Hashable
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
            // Ghostty configured shortcuts are already normalized
            // in `Ghostty.keyboardShortcut(for:)`, see also gh-#12039
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
