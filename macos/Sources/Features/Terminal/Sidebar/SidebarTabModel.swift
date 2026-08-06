import AppKit
import Combine

/// One tab's live state, observed individually by its sidebar row.
///
/// Fine-grained models are the core of the sidebar's update strategy:
/// the list only publishes on membership/order changes, while title,
/// pwd, git and agent-state changes touch a single model — so a single
/// row re-renders instead of the whole list.
@MainActor
final class SidebarTabModel: ObservableObject, Identifiable {
    nonisolated let id: ObjectIdentifier
    unowned let window: NSWindow

    @Published private(set) var title: String = ""
    @Published private(set) var pwd: String?
    @Published private(set) var surfaceId: UUID?
    @Published private(set) var isSelected = false
    @Published private(set) var needsAttention = false
    @Published private(set) var gitBranch: String?
    @Published private(set) var repoRoot: String?
    @Published private(set) var agentState: AgentTabState?
    @Published private(set) var isDirty: Bool?
    @Published private(set) var prNumber: Int?
    @Published private(set) var prURL: String?

    var surfaceCancellables: Set<AnyCancellable> = []

    var directoryName: String? {
        guard let pwd, !pwd.isEmpty else { return nil }
        return (pwd as NSString).lastPathComponent
    }

    init(window: NSWindow) {
        self.id = ObjectIdentifier(window)
        self.window = window
    }

    /// Each setter publishes only on a real change, keeping row
    /// re-renders scoped to actual updates.

    func setTitle(_ value: String) {
        if title != value { title = value }
    }

    func setPwd(_ value: String?) {
        if pwd != value { pwd = value }
    }

    func setSurfaceId(_ value: UUID?) {
        if surfaceId != value { surfaceId = value }
    }

    func setSelected(_ value: Bool) {
        if isSelected != value { isSelected = value }
    }

    func setNeedsAttention(_ value: Bool) {
        if needsAttention != value { needsAttention = value }
    }

    func setGit(branch: String?, root: String?) {
        if gitBranch != branch { gitBranch = branch }
        if repoRoot != root { repoRoot = root }
    }

    func setAgentState(_ value: AgentTabState?) {
        if agentState != value { agentState = value }
    }

    func setRepoStatus(isDirty: Bool?, prNumber: Int?, prURL: String?) {
        if self.isDirty != isDirty { self.isDirty = isDirty }
        if self.prNumber != prNumber { self.prNumber = prNumber }
        if self.prURL != prURL { self.prURL = prURL }
    }
}
