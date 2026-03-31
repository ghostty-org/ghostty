import AppKit

/// Bridges CEFBrowserView delegate callbacks to the browser UI layer.
///
/// Each browser session gets one bridge instance. It receives URL/title/loading
/// state changes from the CEF C++ handlers (dispatched to main queue) and
/// forwards them to the BrowserTabManager and BrowserNavigationBar.
@MainActor
final class BrowserSessionBridge: NSObject, CEFBrowserViewDelegate {
    let sessionId: UUID
    weak var tabManager: BrowserTabManager?
    weak var navigationBar: BrowserNavigationBar?
    weak var coordinator: SessionCoordinator?

    /// The tab ID currently associated with this bridge's CEFBrowserView.
    var activeTabId: UUID?

    init(sessionId: UUID, tabManager: BrowserTabManager, coordinator: SessionCoordinator) {
        self.sessionId = sessionId
        self.tabManager = tabManager
        self.coordinator = coordinator
        super.init()
    }

    // MARK: - CEFBrowserViewDelegate

    func browserView(_ view: CEFBrowserView, didChangeURL url: String) {
        guard let tabId = activeTabId else { return }
        tabManager?.updateTab(id: tabId, url: url)
        navigationBar?.urlField.stringValue = url
    }

    func browserView(_ view: CEFBrowserView, didChangeTitle title: String) {
        guard let tabId = activeTabId else { return }
        tabManager?.updateTab(id: tabId, title: title)
    }

    func browserView(_ view: CEFBrowserView, didChangeLoadingState isLoading: Bool, canGoBack: Bool, canGoForward forward: Bool) {
        guard let tabId = activeTabId else { return }
        tabManager?.updateTab(id: tabId, isLoading: isLoading)
        navigationBar?.backButton.isEnabled = canGoBack
        navigationBar?.forwardButton.isEnabled = forward
        // Update the reload button icon based on loading state.
        if isLoading {
            navigationBar?.reloadButton.image = NSImage(
                systemSymbolName: "xmark",
                accessibilityDescription: "Stop"
            )
        } else {
            navigationBar?.reloadButton.image = NSImage(
                systemSymbolName: "arrow.clockwise",
                accessibilityDescription: "Reload"
            )
        }
    }
}
