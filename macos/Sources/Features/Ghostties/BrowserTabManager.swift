import AppKit
import Combine
import Foundation

/// Manages multiple browser tabs within the browser panel.
/// Each tab owns a CEFBrowserView instance (separate Chromium process).
@MainActor
final class BrowserTabManager: ObservableObject {
    struct Tab: Identifiable {
        let id: UUID
        var title: String
        var url: String
        var isLoading: Bool

        // The actual CEFBrowserView is stored separately since it's an NSView
        // and we don't want value-type semantics on it.
    }

    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var activeTabId: UUID?

    /// Browser views keyed by tab ID. Separate from Tab struct to avoid
    /// value-type copying of NSView references.
    private(set) var browserViews: [UUID: NSView] = [:]  // CEFBrowserView at runtime

    /// Create a new tab with the given URL. Returns the new tab.
    @discardableResult
    func createTab(url: String = "about:blank") -> Tab {
        let tab = Tab(id: UUID(), title: "New Tab", url: url, isLoading: false)
        tabs.append(tab)
        if activeTabId == nil {
            activeTabId = tab.id
        }
        return tab
    }

    /// Close a tab by ID. Switches to adjacent tab if closing the active one.
    func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = id == activeTabId
        tabs.remove(at: index)
        browserViews.removeValue(forKey: id)

        if wasActive {
            // Switch to the tab that was to the right, or the last tab
            if tabs.isEmpty {
                activeTabId = nil
            } else {
                let newIndex = min(index, tabs.count - 1)
                activeTabId = tabs[newIndex].id
            }
        }
    }

    /// Switch to a tab by ID.
    func switchTab(id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabId = id
    }

    /// Close all tabs. Used during session cleanup.
    func closeAllTabs() {
        // Close browser views — CEFBrowserView.closeBrowser() will be called
        // here at runtime. For now, just clear the references.
        browserViews.removeAll()
        tabs.removeAll()
        activeTabId = nil
    }

    /// Update a tab's metadata (called from CEFBrowserViewDelegate).
    func updateTab(id: UUID, title: String? = nil, url: String? = nil, isLoading: Bool? = nil) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if let title { tabs[index].title = title }
        if let url { tabs[index].url = url }
        if let isLoading { tabs[index].isLoading = isLoading }
    }

    /// Register a browser view for a tab.
    func registerBrowserView(_ view: NSView, for tabId: UUID) {
        browserViews[tabId] = view
    }

    /// The active tab's browser view, if any.
    var activeBrowserView: NSView? {
        guard let id = activeTabId else { return nil }
        return browserViews[id]
    }

    /// Number of open tabs.
    var tabCount: Int { tabs.count }
}
