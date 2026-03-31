import AppKit

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

        if let action = ghosttyActionsBySelector[selector] {
            if !syncMenuShortcutFrom(config, action: action, menuItem: item) {
                // No shortcut, clear the menu item
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = []
            }
        }
    }

    /// Syncs a single menu shortcut for the given action. The action string is the same
    /// action string used for the Ghostty configuration.
    func syncMenuShortcutFrom(_ config: Ghostty.Config, action: String, menuItem menu: NSMenuItem) -> Bool {

        guard let shortcut = config.keyboardShortcut(for: action) else {
            return false
        }

        let keyEquivalent = shortcut.key.character.description
        let modifierMask = NSEvent.ModifierFlags(swiftUIFlags: shortcut.modifiers)
        // Build a direct lookup for key-equivalent dispatch so we don't need to
        // linearly walk the full menu hierarchy at event time.
        guard let key = MenuShortcutKey(
            // We don't want to check missing `shift` for Ghostty configured shortcuts,
            // because we know it's there when it needs to be
            keyEquivalent: keyEquivalent.lowercased(),
            modifiers: modifierMask
        ) else {
            return false
        }

        menu.keyEquivalent = keyEquivalent
        menu.keyEquivalentModifierMask = modifierMask

        // Later registrations intentionally override earlier ones for the same key.
        configuredShortcuts[key] = menu.action
        return true
    }
}

extension Ghostty.MenuShortcutManager {
    /// Hashable key for a menu shortcut match, normalized for quick lookup.
    struct MenuShortcutKey: Hashable {
        private static let shortcutModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]

        let keyEquivalent: String
        let modifiersRawValue: UInt

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
