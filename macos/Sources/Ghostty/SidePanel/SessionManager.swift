import Foundation

class SessionManager: ObservableObject {
    static let shared = SessionManager()

    @Published var sessions: [Session] = []

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

    func deleteSession(sessionId: UUID) {
        sessions.removeAll { $0.id == sessionId }
        saveSessions()
    }

    func session(for sessionId: UUID) -> Session? {
        sessions.first { $0.id == sessionId }
    }

    func navigateToSession(id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        // Phase 4 will implement actual Ghostty surface creation
        print("[SessionManager] Navigate to session: \(session.title)")
    }

    func unlinkSession(id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].surfaceId = nil
        saveSessions()
    }
}

private struct SessionsWrapper: Codable {
    let sessions: [Session]
}
