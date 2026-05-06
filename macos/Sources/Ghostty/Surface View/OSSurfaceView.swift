import Foundation
import GhosttyKit

extension Ghostty {
    class OSSurfaceView: OSView, ObservableObject {
        typealias ID = UUID

        /// Unique ID per surface
        let id: UUID

        // The current pwd of the surface as defined by the pty. This can be
        // changed with escape codes.
        @Published var pwd: String?

        // The cell size of this surface. This is set by the core when the
        // surface is first created and any time the cell size changes (i.e.
        // when the font size changes). This is used to allow windows to be
        // resized in discrete steps of a single cell.
        @Published var cellSize: CGSize = .zero

        // The health state of the surface. This currently only reflects the
        // renderer health. In the future we may want to make this an enum.
        @Published var healthy: Bool = true

        // Any error while initializing the surface.
        @Published var error: Error?

        // The hovered URL string
        @Published var hoverUrl: String?

        // The progress report (if any)
        @Published var progressReport: Action.ProgressReport?

        // The currently active key tables. Empty if no tables are active.
        @Published var keyTables: [String] = []

        // The current search state. When non-nil, the search overlay should be shown.
        @Published var searchState: SearchState?

        // The time this surface last became focused. This is a ContinuousClock.Instant
        // on supported platforms.
        @Published var focusInstant: ContinuousClock.Instant?

        // Returns sizing information for the surface. This is the raw C
        // structure because I'm lazy.
        @Published var surfaceSize: ghostty_surface_size_s?

        /// True when the surface is in readonly mode.
        @Published private(set) var readonly: Bool = false

        /// True when the surface should show a highlight effect (e.g., when presented via goto_split).
        @Published private(set) var highlighted: Bool = false

        /// A message sent from `ghostty_surface_t` when a child process exited
        @Published private(set) var childExitedMessage: ChildExitedMessage?

        var surface: ghostty_surface_t? {
            nil
        }

        init(id: UUID?, frame: CGRect) {
            self.id = id ?? UUID()
            super.init(frame: frame)

            // Before we initialize the surface we want to register our notifications
            // so there is no window where we can't receive them.
            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(ghosttyDidChangeReadonly(_:)),
                name: .ghosttyDidChangeReadonly,
                object: self,
            )
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported for this view")
        }

        deinit {
            NotificationCenter.default
                .removeObserver(self)
        }

        @objc private func ghosttyDidChangeReadonly(_ notification: Foundation.Notification) {
            guard let value = notification.userInfo?[Foundation.Notification.Name.ReadonlyKey] as? Bool else { return }
            readonly = value
        }

        /// Triggers a brief highlight animation on this surface.
        func highlight() {
            highlighted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.highlighted = false
            }
        }

        func setChildExitedMessage(_ message: ChildExitedMessage) {
            self.childExitedMessage = message
        }

        @MainActor
        func endSearch() {
            searchState = nil
        }

        // MARK: - Placeholders

        func focusDidChange(_ focused: Bool) {}

        func sizeDidChange(_ size: CGSize) {}
    }
}

// MARK: Search State

extension Ghostty.OSSurfaceView {
    class SearchState: ObservableObject {
        @Published var needle: String = ""
        @Published var selected: UInt?
        @Published var total: UInt?

        init(from startSearch: Ghostty.Action.StartSearch) {
            self.needle = startSearch.needle ?? ""
        }
    }

    func navigateSearchToNext() -> Bool {
        guard let surface = self.surface else { return false }
        let action = "navigate_search:next"
        if !ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
#if canImport(AppKit)
            AppDelegate.logger.warning("action failed action=\(action)")
#endif
            return false
        }
        return true
    }

    func navigateSearchToPrevious() -> Bool {
        guard let surface = self.surface else { return false }
        let action = "navigate_search:previous"
        if !ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
#if canImport(AppKit)
            AppDelegate.logger.warning("action failed action=\(action)")
#endif
            return false
        }
        return true
    }
}
