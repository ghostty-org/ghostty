import AppKit

extension NSMenu {
    /// Inserts a menu item after an existing item with the specified action selector.
    ///
    /// If an item with the same identifier already exists, it is removed first to avoid duplicates.
    /// This is useful when menus are cached and reused across different targets.
    ///
    /// - Parameters:
    ///   - item: The menu item to insert.
    ///   - action: The action selector to search for. The new item will be inserted after the first
    ///             item with this action.
    /// - Returns: `true` if the item was inserted after the specified action, `false` if the action
    ///            was not found and the item was not inserted.
    @discardableResult
    func insertItem(_ item: NSMenuItem, after action: Selector) -> Bool {
        if let identifier = item.identifier,
           let existing = items.first(where: { $0.identifier == identifier }) {
            removeItem(existing)
        }

        guard let idx = items.firstIndex(where: { $0.action == action }) else {
            return false
        }

        insertItem(item, at: idx + 1)
        return true
    }
}
