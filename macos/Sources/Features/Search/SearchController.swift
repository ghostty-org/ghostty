import SwiftUI
import Combine

/// Controller that manages search functionality on macOS.
/// This handles user input from the search bar and talks to the 
/// terminal search engine to find text in scrollback history.
/// 
/// The controller acts as a bridge between SwiftUI interface and
/// the Zig/C terminal code that actually performs the searching.
/// It manages the search state and coordinates between UI updates
/// and terminal operations.
class SearchController: ObservableObject {
    
    /// The text that users are currently searching for.
    /// This updates automatically as users type in the search field.
    /// When this changes, we trigger a new search in the terminal.
    @Published var searchText: String = "" {
        didSet {
            // When search text changes, start a new search
            // We do this with a small delay to avoid searching on every keystroke
            searchDebounceTimer?.invalidate()
            searchDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
                self.performSearch()
            }
        }
    }
    
    /// List of all places where the search text was found.
    /// Each SearchResult contains the position in terminal history
    /// where a match was discovered. This list gets updated every
    /// time we perform a new search.
    @Published var searchResults: [SearchResult] = []
    
    /// Which result from the list above is currently highlighted.
    /// This starts at 0 (first result) and users can navigate through
    /// all results using next/previous buttons or keyboard shortcuts.
    @Published var currentResultIndex: Int = 0 {
        didSet {
            // When current result changes, scroll terminal to show it
            if let surface = terminalSurface {
                scrollToCurrentResult()
            }
        }
    }
    
    /// True when the search bar is visible and users can type searches.
    /// When false, the terminal works normally. When true, some key
    /// presses go to search controls instead of the terminal program.
    @Published var isSearchActive: Bool = false {
        didSet {
            if !isSearchActive {
                // When search is closed, clean up search state
                clearSearch()
            }
        }
    }
    
    /// True when a search is currently running in the background.
    /// This prevents starting multiple searches at the same time
    /// and shows a loading indicator to users.
    @Published var isSearchInProgress: Bool = false
    
    /// Text shown in the results counter (like "3 of 15 matches").
    /// This updates automatically based on search results and current position.
    /// Empty string when no search is active or no results found.
    @Published var resultsCountText: String = ""
    
    /// The terminal surface that we're searching in.
    /// This connects the search controller to a specific terminal tab/window.
    /// The controller needs this to send search commands to the terminal.
    private var terminalSurface: UnsafeMutableRawPointer?
    
    /// Timer used to delay search after user stops typing.
    /// This prevents searching on every single keystroke, which would
    /// be slow and use lots of CPU. Instead we wait for user to pause.
    private var searchDebounceTimer: Timer?
    
    /// Cancellables for Combine subscriptions.
    /// This manages memory for our reactive programming subscriptions.
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        setupResultsCountText()
    }
    
    /// Connect this search controller to a specific terminal surface.
    /// This tells the controller which terminal to search in when
    /// users type search queries.
    func setTerminalSurface(_ surface: UnsafeMutableRawPointer?) {
        terminalSurface = surface
        
        // Clear any existing search when switching terminals
        if surface != nil {
            clearSearch()
        }
    }
    
    /// Show the search bar and focus the text input.
    /// This is called when users press Cmd+F or use the menu.
    /// It makes the search interface visible and ready for typing.
    func showSearch() {
        isSearchActive = true
        
        // Focus will be handled by the SwiftUI view when it appears
        // We use the @FocusState property wrapper for this
    }
    
    /// Hide the search bar and return to normal terminal mode.
    /// This is called when users press Escape or click the close button.
    /// It cleans up search state and hides the search interface.
    func hideSearch() {
        isSearchActive = false
        // clearSearch() is called automatically by isSearchActive didSet
    }
    
    /// Toggle search bar visibility on/off.
    /// This is the main entry point for the Cmd+F keyboard shortcut.
    /// If search is hidden, it shows. If search is shown, it hides.
    func toggleSearch() {
        if isSearchActive {
            hideSearch()
        } else {
            showSearch()
        }
    }
    
    /// Move to the next search result.
    /// This highlights a different match and scrolls the terminal
    /// to make sure it's visible to users. Wraps around to first
    /// result if we're already at the last one.
    func nextResult() {
        guard !searchResults.isEmpty else { return }
        
        currentResultIndex = (currentResultIndex + 1) % searchResults.count
        scrollToCurrentResult()
    }
    
    /// Move to the previous search result.
    /// This highlights a different match and scrolls the terminal
    /// to make sure it's visible to users. Wraps around to last
    /// result if we're already at the first one.
    func previousResult() {
        guard !searchResults.isEmpty else { return }
        
        if currentResultIndex == 0 {
            currentResultIndex = searchResults.count - 1
        } else {
            currentResultIndex -= 1
        }
        scrollToCurrentResult()
    }
    
    /// Clear all search results and reset search state.
    /// This is called when starting a new search or closing search.
    /// It removes all highlighting and resets counters to zero.
    private func clearSearch() {
        searchText = ""
        searchResults = []
        currentResultIndex = 0
        isSearchInProgress = false
        searchDebounceTimer?.invalidate()
        searchDebounceTimer = nil
    }
    
    /// Start searching for the current search text in terminal history.
    /// This calls into the Zig terminal code to actually perform the search.
    /// Results are returned asynchronously and update the UI.
    private func performSearch() {
        // Don't search if no terminal is connected or text is empty
        guard let surface = terminalSurface, !searchText.isEmpty else {
            searchResults = []
            currentResultIndex = 0
            return
        }
        
        // Don't start new search if one is already running
        guard !isSearchInProgress else { return }
        
        isSearchInProgress = true
        
        // Call into the Zig code to start searching
        // This will search through all terminal scrollback history
        DispatchQueue.global(qos: .userInitiated).async {
            // Convert Swift string to C string for Zig code
            let cString = self.searchText.cString(using: .utf8)!
            
            // Call the Zig function to start search
            // The results will be returned through a callback
            ghostty_surface_start_search(surface, cString)
            
            // Update UI on main thread when search completes
            DispatchQueue.main.async {
                self.isSearchInProgress = false
                // Results will be updated through the callback
            }
        }
    }
    
    /// Scroll the terminal to show the currently selected search result.
    /// This makes sure users can see the highlighted match by scrolling
    /// the terminal view if necessary.
    private func scrollToCurrentResult() {
        guard let surface = terminalSurface,
              !searchResults.isEmpty,
              currentResultIndex < searchResults.count else { return }
        
        let result = searchResults[currentResultIndex]
        
        // Call Zig code to scroll terminal to show this result
        ghostty_surface_scroll_to_search_result(surface, result.row, result.column)
    }
    
    /// Set up automatic updates for the results counter text.
    /// This watches for changes in search results and current index,
    /// then updates the display text accordingly.
    private func setupResultsCountText() {
        // Combine the searchResults and currentResultIndex publishers
        // to automatically update the results count text
        Publishers.CombineLatest($searchResults, $currentResultIndex)
            .map { results, currentIndex in
                if results.isEmpty {
                    return "" // No text when no results
                } else {
                    return "\\(currentIndex + 1) of \\(results.count)"
                }
            }
            .assign(to: &$resultsCountText)
    }
}

// MARK: - Search Result Data Structure

/// Represents a single search match found in terminal history.
/// Contains the exact location where the search text was found
/// so we can highlight it and scroll to show it to users.
struct SearchResult: Identifiable, Equatable {
    /// Unique identifier for SwiftUI list management.
    let id = UUID()
    
    /// Row number in terminal history where match was found.
    /// Row 0 is the top of terminal history, higher numbers
    /// are further down in the scrollback.
    let row: Int
    
    /// Column number in the row where match starts.
    /// Column 0 is the leftmost character, higher numbers
    /// are further to the right on the same line.
    let column: Int
    
    /// Length of the matched text in characters.
    /// This tells us how many characters to highlight
    /// starting from the row/column position.
    let length: Int
    
    /// The actual text that was matched.
    /// This is mainly for debugging and display purposes.
    /// The real highlighting happens based on position and length.
    let matchedText: String
}

// MARK: - C Integration Functions

/// These functions provide the interface between Swift and the Zig terminal code.
/// They are declared as external C functions that will be implemented in Zig.

/// Start searching for text in the terminal surface.
/// This calls into Zig code to search through terminal scrollback.
@_silgen_name("ghostty_surface_start_search")
func ghostty_surface_start_search(_ surface: UnsafeMutableRawPointer, _ searchText: UnsafePointer<CChar>)

/// Scroll terminal to show a specific search result.
/// This calls into Zig code to scroll the terminal view.
@_silgen_name("ghostty_surface_scroll_to_search_result")  
func ghostty_surface_scroll_to_search_result(_ surface: UnsafeMutableRawPointer, _ row: Int, _ column: Int)

/// Callback function called from Zig when search results are found.
/// This updates the Swift search controller with new results.
@_silgen_name("ghostty_search_results_callback")
func ghostty_search_results_callback(_ controller: UnsafeMutableRawPointer, _ results: UnsafePointer<CSearchResult>, _ count: Int) {
    // Convert the C array to Swift array
    let swiftController = Unmanaged<SearchController>.fromOpaque(controller).takeUnretainedValue()
    
    var swiftResults: [SearchResult] = []
    for i in 0..<count {
        let cResult = results[i]
        let swiftResult = SearchResult(
            row: Int(cResult.row),
            column: Int(cResult.column),
            length: Int(cResult.length),
            matchedText: String(cString: cResult.text)
        )
        swiftResults.append(swiftResult)
    }
    
    // Update UI on main thread
    DispatchQueue.main.async {
        swiftController.searchResults = swiftResults
        swiftController.currentResultIndex = 0 // Start at first result
    }
}

/// C structure for passing search results from Zig to Swift.
/// This matches the structure used in the Zig code.
struct CSearchResult {
    let row: Int32
    let column: Int32
    let length: Int32
    let text: UnsafePointer<CChar>
}