import Foundation

/// Pollers need presence, not a full hook-version audit on the main thread.
/// Share one bounded background read across every terminal and split.
@MainActor
final class AgentHookPresenceCache {
    static let shared = AgentHookPresenceCache()
    private struct Entry {
        let value: Bool
        let checked: Date
    }
    private var entries: [SupportedAgent: Entry] = [:]
    private var pending: [SupportedAgent: UUID] = [:]
    private let maxAge: TimeInterval
    private let load: @Sendable (SupportedAgent) async -> Bool
    private var observer: NSObjectProtocol?

    init(maxAge: TimeInterval = 5,
         load: @escaping @Sendable (SupportedAgent) async -> Bool = { agent in
             await Task.detached(priority: .utility) {
                 AgentHookInstaller().isInstalled(agent)
             }.value
         }) {
        self.maxAge = maxAge
        self.load = load
        observer = NotificationCenter.default.addObserver(
            forName: AgentHookInstaller.didChangeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let agent = (notification.userInfo?[AgentHookInstaller.changedAgentUserInfoKey] as? String)
                .flatMap(SupportedAgent.init(rawValue:))
            MainActor.assumeIsolated { self?.invalidate(agent) }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Nil means the first read is pending; callers retry on their normal tick.
    func isInstalled(_ agent: SupportedAgent, now: Date = Date()) -> Bool? {
        if let entry = entries[agent], now.timeIntervalSince(entry.checked) < maxAge { return entry.value }
        if pending[agent] == nil {
            let token = UUID()
            pending[agent] = token
            let load = self.load
            Task { [weak self] in
                let value = await load(agent)
                guard let self, self.pending[agent] == token else { return }
                self.pending.removeValue(forKey: agent)
                self.entries[agent] = Entry(value: value, checked: now)
            }
        }
        return entries[agent]?.value
    }

    func invalidate(_ agent: SupportedAgent? = nil) {
        if let agent {
            entries.removeValue(forKey: agent)
            pending.removeValue(forKey: agent)
        } else {
            entries.removeAll()
            pending.removeAll()
        }
    }
}
