import SwiftUI
import GhosttyKit

/// A search overlay that allows searching through the terminal scrollback buffer.
/// This is displayed as a floating overlay in the top-right corner of the terminal.
struct SearchOverlay: View {
    /// The surface view for focus management
    let surfaceView: Ghostty.SurfaceView

    /// The surface model that this search overlay is operating on.
    let surface: Ghostty.Surface

    /// Set this to true to show the view, this will be set to false if the search is closed.
    @Binding var isPresented: Bool

    /// The search query text.
    @State private var query: String = ""

    /// The current search state (updated on demand).
    @State private var searchState: Ghostty.Surface.SearchState = .init(active: false, matchCount: 0, currentMatch: nil)

    /// Whether the text field should be focused.
    @FocusState private var isTextFieldFocused: Bool

    /// Task for debounced search
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            if isPresented {
                VStack {
                    HStack {
                        Spacer()

                        ResponderChainInjector(responder: surfaceView)
                            .frame(width: 0, height: 0)

                        searchBox
                            .padding(.top, 12)
                            .padding(.trailing, 12)
                    }

                    Spacer()
                }
                .transition(
                    .move(edge: .top)
                    .combined(with: .opacity)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8))
                )
            }
        }
        .onChange(of: isPresented) { newValue in
            // When the search overlay disappears we need to send focus back to the
            // surface view we were overlaid on top of.
            if !newValue {
                // Has to be on queue because onChange happens on a user-interactive
                // thread and we need to ensure the view has finished disappearing.
                DispatchQueue.main.async {
                    surfaceView.window?.makeFirstResponder(surfaceView)
                }
            }
        }
    }

    private var searchBox: some View {
        HStack(spacing: 8) {
            // Search icon
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))

            // Search text field
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .frame(width: 180)
                .focused($isTextFieldFocused)
                .onSubmit {
                    if query.isEmpty {
                        handleNext()
                    } else {
                        surface.searchStart(query)
                        updateSearchState()
                    }
                }
                .onChange(of: query) { newValue in
                    handleQueryChange(newValue)
                }

            // Match counter
            if searchState.active {
                Text(matchCounterText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Divider()
                .frame(height: 16)

            // Previous button
            Button(action: handlePrevious) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(!searchState.active || searchState.matchCount == 0)
            .help("Previous Match (⇧⏎)")

            // Next button
            Button(action: handleNext) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(!searchState.active || searchState.matchCount == 0)
            .help("Next Match (⏎)")

            Divider()
                .frame(height: 16)

            // Close button
            Button(action: handleClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                Rectangle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .blendMode(.color)
            }
            .compositingGroup()
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
        .onAppear {
            // Focus text field when appearing
            DispatchQueue.main.async {
                isTextFieldFocused = true
            }
        }
        .onDisappear {
            searchTask?.cancel()
            query = ""
            searchState = .init(active: false, matchCount: 0, currentMatch: nil)
        }
        .onExitCommand {
            handleClose()
        }
        // Invisible buttons for keyboard shortcuts
        .background(
            Group {
                Button("") { handleNext() }
                    .keyboardShortcut(.return, modifiers: [])

                Button("") { handlePrevious() }
                    .keyboardShortcut(.return, modifiers: [.shift])

                Button("") { handleNext() }
                    .keyboardShortcut("g", modifiers: [.command])

                Button("") { handlePrevious() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        )
    }

    private var matchCounterText: String {
        if searchState.matchCount == 0 {
            return "No matches"
        } else if let current = searchState.currentMatch {
            return "\(current + 1) of \(searchState.matchCount)"
        } else {
            return "\(searchState.matchCount) match\(searchState.matchCount == 1 ? "" : "es")"
        }
    }

    private func handleQueryChange(_ newQuery: String) {
        searchTask?.cancel()

        if newQuery.isEmpty {
            surface.searchClose()
            updateSearchState()
            return
        }

        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, isPresented, query == newQuery else { return }
            surface.searchStart(newQuery)
            updateSearchState()
        }
    }

    private func handleNext() {
        surface.searchNext()
        updateSearchState()
    }

    private func handlePrevious() {
        surface.searchPrevious()
        updateSearchState()
    }

    private func handleClose() {
        surface.searchClose()
        isPresented = false
    }

    private func updateSearchState() {
        searchState = surface.searchState()
    }
}

/// This is done to ensure that the given view is in the responder chain.
fileprivate struct ResponderChainInjector: NSViewRepresentable {
    let responder: NSResponder

    func makeNSView(context: Context) -> NSView {
        let dummy = NSView()
        DispatchQueue.main.async {
            dummy.nextResponder = responder
        }
        return dummy
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
