import SwiftUI
import Combine

/// Integration layer that connects SwiftUI search components to the terminal.
/// This handles the coordination between the search interface (SearchView + SearchController)
/// and the actual terminal surface where text searching happens.
/// 
/// This class manages the lifecycle of search operations and ensures proper
/// communication between the Swift UI layer and the underlying Zig terminal code.
class TerminalSearchIntegration: ObservableObject {
    
    /// The search controller that manages search state and operations.
    /// This is exposed to SwiftUI views that need to interact with search.
    @Published var searchController = SearchController()
    
    /// The terminal surface we're currently searching in.
    /// This pointer connects us to the specific terminal tab/window.
    private var terminalSurface: UnsafeMutableRawPointer?
    
    /// Cancellables for managing Combine subscriptions.
    /// This prevents memory leaks from our reactive programming setup.
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        setupSearchController()
    }
    
    /// Connect this integration to a specific terminal surface.
    /// This should be called when a terminal tab becomes active or
    /// when creating a new terminal that will support search.
    func setTerminalSurface(_ surface: UnsafeMutableRawPointer?) {
        terminalSurface = surface
        searchController.setTerminalSurface(surface)
    }
    
    /// Handle keyboard shortcuts for search functionality.
    /// This should be called from the main window's key event handlers
    /// to process search-related keyboard shortcuts.
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        // Check for Cmd+F (show search)
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "f" {
            searchController.toggleSearch()
            return true // We handled this key event
        }
        
        // Check for Escape (hide search) - only if search is active
        if event.keyCode == 53 && searchController.isSearchActive { // 53 is Escape key code
            searchController.hideSearch()
            return true // We handled this key event
        }
        
        // Check for Cmd+G (next result) and Shift+Cmd+G (previous result)
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "g" {
            if event.modifierFlags.contains(.shift) {
                searchController.previousResult()
            } else {
                searchController.nextResult()
            }
            return true // We handled this key event
        }
        
        return false // We didn't handle this key event
    }
    
    /// Handle menu actions for search functionality.
    /// This should be called from the main menu system when users
    /// select search-related menu items.
    func handleMenuAction(_ action: SearchMenuAction) {
        switch action {
        case .find:
            searchController.showSearch()
        case .findNext:
            searchController.nextResult()
        case .findPrevious:
            searchController.previousResult()
        case .hideSearch:
            searchController.hideSearch()
        }
    }
    
    /// Set up the search controller and configure its behavior.
    /// This establishes the connection between search controller and terminal.
    private func setupSearchController() {
        // The search controller will handle its own internal setup
        // We just need to make sure it's connected to our terminal surface
        searchController.setTerminalSurface(terminalSurface)
    }
}

// MARK: - Search Menu Actions

/// Enum representing different search-related actions that can be triggered
/// from the application menu system.
enum SearchMenuAction {
    case find           // Show search bar (Cmd+F)
    case findNext       // Go to next result (Cmd+G)  
    case findPrevious   // Go to previous result (Shift+Cmd+G)
    case hideSearch     // Hide search bar (Escape)
}

// MARK: - SwiftUI Integration

/// SwiftUI view that embeds search functionality into a terminal view.
/// This combines the search interface with terminal content and handles
/// the coordination between them.
struct TerminalWithSearch<Content: View>: View {
    
    /// The search integration that manages search state.
    @ObservedObject var searchIntegration: TerminalSearchIntegration
    
    /// The terminal content view that will be wrapped with search functionality.
    let terminalContent: Content
    
    init(
        searchIntegration: TerminalSearchIntegration,
        @ViewBuilder terminalContent: () -> Content
    ) {
        self.searchIntegration = searchIntegration
        self.terminalContent = terminalContent()
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Search bar appears at the top when active
            SearchView(searchController: searchIntegration.searchController)
                .zIndex(1) // Ensure search bar stays above terminal content
            
            // Terminal content with search results highlighted
            terminalContent
                .overlay(searchHighlightOverlay, alignment: .topLeading)
                .clipped() // Prevent search highlights from extending outside terminal
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalSurfaceChanged)) { notification in
            // Update terminal surface when it changes (e.g., switching tabs)
            if let surface = notification.object as? UnsafeMutableRawPointer {
                searchIntegration.setTerminalSurface(surface)
            }
        }
    }
    
    /// Overlay that renders search result highlights on top of terminal content.
    /// This creates visual highlighting for search matches without modifying
    /// the underlying terminal rendering.
    private var searchHighlightOverlay: some View {
        // This would need to be implemented to actually draw highlights
        // based on search results from the search controller
        Rectangle()
            .fill(Color.clear) // Transparent overlay for now
            .onReceive(searchIntegration.searchController.$searchResults) { results in
                // Update highlights when search results change
                updateSearchHighlights(results)
            }
            .onReceive(searchIntegration.searchController.$currentResultIndex) { index in
                // Update current highlight when selection changes
                updateCurrentHighlight(index)
            }
    }
    
    /// Update the visual highlighting of search results.
    /// This would coordinate with the terminal rendering system to
    /// show highlighted text for all search matches.
    private func updateSearchHighlights(_ results: [SearchResult]) {
        // TODO: Implement actual highlight rendering
        // This would need to:
        // 1. Clear existing highlights
        // 2. Create highlight overlays for each result
        // 3. Position overlays based on terminal character grid
        // 4. Style highlights appropriately (color, opacity, etc.)
    }
    
    /// Update the highlighting of the currently selected search result.
    /// This makes one search result stand out more than the others
    /// to show users which one is currently selected.
    private func updateCurrentHighlight(_ index: Int) {
        // TODO: Implement current result highlighting
        // This would need to:
        // 1. Remove "current" styling from previous result
        // 2. Add "current" styling to new result at index
        // 3. Ensure current result is visible (scroll if needed)
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Notification sent when the terminal surface changes.
    /// This allows search integration to update its connection.
    static let terminalSurfaceChanged = Notification.Name("terminalSurfaceChanged")
}

// MARK: - C Integration Helpers

/// Helper functions for integrating with the Zig terminal code.
/// These provide a clean interface between Swift and C/Zig code.
enum TerminalSearchBridge {
    
    /// Start a search in the specified terminal surface.
    /// This calls into Zig code to perform the actual searching.
    static func startSearch(in surface: UnsafeMutableRawPointer, for text: String) {
        text.withCString { cString in
            ghostty_surface_start_search(surface, cString)
        }
    }
    
    /// Scroll terminal to show a specific search result.
    /// This calls into Zig code to scroll the terminal view.
    static func scrollToResult(in surface: UnsafeMutableRawPointer, row: Int, column: Int) {
        ghostty_surface_scroll_to_search_result(surface, row, column)
    }
    
    /// Get the current search state from the terminal.
    /// This calls into Zig code to retrieve search information.
    static func getCurrentSearchState(from surface: UnsafeMutableRawPointer) -> SearchState? {
        // TODO: Implement this function
        // Would need corresponding Zig function to return search state
        return nil
    }
}

/// Structure representing the current state of search in a terminal.
/// This mirrors the search state maintained by the Zig SearchManager.
struct SearchState {
    let isActive: Bool
    let searchText: String
    let currentResultIndex: Int
    let totalResults: Int
}

// MARK: - Preview Support

#if DEBUG
extension TerminalSearchIntegration {
    /// Create a search integration with sample data for previews.
    /// This allows SwiftUI previews to show search functionality.
    static func preview() -> TerminalSearchIntegration {
        let integration = TerminalSearchIntegration()
        
        // Set up sample search state
        integration.searchController.isSearchActive = true
        integration.searchController.searchText = "example"
        integration.searchController.searchResults = [
            SearchResult(row: 10, column: 5, length: 7, matchedText: "example"),
            SearchResult(row: 25, column: 12, length: 7, matchedText: "example"),
            SearchResult(row: 40, column: 8, length: 7, matchedText: "example")
        ]
        integration.searchController.currentResultIndex = 0
        
        return integration
    }
}
#endif