import Foundation
import SwiftUI
import Combine

@MainActor
final class SidePanelViewModel: ObservableObject {
    @Published var isVisible: Bool = true

    // MARK: - Terminal Bridge

    func activate(_ session: Session) {
        print("[Kanban] activate session: \(session.title) (status: \(session.status.rawValue))")
        let newSplitId = createSplit()
        print("[Kanban] created new split: \(newSplitId)")
        if session.isWorkTree {
            createWorktree(name: session.branch)
        }
    }

    private func createSplit() -> String {
        print("[Kanban] createSplit() - PENDING Ghostty API integration")
        return UUID().uuidString
    }

    private func createWorktree(name: String) {
        print("[Kanban] createWorktree(name: \(name)) - PENDING Ghostty API integration")
    }
}
