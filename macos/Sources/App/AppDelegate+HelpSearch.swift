import AppKit

extension AppDelegate: NSUserInterfaceItemSearching {
    // Item type for matched items.
    private struct SearchItem {
        let value: String
    }

    func searchForItems(withSearch searchString: String, resultLimit: Int, matchedItemHandler handleMatchedItems: @escaping ([Any]) -> Void) {
        handleMatchedItems([SearchItem(value: searchString)])
    }

    func localizedTitles(forItem item: Any) -> [String] {
        guard item is SearchItem else {
            return []
        }

        return ["Search Ghostty Docs"]
    }

    func performAction(forItem item: Any) {
        guard let item = item as? SearchItem else {
            return
        }
        showHelp(searchTerm: item.value)
    }
}
