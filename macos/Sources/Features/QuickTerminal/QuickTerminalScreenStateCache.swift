import Foundation
import Cocoa

/// Manages cached window state per screen for the quick terminal.
///
/// This cache tracks the last closed window frame for each screen, allowing the quick terminal
/// to restore to its previous size and position when reopened. It uses stable display UUIDs
/// to survive NSScreen garbage collection and automatically prunes stale entries.
class QuickTerminalScreenStateCache {
    typealias Entries = [UUID: DisplayEntry]
    
    /// The maximum number of saved screen states we retain. This is to avoid some kind of
    /// pathological memory growth in case we get our screen state serializing wrong. I don't
    /// know anyone with more than 10 screens, so let's just arbitrarily go with that.
    private static let maxSavedScreens = 10
    
    /// Time-to-live for screen entries that are no longer present (14 days).
    private static let screenStaleTTL: TimeInterval = 14 * 24 * 60 * 60
    
    /// Keyed by display UUID to survive NSScreen garbage collection.
    private(set) var stateByDisplay: Entries = [:]

    init(stateByDisplay: Entries = [:]) {
        self.stateByDisplay = stateByDisplay
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onScreensChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    /// Save the window frame for a screen.
    func save(frame: NSRect, for screen: NSScreen) {
        guard let key = screen.displayUUID else { return }
        let entry = DisplayEntry(
            frame: frame,
            screenSize: screen.frame.size,
            scale: screen.backingScaleFactor,
            lastSeen: Date()
        )
        stateByDisplay[key] = entry
        pruneCapacity()
    }
    
    /// Retrieve the last closed frame for a screen, if valid.
    func frame(for screen: NSScreen) -> NSRect? {
        guard let key = screen.displayUUID, var entry = stateByDisplay[key] else { return nil }
        
        // Drop on dimension/scale change that makes the entry invalid
        if !entry.isValid(for: screen) {
            stateByDisplay.removeValue(forKey: key)
            return nil
        }
        
        entry.lastSeen = Date()
        stateByDisplay[key] = entry
        return entry.frame
    }
    
    @objc private func onScreensChanged(_ note: Notification) {
        let screens = NSScreen.screens
        let now = Date()
        let currentIDs = Set(screens.compactMap { $0.displayUUID })
        
        for screen in screens {
            guard let key = screen.displayUUID else { continue }
            if var entry = stateByDisplay[key] {
                // Drop on dimension/scale change that makes the entry invalid
                if !entry.isValid(for: screen) {
                    stateByDisplay.removeValue(forKey: key)
                } else {
                    // Update the screen size if it grew (keep entry valid for larger screens)
                    entry.screenSize = screen.frame.size
                    entry.lastSeen = now
                    stateByDisplay[key] = entry
                }
            }
        }
        
        // TTL prune for non-present screens
        stateByDisplay = stateByDisplay.filter { key, entry in
            currentIDs.contains(key) || now.timeIntervalSince(entry.lastSeen) < Self.screenStaleTTL
        }
        
        pruneCapacity()
    }
    
    private func pruneCapacity() {
        guard stateByDisplay.count > Self.maxSavedScreens else { return }
        let toRemove = stateByDisplay
            .sorted { $0.value.lastSeen < $1.value.lastSeen }
            .prefix(stateByDisplay.count - Self.maxSavedScreens)
        for (key, _) in toRemove {
            stateByDisplay.removeValue(forKey: key)
        }
    }
    
    struct DisplayEntry: Codable {
        var frame: NSRect
        var screenSize: CGSize
        var scale: CGFloat
        var lastSeen: Date
        
        /// Returns true if this entry is still valid for the given screen.
        /// Valid if the scale matches and the cached size is not larger than the current screen size.
        /// This allows entries to persist when screens grow, but invalidates them when screens shrink.
        func isValid(for screen: NSScreen) -> Bool {
            guard scale == screen.backingScaleFactor else { return false }
            return screenSize.width <= screen.frame.size.width && screenSize.height <= screen.frame.size.height
        }
    }
}
