import SwiftUI

/// Content for the status ring tooltip
struct StatusRingTooltipContent {
    let agentStatus: WorktreeAgentStatus?
    let prStatus: PRStatus?
    let ciState: CIState
}

/// Observable state for the status ring hover tooltip
/// Lives at the root level (TerminalWorkspaceView) to render outside sidebar clipping bounds
@MainActor
final class StatusRingTooltipState: ObservableObject {
    @Published var isVisible = false
    @Published var anchorRect: CGRect = .zero
    @Published var content: StatusRingTooltipContent?

    private var showTask: Task<Void, Never>?

    /// Schedule showing the tooltip after a delay
    func scheduleShow(anchor: CGRect, content: StatusRingTooltipContent, delay: TimeInterval = 0.4) {
        showTask?.cancel()
        showTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self.anchorRect = anchor
            self.content = content
            self.isVisible = true
        }
    }

    /// Hide the tooltip immediately
    func hide() {
        showTask?.cancel()
        showTask = nil
        isVisible = false
    }
}

// MARK: - Environment Key

private struct StatusRingTooltipStateKey: EnvironmentKey {
    static let defaultValue: StatusRingTooltipState? = nil
}

extension EnvironmentValues {
    var statusRingTooltipState: StatusRingTooltipState? {
        get { self[StatusRingTooltipStateKey.self] }
        set { self[StatusRingTooltipStateKey.self] = newValue }
    }
}
