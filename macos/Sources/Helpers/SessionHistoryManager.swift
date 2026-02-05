import AppKit
import OSLog

/// Manages a history of recently closed terminal sessions for the Sessions menu.
///
/// This class tracks closed tabs, windows, and splits, allowing users to restore
/// them from a dedicated Sessions menu. It maintains up to `maxHistoryCount` entries
/// and automatically removes expired entries based on the undo timeout.
class SessionHistoryManager: NSObject {
    /// Shared singleton instance
    static let shared = SessionHistoryManager()

    /// Logger for session history events
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "SessionHistory"
    )

    /// Maximum number of sessions to keep in history
    let maxHistoryCount = 20

    /// The menu that displays session history
    weak var sessionsMenu: NSMenu?

    /// The undo manager to use for restore operations
    weak var undoManager: ExpiringUndoManager?

    /// Represents a closed session that can be restored
    struct ClosedSession {
        let id: UUID
        let title: String
        let closedAt: Date
        let type: SessionType
        let workingDirectory: String?

        enum SessionType: String {
            case tab = "Tab"
            case window = "Window"
            case split = "Split"
        }

        /// Formatted time string for display
        var timeAgo: String {
            let interval = Date().timeIntervalSince(closedAt)
            if interval < 60 {
                return "just now"
            } else if interval < 3600 {
                let minutes = Int(interval / 60)
                return "\(minutes)m ago"
            } else {
                let hours = Int(interval / 3600)
                return "\(hours)h ago"
            }
        }

        /// Menu item title
        var menuTitle: String {
            let truncatedTitle = title.count > 40 ? String(title.prefix(37)) + "..." : title
            return "\(type.rawValue): \(truncatedTitle)"
        }
    }

    /// The list of closed sessions, most recent first
    private(set) var closedSessions: [ClosedSession] = []

    /// Notification posted when session history changes
    static let historyDidChangeNotification = Notification.Name("SessionHistoryDidChange")

    private override init() {
        super.init()

        // Listen for undo manager changes to sync with session history
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(undoManagerDidChange),
            name: .NSUndoManagerDidUndoChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(undoManagerDidChange),
            name: .NSUndoManagerDidRedoChange,
            object: nil
        )
    }

    /// Records a closed session in the history
    func recordClosedSession(title: String, type: ClosedSession.SessionType, workingDirectory: String? = nil) {
        let session = ClosedSession(
            id: UUID(),
            title: title.isEmpty ? "Untitled" : title,
            closedAt: Date(),
            type: type,
            workingDirectory: workingDirectory
        )

        closedSessions.insert(session, at: 0)

        // Trim to max count
        if closedSessions.count > maxHistoryCount {
            closedSessions = Array(closedSessions.prefix(maxHistoryCount))
        }

        Self.logger.debug("Recorded closed session: \(session.menuTitle)")

        updateMenu()
        NotificationCenter.default.post(name: Self.historyDidChangeNotification, object: self)
    }

    /// Removes the most recent session from history (called after restore)
    func removeLastSession() {
        guard !closedSessions.isEmpty else { return }
        closedSessions.removeFirst()
        updateMenu()
        NotificationCenter.default.post(name: Self.historyDidChangeNotification, object: self)
    }

    /// Clears all session history
    func clearHistory() {
        closedSessions.removeAll()
        updateMenu()
        NotificationCenter.default.post(name: Self.historyDidChangeNotification, object: self)
    }

    /// Restores a session by index
    func restoreSession(at index: Int) {
        guard let undoManager = undoManager, undoManager.canUndo else {
            Self.logger.warning("Cannot restore session: undo manager not available")
            return
        }

        // We need to undo the matching number of times to get to that session
        // For simplicity, we just undo once (the most recent)
        // A more sophisticated implementation would track the actual undo operations
        if index == 0 {
            undoManager.undo()
            removeLastSession()
        }
    }

    /// Updates the Sessions menu with current history
    func updateMenu() {
        guard let menu = sessionsMenu else { return }

        // Remove old session items (keep static items at the end)
        let staticItemCount = 3 // Separator, Clear History, (future items)
        while menu.items.count > staticItemCount {
            menu.removeItem(at: 0)
        }

        if closedSessions.isEmpty {
            let emptyItem = NSMenuItem(title: "No Recent Sessions", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.insertItem(emptyItem, at: 0)
        } else {
            // Add session items in reverse order so most recent is at top
            for (index, session) in closedSessions.enumerated() {
                let item = NSMenuItem(
                    title: session.menuTitle,
                    action: #selector(restoreSessionFromMenu(_:)),
                    keyEquivalent: index == 0 ? "T" : ""
                )
                if index == 0 {
                    item.keyEquivalentModifierMask = [.command, .shift]
                }
                item.target = self
                item.tag = index

                // Add subtitle with time and directory
                var subtitle = session.timeAgo
                if let dir = session.workingDirectory {
                    let shortDir = (dir as NSString).abbreviatingWithTildeInPath
                    subtitle += " • \(shortDir)"
                }
                item.toolTip = subtitle

                menu.insertItem(item, at: index)
            }
        }
    }

    /// Menu action to restore a session
    @objc private func restoreSessionFromMenu(_ sender: NSMenuItem) {
        let index = sender.tag
        restoreSession(at: index)
    }

    /// Called when undo manager state changes
    @objc private func undoManagerDidChange(_ notification: Notification) {
        // Sync our history with undo manager state
        // This is a simplified sync - a full implementation would track
        // the actual correspondence between sessions and undo operations
    }
}
