import Foundation
import SwiftUI
import Combine
import GhosttyKit

@MainActor
final class SidePanelViewModel: ObservableObject {
    @Published var isVisible: Bool = true

    /// Reference to the Ghostty app instance for creating splits
    private weak var ghosttyApp: Ghostty.App?

    init() {}

    /// Set the Ghostty app instance
    func setGhosttyApp(_ app: Ghostty.App) {
        self.ghosttyApp = app
    }

    // MARK: - Terminal Bridge

    func activate(_ session: Session) {
        print("[Kanban] activate session: \(session.title) (status: \(session.status.rawValue))")
        let newSplitId = createSplit(for: session)
        print("[Kanban] created new split: \(newSplitId)")
        if session.isWorkTree {
            createWorktree(name: session.branch)
        }
    }

    /// Create a new session and open it in a Ghostty split
    func createSessionAndOpenSplit(cwd: String, isWorkTree: Bool, worktreeName: String?) -> Session {
        // Create the session
        let session = SessionManager.shared.createSession(
            cwd: cwd,
            isWorktree: isWorkTree,
            worktreeName: worktreeName
        )

        // Create the split
        _ = createSplit(for: session)

        return session
    }

    private func createSplit(for session: Session) -> String {
        guard ghosttyApp != nil else {
            print("[Kanban] createSplit: no Ghostty app reference")
            return UUID().uuidString
        }

        // Post notification that TerminalController will handle
        NotificationCenter.default.post(
            name: .kanbanCreateSplit,
            object: nil,
            userInfo: ["sessionId": session.id]
        )

        return session.id.uuidString
    }

    private func createWorktree(name: String) {
        print("[Kanban] createWorktree(name: \(name)) - PENDING Ghostty API integration")
    }
}

// MARK: - Custom Notifications

extension Notification.Name {
    static let kanbanCreateSplit = Notification.Name("com.kanban.createSplit")
    static let kanbanCloseSurface = Notification.Name("kanbanCloseSurface")
    static let kanbanResumeSession = Notification.Name("kanbanResumeSession")
}
