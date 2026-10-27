import AppKit
@testable import Ghostty
import Testing

struct NSMenuTests {
    let menu = NSMenu(title: "Menu")

    // MARK: - NSMenuItem insertions

    @Test func insertItemFromEmptyMenuReturnsNil() {
        let menuItem = NSMenuItem(title: "menu item 2", action: NSSelectorFromString("action 2"), keyEquivalent: "")

        #expect(menu.insertItem(menuItem, after: NSSelectorFromString("action")) == nil)
    }

    @Test func insertItemWithExistingItemsReturnsIndex() {
        let menuItem = NSMenuItem(title: "menu item", action: NSSelectorFromString("action"), keyEquivalent: "")
        let menuItem2 = NSMenuItem(title: "menu item 2", action: NSSelectorFromString("action 2"), keyEquivalent: "")

        menu.insertItem(menuItem, at: 0)

        #expect(menu.insertItem(menuItem2, after: NSSelectorFromString("action")) == 1)
    }

    @Test func insertItemWithSimilarIdentifierReturnsNil() {
        let menuItem = NSMenuItem(title: "menu item", action: NSSelectorFromString("action"), keyEquivalent: "")
        menuItem.identifier = NSUserInterfaceItemIdentifier("id")

        let menuItem2 = NSMenuItem(title: "menu item 2", action: NSSelectorFromString("action 2"), keyEquivalent: "")
        menuItem2.identifier = NSUserInterfaceItemIdentifier("id")

        menu.insertItem(menuItem, at: 0)

        #expect(menu.insertItem(menuItem2, after: NSSelectorFromString("action")) == nil)
    }
}
