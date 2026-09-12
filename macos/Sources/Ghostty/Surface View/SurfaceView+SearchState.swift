import AppKit
import Combine
import GhosttyKit

extension Ghostty.SurfaceView {
    @MainActor class SearchState: ObservableObject {

        /// We should always change needle's text and its selection together
        struct Needle: Equatable {
            var text: String
            var selection: Range<String.Index>?

            static let empty = Needle(text: "", selection: nil)
        }

        /// The pasteboard used to persist the search needle.
        ///
        /// The `.find` pasteboard lets us sync our needle across the system and other find bars.
        private let pasteboard: NSPasteboard

        @Published var needle = Needle.empty

        @Published var selected: UInt?
        @Published var total: UInt?

        init(
            from startSearch: Ghostty.Action.StartSearch,
            pasteboard: NSPasteboard? = nil
        ) {
            self.pasteboard = pasteboard ?? .find
            if let needle = startSearch.needle, !needle.isEmpty {
                setNeedle(needle)
                writePasteboardNeedle()
            } else {
                readPasteboardNeedle()
            }
        }

        /// Replaces the search needle while keeping its selection valid.
        func setNeedle(_ needle: String, selectAll: Bool = false) {
            self.needle = .init(
                text: needle,
                selection: selectAll ? needle.startIndex..<needle.endIndex : nil
            )
        }

        func readPasteboardNeedle() {
            let pasteboardNeedle = pasteboard.string
            if let pasteboardNeedle, pasteboardNeedle != needle.text {
                setNeedle(pasteboardNeedle, selectAll: true)
            }
        }

        func writePasteboardNeedle() {
            pasteboard.string = needle.text
        }
    }

    func navigateSearchToNext() -> Bool {
        guard let surface = self.surface else { return false }
        let action = "navigate_search:next"
        if !ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
            AppDelegate.logger.warning("action failed action=\(action, privacy: .public)")
            return false
        }
        return true
    }

    func navigateSearchToPrevious() -> Bool {
        guard let surface = self.surface else { return false }
        let action = "navigate_search:previous"
        if !ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
            AppDelegate.logger.warning("action failed action=\(action, privacy: .public)")
            return false
        }
        return true
    }
}
