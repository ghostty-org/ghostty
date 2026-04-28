import Foundation

class SessionManager: ObservableObject {
    static let shared = SessionManager()

    @Published var sessions: [Session] = []
    private let pendingSessionMatchWindow: TimeInterval = 30

    private let sessionsFileName = "sessions.json"

    private var sessionsFileURL: URL? {
        guard let configDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let ghosttyDir = configDir.appendingPathComponent("ghostty", isDirectory: true)
        return ghosttyDir.appendingPathComponent(sessionsFileName)
    }

    private init() {
        loadSessions()
    }

    func loadSessions() {
        guard let url = sessionsFileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            sessions = []
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(SessionsWrapper.self, from: data)
            sessions = decoded.sessions
        } catch {
            print("[SessionManager] Failed to load sessions: \(error)")
            sessions = []
        }
    }

    func saveSessions() {
        guard let url = sessionsFileURL else { return }

        do {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let wrapper = SessionsWrapper(sessions: sessions)
            let data = try JSONEncoder().encode(wrapper)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[SessionManager] Failed to save sessions: \(error)")
        }
    }

    func createSession(cwd: String, isWorktree: Bool, worktreeName: String?) -> Session {
        let session = Session(
            id: UUID(),
            title: "New Session",
            status: .running,
            timestamp: Date(),
            isWorkTree: isWorktree,
            branch: isWorktree ? (worktreeName ?? "main") : "main",
            sessionId: nil,
            surfaceId: nil,
            cwd: cwd
        )
        sessions.append(session)
        saveSessions()
        return session
    }

    func upsertSession(_ session: Session) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        saveSessions()
    }

    func linkSessionToSurface(sessionId: UUID, surfaceId: UInt64) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[index].surfaceId = surfaceId
        saveSessions()
    }

    func unlinkSurface(surfaceId: UInt64) {
        guard let index = sessions.firstIndex(where: { $0.surfaceId == surfaceId }) else { return }
        sessions[index].surfaceId = nil
        saveSessions()
    }

    func updateSessionStatus(sessionId: UUID, status: SessionStatus) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[index].status = status
        saveSessions()
    }

    func updateSession(
        localId: UUID,
        title: String? = nil,
        status: SessionStatus? = nil,
        timestamp: Date? = nil,
        sessionId: String? = nil,
        branch: String? = nil,
        isWorkTree: Bool? = nil
    ) {
        guard let index = sessions.firstIndex(where: { $0.id == localId }) else { return }

        if let title, !title.isEmpty {
            sessions[index].title = title
        }
        if let status {
            sessions[index].status = status
        }
        if let timestamp {
            sessions[index].timestamp = timestamp
        }
        if let sessionId, !sessionId.isEmpty {
            sessions[index].sessionId = sessionId
        }
        if let branch, !branch.isEmpty {
            sessions[index].branch = branch
        }
        if let isWorkTree {
            sessions[index].isWorkTree = isWorkTree
        }

        saveSessions()
    }

    func updateSession(from parsed: ParsedSession) {
        if let existing = sessions.first(where: { $0.sessionId == parsed.sessionId }) {
            updateSession(
                localId: existing.id,
                title: parsed.title,
                status: parsed.status,
                timestamp: parsed.timestamp,
                sessionId: parsed.sessionId,
                branch: parsed.branch,
                isWorkTree: parsed.isWorkTree
            )
            return
        }

        guard let pending = bestPendingSessionMatch(for: parsed) else { return }
        updateSession(
            localId: pending.id,
            title: parsed.title,
            status: parsed.status,
            timestamp: parsed.timestamp,
            sessionId: parsed.sessionId,
            branch: parsed.branch,
            isWorkTree: parsed.isWorkTree
        )
    }

    func session(forSurfaceId surfaceId: UInt64) -> Session? {
        sessions.first { $0.surfaceId == surfaceId }
    }

    func deleteSession(sessionId: UUID) {
        // Close surface if linked
        if let surfaceId = sessions.first(where: { $0.id == sessionId })?.surfaceId {
            NotificationCenter.default.post(
                name: .kanbanCloseSurface,
                object: nil,
                userInfo: ["surfaceId": surfaceId]
            )
        }
        sessions.removeAll { $0.id == sessionId }
        saveSessions()
    }

    func session(for sessionId: UUID) -> Session? {
        sessions.first { $0.id == sessionId }
    }

    func navigateToSession(id: UUID) {
        guard sessions.first(where: { $0.id == id }) != nil else { return }
        NotificationCenter.default.post(
            name: .kanbanResumeSession,
            object: nil,
            userInfo: ["sessionId": id]
        )
    }

    func unlinkSession(id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].surfaceId = nil
        saveSessions()
    }

    private func bestPendingSessionMatch(for parsed: ParsedSession) -> Session? {
        let cutoff = Date().addingTimeInterval(-pendingSessionMatchWindow)

        return sessions
            .filter {
                $0.sessionId == nil &&
                $0.timestamp >= cutoff &&
                ($0.isWorkTree == parsed.isWorkTree || !$0.isWorkTree || !parsed.isWorkTree)
            }
            .sorted { $0.timestamp > $1.timestamp }
            .first
    }
}

private struct SessionsWrapper: Codable {
    let sessions: [Session]
}
