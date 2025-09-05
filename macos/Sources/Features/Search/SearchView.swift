import SwiftUI

/// SwiftUI view that provides the search interface for finding text in terminal.
/// This creates a search bar that appears when users press Cmd+F, with
/// a text field for typing search terms, navigation buttons, and result counter.
/// 
/// The view integrates with SearchController to manage search state and
/// communicates with the terminal to actually perform the searching.
/// It follows macOS design guidelines for search interfaces.
struct SearchView: View {
    
    /// The search controller that manages search state and terminal communication.
    /// This is observed so the view updates automatically when search state changes.
    @ObservedObject var searchController: SearchController
    
    /// Controls focus state of the search text field.
    /// When true, the text field is focused and ready for typing.
    /// This is set automatically when search bar first appears.
    @FocusState private var isSearchFieldFocused: Bool
    
    /// Environment value for color scheme (light/dark mode).
    /// This helps us style the search bar appropriately for the current theme.
    @Environment(\\.colorScheme) private var colorScheme
    
    var body: some View {
        // Only show search interface when search is active
        if searchController.isSearchActive {
            HStack(spacing: 8) {
                // Search text input field where users type what they want to find
                searchTextField
                
                // Navigation buttons to move between search results
                navigationButtons
                
                // Results counter showing "X of Y matches"
                resultsCounter
                
                // Close button to hide search bar
                closeButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(searchBarBackground)
            .overlay(searchBarBorder, alignment: .bottom)
            .animation(.easeInOut(duration: 0.2), value: searchController.isSearchActive)
            .onAppear {
                // Focus the search field when search bar appears
                // Small delay ensures the view is fully rendered first
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isSearchFieldFocused = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .escapeKeyPressed)) { _ in
                // Close search when Escape key is pressed
                searchController.hideSearch()
            }
        }
    }
    
    /// Text field where users type their search terms.
    /// Updates the search controller automatically as users type,
    /// which triggers new searches in the terminal.
    private var searchTextField: some View {
        TextField("Search in terminal...", text: $searchController.searchText)
            .textFieldStyle(RoundedBorderTextFieldStyle())
            .focused($isSearchFieldFocused)
            .frame(minWidth: 200, maxWidth: 300)
            .onSubmit {
                // When user presses Enter, go to next search result
                searchController.nextResult()
            }
            .overlay(
                // Show loading spinner when search is in progress
                Group {
                    if searchController.isSearchInProgress {
                        HStack {
                            Spacer()
                            ProgressView()
                                .scaleEffect(0.6)
                                .padding(.trailing, 8)
                        }
                    }
                }
            )
    }
    
    /// Navigation buttons for moving between search results.
    /// Includes previous/next buttons with keyboard shortcuts and tooltips.
    private var navigationButtons: some View {
        HStack(spacing: 4) {
            // Previous result button (up arrow)
            Button(action: {
                searchController.previousResult()
            }) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(SearchButtonStyle())
            .disabled(searchController.searchResults.isEmpty)
            .help("Previous result (⇧⌘G)")
            .keyboardShortcut("g", modifiers: [.command, .shift])
            
            // Next result button (down arrow)  
            Button(action: {
                searchController.nextResult()
            }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(SearchButtonStyle())
            .disabled(searchController.searchResults.isEmpty)
            .help("Next result (⌘G)")
            .keyboardShortcut("g", modifiers: .command)
        }
    }
    
    /// Results counter that shows "X of Y matches" or "No results".
    /// Updates automatically as search finds matches and user navigates.
    private var resultsCounter: some View {
        Text(resultsCounterText)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .frame(minWidth: 80, alignment: .leading)
    }
    
    /// Close button to hide the search bar and return to normal mode.
    /// Shows an X icon and responds to clicks and Escape key.
    private var closeButton: some View {
        Button(action: {
            searchController.hideSearch()
        }) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .medium))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(SearchButtonStyle())
        .help("Close search (⎋)")
        .keyboardShortcut(.escape)
    }
    
    /// Background styling for the search bar.
    /// Uses appropriate colors for light/dark mode and creates
    /// a subtle background that doesn't interfere with terminal content.
    private var searchBarBackground: some View {
        RoundedRectangle(cornerRadius: 0)
            .fill(colorScheme == .dark ? Color(NSColor.controlBackgroundColor) : Color(NSColor.windowBackgroundColor))
            .opacity(0.95)
    }
    
    /// Border line at the bottom of search bar.
    /// Provides visual separation between search interface and terminal content.
    private var searchBarBorder: some View {
        Rectangle()
            .fill(Color(NSColor.separatorColor))
            .frame(height: 0.5)
    }
    
    /// Computed text for the results counter.
    /// Shows different messages based on search state and results.
    private var resultsCounterText: String {
        if searchController.isSearchInProgress {
            return "Searching..."
        } else if searchController.searchText.isEmpty {
            return ""
        } else if searchController.searchResults.isEmpty {
            return "No results"
        } else {
            return searchController.resultsCountText
        }
    }
}

// MARK: - Custom Button Style

/// Custom button style for search navigation and close buttons.
/// Creates small, subtle buttons that fit well in the search bar
/// without being too prominent or distracting from the search field.
struct SearchButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(configuration.isPressed ? Color.primary.opacity(0.1) : Color.clear)
            )
            .foregroundColor(.primary)
            .opacity(configuration.isPressed ? 0.6 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Notification sent when Escape key is pressed.
    /// This allows the search view to respond to Escape from anywhere in the app.
    static let escapeKeyPressed = Notification.Name("escapeKeyPressed")
}

// MARK: - Preview

#if DEBUG
struct SearchView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 0) {
            // Show search view with sample data
            SearchView(searchController: {
                let controller = SearchController()
                controller.isSearchActive = true
                controller.searchText = "example"
                controller.searchResults = [
                    SearchResult(row: 10, column: 5, length: 7, matchedText: "example"),
                    SearchResult(row: 25, column: 12, length: 7, matchedText: "example"),
                    SearchResult(row: 40, column: 8, length: 7, matchedText: "example")
                ]
                controller.currentResultIndex = 0
                return controller
            }())
            
            // Placeholder for terminal content
            Rectangle()
                .fill(Color.black)
                .overlay(
                    Text("Terminal Content Area\\n(Search results would be highlighted here)")
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                )
        }
        .frame(width: 600, height: 400)
        .previewDisplayName("Search Active")
        
        // Preview with no search active
        VStack(spacing: 0) {
            SearchView(searchController: {
                let controller = SearchController()
                controller.isSearchActive = false
                return controller
            }())
            
            Rectangle()
                .fill(Color.black)
                .overlay(
                    Text("Terminal Content Area\\n(Press ⌘F to search)")
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                )
        }
        .frame(width: 600, height: 400)
        .previewDisplayName("Search Inactive")
    }
}
#endif