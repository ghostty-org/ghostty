import Foundation
import Testing
@testable import Ghostty

struct BrowserTabManagerTests {
    @Test @MainActor func testCreateTabReturnsTab() {
        let manager = BrowserTabManager()
        let tab = manager.createTab(url: "https://example.com")

        #expect(tab.url == "https://example.com")
        #expect(tab.title == "New Tab")
        #expect(tab.isLoading == false)
        // ID should be a valid UUID (non-nil by construction)
        #expect(manager.tabs.contains(where: { $0.id == tab.id }))
    }

    @Test @MainActor func testCreateTabSetsFirstAsActive() {
        let manager = BrowserTabManager()
        #expect(manager.activeTabId == nil)

        let tab = manager.createTab()
        #expect(manager.activeTabId == tab.id)

        // Second tab should NOT change the active tab
        let tab2 = manager.createTab()
        #expect(manager.activeTabId == tab.id)
        #expect(manager.activeTabId != tab2.id)
    }

    @Test @MainActor func testCloseTabSwitchesToAdjacent() {
        let manager = BrowserTabManager()
        let tab1 = manager.createTab(url: "https://one.com")
        let tab2 = manager.createTab(url: "https://two.com")
        let tab3 = manager.createTab(url: "https://three.com")

        // Activate the middle tab, then close it
        manager.switchTab(id: tab2.id)
        #expect(manager.activeTabId == tab2.id)

        manager.closeTab(id: tab2.id)

        // Should switch to tab3 (was to the right)
        #expect(manager.activeTabId == tab3.id)
        #expect(manager.tabs.count == 2)

        // Close tab3 (last in list) — should switch to tab1
        manager.switchTab(id: tab3.id)
        manager.closeTab(id: tab3.id)
        #expect(manager.activeTabId == tab1.id)
    }

    @Test @MainActor func testCloseLastTabClearsActive() {
        let manager = BrowserTabManager()
        let tab = manager.createTab()
        #expect(manager.activeTabId == tab.id)

        manager.closeTab(id: tab.id)
        #expect(manager.activeTabId == nil)
        #expect(manager.tabs.isEmpty)
    }

    @Test @MainActor func testSwitchTab() {
        let manager = BrowserTabManager()
        let tab1 = manager.createTab()
        let tab2 = manager.createTab()

        #expect(manager.activeTabId == tab1.id)

        manager.switchTab(id: tab2.id)
        #expect(manager.activeTabId == tab2.id)

        manager.switchTab(id: tab1.id)
        #expect(manager.activeTabId == tab1.id)

        // Switching to a non-existent ID should be a no-op
        manager.switchTab(id: UUID())
        #expect(manager.activeTabId == tab1.id)
    }

    @Test @MainActor func testCloseAllTabs() {
        let manager = BrowserTabManager()
        _ = manager.createTab(url: "https://one.com")
        _ = manager.createTab(url: "https://two.com")
        _ = manager.createTab(url: "https://three.com")

        #expect(manager.tabs.count == 3)
        #expect(manager.activeTabId != nil)

        manager.closeAllTabs()

        #expect(manager.tabs.isEmpty)
        #expect(manager.activeTabId == nil)
        #expect(manager.browserViews.isEmpty)
        #expect(manager.tabCount == 0)
    }

    @Test @MainActor func testUpdateTab() {
        let manager = BrowserTabManager()
        let tab = manager.createTab()

        // Update title only
        manager.updateTab(id: tab.id, title: "Google")
        #expect(manager.tabs[0].title == "Google")
        #expect(manager.tabs[0].url == "about:blank")

        // Update url only
        manager.updateTab(id: tab.id, url: "https://google.com")
        #expect(manager.tabs[0].url == "https://google.com")
        #expect(manager.tabs[0].title == "Google")

        // Update isLoading only
        manager.updateTab(id: tab.id, isLoading: true)
        #expect(manager.tabs[0].isLoading == true)

        // Update all at once
        manager.updateTab(id: tab.id, title: "GitHub", url: "https://github.com", isLoading: false)
        #expect(manager.tabs[0].title == "GitHub")
        #expect(manager.tabs[0].url == "https://github.com")
        #expect(manager.tabs[0].isLoading == false)

        // Updating a non-existent tab should be a no-op
        manager.updateTab(id: UUID(), title: "Nope")
        #expect(manager.tabs.count == 1)
    }

    @Test @MainActor func testTabCountReflectsState() {
        let manager = BrowserTabManager()
        #expect(manager.tabCount == 0)

        let tab1 = manager.createTab()
        #expect(manager.tabCount == 1)

        _ = manager.createTab()
        #expect(manager.tabCount == 2)

        _ = manager.createTab()
        #expect(manager.tabCount == 3)

        manager.closeTab(id: tab1.id)
        #expect(manager.tabCount == 2)

        manager.closeAllTabs()
        #expect(manager.tabCount == 0)
    }
}
